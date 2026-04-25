import SwiftUI
import AppKit
import ImageIO

/// Drop-in replacement for `AsyncImage(url:)` for local thumbnail
/// files. Designed for the images/videos grids where SwiftUI used
/// to spend 5-30ms per cell waiting on AsyncImage's URL-fetch
/// pipeline even though the bytes were already on disk a few
/// hundred microseconds away.
///
/// The flow:
///
/// 1. **Synchronous cache hit** — `body` is computed with the cached
///    `NSImage` already in `@State`. SwiftUI renders the image on
///    the same frame the cell appears, so scrolling and pasting both
///    feel native-fast.
/// 2. **Cache miss** — the `placeholder` view paints while a
///    `Task.detached` decodes the file off-main. The decoded
///    NSImage is shoved into the shared cache and into `@State`,
///    swapping in on the next frame.
/// 3. **Identity change** (e.g. ForEach reuses this cell for a
///    different record) — `task(id: id)` re-runs, repopulating
///    `@State` from cache or from disk as appropriate.
///
/// `aspectRatio(contentMode: .fill)` is applied here rather than on
/// the consumer side so callers can swap this in without changing
/// surrounding modifiers. Call sites that need `.fit` can wrap.
struct LocalThumbnailView<Placeholder: View>: View {
    let id: String
    let url: URL
    var contentMode: ContentMode = .fill
    @ViewBuilder var placeholder: () -> Placeholder

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                placeholder()
            }
        }
        // `task(id:)` cancels and restarts when the id changes —
        // exactly the behavior we want when ForEach reuses this cell
        // for a different record. The id-keyed `@State` reset is
        // free in SwiftUI: only the view body re-evaluates.
        .task(id: id) {
            // Synchronous cache hit — paint on the same frame the
            // cell appears. This is the path that makes pastes/
            // screenshots/scroll feel instant after first load.
            if let cached = ThumbnailCache.shared.image(for: id) {
                if image !== cached { image = cached }
                return
            }
            // Off-main decode for cache miss. We decode to a `CGImage`
            // off-main (CGImage is Sendable on every macOS version
            // we care about, unlike NSImage which only earns
            // Sendable conformance in macOS 14+) and wrap it in
            // NSImage on the main actor. The expensive work — the
            // file read + image decode — happens on the detached
            // Task; the main-actor work is just a pointer wrap.
            let captureUrl = url
            let captureId = id
            let cgImage: CGImage? = await Task.detached(priority: .userInitiated) {
                guard let src = CGImageSourceCreateWithURL(captureUrl as CFURL, nil) else {
                    return nil
                }
                return CGImageSourceCreateImageAtIndex(src, 0, nil)
            }.value
            // If the cell was recycled to a different id during
            // the await, `task(id:)` already cancelled us. Bail
            // before writing the wrong image into @State.
            guard !Task.isCancelled, let cgImage else { return }
            let size = NSSize(width: cgImage.width, height: cgImage.height)
            let loaded = NSImage(cgImage: cgImage, size: size)
            ThumbnailCache.shared.set(loaded, for: captureId)
            image = loaded
        }
    }
}

// Default placeholder convenience init — most call sites just want
// the standard subtle-bg rectangle, so they shouldn't have to
// write the closure.
extension LocalThumbnailView where Placeholder == AnyView {
    init(id: String, url: URL, contentMode: ContentMode = .fill) {
        self.id = id
        self.url = url
        self.contentMode = contentMode
        self.placeholder = { AnyView(Rectangle().fill(DS.Color.bgSubtle)) }
    }
}
