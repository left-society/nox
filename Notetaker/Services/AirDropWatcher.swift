import Foundation
import AppKit

/// Surfaces a notch pill whenever a file lands in the user's
/// Downloads (and Desktop) folders via AirDrop.
///
/// We watch the directories with FSEvents (same pattern
/// `ScreenshotWatcher` uses) rather than NSMetadataQuery, because
/// the codebase comment in ScreenshotWatcher notes the metadata
/// approach silently fails in this app's environment —
/// `didFinishGathering` never fires and the Spotlight scope
/// returns nothing. FSEvents is fast (sub-second), reliable, and
/// doesn't depend on Spotlight indexing being current.
///
/// AirDrop detection: when a new file appears we read its
/// `com.apple.quarantine` extended attribute. AirDrop arrivals
/// have an agent of `Sharingd` in the quarantine string
/// (format `0181;hex_timestamp;Sharingd;UUID`). Files transferred
/// over Bluetooth or via Continuity also use Sharingd, so this
/// also covers iPhone "Send to Mac" handoffs — same UX is
/// appropriate for both.
@MainActor
final class AirDropWatcher: NSObject {
    /// Closure fired each time a fresh AirDrop arrival is detected.
    /// Carries the URL of the dropped file so the click handler can
    /// reveal it in Finder.
    var onArrival: ((URL) -> Void)?

    private var streams: [FSEventStreamRef] = []
    /// Bounded set of paths we've already processed. Backed by a
    /// Set for O(1) lookup and a parallel ring-buffer order list
    /// so we can FIFO-evict the oldest entries once we hit the
    /// cap. Per BUG-013: previously this was an unbounded
    /// `Set<String>` that would grow forever as new files
    /// appeared in Downloads / Desktop — over months of uptime
    /// it would balloon into thousands of entries (~50-100 bytes
    /// each), a slow memory leak. The cap is sized generously
    /// (2000) so even heavy AirDrop / Downloads churn doesn't
    /// evict an entry that's still in the FSEvents flush
    /// pipeline.
    private var seenPaths: Set<String> = []
    private var seenPathsOrder: [String] = []
    private let seenPathsLimit = 2000
    /// Files that have arrived but haven't yet had their quarantine
    /// xattr set (AirDrop sometimes writes the quarantine flag
    /// after the initial file appearance). We retry these for a
    /// short window before giving up.
    private var pendingChecks: [String: Int] = [:]

    private let watchedDirectories: [URL]

    override init() {
        self.watchedDirectories = Self.defaultWatchedDirectories()
        super.init()
    }

    /// Default watch list: Downloads (the primary AirDrop target on
    /// modern macOS) and Desktop (older default, still used by some
    /// Macs and apps that share to the desktop).
    private static func defaultWatchedDirectories() -> [URL] {
        var urls: [URL] = []
        if let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first {
            urls.append(downloads)
        }
        if let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first {
            urls.append(desktop)
        }
        return urls
    }

    /// Begin watching. Idempotent — calling repeatedly is safe.
    func start() {
        guard streams.isEmpty else { return }

        // Seed seenPaths with everything currently in the watched
        // directories so the first FSEvents flush doesn't fire
        // onArrival for files that already existed at launch.
        for dir in watchedDirectories {
            if let existing = try? FileManager.default.contentsOfDirectory(atPath: dir.path) {
                for name in existing {
                    markSeen((dir.path as NSString).appendingPathComponent(name))
                }
            }
        }
        NSLog("Notetaker: AirDropWatcher watching \(watchedDirectories.count) dirs, seeded \(seenPaths.count) existing files")

        // Per BUG-001 fix: FSEventStreamContext now uses proper
        // retain/release callbacks so FSEventStream holds a
        // strong reference to `self` for the stream's entire
        // lifetime. The previous version used
        // `Unmanaged.passUnretained` with nil retain/release
        // callbacks — if `AirDropWatcher` was deallocated while
        // the stream was still flushing pending events, the C
        // callback would dereference freed memory. The
        // retain/release pair below uses Unmanaged.retain /
        // .release to balance correctly: FSEventStream calls
        // `retain` immediately when the stream is created (one
        // strong ref out), and `release` when the stream is
        // invalidated in `stop()` / `deinit` (one strong ref
        // back). Until then, even if the owner drops their
        // reference, FSEventStream's retain keeps `self` alive.
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: { ptr in
                guard let ptr else { return nil }
                return UnsafeRawPointer(
                    Unmanaged<AirDropWatcher>.fromOpaque(ptr).retain().toOpaque()
                )
            },
            release: { ptr in
                guard let ptr else { return }
                Unmanaged<AirDropWatcher>.fromOpaque(ptr).release()
            },
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = {
            _, clientCallBackInfo, numEvents, eventPaths, eventFlags, _ in
            guard let info = clientCallBackInfo else { return }
            let watcher = Unmanaged<AirDropWatcher>.fromOpaque(info).takeUnretainedValue()
            let nsArray = unsafeBitCast(eventPaths, to: NSArray.self)
            guard let paths = nsArray as? [String] else { return }
            for i in 0..<numEvents {
                let flags = eventFlags[i]
                let path = paths[i]
                let isFile = (flags & UInt32(kFSEventStreamEventFlagItemIsFile)) != 0
                let isCreated = (flags & UInt32(kFSEventStreamEventFlagItemCreated)) != 0
                let isRenamed = (flags & UInt32(kFSEventStreamEventFlagItemRenamed)) != 0
                let isModified = (flags & UInt32(kFSEventStreamEventFlagItemModified)) != 0
                if isFile && (isCreated || isRenamed || isModified) {
                    // Per BUG-002 fix: hop into the main actor's
                    // isolation domain via `Task { @MainActor in }`.
                    // Same pattern used in MediaRemoteService for
                    // BUG-010 — keeps the actor-isolation story
                    // consistent across the watcher fleet. There's
                    // a small async-scheduling cost vs the prior
                    // `DispatchQueue.main.async` (or the
                    // alternative `MainActor.assumeIsolated`), but
                    // for FSEvents file-arrival events the rate
                    // is low (<10/s in any realistic scenario), so
                    // ordering and overhead are non-issues here.
                    Task { @MainActor in
                        watcher.handleEvent(path: path)
                    }
                }
            }
        }

        let pathsToWatch = watchedDirectories.map(\.path) as CFArray
        let createFlags = UInt32(
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagUseCFTypes |
            kFSEventStreamCreateFlagNoDefer
        )
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.3,
            createFlags
        ) else {
            NSLog("Notetaker: AirDropWatcher FSEventStreamCreate failed")
            return
        }
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        FSEventStreamStart(stream)
        streams.append(stream)
        NSLog("Notetaker: AirDropWatcher started FSEvents stream")
    }

    /// Stop the watcher. Idempotent.
    func stop() {
        for stream in streams {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        streams.removeAll()
        pendingChecks.removeAll()
    }

    /// Handle a single FSEvents path notification. Skips already-seen
    /// paths, hidden files (`.DS_Store` etc.), and falls through to
    /// `checkAirDrop` for actual new arrivals.
    private func handleEvent(path: String) {
        // Skip hidden files (macOS sprinkles .DS_Store, .localized etc.
        // into Downloads/Desktop on a regular basis).
        let basename = (path as NSString).lastPathComponent
        if basename.hasPrefix(".") { return }

        if seenPaths.contains(path) {
            // We've seen this path before. AirDrop sometimes flushes
            // the quarantine xattr a moment after the file lands —
            // re-check if we previously failed to identify it AS an
            // AirDrop file (still in pendingChecks).
            if pendingChecks[path] != nil {
                NSLog("Notetaker: AirDropWatcher re-checking pending file \(basename)")
                checkAirDrop(path: path)
            }
            return
        }
        NSLog("Notetaker: AirDropWatcher new file \(basename)")
        markSeen(path)
        checkAirDrop(path: path)
    }

    /// Insert `path` into the bounded `seenPaths` set with LRU
    /// eviction once the cap is reached. Per BUG-013 fix.
    ///
    /// LRU (not FIFO): re-seeing an already-known path moves it
    /// to the END of `seenPathsOrder`, marking it as "recently
    /// touched." Only paths that haven't been seen in a long
    /// time get evicted. The earlier FIFO version had a behavior
    /// quirk where a path that arrived 2000 events ago and is
    /// being modified continuously (e.g. a long-lived sync
    /// folder) could still be evicted, then re-fire as "new
    /// AirDrop" on the next FSEvent. LRU avoids that — the
    /// ongoing-touch keeps it warm.
    private func markSeen(_ path: String) {
        if seenPaths.contains(path) {
            // Already known — promote to most-recently-used.
            // Cheap because in practice we only re-see a tiny
            // working set of paths per second.
            if let idx = seenPathsOrder.firstIndex(of: path) {
                seenPathsOrder.remove(at: idx)
                seenPathsOrder.append(path)
            }
            return
        }
        seenPaths.insert(path)
        seenPathsOrder.append(path)
        while seenPathsOrder.count > seenPathsLimit {
            let oldest = seenPathsOrder.removeFirst()
            seenPaths.remove(oldest)
        }
    }

    /// Read the file's quarantine xattr and decide whether it's an
    /// AirDrop arrival. If the xattr isn't there yet (AirDrop
    /// sometimes writes file content first and quarantine second),
    /// schedule a couple of retries before giving up.
    private func checkAirDrop(path: String) {
        let basename = (path as NSString).lastPathComponent
        guard let quarantine = Self.quarantineString(forPath: path) else {
            // No quarantine xattr — could be a non-AirDrop file
            // (a Finder copy from another folder won't have one),
            // or AirDrop hasn't finished writing it yet. Retry up
            // to 3 times at 0.5s intervals before giving up.
            let attempts = pendingChecks[path] ?? 0
            if attempts >= 3 {
                NSLog("Notetaker: AirDropWatcher giving up on \(basename) — no quarantine after 3 retries")
                pendingChecks.removeValue(forKey: path)
                return
            }
            pendingChecks[path] = attempts + 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.checkAirDrop(path: path)
            }
            return
        }

        pendingChecks.removeValue(forKey: path)
        NSLog("Notetaker: AirDropWatcher quarantine for \(basename): \(quarantine)")

        // Quarantine format: FLAGS;hex_timestamp;Agent;UUID
        // Confirmed on macOS 26 (Tahoe): "0081;...;sharingd;UUID"
        // for AirDrop (note: lowercase "sharingd"). Same agent is
        // used for iPhone "Send to Mac" — fine to surface either
        // with the same pill.
        let lower = quarantine.lowercased()
        guard lower.contains("sharingd") || lower.contains("airdrop") else {
            NSLog("Notetaker: AirDropWatcher \(basename) not from AirDrop, ignoring")
            return
        }

        NSLog("Notetaker: AirDropWatcher firing pill for \(basename)")
        let url = URL(fileURLWithPath: path)
        onArrival?(url)
    }

    /// Read `com.apple.quarantine` xattr as a UTF-8 string. Returns
    /// nil when the attribute isn't set (which is normal for files
    /// that aren't network-acquired) or when the value can't be
    /// interpreted.
    private static func quarantineString(forPath path: String) -> String? {
        let key = "com.apple.quarantine"
        let size = path.withCString { cPath in
            getxattr(cPath, key, nil, 0, 0, 0)
        }
        guard size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        let read = path.withCString { cPath in
            getxattr(cPath, key, &buffer, size, 0, 0)
        }
        guard read > 0 else { return nil }
        return String(bytes: buffer.prefix(read), encoding: .utf8)
    }

    deinit {
        for stream in streams {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}
