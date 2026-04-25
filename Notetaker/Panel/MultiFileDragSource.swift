import AppKit
import SwiftUI

final class MultiFileDragSourceNSView: NSView, NSDraggingSource {
    var fileURLs: [URL] = []
    /// Optional per-file image to show while dragging. When nil we fall back
    /// to `NSImage(contentsOf:)` on the file itself. For images that works;
    /// for videos it returns a blank `NSImage`, so callers pass the
    /// generated thumbnail URL here to make drags feel satisfying.
    var dragImageURLs: [URL] = []
    var onClick: (() -> Void)?
    private var mouseDownPoint: NSPoint?
    private var didDrag = false

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        [.copy]
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        fileURLs.isEmpty ? nil : self
    }

    override func resetCursorRects() {
        // Telegraph that the cell does something when clicked — the pointing
        // hand shows up automatically over everything tappable on macOS.
        if !fileURLs.isEmpty, onClick != nil {
            addCursorRect(bounds, cursor: .pointingHand)
        }
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = event.locationInWindow
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !fileURLs.isEmpty, let start = mouseDownPoint else { return }
        let dx = event.locationInWindow.x - start.x
        let dy = event.locationInWindow.y - start.y
        guard dx * dx + dy * dy > 16 else { return }
        didDrag = true
        mouseDownPoint = nil

        let items: [NSDraggingItem] = fileURLs.enumerated().map { idx, url in
            let pbItem = NSPasteboardItem()
            pbItem.setString(url.absoluteString, forType: .fileURL)
            let item = NSDraggingItem(pasteboardWriter: pbItem)
            let thumbURL = idx < dragImageURLs.count ? dragImageURLs[idx] : nil
            let image: NSImage
            if let thumbURL, let thumb = NSImage(contentsOf: thumbURL) {
                image = thumb
            } else {
                image = NSImage(contentsOf: url) ?? NSImage()
            }
            let maxSide: CGFloat = 64
            var size = image.size
            if size.width == 0 || size.height == 0 { size = NSSize(width: maxSide, height: maxSide) }
            let scale = min(maxSide / size.width, maxSide / size.height, 1)
            let thumbSize = NSSize(width: size.width * scale, height: size.height * scale)
            let origin = NSPoint(
                x: bounds.midX - thumbSize.width / 2 + CGFloat(idx - fileURLs.count / 2) * 8,
                y: bounds.midY - thumbSize.height / 2 + CGFloat(idx - fileURLs.count / 2) * 3
            )
            item.setDraggingFrame(NSRect(origin: origin, size: thumbSize), contents: image)
            return item
        }

        beginDraggingSession(with: items, event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        // A mouseDown that never escaped the drag threshold is a tap. The
        // drag source sits on top of SwiftUI in the z-order and swallows
        // hit-tests, so SwiftUI's .onTapGesture never sees the click —
        // surfacing it here is the only way to play the video on click.
        let wasTap = !didDrag && mouseDownPoint != nil
        mouseDownPoint = nil
        didDrag = false
        if wasTap { onClick?() }
    }
}

struct MultiFileDragSource: NSViewRepresentable {
    let fileURLs: [URL]
    var dragImageURLs: [URL] = []
    var onClick: (() -> Void)? = nil

    func makeNSView(context: Context) -> MultiFileDragSourceNSView {
        MultiFileDragSourceNSView()
    }

    func updateNSView(_ nsView: MultiFileDragSourceNSView, context: Context) {
        nsView.fileURLs = fileURLs
        nsView.dragImageURLs = dragImageURLs
        nsView.onClick = onClick
    }
}
