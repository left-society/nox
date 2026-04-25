import AppKit

/// Process-wide thumbnail cache so the images grid never has to wait
/// on async disk-loading machinery for cells that have been seen
/// before. Backed by `NSCache` so the OS automatically evicts under
/// memory pressure — we don't have to manage it.
///
/// **Why this exists:** the previous implementation used SwiftUI's
/// `AsyncImage(url:)` for thumbnails, which:
///   1. Routes file:// URLs through the URLSession async pipeline
///      (~5-30ms per cell even though the bytes are local)
///   2. Doesn't cache across cell identity changes — scrolling a
///      grid recycles cells, and every recycle re-runs the fetch
///   3. Flickers between empty → loaded on every recycle
///
/// With NSCache + a synchronous lookup path, cells that have ever
/// rendered before paint immediately on the next frame. The first
/// render still loads from disk but that work happens off-main and
/// the result is reused thereafter.
///
/// `NSCache` is thread-safe per Apple docs (unlike NSDictionary), so
/// this whole thing is non-isolated and the SwiftUI consumer can hit
/// it from any thread without locking.
final class ThumbnailCache: @unchecked Sendable {
    static let shared = ThumbnailCache()

    private let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        // Ballpark cap — 200 thumbs at ~256x256 RGBA ≈ 50MB. The
        // grid view rarely scrolls past 100 cells so this is plenty,
        // and NSCache will trim under pressure anyway.
        c.countLimit = 200
        return c
    }()

    private init() {}

    func image(for id: String) -> NSImage? {
        cache.object(forKey: id as NSString)
    }

    func set(_ image: NSImage, for id: String) {
        cache.setObject(image, forKey: id as NSString)
    }

    func remove(id: String) {
        cache.removeObject(forKey: id as NSString)
    }
}
