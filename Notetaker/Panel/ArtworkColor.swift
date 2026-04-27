import AppKit
import SwiftUI

/// Cheap dominant-color extraction from album artwork. Resizes the
/// source image to a 1×1 thumbnail and reads the resulting pixel —
/// CoreGraphics does the averaging for us via the resampling kernel,
/// so we don't have to walk individual pixels. The 1×1 result IS
/// (by definition) the average color of the source.
///
/// Returns a Color tuned for use as a UI accent: clamped saturation
/// and lightness so the result reads as a "tonal hint" rather than
/// taking over the whole UI. Used by:
///   - MusicPanelView's progress-bar gradient (artwork-color tint
///     on the filled portion of the scrubber)
///   - MusicPanelView's waveform (slab) tint
///   - PanelRootView's pill waveform tint
/// User: "the timeline and the webfrom should have the gradient
/// look of that videos thumbnail ... Same goes for the pill"
///
/// ## Memoization
///
/// `dominant(from:)` is called from at least four call sites that
/// re-evaluate on every body invocation (progress bar fill, waveform
/// tint in slab, waveform tint in pill, gradient header). Without a
/// cache, each render decoded the artwork data, allocated a 4-byte
/// CGContext, drew the image, and ran HSB conversion. For a typical
/// 4-eval render at 30fps that's ~120 unnecessary decodes per second.
///
/// We key on the artwork data's identity hash (SHA-style: byte count
/// + a sample of bytes) because `Data` doesn't expose object identity
/// and full byte-equality would defeat the purpose. The cache is
/// bounded to the last 4 entries (current + a couple of recent tracks)
/// — bigger would just retain CGContext-derived NSColor instances we
/// no longer need. Access is serialized via a lock so SwiftUI's
/// concurrent body evaluation can't race.
enum ArtworkColor {

    /// Lightweight cache keyed by artwork data identity. Bounded LRU
    /// at 4 entries — enough to cover current track + immediate
    /// previous so a quick skip-forward / skip-back doesn't re-decode.
    private static let cacheLock = NSLock()
    private static var cache: [(key: ArtworkKey, color: Color?)] = []
    private static let cacheLimit = 4

    /// Sample the artwork data and return the dominant color, or nil
    /// if the data isn't decodable. Memoized — same data identity
    /// returns the cached result without re-decoding.
    static func dominant(from data: Data?) -> Color? {
        guard let data else { return nil }
        let key = ArtworkKey(data: data)

        cacheLock.lock()
        if let hit = cache.first(where: { $0.key == key }) {
            cacheLock.unlock()
            return hit.color
        }
        cacheLock.unlock()

        let computed = compute(from: data)

        cacheLock.lock()
        // Insert at front (most-recent), trim tail to bound.
        cache.removeAll { $0.key == key }
        cache.insert((key, computed), at: 0)
        if cache.count > cacheLimit {
            cache.removeLast(cache.count - cacheLimit)
        }
        cacheLock.unlock()

        return computed
    }

    /// Heavy path — extracted so the cache check can short-circuit
    /// before we touch CoreGraphics.
    private static func compute(from data: Data) -> Color? {
        guard let image = NSImage(data: data) else { return nil }
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }

        // Render the source down to a 1×1 pixel via CoreGraphics. The
        // resampling kernel (linear by default) averages all source
        // pixels into the single destination pixel — the result IS
        // the average color, no manual loop needed.
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        var pixel: [UInt8] = [0, 0, 0, 0]
        guard let context = CGContext(
            data: &pixel,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return nil }
        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))

        let r = Double(pixel[0]) / 255.0
        let g = Double(pixel[1]) / 255.0
        let b = Double(pixel[2]) / 255.0

        // Boost saturation slightly and clamp lightness — averaging
        // tends to produce muted mid-grays. We want the color to
        // read as a real chromatic tint, not just "slightly warm
        // white." Convert to HSB, push saturation up, lift lightness
        // toward the mid-range.
        let nsColor = NSColor(red: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: 1.0)
        var hue: CGFloat = 0
        var sat: CGFloat = 0
        var bri: CGFloat = 0
        nsColor.usingColorSpace(.deviceRGB)?.getHue(&hue, saturation: &sat, brightness: &bri, alpha: nil)
        let boostedSat = min(1.0, sat * 1.6 + 0.15)
        let liftedBri = max(0.55, min(0.85, bri * 1.2 + 0.15))
        let tuned = NSColor(hue: hue, saturation: boostedSat, brightness: liftedBri, alpha: 1.0)

        return Color(nsColor: tuned)
    }
}

/// Cheap identity hash for `Data` — full byte equality would defeat
/// the cache (it'd be O(N) per lookup, on every render). We pick the
/// byte count plus a few sampled bytes from start/middle/end as a
/// fingerprint. Two distinct artworks with the same length AND the
/// same bytes at all sampled offsets is astronomically unlikely for
/// album-art payloads (PNG/JPEG headers + variable image content).
private struct ArtworkKey: Equatable {
    let count: Int
    let signature: UInt64

    init(data: Data) {
        self.count = data.count
        // Sample up to 8 bytes spread across the data. For short
        // payloads we just hash whatever's there. UInt64 leaves
        // plenty of room for the bytes plus length to stay distinct.
        var sig: UInt64 = UInt64(data.count) &* 0x9E3779B97F4A7C15
        let stride = max(1, data.count / 8)
        var i = 0
        var taken = 0
        while i < data.count && taken < 8 {
            sig = (sig &* 31) &+ UInt64(data[i])
            i += stride
            taken += 1
        }
        self.signature = sig
    }
}
