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

    init(
        hosting: NSView,
        onVideo: @escaping (VideoDropScanner.Candidate) -> Void,
        onImage: @escaping (Data, String) -> Void,
        onFile: @escaping ([URL]) -> Void,
        onTargeted: @escaping (Bool) -> Void
    ) {
        self.onVideo = onVideo
        self.onImage = onImage
        self.onFile = onFile
        self.onTargeted = onTargeted
        super.init(frame: .zero)
        autoresizesSubviews = true
        addSubview(hosting)
        hosting.autoresizingMask = [.width, .height]
        hosting.frame = bounds
        registerForDraggedTypes(Self.allTypes)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        DispatchQueue.main.async { [weak self] in self?.onTargeted(true) }
        return .copy
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func draggingExited(_ sender: NSDraggingInfo?) {
        DispatchQueue.main.async { [weak self] in self?.onTargeted(false) }
    }
    override func draggingEnded(_ sender: NSDraggingInfo) {
        DispatchQueue.main.async { [weak self] in self?.onTargeted(false) }
    }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        DispatchQueue.main.async { [weak self] in self?.onTargeted(false) }
        let pb = sender.draggingPasteboard

        // Video first — it's the most specific signal. A YouTube link
        // pasted as plain text would also match the image-data path
        // below if we didn't lead with the video scanner.
        if let candidate = VideoDropScanner.findCandidate(in: pb) {
            NSLog("Notetaker: drop → video candidate")
            DispatchQueue.main.async { [weak self] in self?.onVideo(candidate) }
            return true
        }
        // Image next — png/tiff/jpeg directly on the pasteboard, or a
        // file URL pointing at an image extension.
        if let (data, mime) = ImageDropExtractor.extract(from: pb) {
            NSLog("Notetaker: drop → image (\(mime), \(data.count) bytes)")
            DispatchQueue.main.async { [weak self] in self?.onImage(data, mime) }
            return true
        }
        // Generic file URLs — falls through to the Files tab as a
        // pure staging operation (we never copy the file, just hold
        // the URL). Anything that wasn't a video or image goes here.
        if let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL] {
            let fileUrls = urls.filter { $0.isFileURL }
            if !fileUrls.isEmpty {
                NSLog("Notetaker: drop → \(fileUrls.count) file(s)")
                DispatchQueue.main.async { [weak self] in self?.onFile(fileUrls) }
                return true
            }
        }
        NSLog("Notetaker: drop → no candidate, rejecting; types=\(pb.types ?? [])")
        return false
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
        // TIFF is what most browser drags come through as — convert to PNG
        // before storing so the rest of the app deals with one less codec.
        if let tiff = pb.data(forType: .tiff),
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            return (png, "image/png")
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
