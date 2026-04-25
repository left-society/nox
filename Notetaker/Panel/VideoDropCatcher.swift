import SwiftUI
import AppKit

/// NSView-backed drop zone that inspects the full drag pasteboard (not just
/// the SwiftUI-exposed UTTypes), so we can pull the source page URL out of
/// browser-internal types like `org.chromium.source-url` and
/// `WebURLsWithTitlesPboardType`.
struct VideoDropCatcher: NSViewRepresentable {
    @Binding var isTargeted: Bool
    let onCandidate: (VideoDropScanner.Candidate) -> Void

    func makeNSView(context: Context) -> DropView {
        let v = DropView()
        v.parent = self
        return v
    }

    func updateNSView(_ nsView: DropView, context: Context) {
        nsView.parent = self
    }

    final class DropView: NSView {
        var parent: VideoDropCatcher?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            var types: [NSPasteboard.PasteboardType] = [
                .URL, .fileURL, .string, .html,
                VideoDropScanner.urlType,
                VideoDropScanner.chromeSourceURL,
                VideoDropScanner.webURLsWithTitles,
                VideoDropScanner.htmlType
            ]
            types.append(contentsOf: VideoDropScanner.movieTypes)
            registerForDraggedTypes(types)
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
            guard let candidate = VideoDropScanner.findCandidate(in: sender.draggingPasteboard) else {
                return false
            }
            DispatchQueue.main.async { [weak self] in
                self?.parent?.onCandidate(candidate)
            }
            return true
        }
    }
}
