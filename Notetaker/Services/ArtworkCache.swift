import AppKit

/// In-memory cache of decoded album artwork keyed by track identity
/// ("title|artist"). Solves two latency problems with the previous
/// `NSImage(data:)` inline decode:
///
/// 1. **Re-decode on every render**: SwiftUI re-evaluates view bodies
///    on each `presenter.nowPlaying` change, which means the same
///    artwork was being decoded again every tick. With the cache,
///    decode happens once per track and subsequent reads are O(1).
///
/// 2. **Switch-back latency**: Going PREV to a recently-played song
///    used to re-decode that song's artwork from raw bytes. With the
///    cache, the prior NSImage is returned instantly — no flash, no
///    re-decode, no main-thread block.
///
/// We can't TRULY pre-fetch the NEXT track's artwork because
/// Spotify/Apple Music don't expose the queue to third-party apps
/// in a uniform way. But this cache handles the realistic patterns
/// — repeats, A/B-ing between two tracks, going back — at zero
/// perceived latency.
///
/// The cache also decodes new artworkData on a background queue so
/// the main thread never stalls on `NSImage(data:)` for a fresh
/// arrival. When the decode lands, the cache notifies via callback
/// and the view fades the new image in.
@MainActor
final class ArtworkCache {
    static let shared = ArtworkCache()

    /// LRU-bounded cache. NSCache handles eviction automatically
    /// when memory pressure rises. Tuned to hold ~20 tracks worth
    /// of decoded artwork (each ≈ 200KB-1MB depending on size,
    /// total ≈ 4-20MB which is well within reason).
    private let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 20
        c.totalCostLimit = 32 * 1024 * 1024   // 32MB ceiling
        return c
    }()

    /// Track keys that have an in-flight background decode. Used to
    /// avoid scheduling multiple decodes for the same track if the
    /// view re-evaluates during the decode window.
    private var inFlight: Set<String> = []

    /// Completion callbacks waiting on an in-flight decode. Multiple
    /// views can ask for the same artwork during one render pass; all
    /// of them should hear when the shared decode finishes.
    private var waiters: [String: [@MainActor (NSImage?) -> Void]] = [:]

    /// Background queue for decode work. Concurrent so multiple
    /// tracks' decodes can run in parallel (cheap on modern CPUs).
    private let decodeQueue = DispatchQueue(
        label: "app.trynox.artwork-decode",
        qos: .userInitiated,
        attributes: .concurrent
    )

    private init() {}

    /// Synchronous cache lookup. Returns nil if not yet decoded.
    /// Callers should treat nil as "kick off decode + show
    /// placeholder" — call `decode(...)` after this returns nil.
    func get(forKey key: String) -> NSImage? {
        cache.object(forKey: key as NSString)
    }

    /// Schedule a background decode for the given data + key. When
    /// the decode completes, calls `onReady` on the main queue with
    /// the decoded image (or nil if decode failed). Idempotent:
    /// scheduling the same key again while a decode is in flight joins
    /// the existing work and receives the same completion.
    ///
    /// Cost is computed from data length so NSCache's `totalCostLimit`
    /// gets a meaningful number to weigh evictions against.
    func decode(data: Data, key: String, onReady: @MainActor @escaping (NSImage?) -> Void) {
        // Synchronous cache hit short-circuit.
        if let cached = cache.object(forKey: key as NSString) {
            onReady(cached)
            return
        }
        // Already decoding for this key — join the decode instead of
        // dropping the callback. Dropped callbacks were enough to leave
        // one surface stuck on a placeholder while another warmed cache.
        if inFlight.contains(key) {
            waiters[key, default: []].append(onReady)
            return
        }
        inFlight.insert(key)
        waiters[key] = [onReady]

        // Background decode + main-actor completion. Earlier this
        // used `DispatchQueue.main.async`, which puts the closure
        // on the main THREAD but NOT in the @MainActor's isolation
        // domain — that silently dropped writes to `self.cache` and
        // `self.inFlight` (which are @MainActor-isolated state) and
        // never called `onReady`. The pill never received its
        // decoded image and stayed at the music.note placeholder.
        // `Task { @MainActor in ... }` correctly hops into the
        // main actor, so all isolated reads/writes work and
        // `onReady` actually fires.
        decodeQueue.async {
            let image = NSImage(data: data)
            Task { @MainActor in
                if let image = image {
                    let cost = data.count
                    self.cache.setObject(image, forKey: key as NSString, cost: cost)
                }
                self.inFlight.remove(key)
                let callbacks = self.waiters.removeValue(forKey: key) ?? []
                for callback in callbacks {
                    callback(image)
                }
            }
        }
    }

    /// Convenience wrapper: returns a cached image if available and
    /// starts a background decode on miss. It never decodes on the
    /// caller's thread.
    ///
    /// Per BUG-012 fix: the previous signature carried an
    /// `onReady` callback parameter that was documented as
    /// "never fires," kept for API compatibility. That's a hidden
    /// trap — any future caller that wires up the callback
    /// expecting an async result silently never gets notified.
    /// The unused parameter is removed; callers should consume
    /// the synchronous return value.
    ///
    /// Callers that need to update UI on a miss should call
    /// `decode(data:key:onReady:)` and guard the callback against
    /// stale track identity.
    func image(data: Data?, key: String) -> NSImage? {
        // 2026-05-01: cache lookup by key BEFORE the data-nil guard.
        // YouTube (and other browser tabs) re-emit MediaRemote info
        // with `artworkData = nil` when the user pauses — it's a
        // metadata refresh that signals "still the same track, just
        // paused now," not a true track change. Pre-fix the cache
        // check was gated behind `guard let data` so a nil-data
        // emission returned nil even though we had the decoded image
        // stored under this same key from when the track first played.
        // The pill then blanked to the music-note placeholder for the
        // duration of the paused state. Looking up by key first
        // lets us return the cached image regardless of whether THIS
        // emission has bytes attached. If the track is genuinely
        // different the caller's key won't be in the cache and we
        // fall through to the decode-or-nil paths below.
        if let cached = cache.object(forKey: key as NSString) {
            return cached
        }
        if let data = data {
            decode(data: data, key: key) { _ in }
        }
        return nil
    }
}
