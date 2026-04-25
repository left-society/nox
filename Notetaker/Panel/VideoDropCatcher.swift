import SwiftUI
import AppKit

/// Panel-wide smart drop zone. Inspects the full drag pasteboard (not just
/// the SwiftUI-exposed UTTypes), decides whether the drag is a video, an
/// image, or neither, and routes to the right callback. Lives at
/// PanelRootView level so the user can drop onto any tab — the panel
/// switches to the destination tab on drop instead of silently rejecting
/// the drag.
///
/// Filename kept as VideoDropCatcher.swift to avoid pbxproj churn; the
/// struct itself is `PanelDropCatcher`.
struct PanelDropCatcher: NSViewRepresentable {
    @Binding var isTargeted: Bool
    let onVideo: (VideoDropScanner.Candidate) -> Void
    let onImage: (Data, String) -> Void

    func makeNSView(context: Context) -> DropView {
        let v = DropView()
        v.parent = self
        return v
    }

    func updateNSView(_ nsView: DropView, context: Context) {
        nsView.parent = self
    }

    final class DropView: NSView {
        var parent: PanelDropCatcher?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            registerForDraggedTypes(Self.allTypes)
        }
        required init?(coder: NSCoder) { fatalError() }

        // Mouse events fall through to SwiftUI beneath; drag-destination
        // routing uses a separate path and still reaches this view.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            DispatchQueue.main.async { [weak self] in self?.parent?.isTargeted = true }
            return .copy
        }
        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
        override func draggingExited(_ sender: NSDraggingInfo?) {
            DispatchQueue.main.async { [weak self] in self?.parent?.isTargeted = false }
        }
        override func draggingEnded(_ sender: NSDraggingInfo) {
            DispatchQueue.main.async { [weak self] in self?.parent?.isTargeted = false }
        }
        override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            DispatchQueue.main.async { [weak self] in self?.parent?.isTargeted = false }
            let pb = sender.draggingPasteboard

            // Video first — it's the most specific signal. A YouTube link
            // pasted as plain text would also match the image-data path
            // below if we didn't lead with the video scanner.
            if let candidate = VideoDropScanner.findCandidate(in: pb) {
                NSLog("Notetaker: drop → video candidate")
                DispatchQueue.main.async { [weak self] in self?.parent?.onVideo(candidate) }
                return true
            }
            // Image next — png/tiff/jpeg directly on the pasteboard, or a
            // file URL pointing at an image extension.
            if let (data, mime) = ImageDropExtractor.extract(from: pb) {
                NSLog("Notetaker: drop → image (\(mime), \(data.count) bytes)")
                DispatchQueue.main.async { [weak self] in self?.parent?.onImage(data, mime) }
                return true
            }
            NSLog("Notetaker: drop → no candidate, rejecting")
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
}

/// Pulls image data off a pasteboard the way ImagesGridView's old SwiftUI
/// .onDrop used to — direct PNG/JPEG/GIF/WebP, TIFF converted to PNG, or
/// a file URL with an image extension. Splits the dance out of
/// PanelDropCatcher so the catcher stays focused on routing.
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
