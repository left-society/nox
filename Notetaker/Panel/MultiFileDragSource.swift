import AppKit
import SwiftUI

final class MultiFileDragSourceNSView: NSView, NSDraggingSource {
    var fileURLs: [URL] = []
    /// Optional per-file image to show while dragging. When nil we fall back
    /// to `NSImage(contentsOf:)` on the file itself. For images that works;
    /// for videos it returns a blank `NSImage`, so callers pass the
    /// generated thumbnail URL here to make drags feel satisfying.
    var dragImageURLs: [URL] = [] {
        didSet {
            // Preload the drag previews in the background as soon as the
            // URL list changes. Drag preview images MUST be available
            // synchronously when `beginDraggingSession` runs — there's
            // no async API for them — so any I/O here would happen on
            // the main thread at drag-start and freeze the panel for a
            // visible beat. Pre-warming a small in-memory cache means
            // drag-start is a O(1) dictionary lookup.
            preloadDragImages(urls: dragImageURLs)
        }
    }
    var onClick: (() -> Void)?
    private var mouseDownPoint: NSPoint?
    private var didDrag = false

    /// In-memory drag-preview cache keyed by source URL. Populated by
    /// `preloadDragImages` on a background queue; consumed
    /// synchronously by `mouseDragged`. Capped via NSCache so a long
    /// scroll over thousands of cells doesn't blow memory.
    private static let dragImageCache: NSCache<NSURL, NSImage> = {
        let c = NSCache<NSURL, NSImage>()
        c.countLimit = 200
        return c
    }()

    /// Background queue for loading + decoding drag preview images.
    /// Userland priority: this work is for an upcoming drag, but we
    /// don't want it to compete with the panel's animation runloop.
    private static let preloadQueue: DispatchQueue = {
        DispatchQueue(label: "nox.MultiFileDragSource.preload",
                      qos: .userInitiated,
                      attributes: .concurrent)
    }()

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
            // Thumbnail lookup is now O(1) — no disk reads on the main
            // thread. If the cache miss (which happens only for the
            // very first drag of a freshly-mounted cell), fall back to
            // an empty NSImage and let macOS substitute its own file-
            // icon preview. That's preferable to a 30-80ms freeze for
            // every drag; the next drag will be cached and beautiful.
            let thumbURL = idx < dragImageURLs.count ? dragImageURLs[idx] : nil
            let image: NSImage = {
                if let thumbURL,
                   let cached = Self.dragImageCache.object(forKey: thumbURL as NSURL) {
                    return cached
                }
                if let cached = Self.dragImageCache.object(forKey: url as NSURL) {
                    return cached
                }
                // No cache hit — give AppKit nothing and let it fall
                // back to the system's file icon. The previous code
                // synchronously read the WHOLE source file here
                // (`NSImage(contentsOf: url)`), which for a 5MB
                // browser-saved photo cost 30-80ms of main-thread
                // I/O per file. Multiplied across an 8-image drag,
                // that's enough to feel like a stutter at the start
                // of the drag.
                return NSImage()
            }()
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

    /// Background-decode each thumbnail URL into the shared NSCache so
    /// `mouseDragged` can pull them synchronously without blocking.
    /// Skips URLs already cached, so a re-render with the same set is
    /// effectively free.
    private func preloadDragImages(urls: [URL]) {
        for url in urls {
            let key = url as NSURL
            if Self.dragImageCache.object(forKey: key) != nil { continue }
            Self.preloadQueue.async {
                guard let image = NSImage(contentsOf: url) else { return }
                // NSCache is thread-safe; safe to set from any queue.
                Self.dragImageCache.setObject(image, forKey: key)
            }
        }
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
