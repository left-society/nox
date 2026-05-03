import AppKit
import SwiftUI

/// Panel-wide smart drop zone. Sits at the NSPanel contentView level so
/// it captures drags before any SwiftUI hit-testing happens — earlier
/// attempts to do this via a `.overlay(NSViewRepresentable)` failed
/// because returning `nil` from `hitTest` (needed to let mouse events
/// fall through to SwiftUI) also disables AppKit's drag-destination
/// routing for that view.
///
/// Inspects the full drag pasteboard (not just the SwiftUI-exposed
/// UTTypes), decides whether the drag is a video, an image, or neither,
/// and routes to the right callback. Hosted SwiftUI tree sits as a
/// subview — drag types it doesn't register for fall through to us.
///
/// Filename kept as VideoDropCatcher.swift to avoid pbxproj churn.
final class PanelDropContainer: NSView {
    let onVideo: (VideoDropScanner.Candidate) -> Void
    let onImage: (Data, String) -> Void
    let onFile: ([URL]) -> Void
    let onTargeted: (Bool) -> Void
    /// File count on the in-flight drag, reported once on
    /// `draggingEntered`. The DropPickerView shows this as a
    /// "✈ N" badge in the AirDrop zone so the user gets a
    /// visual confirmation that the whole batch was picked up
    /// before they release.
    let onFileCount: (Int) -> Void
    /// Two-zone drop picker hover callback. Fires every time the
    /// cursor moves between the left (Save) and right (AirDrop)
    /// halves of the panel during a drag, so the SwiftUI overlay
    /// can highlight the hot zone in real time. nil = cursor is
    /// outside the panel (drag exited or just hasn't entered yet).
    let onZoneHover: (DropDestination?) -> Void
    /// AirDrop dispatch. Fires on `performDragOperation` only when
    /// the drop landed in the right (AirDrop) zone. Receives the
    /// extracted file URLs (or temp-file URLs for pasteboard image
    /// data) — caller is responsible for invoking the share sheet.
    let onAirDrop: ([URL]) -> Void

    /// Debounce token for the "drag exited" signal. AppKit fires
    /// `draggingExited` whenever the panel's frame changes during
    /// a drag — and the auto-open-on-drag-enter behavior triggers
    /// a slab expansion that DOES change the frame. Result: rapid
    /// `enter → exit → enter → exit` cycles where the user is
    /// actually still hovering. Each toggle flashes the drop ring
    /// on/off; the user sees a glitching halo.
    ///
    /// We debounce the false-flip by 180ms. If `draggingEntered`
    /// fires within the window, we cancel the pending exit. This
    /// keeps `isDropTargeted` stable through frame-morph noise so
    /// the breathing animation can run smoothly.
    private var exitDebounceWorkItem: DispatchWorkItem?

    init(
        hosting: NSView,
        onVideo: @escaping (VideoDropScanner.Candidate) -> Void,
        onImage: @escaping (Data, String) -> Void,
        onFile: @escaping ([URL]) -> Void,
        onTargeted: @escaping (Bool) -> Void,
        onZoneHover: @escaping (DropDestination?) -> Void,
        onAirDrop: @escaping ([URL]) -> Void,
        onFileCount: @escaping (Int) -> Void = { _ in }
    ) {
        self.onVideo = onVideo
        self.onImage = onImage
        self.onFile = onFile
        self.onTargeted = onTargeted
        self.onZoneHover = onZoneHover
        self.onAirDrop = onAirDrop
        self.onFileCount = onFileCount
        super.init(frame: .zero)
        autoresizesSubviews = true
        addSubview(hosting)
        hosting.autoresizingMask = [.width, .height]
        hosting.frame = bounds
        registerForDraggedTypes(Self.allTypes)
    }

    /// Compute which zone (left=save / right=airdrop) the cursor is
    /// currently over. Splits the panel down the middle. Returns
    /// `.save` for x < midX, `.airDrop` for x ≥ midX.
    private func zoneAt(point: NSPoint) -> DropDestination {
        return point.x < bounds.midX ? .save : .airDrop
    }

    /// Most recent hovered zone — kept so we can route the eventual
    /// drop based on where the cursor was when the user released,
    /// without re-querying NSPasteboard for cursor position.
    private var lastHoveredZone: DropDestination = .save

    required init?(coder: NSCoder) { fatalError() }

    /// Accept clicks/drags BEFORE the panel becomes key. The panel is
    /// `.nonactivatingPanel` so it never auto-activates on click; without
    /// this override, the FIRST mousedown gets eaten as an "activate
    /// the window" event and never reaches the SwiftUI gesture
    /// recognizers below. User reported: "And i can't move that progress
    /// bar" — exactly this. Returning true delivers every click/drag
    /// straight through to SwiftUI gestures, no activation step.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        DictationOrchestrator.dlog("🟢 draggingEntered loc=\(sender.draggingLocation) bounds=\(bounds)")
        // Cancel any pending exit-debounce — we're back inside.
        exitDebounceWorkItem?.cancel()
        exitDebounceWorkItem = nil
        let local = convert(sender.draggingLocation, from: nil)
        let zone = zoneAt(point: local)
        lastHoveredZone = zone
        // Snapshot the dragged file count for the AirDrop zone
        // badge. Two cases:
        //   1. Pasteboard has file URLs (Finder drag, multi-select)
        //      → count = number of URLs.
        //   2. Pasteboard has only image data (browser image drag)
        //      → count = 1, since there's exactly one image.
        let pb = sender.draggingPasteboard
        let urlCount = (pb.readObjects(forClasses: [NSURL.self]) as? [URL])?
            .filter { $0.isFileURL }.count ?? 0
        let count: Int
        if urlCount > 0 {
            count = urlCount
        } else if ImageDropExtractor.extract(from: pb) != nil {
            count = 1
        } else {
            count = 0
        }
        DispatchQueue.main.async { [weak self] in
            self?.onTargeted(true)
            self?.onZoneHover(zone)
            self?.onFileCount(count)
        }
        return .copy
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        // Track which side of the panel the cursor is on so the
        // SwiftUI overlay can highlight the hot zone in real time.
        let local = convert(sender.draggingLocation, from: nil)
        let zone = zoneAt(point: local)
        if zone != lastHoveredZone {
            lastHoveredZone = zone
            DispatchQueue.main.async { [weak self] in self?.onZoneHover(zone) }
        }
        return .copy
    }
    override func draggingExited(_ sender: NSDraggingInfo?) {
        DictationOrchestrator.dlog("🔴 draggingExited (debouncing)")
        // Don't flip targeted=false instantly. AppKit fires
        // draggingExited spuriously when the panel resizes mid-drag
        // (slab expansion = frame change = drag-tracking re-eval =
        // exit/enter cycle). Schedule the false-flip 180ms out; if
        // draggingEntered fires before then, the work item is
        // cancelled and the user never sees the flicker.
        exitDebounceWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            DictationOrchestrator.dlog("🔴 exit debounce committed — onTargeted(false)")
            self?.onTargeted(false)
            self?.onZoneHover(nil)
            self?.onFileCount(0)
        }
        exitDebounceWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
    }
    override func draggingEnded(_ sender: NSDraggingInfo) {
        DictationOrchestrator.dlog("🟡 draggingEnded")
        // Drag ended for real (release happened OR cursor really
        // left). Cancel any pending debounce — fire false NOW.
        exitDebounceWorkItem?.cancel()
        exitDebounceWorkItem = nil
        DispatchQueue.main.async { [weak self] in
            self?.onTargeted(false)
            self?.onZoneHover(nil)
            self?.onFileCount(0)
        }
    }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        DictationOrchestrator.dlog("🟣 prepareForDragOperation")
        return true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        DictationOrchestrator.dlog("✅ performDragOperation FIRED loc=\(sender.draggingLocation) zone=\(lastHoveredZone)")
        // Capture the dropped zone before clearing target state.
        let local = convert(sender.draggingLocation, from: nil)
        let dropZone = zoneAt(point: local)
        DispatchQueue.main.async { [weak self] in
            self?.onTargeted(false)
            self?.onZoneHover(nil)
        }
        let pb = sender.draggingPasteboard

        // AirDrop branch — pure send, no local save. Pull file URLs
        // directly from the pasteboard (Finder drags, Notetaker
        // re-drags) and hand them to the share-sheet caller. For
        // pasteboard image DATA without a backing URL (browser
        // image drag), materialize it to a temp file first so
        // AirDrop has something to send.
        if dropZone == .airDrop {
            var urls: [URL] = []
            if let pbUrls = pb.readObjects(forClasses: [NSURL.self]) as? [URL] {
                urls.append(contentsOf: pbUrls.filter { $0.isFileURL })
            }
            // Multi-image fallback: when there are no file URLs (raw
            // pasteboard image data, e.g. from a browser drag),
            // materialize EVERY extractable image to its own temp
            // file so AirDrop has the full set. Previously only the
            // first image got materialized — same root bug as the
            // save path.
            if urls.isEmpty {
                let images = ImageDropExtractor.extractAll(from: pb)
                for (data, mime) in images {
                    if let tempURL = Self.materializeTempImage(data: data, mime: mime) {
                        urls.append(tempURL)
                    }
                }
            }
            if !urls.isEmpty {
                DictationOrchestrator.dlog("  ROUTE → onAirDrop (\(urls.count) URL(s))")
                DispatchQueue.main.async { [weak self] in self?.onAirDrop(urls) }
                return true
            }
            DictationOrchestrator.dlog("  ⚠️ AirDrop zone hit but no usable URLs — falling through to save")
            // Fall through to save below if there's nothing AirDrop can take.
        }

        // **Image FIRST.** Browser image drags (Chrome, Safari) put
        // BOTH the image bytes AND a source URL on the pasteboard.
        // The previous ordering (video first) made VideoDropScanner
        // catch the URL and treat the drop as a "remote video
        // candidate" — image data was discarded, photo never
        // saved. User reported: "no photo is saving to the thing."
        //
        // Image extraction only succeeds when there's actual image
        // DATA on the pasteboard (PNG / TIFF / JPEG / WebP / GIF /
        // image file URL). A plain video file URL or a YouTube link
        // has no image data so it falls through cleanly to the
        // video branch below.
        // Multi-image extract — when Finder hands us 8 selected
        // images, all 8 land. The previous `extract` returned just
        // one and silently dropped the rest. Each image fires its
        // own `onImage` callback so the existing single-image save
        // pipeline stays unchanged downstream — we just call it N
        // times instead of once.
        let images = ImageDropExtractor.extractAll(from: pb)
        if !images.isEmpty {
            DictationOrchestrator.dlog("  ROUTE → onImage ×\(images.count)")
            DispatchQueue.main.async { [weak self] in
                for (data, mime) in images {
                    self?.onImage(data, mime)
                }
            }
            return true
        }
        // Video next — local video file URL or a remote video URL
        // (YouTube, Vimeo, etc.). Reads the URL slot only after we've
        // ruled out image data.
        if let candidate = VideoDropScanner.findCandidate(in: pb) {
            DictationOrchestrator.dlog("  ROUTE → onVideo")
            DispatchQueue.main.async { [weak self] in self?.onVideo(candidate) }
            return true
        }
        // Generic file URLs — falls through to the Files tab as a
        // pure staging operation (we never copy the file, just hold
        // the URL). Anything that wasn't an image or video goes here.
        if let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL] {
            let fileUrls = urls.filter { $0.isFileURL }
            if !fileUrls.isEmpty {
                DictationOrchestrator.dlog("  ROUTE → onFile (\(fileUrls.count) URL(s))")
                DispatchQueue.main.async { [weak self] in self?.onFile(fileUrls) }
                return true
            }
        }
        DictationOrchestrator.dlog("  ⚠️ NO ROUTE — pasteboard had no recognizable type; types=\(pb.types?.map { $0.rawValue } ?? [])")
        return false
    }

    /// Write pasteboard image data to a temp file so AirDrop has a
    /// real URL to send. Browser image drags don't carry a file URL,
    /// only raw bytes — AirDrop's share service requires file URLs.
    /// Filename is derived from the MIME type's primary extension;
    /// the file lives in NSTemporaryDirectory and is left for the
    /// system to clean up (it's tiny and AirDrop only needs it long
    /// enough to send).
    static func materializeTempImage(data: Data, mime: String) -> URL? {
        let ext: String
        switch mime {
        case "image/png": ext = "png"
        case "image/jpeg": ext = "jpg"
        case "image/gif": ext = "gif"
        case "image/webp": ext = "webp"
        case "image/heic": ext = "heic"
        default: ext = "img"
        }
        // UUID suffix ensures collision-free names when multiple
        // images are materialized in the same second (multi-image
        // browser drag → AirDrop). The previous timestamp-only name
        // would have N images all overwrite the same path; AirDrop
        // would only receive the last write.
        let name = "Notetaker-AirDrop-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8)).\(ext)"
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(name)
        do {
            try data.write(to: url)
            return url
        } catch {
            DictationOrchestrator.dlog("⚠️ materializeTempImage failed: \(error)")
            return nil
        }
    }

    private static var allTypes: [NSPasteboard.PasteboardType] {
        var types: [NSPasteboard.PasteboardType] = [
            .URL, .fileURL, .string, .html,
            .png, .tiff,
            NSPasteboard.PasteboardType("public.image"),
            NSPasteboard.PasteboardType("public.jpeg"),
            NSPasteboard.PasteboardType("com.compuserve.gif"),
            NSPasteboard.PasteboardType("org.webmproject.webp"),
            VideoDropScanner.urlType,
            VideoDropScanner.chromeSourceURL,
            VideoDropScanner.webURLsWithTitles,
            VideoDropScanner.htmlType
        ]
        types.append(contentsOf: VideoDropScanner.movieTypes)
        return types
    }
}

/// Pulls image data off a pasteboard the way ImagesGridView's old SwiftUI
/// .onDrop used to — direct PNG/JPEG/GIF/WebP, TIFF converted to PNG, or
/// a file URL with an image extension. Splits the dance out of
/// PanelDropContainer so the catcher stays focused on routing.
enum ImageDropExtractor {
    static func extract(from pb: NSPasteboard) -> (Data, String)? {
        if let png = pb.data(forType: .png) {
            return (png, "image/png")
        }
        if let jpeg = pb.data(forType: NSPasteboard.PasteboardType("public.jpeg")) {
            return (jpeg, "image/jpeg")
        }
        if let gif = pb.data(forType: NSPasteboard.PasteboardType("com.compuserve.gif")) {
            return (gif, "image/gif")
        }
        if let webp = pb.data(forType: NSPasteboard.PasteboardType("org.webmproject.webp")) {
            return (webp, "image/webp")
        }
        // TIFF — pass through raw. The previous code converted TIFF
        // to PNG synchronously here, which on the main thread was
        // 20-50ms for a screenshot-sized image (and worse for big
        // browser drags). The save path runs off-main and handles
        // TIFF natively, so pushing the conversion downstream
        // unblocks the drop UI immediately.
        if let tiff = pb.data(forType: .tiff) {
            return (tiff, "image/tiff")
        }
        // File URL fallback — a screenshot dragged from Finder, or any image
        // file the user tossed at us.
        if let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL] {
            for url in urls where url.isFileURL {
                let ext = url.pathExtension.lowercased()
                if Self.imageExts.contains(ext),
                   let data = try? Data(contentsOf: url) {
                    return (data, mime(forExt: ext))
                }
            }
        }
        return nil
    }

    /// Multi-image variant of `extract`. Used when the user drops
    /// MULTIPLE images at once — Finder multi-select, an image
    /// folder, multi-select from Photos. The original single-image
    /// path was the actual save bug the user reported: pasteboard
    /// might contain 8 file URLs but only one was saved.
    ///
    /// Order of precedence:
    /// 1. **All file URLs with image extensions** — handles Finder
    ///    multi-select cleanly, one entry per file.
    /// 2. **Single in-memory image data** (PNG / JPEG / GIF / WebP /
    ///    TIFF) — pasteboards from browser drags carry only one
    ///    image data slot, so this stays a singleton even in the
    ///    array form.
    static func extractAll(from pb: NSPasteboard) -> [(Data, String)] {
        // Multi-file path first — if Finder hands us a stack of
        // image URLs, every one of them should land. Iterating
        // returns ALL matches rather than the previous bug where
        // we returned the first hit and dropped the rest.
        if let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL] {
            var images: [(Data, String)] = []
            for url in urls where url.isFileURL {
                let ext = url.pathExtension.lowercased()
                guard Self.imageExts.contains(ext),
                      let data = try? Data(contentsOf: url) else { continue }
                images.append((data, mime(forExt: ext)))
            }
            if !images.isEmpty { return images }
        }
        // Fall back to the single in-memory data path.
        if let single = extract(from: pb) {
            return [single]
        }
        return []
    }

    private static let imageExts: Set<String> = [
        "png", "jpg", "jpeg", "gif", "tiff", "tif", "webp", "heic", "bmp"
    ]

    private static func mime(forExt ext: String) -> String {
        switch ext {
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "tiff", "tif": return "image/tiff"
        case "heic": return "image/heic"
        case "bmp": return "image/bmp"
        default: return "image/png"
        }
    }
}
