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
        } else if !ImageDropExtractor.extractInMemory(from: pb).isEmpty {
            // `extractInMemory` is the disk-free probe — checks
            // pasteboard data slots only. The previous `extract`
            // call had a file-URL fallback that did
            // `Data(contentsOf:)` synchronously, which would have
            // stalled drag-enter if the user dragged a single
            // multi-MB image with no file URL on the pasteboard.
            // (Browser drags normally have only image data, no
            // URL — so the fallback would never have fired here in
            // practice, but using the disk-free probe keeps that
            // guarantee explicit.)
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

        // **Drop-smoothness fix.** The pasteboard is only readable
        // for the duration of `performDragOperation` — but disk
        // I/O against the URL slots (`Data(contentsOf:)` on each
        // image file the user dropped) is allowed to happen later
        // because the underlying files persist after the drag
        // session ends. Previously we read every dropped file
        // synchronously here on the main thread; for a multi-select
        // of large screenshots that stalled the panel for 200-500ms
        // (mouse release → image grid update). User reported "some
        // stiffness or lag while dropping something."
        //
        // New flow:
        //   1. Capture references off the pasteboard SYNCHRONOUSLY
        //      while it's still valid (URLs + in-memory image data
        //      slots — both are O(memcpy) fast)
        //   2. Return `true` immediately so the OS can finish the
        //      drag session and the panel UI is unblocked
        //   3. Read the file bytes on a background queue
        //   4. Dispatch the resolved data via the existing onImage
        //      / onFile / onVideo / onAirDrop callbacks on main
        //
        // The public callback contract is unchanged — same arguments,
        // same dispatch onto the main queue. Only the timing differs:
        // a few tens of ms later, but with no main-thread stall.
        let pb = sender.draggingPasteboard
        let pbUrls: [URL] = (pb.readObjects(forClasses: [NSURL.self]) as? [URL])?
            .filter { $0.isFileURL } ?? []
        let inMemoryImages: [(Data, String)] = ImageDropExtractor.extractInMemory(from: pb)
        let videoCandidate = VideoDropScanner.findCandidate(in: pb)
        let pbTypeNames = pb.types?.map { $0.rawValue } ?? []

        // Off-main routing — does the slow stuff (disk reads, temp-
        // file writes for AirDrop) on a background queue, then
        // dispatches the existing callbacks back to main.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.routeDropAsync(
                dropZone: dropZone,
                pbUrls: pbUrls,
                inMemoryImages: inMemoryImages,
                videoCandidate: videoCandidate,
                pbTypeNames: pbTypeNames
            )
        }

        // Returning true unconditionally — the routing above will
        // emit the appropriate callback (or log "no route" if the
        // pasteboard had nothing usable). False here would tell the
        // OS the drop failed and trigger the fly-back animation,
        // which would fight our async routing. Worst case (truly
        // empty pasteboard) is a silent drop; the dlog catches it.
        return true
    }

    /// Background-queue routing for a drop. Reads file bytes,
    /// materializes pasteboard image data to temp files (for AirDrop),
    /// and dispatches the appropriate callback back to main. Called
    /// once per `performDragOperation` from a `userInitiated` queue.
    private func routeDropAsync(
        dropZone: DropDestination,
        pbUrls: [URL],
        inMemoryImages: [(Data, String)],
        videoCandidate: VideoDropScanner.Candidate?,
        pbTypeNames: [String]
    ) {
        // AirDrop branch — pure send, no local save. We need real
        // file URLs for the share sheet; pasteboard image DATA gets
        // materialized to temp files here on the bg queue (writes
        // were one of the synchronous-main-thread offenders).
        if dropZone == .airDrop {
            var urls = pbUrls
            if urls.isEmpty {
                for (data, mime) in inMemoryImages {
                    if let tempURL = Self.materializeTempImage(data: data, mime: mime) {
                        urls.append(tempURL)
                    }
                }
            }
            if !urls.isEmpty {
                DictationOrchestrator.dlog("  ROUTE → onAirDrop (\(urls.count) URL(s))")
                DispatchQueue.main.async { [weak self] in self?.onAirDrop(urls) }
                return
            }
            DictationOrchestrator.dlog("  ⚠️ AirDrop zone hit but no usable URLs — falling through to save")
            // Fall through to save branches below.
        }

        // **Image FIRST.** Browser image drags (Chrome, Safari) put
        // BOTH the image bytes AND a source URL on the pasteboard.
        // Putting video before image made VideoDropScanner catch the
        // URL and treat the drop as a remote-video candidate, which
        // dropped the image data on the floor. (User: "no photo is
        // saving to the thing.")
        //
        // We resolve images in two passes:
        //   1. File URLs that point to images — read off this bg
        //      queue with `Data(contentsOf:)`, one read per file
        //   2. In-memory pasteboard image data — already captured
        //      synchronously upstream, just pass through
        var images: [(Data, String)] = []
        for url in pbUrls {
            let ext = url.pathExtension.lowercased()
            guard ImageDropExtractor.imageExts.contains(ext) else { continue }
            if let data = try? Data(contentsOf: url) {
                images.append((data, ImageDropExtractor.mime(forExt: ext)))
            }
        }
        if images.isEmpty { images = inMemoryImages }

        if !images.isEmpty {
            DictationOrchestrator.dlog("  ROUTE → onImage ×\(images.count)")
            DispatchQueue.main.async { [weak self] in
                for (data, mime) in images {
                    self?.onImage(data, mime)
                }
            }
            return
        }
        // Video — local video file URL or a remote video URL
        // (YouTube, Vimeo, etc.). Captured synchronously upstream
        // because the scanner needs pasteboard access; we just
        // dispatch here.
        if let candidate = videoCandidate {
            DictationOrchestrator.dlog("  ROUTE → onVideo")
            DispatchQueue.main.async { [weak self] in self?.onVideo(candidate) }
            return
        }
        // Generic file URLs — falls through to the Files tab as a
        // pure staging operation (we never copy the file, just hold
        // the URL). Anything that wasn't an image or video lands here.
        if !pbUrls.isEmpty {
            DictationOrchestrator.dlog("  ROUTE → onFile (\(pbUrls.count) URL(s))")
            DispatchQueue.main.async { [weak self] in self?.onFile(pbUrls) }
            return
        }
        DictationOrchestrator.dlog("  ⚠️ NO ROUTE — pasteboard had no recognizable type; types=\(pbTypeNames)")
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
        let name = "nox-AirDrop-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8)).\(ext)"
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
    /// Pasteboard image data ONLY — no file URL fallback, so this
    /// never touches disk. Used by the drop hot-path so that a
    /// quick probe ("does the pb have any image bytes?") finishes
    /// in microseconds even when the user is dragging a hefty
    /// image. Returns every image data slot found (PNG, JPEG, GIF,
    /// WebP, TIFF) — usually 0 or 1 entries since pasteboards
    /// hold one image data slot, but designed array-shaped to match
    /// `extractAll`'s signature for caller convenience.
    static func extractInMemory(from pb: NSPasteboard) -> [(Data, String)] {
        var images: [(Data, String)] = []
        if let png = pb.data(forType: .png) {
            images.append((png, "image/png"))
        } else if let jpeg = pb.data(forType: NSPasteboard.PasteboardType("public.jpeg")) {
            images.append((jpeg, "image/jpeg"))
        } else if let gif = pb.data(forType: NSPasteboard.PasteboardType("com.compuserve.gif")) {
            images.append((gif, "image/gif"))
        } else if let webp = pb.data(forType: NSPasteboard.PasteboardType("org.webmproject.webp")) {
            images.append((webp, "image/webp"))
        } else if let tiff = pb.data(forType: .tiff) {
            // TIFF passes through raw; the save path handles
            // conversion off-main. Same reason as `extract` below.
            images.append((tiff, "image/tiff"))
        }
        return images
    }

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

    /// Image-file extensions the extractor recognizes. Internal
    /// (not private) so the off-main drop router in PanelDropContainer
    /// can iterate file URLs and pick out images without duplicating
    /// the list.
    static let imageExts: Set<String> = [
        "png", "jpg", "jpeg", "gif", "tiff", "tif", "webp", "heic", "bmp"
    ]

    /// MIME type for a file extension. Internal so the off-main
    /// drop router can stamp the right MIME on file-loaded images.
    static func mime(forExt ext: String) -> String {
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
