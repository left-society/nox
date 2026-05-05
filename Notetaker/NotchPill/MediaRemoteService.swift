import AppKit
import Foundation

/// Snapshot of the system-wide "now playing" media — Spotify track,
/// YouTube tab in Safari, Apple Music, podcast app, anything that
/// publishes to macOS's MediaRemote pipeline.
///
/// Equatable so the orchestrator can drop redundant updates and only
/// drive the HUD when something user-visible changed (title flipped,
/// playback paused, app changed). Without dedup, the system fires
/// notifications several times per playing track (every ~1s for some
/// apps as elapsed-time advances), and we'd thrash the HUD.
struct NowPlayingInfo: Equatable {
    let title: String
    let artist: String
    let album: String?
    /// Encoded artwork bytes (usually JPEG or PNG). Decoded into NSImage
    /// inside the view rather than here so the service stays free of
    /// AppKit dependencies for the data layer.
    let artworkData: Data?
    let isPlaying: Bool
    /// Bundle ID of the source app — Spotify, Music, Safari, Chrome,
    /// Arc, Brave, etc. Used by the view to badge the pill with the
    /// source app's icon ("playing in Spotify"). nil means MediaRemote
    /// reported no source — we still show the HUD if there's a title.
    let sourceBundleID: String?
    /// Track duration in seconds, when the source publishes it. Spotify
    /// and Apple Music both populate this via MediaRemote; YouTube tabs
    /// in Safari do not. nil means "no progress bar" — the view falls
    /// back to a button-only transport strip.
    let duration: TimeInterval?
    /// Playback position at the moment of the last MediaRemote update.
    /// To get the *current* position, the view should add wall-clock
    /// time elapsed since `infoTimestamp` (only meaningful while
    /// `isPlaying` is true). nil means "no progress bar."
    let elapsedTime: TimeInterval?
    /// Wall-clock timestamp of the elapsed-time snapshot. Lets the view
    /// extrapolate `elapsedTime + (now - infoTimestamp)` so the bar
    /// advances smoothly between MediaRemote notifications instead of
    /// stepping forward only when a new snapshot lands.
    let infoTimestamp: Date?

    /// True when there's enough payload to bother showing a HUD. A
    /// title or artist plus any sign of playback (or known source) is
    /// enough; an empty info dict means "nothing playing" → hide.
    var isPresentable: Bool {
        !title.isEmpty || !artist.isEmpty
    }

    /// Return a copy with `artworkData` replaced. Used by the artwork
    /// fetcher to re-publish a snapshot once the iTunes Search lookup
    /// lands, without forcing every other call site to know about the
    /// fetch lifecycle. NowPlayingInfo stays immutable everywhere else.
    func with(artworkData newArtwork: Data?) -> NowPlayingInfo {
        NowPlayingInfo(
            title: title,
            artist: artist,
            album: album,
            artworkData: newArtwork,
            isPlaying: isPlaying,
            sourceBundleID: sourceBundleID,
            duration: duration,
            elapsedTime: elapsedTime,
            infoTimestamp: infoTimestamp
        )
    }

    /// Linearly extrapolated current playhead position. Returns
    /// `elapsedTime + (now - infoTimestamp)` while playing, or just
    /// `elapsedTime` when paused (the snapshot is the source of truth
    /// in that state — wall-clock advance shouldn't move the bar).
    /// nil whenever the source app didn't publish elapsed-time data.
    ///
    /// 2026-05-02: removed the 2.5s drift cap. The cap was added
    /// when YouTube-paused snapshots stayed isPlaying=true forever
    /// and the bar would extrapolate indefinitely. Pill visibility
    /// is now gated on `nowPlaying.isPlaying` (AppDelegate
    /// updatePillVisibility), AND the orchestrator forwards
    /// MediaRemote's actual isPlaying flag instead of caching a
    /// stale true. So when the source is paused, isPlaying flips
    /// false and this function falls back to `elapsed` (no
    /// extrapolation) via the guard below. The cap was capping
    /// LEGIT playback at 2.5s past the last MR snapshot, making
    /// the bar look stuck at 2-4 seconds for sources whose MR
    /// emit cadence is sparse.
    func currentPosition(at moment: Date = Date()) -> TimeInterval? {
        guard let elapsed = elapsedTime else { return nil }
        guard let timestamp = infoTimestamp, isPlaying else { return elapsed }
        let drift = max(moment.timeIntervalSince(timestamp), 0)
        let projected = elapsed + drift
        if let total = duration { return min(max(0, projected), total) }
        return max(0, projected)
    }
}

/// Wrapper around macOS's private MediaRemote framework, which is the
/// only system-wide way to observe what other apps are playing. We
/// dlopen the framework dynamically because:
///   1. We can't link against it at compile time without entitlements
///      Apple won't grant to third-party developers.
///   2. The symbol set / availability has shifted across macOS versions
///      (15.4 tightened restrictions on `GetNowPlayingInfo`); resolving
///      via dlsym lets us degrade gracefully when a symbol is missing.
///
/// What this service is NOT:
///   - It's not a full media-control client. It exposes the minimum
///     surface the notch HUD needs: subscribe to changes, read the
///     current track, send play/pause/skip commands.
///   - It's not a guarantee. On post-15.4 macOS some symbols may be
///     restricted; if `currentInfo()` ever returns empty for a track
///     we know is playing, the HUD just stays hidden — the rest of
///     the app keeps working.
@MainActor
final class MediaRemoteService {
    /// Commands MediaRemote understands. Raw values are stable across
    /// macOS versions — these are the same constants Alcove, Sleeve,
    /// and other notch-HUD apps have been using since macOS 10.13.
    enum Command: UInt32 {
        case play = 0
        case pause = 1
        case togglePlayPause = 2
        case stop = 3
        case next = 4
        case previous = 5
        case toggleShuffle = 6
    }

    /// Fired when the currently-playing info changes (track changed,
    /// art changed, playback flipped). The closure receives the latest
    /// snapshot already deduplicated against the previous one.
    var onChange: ((NowPlayingInfo?) -> Void)?

    private var bundle: CFBundle?
    private var getNowPlayingInfo: (@convention(c) (DispatchQueue, @escaping ([String: Any]) -> Void) -> Void)?
    private var getIsPlaying: (@convention(c) (DispatchQueue, @escaping (Bool) -> Void) -> Void)?
    private var sendCommand: (@convention(c) (UInt32, [AnyHashable: Any]?) -> Bool)?
    private var registerForNotifications: (@convention(c) (DispatchQueue) -> Void)?
    /// `MRMediaRemoteGetNowPlayingApplicationDisplayID` — returns the
    /// bundle ID (e.g. "com.google.Chrome", "com.spotify.client") of
    /// whichever app is the current MediaRemote source. Resolves the
    /// "click on title → open source app" gesture for browsers and
    /// other non-builtin apps where MediaRemote previously published
    /// `sourceBundleID = nil`.
    private var getNowPlayingApplicationDisplayID: (@convention(c) (DispatchQueue, @escaping (String?) -> Void) -> Void)?

    /// Most recent snapshot, used for diffing across notifications and
    /// for command callbacks that want to read state synchronously.
    private var lastInfo: NowPlayingInfo?
    private var observers: [NSObjectProtocol] = []

    /// Periodic timer that re-fetches `duration` + `player position`
    /// for Spotify / Apple Music via AppleScript. Required because:
    ///   • DistributedNotifications don't carry timing.
    ///   • MediaRemote is restricted on macOS 15.4+ for unsigned
    ///     third-party apps, so its timing path is dead too.
    /// Without this refresher the progress bar is stuck at 0 and the
    /// scrub gesture is gated off (see MusicPanelView.progressBar's
    /// `hasTiming` check).
    private var appScriptTimingTimer: Timer?
    /// Bundle ID currently being polled. Compared against `lastInfo`
    /// each tick so we stop polling the moment the source changes
    /// away from Spotify/Music (no point asking Spotify for timing
    /// while YouTube is playing).
    private var appScriptTimingFor: String?

    /// In-memory cache of artwork bytes keyed by `title|artist` (lower-
    /// cased, trimmed). Avoids re-querying iTunes Search every time the
    /// user pauses and resumes the same track, switches tracks back to
    /// one we've already fetched, or relaunches the app within the same
    /// listening session.
    ///
    /// Per BUG-039 fix: previously documented as "bounded organically
    /// by user's actual play history — typical session touches a few
    /// dozen tracks." That assumption breaks for shuffle-mode users
    /// who blow through hundreds of tracks an hour; the cache could
    /// swell into 100MB+ of artwork bytes with no eviction path.
    /// Now: explicit LRU cap at 100 entries, total ~10-50 MB. The
    /// `artworkCacheOrder` array tracks insertion order; on overflow
    /// we evict the least-recently-used key first. Re-touching a
    /// cached key promotes it to the most-recently-used end, so an
    /// active session's hot set is preserved.
    private var artworkCache: [String: Data] = [:]
    private var artworkCacheOrder: [String] = []
    private let artworkCacheLimit = 100

    /// Set of cache keys for fetches currently in flight. Spotify's
    /// PlaybackStateChanged and MediaRemote's NowPlayingInfoDidChange
    /// often fire near-simultaneously for the same track; this set
    /// suppresses the duplicate HTTP request the second one would
    /// otherwise trigger.
    private var artworkInFlight: Set<String> = []

    /// Currently in-flight artwork fetch task. Cancelled before each
    /// new fetch starts so fast track-skipping doesn't pile up
    /// orphaned network requests racing the new track's fetch.
    /// Mirrors boring.notch's `artworkFetchTask?.cancel()` pattern in
    /// `boringNotch/MediaControllers/SpotifyController.swift`.
    private var currentArtworkFetchTask: Task<Void, Never>?

    /// Pending session-end clear, debounced via a 500ms grace period.
    /// Per `jackson-storm/DynamicNotch`'s `NowPlayingViewModel`
    /// (`transientSessionGracePeriod = 0.55`): Spotify and Apple Music
    /// constantly send spurious "no session" notifications between
    /// tracks (especially during a skip — the source app briefly drops
    /// to a non-playing state before announcing the new track). If we
    /// clear `lastInfo` immediately on those notifications, the pill
    /// flashes empty and the new track's fetch starts from scratch
    /// with no artwork inheritance. The grace period lets a real
    /// track update arrive and cancel the pending clear, eliminating
    /// the flash entirely.
    private var pendingSessionEndWorkItem: DispatchWorkItem?

    /// Pause-debounce work item. When `info.isPlaying` transitions
    /// true → false, we hold the false-state for `pauseDebounceDelay`
    /// before propagating to `onChange`. If isPlaying flips back to
    /// true within that window, we cancel and fire the new state
    /// immediately — eliminating the brief paused-state flicker
    /// Spotify (and to a lesser extent Apple Music) emit between
    /// tracks (80-150ms gap during track skip where playbackState
    /// is briefly "paused").
    ///
    /// Pattern lifted from Alcove's `pauseDebounce` (verified in
    /// the Alcove binary's strings table during the 2026-04-29
    /// reverse-engineering pass).
    private var pauseDebounceWorkItem: DispatchWorkItem?
    private let pauseDebounceDelay: TimeInterval = 0.20

    // MARK: - Lifecycle

    /// Resolve symbols and start listening. Idempotent — second call
    /// is a no-op. Returns silently on any framework-load or symbol-
    /// resolve failure; check `isAvailable` if you need to know.
    func start() {
        guard bundle == nil else { return }

        let url = URL(fileURLWithPath: "/System/Library/PrivateFrameworks/MediaRemote.framework")
        guard let cfBundle = CFBundleCreate(kCFAllocatorDefault, url as CFURL) else {
            NSLog("nox: MediaRemote framework not found at \(url.path)")
            return
        }
        guard CFBundleLoadExecutable(cfBundle) else {
            NSLog("nox: MediaRemote framework failed to load")
            return
        }
        bundle = cfBundle

        // Resolve the symbols we need. Each is optional — missing any
        // single one degrades us gracefully (no notification → no HUD;
        // no command sender → no playback control buttons).
        //
        // macOS 15.4 (Mar 2025) tightened MediaRemote: third-party apps
        // without the relevant private entitlements can find the
        // framework loaded but the function pointers come back nil.
        // We log every resolution explicitly so the failure mode is
        // visible in Console.app — without these logs a user reporting
        // "music HUD doesn't show" had no way to distinguish
        // "framework restricted" from "orchestrator bug" from
        // "SwiftUI didn't render."
        if let ptr = CFBundleGetFunctionPointerForName(cfBundle, "MRMediaRemoteGetNowPlayingInfo" as CFString) {
            getNowPlayingInfo = unsafeBitCast(ptr, to: (@convention(c) (DispatchQueue, @escaping ([String: Any]) -> Void) -> Void).self)
        }
        if let ptr = CFBundleGetFunctionPointerForName(cfBundle, "MRMediaRemoteGetNowPlayingApplicationIsPlaying" as CFString) {
            getIsPlaying = unsafeBitCast(ptr, to: (@convention(c) (DispatchQueue, @escaping (Bool) -> Void) -> Void).self)
        }
        if let ptr = CFBundleGetFunctionPointerForName(cfBundle, "MRMediaRemoteSendCommand" as CFString) {
            sendCommand = unsafeBitCast(ptr, to: (@convention(c) (UInt32, [AnyHashable: Any]?) -> Bool).self)
        }
        if let ptr = CFBundleGetFunctionPointerForName(cfBundle, "MRMediaRemoteRegisterForNowPlayingNotifications" as CFString) {
            registerForNotifications = unsafeBitCast(ptr, to: (@convention(c) (DispatchQueue) -> Void).self)
        }
        // Resolve the source-bundleID symbol. Same restriction risk
        // as the other private symbols on macOS 15.4+ — we log
        // success/failure so it's visible in Console when debugging
        // "click on title doesn't open Chrome" reports.
        if let ptr = CFBundleGetFunctionPointerForName(cfBundle, "MRMediaRemoteGetNowPlayingApplicationDisplayID" as CFString) {
            getNowPlayingApplicationDisplayID = unsafeBitCast(ptr, to: (@convention(c) (DispatchQueue, @escaping (String?) -> Void) -> Void).self)
        }
        NSLog("nox: MediaRemote symbols — getInfo=\(getNowPlayingInfo != nil) getIsPlaying=\(getIsPlaying != nil) sendCommand=\(sendCommand != nil) registerNotifs=\(registerForNotifications != nil) getDisplayID=\(getNowPlayingApplicationDisplayID != nil)")

        // Subscribe to the three notifications we care about. Names are
        // stable since macOS 10.13. We listen on DistributedNotificationCenter
        // because some apps publish through there; NotificationCenter
        // covers the rest. We post observers to both for robustness.
        registerForNotifications?(.main)

        let nc = DistributedNotificationCenter.default()
        let names = [
            "kMRMediaRemoteNowPlayingInfoDidChangeNotification",
            "kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
            "kMRMediaRemoteNowPlayingApplicationDidChangeNotification"
        ]
        for name in names {
            // Per BUG-010 fix: previously `MainActor.assumeIsolated`,
            // which TRUSTS the caller's claim that the call is in
            // the main actor's isolation domain. Passing `queue: .main`
            // to NotificationCenter.addObserver only guarantees the
            // closure runs on the main THREAD — that's not the same
            // as the main actor's isolation domain in Swift's
            // structured-concurrency model. Strict-concurrency
            // builds rightly flag this; future Swift versions may
            // turn it into a runtime crash. Routing through
            // `Task { @MainActor in ... }` properly hops into the
            // actor's isolation domain.
            let token = nc.addObserver(
                forName: Notification.Name(name),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.refresh()
                }
            }
            observers.append(token)
        }

        // Local notification center for in-process media servers.
        let lnc = NotificationCenter.default
        for name in names {
            let token = lnc.addObserver(
                forName: Notification.Name(name),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.refresh()
                }
            }
            observers.append(token)
        }

        // App-specific fallback subscriptions — Apple Music and Spotify
        // both publish public DistributedNotifications with full track
        // payload in userInfo. These bypass MediaRemote entirely, so
        // they keep working even on macOS versions that have restricted
        // the private framework symbols (15.4+ tightened third-party
        // access; 16+ may have removed it altogether). We never
        // discriminate against MediaRemote — if both pipelines fire for
        // the same track, the dedup in `publish()` swallows the second
        // one. The fallback is purely additive insurance.
        let appNotifications: [(name: String, source: String)] = [
            ("com.apple.Music.playerInfo", "com.apple.Music"),
            ("com.spotify.client.PlaybackStateChanged", "com.spotify.client")
        ]
        for entry in appNotifications {
            let token = nc.addObserver(
                forName: Notification.Name(entry.name),
                object: nil,
                queue: .main
            ) { [weak self] note in
                // Per BUG-010 fix: same as the loop above — replace
                // `MainActor.assumeIsolated` with a proper Task hop.
                Task { @MainActor in
                    self?.applyAppNotification(note, sourceBundleID: entry.source)
                }
            }
            observers.append(token)
        }

        // Pull initial state so the orchestrator has a baseline before
        // the user changes tracks.
        refresh()

        // MediaRemote's initial dict can come back empty even when an
        // app is actively playing — Spotify in particular doesn't seed
        // the system NowPlayingInfo on launch; it only publishes via
        // its own DistributedNotification (PlaybackStateChanged), which
        // fires *on state changes*, not on subscriber-attach. So if the
        // user is mid-song when Notetaker starts, we have no signal at
        // all until they pause/skip.
        //
        // The fix: on start, scan known music apps (Spotify, Apple Music)
        // for already-running instances and AppleScript-probe their
        // current track. This populates lastInfo with a real snapshot,
        // so the orchestrator can immediately render the pill. We treat
        // it as a synthesized "app notification" so it routes through
        // the same publish() path as live notifications — the dedup
        // logic prevents a duplicate bloom if MediaRemote *also* fires
        // shortly after.
        probeRunningMusicApps()
    }

    /// Walk known music apps that are currently running and ask each
    /// for its current track via AppleScript. Each successful probe
    /// synthesizes the same payload the live PlaybackStateChanged /
    /// playerInfo notification would have carried, then routes through
    /// `applyAppNotification` for normal dedup + publish.
    ///
    /// Why we don't just `tell application "Spotify"` blindly: Spotify
    /// (and Music) auto-launch in response to AppleScript commands.
    /// We absolutely don't want to spawn either app at Notetaker start.
    /// `NSRunningApplication.runningApplications(withBundleIdentifier:)`
    /// gates that — only run AppleScript against an already-running app.
    ///
    /// Why AppleScript and not MediaRemote: the whole reason this method
    /// exists is that MediaRemote returned empty. AppleScript inherits
    /// the user's existing automation grant (already required for the
    /// transport buttons to work), so there's no extra permission cost.
    private func probeRunningMusicApps() {
        // Per 2026-04-29 deep dive on open-source notch HUDs: NONE of
        // boring.notch / DynamicNotch / ComfyNotch special-case
        // Podcasts.app, even though Podcasts publishes sparsely to
        // MediaRemote (often just bundle ID + media type, no title
        // for ~500ms after play start). Adding it here is a clean
        // differentiator and the user's specific bug — "Apple
        // Podcast just says podcast with no description, title, or
        // thumbnail" — is downstream of the Podcasts.app being
        // absent from this list.
        //
        // Podcasts.app's AppleScript dictionary uses `current
        // episode` (not `current track`); the probe routes through
        // a separate helper to handle the schema diff.
        let probes: [(bundleID: String, appName: String)] = [
            ("com.spotify.client", "Spotify"),
            ("com.apple.Music", "Music")
        ]
        for probe in probes {
            let running = NSRunningApplication.runningApplications(
                withBundleIdentifier: probe.bundleID
            )
            guard !running.isEmpty else { continue }
            probeAppleScriptTrack(appName: probe.appName, sourceBundleID: probe.bundleID)
        }
        // NO Apple Podcasts AppleScript probe — Podcasts.app has
        // no AppleScript dictionary on macOS 15+ (verified via
        // `osascript -e 'tell application "Podcasts" to ...'`
        // returning syntax errors, and `scriptable of (application
        // process "Podcasts")` in System Events failing). The agent
        // research that suggested `name of current episode` was
        // incorrect — that schema is for Music.app's old podcast-
        // mode (deprecated when Podcasts.app split off in macOS
        // Catalina). The proper fix for richer Podcasts metadata
        // is the `ungive/mediaremote-adapter` Perl bridge — Perl
        // is signed as `com.apple.perl` and retains MediaRemote
        // artwork access that direct dlopen'd MediaRemote loses
        // on 15.4+. Bundle that adapter as a follow-up ship.
    }

    /// Single-app probe. Wrapped in a Task because executeAndReturnError
    /// is synchronous and slow (~50-150ms per call); we don't want to
    /// block start() — and by extension `applicationDidFinishLaunching` —
    /// while the AppleScript bridge spins up.
    private func probeAppleScriptTrack(appName: String, sourceBundleID: String) {
        Task.detached(priority: .userInitiated) { [weak self] in
            // Each value comes back as a single-line string. We ask for
            // four strings concatenated with a stable separator instead
            // of four round trips — keeps the AppleScript boundary cost
            // minimal. The `try` blocks swallow "track not available"
            // errors that fire when the app is running but has no
            // current track loaded (e.g. Spotify on the home screen).
            let source = """
            tell application "\(appName)"
                if not (player state is not stopped) then return ""
                try
                    set t to name of current track as text
                on error
                    return ""
                end try
                set a to ""
                try
                    set a to artist of current track as text
                end try
                set al to ""
                try
                    set al to album of current track as text
                end try
                set s to player state as text
                return t & "|||" & a & "|||" & al & "|||" & s
            end tell
            """
            guard let script = NSAppleScript(source: source) else { return }
            var error: NSDictionary?
            let result = script.executeAndReturnError(&error)
            if error != nil { return }
            let payload = result.stringValue ?? ""
            guard !payload.isEmpty else { return }
            let parts = payload.components(separatedBy: "|||")
            guard parts.count == 4 else { return }
            let title = parts[0]
            let artist = parts[1]
            let album = parts[2]
            let state = parts[3]
            guard !title.isEmpty || !artist.isEmpty else { return }

            // Synthesize the same userInfo shape the live notification
            // would have carried, and reuse applyAppNotification so the
            // probe and the live path stay in lockstep.
            let userInfo: [AnyHashable: Any] = [
                "Name": title,
                "Artist": artist,
                "Album": album,
                "Player State": state
            ]
            let note = Notification(
                name: Notification.Name("Notetaker.SyntheticInitialProbe"),
                object: nil,
                userInfo: userInfo
            )
            await MainActor.run {
                guard let self else { return }
                NSLog("nox: initial AppleScript probe \(appName) title=\"\(title)\" artist=\"\(artist)\" state=\(state)")
                self.applyAppNotification(note, sourceBundleID: sourceBundleID)
            }
        }
    }

    /// Parse a track update from one of the app-specific
    /// `NSDistributedNotificationCenter` payloads. Apple Music and
    /// Spotify use compatible-enough schemas that one parser handles
    /// both: `Player State`, `Name`, `Artist`, `Album` — same keys,
    /// same value types. iTunes inherited the schema from the original
    /// iTunes Music helper protocol; Spotify mirrored it for AppleScript
    /// compatibility back when iTunes was the de-facto music app on
    /// macOS, and they've never broken it.
    ///
    /// Artwork isn't carried in the notification payload (it would
    /// blow the distributed-notification size limit — these are
    /// supposed to be lightweight). Apple Music tracks get artwork via
    /// MediaRemote when that's available; without it we render the
    /// `music.note` placeholder, which is a clean enough fallback
    /// (the user gets the title/artist/play-pause buttons regardless).
    private func applyAppNotification(_ note: Notification, sourceBundleID: String) {
        let userInfo = note.userInfo ?? [:]
        let title = (userInfo["Name"] as? String) ?? ""
        let artist = (userInfo["Artist"] as? String) ?? ""
        let album = userInfo["Album"] as? String
        let stateRaw = (userInfo["Player State"] as? String) ?? ""
        let isPlaying = stateRaw.caseInsensitiveCompare("Playing") == .orderedSame

        NSLog("nox: app-notif source=\(sourceBundleID) title=\"\(title)\" artist=\"\(artist)\" state=\(stateRaw)")

        // Stopped state with no track payload → schedule a deferred
        // session-end clear (500ms grace period). Don't tear down
        // immediately — Spotify constantly sends "no session" between
        // tracks, and immediate clear-then-rebuild flashes the pill
        // back to placeholder. If a real track update arrives within
        // 500ms, the cancel below in the publish path skips the clear.
        // Pattern from jackson-storm/DynamicNotch's transientSession
        // GracePeriod = 0.55 (NowPlayingViewModel.swift:47-49).
        if title.isEmpty && artist.isEmpty && !isPlaying {
            scheduleSessionEnd()
            return
        }

        // Real track update — cancel any pending session-end clear.
        // If we got here, the session is alive after all (Spotify just
        // sent a transient empty-state mid-skip).
        cancelPendingSessionEnd()

        publish(NowPlayingInfo(
            title: title,
            artist: artist,
            album: album,
            artworkData: nil,
            isPlaying: isPlaying,
            sourceBundleID: sourceBundleID,
            // App-specific notifications don't carry timing — the
            // distributed-notification payload size limit can't fit
            // duration + position reliably. We publish nil here and
            // immediately kick off an AppleScript fetch (below) that
            // re-publishes the same track WITH timing populated.
            duration: nil,
            elapsedTime: nil,
            infoTimestamp: nil
        ))

        // Spotify and Apple Music expose `duration of current track`
        // and `player position` via AppleScript — the only reliable
        // source on macOS 15.4+ where MediaRemote is restricted.
        // Fetch once now (so the bar appears with the right starting
        // position) and (re)start the periodic refresher so it stays
        // accurate during playback and after external seeks.
        let appName: String?
        switch sourceBundleID {
        case "com.spotify.client": appName = "Spotify"
        case "com.apple.Music": appName = "Music"
        default: appName = nil
        }
        if let appName, isPlaying {
            startAppScriptTimingTimer(forApp: appName, bundleID: sourceBundleID)
            refreshAppScriptTiming(forApp: appName, bundleID: sourceBundleID)
        } else {
            stopAppScriptTimingTimer()
        }
    }

    // MARK: - AppleScript timing (Spotify / Apple Music)

    private func startAppScriptTimingTimer(forApp appName: String, bundleID: String) {
        if appScriptTimingFor == bundleID, appScriptTimingTimer != nil { return }
        stopAppScriptTimingTimer()
        appScriptTimingFor = bundleID
        let t = Timer(timeInterval: 2.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self,
                      self.appScriptTimingFor == bundleID,
                      let last = self.lastInfo,
                      last.sourceBundleID == bundleID,
                      last.isPlaying
                else {
                    self?.stopAppScriptTimingTimer()
                    return
                }
                self.refreshAppScriptTiming(forApp: appName, bundleID: bundleID)
            }
        }
        RunLoop.main.add(t, forMode: .common)
        appScriptTimingTimer = t
    }

    private func stopAppScriptTimingTimer() {
        appScriptTimingTimer?.invalidate()
        appScriptTimingTimer = nil
        appScriptTimingFor = nil
    }

    /// One-shot fetch on a background queue. On success, hops back
    /// to the main actor and re-publishes `lastInfo` augmented with
    /// the freshly-read duration + position. The infoTimestamp is
    /// the moment the read landed — which is what the view's
    /// `currentPosition(at:)` extrapolation expects.
    private func refreshAppScriptTiming(forApp appName: String, bundleID: String) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let script = """
            tell application "\(appName)"
                if it is running then
                    try
                        set d to (duration of current track) as real
                        set p to (player position) as real
                        return (d as text) & "|" & (p as text)
                    end try
                end if
            end tell
            return ""
            """
            var error: NSDictionary?
            guard let osa = NSAppleScript(source: script) else { return }
            let result = osa.executeAndReturnError(&error)
            guard error == nil,
                  let str = result.stringValue,
                  !str.isEmpty
            else { return }
            let parts = str.split(separator: "|")
            guard parts.count == 2,
                  var duration = Double(parts[0]),
                  let position = Double(parts[1])
            else { return }
            // Spotify's dictionary documents seconds but its actual
            // return values are milliseconds in current builds (a 3-min
            // track returns 184384, not 184). Normalize anything > 1h
            // to seconds so we don't render a 51-hour track. Apple
            // Music returns true seconds and is unaffected by this
            // (real songs are < 3600).
            if duration > 3600 { duration = duration / 1000.0 }
            let fetchedAt = Date()
            DispatchQueue.main.async {
                guard let self,
                      let last = self.lastInfo,
                      last.sourceBundleID == bundleID
                else { return }

                // THROTTLE: skip the publish if the freshly-fetched
                // position matches what we'd have extrapolated from
                // last.elapsedTime + (now - last.infoTimestamp). The
                // 2.5s timer firing during a panel morph used to
                // trigger a full SwiftUI re-render of MusicPanelView
                // mid-animation — visible as jitter. Spotify and
                // Apple Music have very accurate clocks; over a few
                // seconds the projected position is within ~0.3s of
                // the real one. Anything beyond 0.5s drift means
                // the user (or the app) seeked, which IS worth
                // re-publishing.
                if last.duration == duration,
                   let lastElapsed = last.elapsedTime,
                   let lastTimestamp = last.infoTimestamp {
                    let projected = lastElapsed + fetchedAt.timeIntervalSince(lastTimestamp) * (last.isPlaying ? 1 : 0)
                    if abs(position - projected) < 0.5 {
                        // Update the timestamp+elapsed silently so
                        // future projections stay accurate, but
                        // don't fire onChange (no SwiftUI re-render).
                        self.lastInfo = NowPlayingInfo(
                            title: last.title,
                            artist: last.artist,
                            album: last.album,
                            artworkData: last.artworkData,
                            isPlaying: last.isPlaying,
                            sourceBundleID: last.sourceBundleID,
                            duration: duration,
                            elapsedTime: position,
                            infoTimestamp: fetchedAt
                        )
                        return
                    }
                }

                let updated = NowPlayingInfo(
                    title: last.title,
                    artist: last.artist,
                    album: last.album,
                    artworkData: last.artworkData,
                    isPlaying: last.isPlaying,
                    sourceBundleID: last.sourceBundleID,
                    duration: duration,
                    elapsedTime: position,
                    infoTimestamp: fetchedAt
                )
                self.lastInfo = updated
                self.onChange?(updated)
            }
        }
    }

    func stop() {
        let dnc = DistributedNotificationCenter.default()
        let lnc = NotificationCenter.default
        for token in observers {
            dnc.removeObserver(token)
            lnc.removeObserver(token)
        }
        observers.removeAll()
        stopAppScriptTimingTimer()
        // Don't unload the framework — other parts of the system may
        // be using it, and CFBundleUnloadExecutable on a private
        // framework is undefined behavior on Apple silicon.
        lastInfo = nil
    }

    /// True if we successfully resolved enough symbols to do useful
    /// work. The orchestrator can read this to decide whether to
    /// surface "music HUD unavailable" UI somewhere down the line.
    var isAvailable: Bool {
        getNowPlayingInfo != nil
    }

    // MARK: - Commands

    /// Fire a media command at the SAME app whose info we're currently
    /// displaying. The user reported "when I pause it pauses a different
    /// app than the one playing" — that's because
    /// `MRMediaRemoteSendCommand` routes to whichever app MediaRemote
    /// considers the system "primary" client, and that client can drift
    /// from the one publishing the info we're showing (Spotify is paused
    /// but Music has the slot, etc.).
    ///
    /// The fix: when the displayed track came from an app with a
    /// well-known AppleScript dictionary (Spotify, Apple Music — both
    /// inherited the pre-iTunes-rename API), drive that specific app
    /// directly. AppleScript naming is stable across decades, can't be
    /// "stolen" by another app holding the system media slot, and runs
    /// without any private-framework entitlements.
    ///
    /// For unknown source apps (Safari/YouTube tabs, Chrome/Arc, podcast
    /// clients without a stable AppleScript surface), fall through to
    /// `MRMediaRemoteSendCommand`. It's not perfect, but for those
    /// sources MediaRemote is usually the only signal we have, so they
    /// already are the system primary by definition.
    func send(_ command: Command) {
        let bundleID = lastInfo?.sourceBundleID
        switch bundleID {
        case "com.spotify.client":
            runAppleScript(forApp: "Spotify", command: command)
        case "com.apple.Music":
            runAppleScript(forApp: "Music", command: command)
        default:
            // Unknown / nil source. On macOS 15.4+ `sendCommand` resolves
            // to nil (the private framework is restricted) so the bare
            // MediaRemote dispatch is a silent no-op — the user reported
            // "press play, nothing happens, the panel keeps saying
            // Nothing playing" because of exactly this branch.
            //
            // For play-style commands we can still do something useful:
            // if Spotify or Apple Music is already running but paused
            // (no MediaRemote source is published when they're paused),
            // route the AppleScript verb to whichever is running. This
            // matches the empty-state hint the panel shows
            // ("Open Spotify, Apple Music, or any audio source") and
            // makes the play button feel responsive instead of broken.
            //
            // Gate on `runningApplications(withBundleIdentifier:)` so we
            // never auto-launch an app the user hasn't already opened —
            // `tell application "Spotify" to play` would otherwise
            // cold-launch Spotify, which is a surprise click. Skip
            // commands fall through to MediaRemote so we don't try to
            // "next track" a paused app that has no track loaded.
            if command == .play || command == .togglePlayPause {
                if !NSRunningApplication.runningApplications(
                    withBundleIdentifier: "com.spotify.client"
                ).isEmpty {
                    runAppleScript(forApp: "Spotify", command: command)
                    return
                }
                if !NSRunningApplication.runningApplications(
                    withBundleIdentifier: "com.apple.Music"
                ).isEmpty {
                    runAppleScript(forApp: "Music", command: command)
                    return
                }
            }
            _ = sendCommand?(command.rawValue, nil)
        }
    }

    /// Run a play/pause/skip command via AppleScript against a specific
    /// app. Both Spotify and Apple Music expose the same verbs in their
    /// AppleScript dictionary — `play`, `pause`, `playpause`,
    /// `next track`, `previous track`. Spotify inherited this API from
    /// iTunes back when it was the de-facto music app on macOS, and
    /// Apple kept it stable through the iTunes → Music rename, so a
    /// single helper handles both apps.
    ///
    /// The first invocation in a session triggers a system permission
    /// prompt ("Notetaker would like to control \"Spotify\""). The user
    /// has to grant it once; afterwards macOS remembers in System
    /// Settings → Privacy → Automation. We surface the failure as a
    /// log line rather than a UI error because the alternative path
    /// (MediaRemote) usually still works for the same track — just
    /// imprecisely — so a denied prompt isn't a hard break.
    private func runAppleScript(forApp app: String, command: Command) {
        let verb: String
        switch command {
        case .play: verb = "play"
        case .pause: verb = "pause"
        case .togglePlayPause: verb = "playpause"
        case .stop: verb = "pause"            // both apps lack stop; pause is the closest behavior
        case .next: verb = "next track"
        case .previous: verb = "previous track"
        case .toggleShuffle:
            // Spotify and Apple Music both expose `set shuffling
            // to (not shuffling)` — toggle property, not a verb.
            // Skip the verb-style script; route through
            // MediaRemote's MRToggleShuffle command code below.
            _ = sendCommand?(command.rawValue, nil)
            return
        }
        let source = "tell application \"\(app)\" to \(verb)"
        guard let script = NSAppleScript(source: source) else {
            NSLog("nox: AppleScript construction failed for \(app)/\(verb)")
            return
        }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
        if let error {
            NSLog("nox: AppleScript error for \(app)/\(verb): \(error)")
            // Fall back to MediaRemote so a denied automation prompt
            // doesn't leave the user with totally-broken transport.
            _ = sendCommand?(command.rawValue, nil)
        }
    }

    // MARK: - State refresh

    /// Re-read the current now-playing info and isPlaying flag, build
    /// a NowPlayingInfo, dedupe against the last one, and fire onChange.
    /// Called from notification observers and on start().
    private func refresh() {
        guard let getInfo = getNowPlayingInfo else {
            // Without GetNowPlayingInfo there's nothing to publish.
            // This is the post-15.4 restricted path — fail closed.
            NSLog("nox: MediaRemote.refresh() bailed — getNowPlayingInfo is nil (likely restricted on this macOS)")
            return
        }

        getInfo(.main) { [weak self] dict in
            // Per BUG-010 follow-up: the prior `MainActor.assumeIsolated`
            // missed the same actor-isolation hole the notification path
            // got fixed for. Passing `.main` to MediaRemote's C callback
            // gets us on the main *thread* but not in MainActor's
            // isolation domain. `Task { @MainActor in ... }` hops
            // properly. Same template now used in three other call
            // sites in this file plus NotchHUDWindowController.
            Task { @MainActor in
                guard let self else { return }
                self.applyInfoDict(dict)
            }
        }
    }

    private func applyInfoDict(_ dict: [String: Any]) {
        let keysPreview = dict.keys.sorted().prefix(8).joined(separator: ",")
        NSLog("nox: MediaRemote.applyInfoDict empty=\(dict.isEmpty) keys=\(keysPreview)")
        // Empty dict → treat as "nothing playing". Some apps (Safari
        // tabs) clear the dict instead of explicitly publishing
        // isPlaying=false, so we have to handle this edge case.
        //
        // We always fire onChange?(nil) on empty — even if lastInfo is
        // already nil — so the orchestrator's didReceiveInitialNowPlaying
        // flag flips on the very first refresh. Without that, an app
        // launched while no music was playing would never set the
        // initial flag, which doesn't currently break anything (the
        // post-initial path also fires show() correctly via the
        // playStateChanged check), but it's cleaner to keep the
        // emission contract simple: every refresh emits something.
        if dict.isEmpty {
            lastInfo = nil
            onChange?(nil)
            return
        }

        let title = (dict["kMRMediaRemoteNowPlayingInfoTitle"] as? String) ?? ""
        let artist = (dict["kMRMediaRemoteNowPlayingInfoArtist"] as? String) ?? ""
        let album = dict["kMRMediaRemoteNowPlayingInfoAlbum"] as? String
        let artworkData = dict["kMRMediaRemoteNowPlayingInfoArtworkData"] as? Data

        // Timing payload — duration + elapsed-time + the wall-clock
        // moment those values were measured. The view extrapolates the
        // *current* position by adding `now - infoTimestamp` to
        // `elapsedTime`, so we can render a smoothly-advancing progress
        // bar without forcing MediaRemote to fire a refresh every frame.
        // All three are optional — Spotify and Apple Music populate them;
        // YouTube tabs in Safari typically don't. Anything missing
        // collapses the progress bar gracefully (the view nil-guards).
        //
        // We bridge timestamp from the dict's NSDate (or Double seconds
        // since reference, depending on macOS version) into Swift Date.
        // Keeping the bridge tolerant of either shape avoids breaking
        // when Apple flips representations between releases — a thing
        // they've actually done with this key in the past.
        let duration = dict["kMRMediaRemoteNowPlayingInfoDuration"] as? TimeInterval
        let elapsedTime = dict["kMRMediaRemoteNowPlayingInfoElapsedTime"] as? TimeInterval
        let infoTimestamp: Date? = {
            if let date = dict["kMRMediaRemoteNowPlayingInfoTimestamp"] as? Date {
                return date
            }
            if let interval = dict["kMRMediaRemoteNowPlayingInfoTimestamp"] as? TimeInterval {
                return Date(timeIntervalSinceReferenceDate: interval)
            }
            return nil
        }()

        // isPlaying needs a separate async call. If the symbol wasn't
        // resolved (post-15.4 restriction), fall back to "assume
        // playing whenever we have a title" — better to over-show the
        // pill than lose music HUDs entirely. The system will correct
        // us via the next NowPlayingApplicationIsPlayingDidChange
        // notification if that's wrong.
        // Resolve the source bundle ID via the private API. This is
        // the only path that gives us "what app is currently the
        // now-playing source" for browser tabs (Chrome / Safari /
        // Brave etc.) and other apps that don't go through the
        // app-specific notification fallback. Without this the
        // sourceBundleID stays nil for YouTube/Chrome tracks and
        // the "click to open source" gesture doesn't work.
        resolveSourceBundleID { [weak self] sourceID in
            // Per BUG-010 follow-up: same actor-isolation fix as the
            // notification observers above. resolveSourceBundleID's
            // completion fires on the main queue (its inner getDisplayID
            // callback uses `.main`) but outside MainActor isolation.
            Task { @MainActor in
                guard let self else { return }
                if let getPlaying = self.getIsPlaying {
                    getPlaying(.main) { [weak self] playing in
                        // Same fix as the outer hop — proper actor
                        // domain entry, not a runtime assertion.
                        Task { @MainActor in
                            guard let self else { return }
                            self.publish(NowPlayingInfo(
                                title: title,
                                artist: artist,
                                album: album,
                                artworkData: artworkData,
                                isPlaying: playing,
                                sourceBundleID: sourceID,
                                duration: duration,
                                elapsedTime: elapsedTime,
                                infoTimestamp: infoTimestamp
                            ))
                        }
                    }
                } else {
                    let assumed = !title.isEmpty || !artist.isEmpty
                    self.publish(NowPlayingInfo(
                        title: title,
                        artist: artist,
                        album: album,
                        artworkData: artworkData,
                        isPlaying: assumed,
                        sourceBundleID: sourceID,
                        duration: duration,
                        elapsedTime: elapsedTime,
                        infoTimestamp: infoTimestamp
                    ))
                }
            }
        }
    }

    // MARK: - Session-end grace period

    /// Schedule a deferred session clear in 500ms. If a real track
    /// update arrives in that window, `cancelPendingSessionEnd()` is
    /// called from publish() and the clear never happens. Otherwise
    /// the clear fires, lastInfo is nilled, and the HUD collapses.
    /// Per jackson-storm/DynamicNotch's `transientSessionGracePeriod`
    /// = 0.55 in NowPlayingViewModel.swift.
    private func scheduleSessionEnd() {
        // Already scheduled? Don't pile up multiple clears.
        if pendingSessionEndWorkItem != nil { return }
        // No-op if there's nothing to clear.
        guard lastInfo != nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            // Final sanity check at fire time — if a real track update
            // landed and self.pendingSessionEndWorkItem was already
            // cancelled, this work item won't run anyway. But belt +
            // suspenders.
            self.pendingSessionEndWorkItem = nil
            if self.lastInfo != nil {
                self.lastInfo = nil
                self.onChange?(nil)
            }
        }
        pendingSessionEndWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// Cancel a pending session-end clear (a real track update arrived
    /// within the 500ms grace window). Called from publish() at the
    /// top — any successful publish proves the session is alive.
    private func cancelPendingSessionEnd() {
        pendingSessionEndWorkItem?.cancel()
        pendingSessionEndWorkItem = nil
    }

    /// Resolve the active MediaRemote source's bundle ID via the
    /// private symbol if available. Falls back to nil (the existing
    /// publish() inheritance from the previous track will then keep
    /// any previously-known source ID for the same title/artist).
    private func resolveSourceBundleID(_ completion: @escaping (String?) -> Void) {
        guard let getDisplayID = getNowPlayingApplicationDisplayID else {
            completion(nil)
            return
        }
        getDisplayID(.main) { id in
            // Some macOS versions return empty string instead of nil
            // when no source is registered. Normalize to nil.
            let normalized = (id?.isEmpty == false) ? id : nil
            completion(normalized)
        }
    }

    private func publish(_ info: NowPlayingInfo) {
        // Cancel any pending session-end clear at the top of every
        // publish — a real track update is the proof we need that
        // the session is alive. Without this, the deferred clear
        // would still fire 500ms after a transient empty notification
        // even though the session is actually playing again. Pattern
        // from DynamicNotch's NowPlayingViewModel.scheduleSessionEnd
        // / apply(snapshot:) interplay.
        cancelPendingSessionEnd()

        // Inherit sourceBundleID from lastInfo when the new info doesn't
        // carry one but it's clearly the same track. Without this, the
        // app-notification path publishes with sourceBundleID set
        // ("com.spotify.client"), then a follow-up MediaRemote refresh
        // for the same track publishes with sourceBundleID=nil and
        // OVERWRITES the good ID — leaving send() with nothing to route
        // commands against. The user's "pause hits a different app"
        // bug is downstream of this clobber.
        //
        // We only inherit when title and artist match, so a real track
        // change still resets the source. Empty-payload publishes
        // (clears) skip this — they take the "nothing playing" branch
        // below.
        var info = info
        // Same-track inheritance — when title+artist match the last
        // publish, fields the new info doesn't carry are filled in
        // from lastInfo. Four inheritances matter:
        //   • sourceBundleID — keeps `send()` routing pointed at the
        //     right app when a follow-up publish arrives without a
        //     bundle ID (the original "pause hits a different app"
        //     bug).
        //   • duration / elapsedTime / infoTimestamp — keeps the
        //     progress bar's `hasTiming` true across play/pause
        //     toggles. Otherwise: notification fires (no timing) →
        //     bar's gesture early-returns on `hasTiming` → user's
        //     click is silently ignored. AppleScript refresher will
        //     repopulate timing within 2.5s but during that window
        //     the bar is unresponsive. Inheriting preserves it.
        //   • artworkData — kills the "thumbnail goes missing
        //     mid-playback" bug. Spotify (and to a lesser extent
        //     Apple Music) push notifications in stages: title +
        //     artist arrive first, artwork bytes arrive 200-500ms
        //     later in a SECOND notification for the same track.
        //     Without this inheritance, the second notification
        //     publishes with artworkData=nil → overwrites the good
        //     bytes from the first publish + iTunes-Search fill →
        //     the user sees the thumbnail vanish. boring.notch
        //     (TheBoredTeam/boring.notch on GitHub) uses the same
        //     "preserve on diff, only clear on full update" pattern
        //     in its NowPlayingController. Reference:
        //     boringNotch/MediaControllers/NowPlayingController.swift
        //     (the `else if !diff { artwork = nil }` guard).
        // Track CHANGE (different title/artist) skips inheritance
        // entirely so a new song starts fresh.
        if let last = lastInfo,
           !info.title.isEmpty,
           info.title == last.title,
           info.artist == last.artist {
            info = NowPlayingInfo(
                title: info.title,
                artist: info.artist,
                album: info.album,
                artworkData: info.artworkData ?? last.artworkData,
                isPlaying: info.isPlaying,
                sourceBundleID: info.sourceBundleID ?? last.sourceBundleID,
                duration: info.duration ?? last.duration,
                elapsedTime: info.elapsedTime ?? last.elapsedTime,
                infoTimestamp: info.infoTimestamp ?? last.infoTimestamp
            )
        }

        NSLog("nox: MediaRemote.publish title=\"\(info.title)\" artist=\"\(info.artist)\" isPlaying=\(info.isPlaying) hasArt=\(info.artworkData != nil) source=\(info.sourceBundleID ?? "nil")")
        // Dedup — many notifications fire spurious refreshes (every
        // ~1s for elapsed-time updates on some sources). Without this
        // check the HUD would re-bloom every second during playback.
        if info == lastInfo { return }
        // Bail if there's literally nothing to show — empty title AND
        // empty artist AND not playing means no useful payload.
        if !info.isPresentable && !info.isPlaying {
            if lastInfo != nil {
                lastInfo = nil
                onChange?(nil)
            }
            return
        }
        // Pause debounce: if we're transitioning from playing → paused,
        // hold the new (paused) state for 200ms before publishing.
        // Spotify emits a paused-state ping for 80-150ms between
        // tracks during a skip; without this debounce the user sees
        // the waveform briefly freeze + glow drop, then resume — a
        // visible flicker. With it, only genuine pauses (held for
        // >200ms) propagate.
        let wasPlaying = lastInfo?.isPlaying ?? false
        let isTransitionToPause = wasPlaying && !info.isPlaying
            && lastInfo?.title == info.title
            && lastInfo?.artist == info.artist
        if isTransitionToPause {
            pauseDebounceWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.lastInfo = info
                self.onChange?(info)
                self.fetchArtworkIfNeeded(for: info)
            }
            pauseDebounceWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + pauseDebounceDelay, execute: work)
            return
        }
        // Any non-pause-transition publish cancels a pending pause
        // debounce — the new state wins immediately. Covers the
        // "Spotify resumed before debounce fired" case.
        pauseDebounceWorkItem?.cancel()
        pauseDebounceWorkItem = nil

        lastInfo = info
        onChange?(info)
        // Kick off async artwork fill after the synchronous publish so
        // subscribers see the title/artist update immediately while the
        // image bytes are still in flight. fetchArtworkIfNeeded is a
        // no-op when artwork is already present or when we're already
        // fetching the same track.
        fetchArtworkIfNeeded(for: info)
    }

    // MARK: - Artwork lookup

    /// Build a normalized cache key from title + artist. Lowercased and
    /// trimmed so the same track surfaced from two slightly different
    /// payloads (Spotify includes a trailing space on some albums; some
    /// tracks vary "feat." capitalization between sources) hits the
    /// same slot.
    private func artworkKey(for info: NowPlayingInfo) -> String? {
        let title = info.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let artist = info.artist.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if title.isEmpty && artist.isEmpty { return nil }
        return "\(title)|\(artist)"
    }

    /// Fill in artwork via iTunes Search if the snapshot lacks it. The
    /// path here covers both restricted-MediaRemote macOS versions
    /// (15.4+ where `kMRMediaRemoteNowPlayingInfoArtworkData` comes back
    /// nil) AND the app-specific notification fallback (Spotify and
    /// Apple Music's distributed notifications never carry artwork
    /// bytes — they'd blow the notification size limit). On a cache
    /// hit we re-publish synchronously; on a miss we dispatch a
    /// detached Task and re-publish from its completion.
    ///
    /// IN-FLIGHT CANCELLATION: every call cancels any prior in-flight
    /// fetch task BEFORE starting a new one — boring.notch
    /// (TheBoredTeam/boring.notch) does the same in its
    /// `SpotifyController.swift` (`artworkFetchTask?.cancel()` at
    /// line 138). Without this, fast track-skipping leaves stale
    /// fetches racing the new track's fetch — they don't corrupt
    /// the UI (the title/artist guard at completion time prevents
    /// that) but they waste network and can starve the new fetch
    /// when running over a slow connection.
    private func fetchArtworkIfNeeded(for info: NowPlayingInfo) {
        // Treat tiny artwork (<1024 bytes) as effectively missing.
        // Apple Podcasts publishes a ~72-byte placeholder stub via
        // MediaRemote rather than nothing — verified by capturing
        // the Perl-bridge stream on 2026-04-29 (payload had
        // `artwork=72b` for a real episode). Without this guard the
        // existing nil-only check would treat the stub as valid art
        // and skip the iTunes Search fallback, leaving the small pill
        // showing the music-note placeholder for podcasts forever.
        // 1024 is a safe floor — any real JPEG/PNG album art is at
        // least 5-10KB even at lowest quality.
        let bytes = info.artworkData?.count ?? 0
        guard bytes < 1024 else { return }
        guard let key = artworkKey(for: info) else { return }

        if let cached = artworkCache[key] {
            // Per BUG-039 fix: promote to most-recently-used so
            // an active hot track doesn't get evicted just
            // because it's been in the cache the longest.
            promoteArtworkCacheKey(key)
            // Re-publish with the cached bytes. publish() will dedup
            // against lastInfo (which lacks artworkData), so the new
            // info is genuinely different and onChange fires once more
            // with the artwork filled in.
            publish(info.with(artworkData: cached))
            return
        }
        if artworkInFlight.contains(key) { return }
        artworkInFlight.insert(key)

        // Cancel any prior in-flight fetch — protects against
        // wasted bandwidth when the user fast-skips through tracks.
        currentArtworkFetchTask?.cancel()

        let title = info.title
        let artist = info.artist
        let bundleID = info.sourceBundleID
        currentArtworkFetchTask = Task.detached(priority: .userInitiated) { [weak self] in
            // 2026-05-01: try YouTube thumbnail FIRST when the source
            // is a browser. Many YouTube videos don't include artwork
            // bytes in their MediaSession metadata, so the small pill
            // shows the music-note placeholder. But every YouTube
            // video has a thumbnail at a deterministic URL —
            // `https://i.ytimg.com/vi/{ID}/hqdefault.jpg`. Get the
            // active tab URL via AppleScript, parse the video ID,
            // fetch. Falls through to iTunes Search if the URL isn't
            // a YouTube URL or the fetch fails. Pattern from the
            // 2026-04-29 reverse-engineering research findings.
            var data: Data? = nil
            if let bundleID, ["com.apple.Safari", "com.google.Chrome", "company.thebrowser.Browser", "com.brave.Browser"].contains(bundleID) {
                if let ytData = await Self.lookupYouTubeThumbnail(bundleID: bundleID) {
                    data = ytData
                }
            }
            if data == nil {
                data = await Self.lookupArtwork(title: title, artist: artist)
            }
            // Capture cancellation BEFORE the MainActor hop so the
            // cleanup branch below always runs regardless of state.
            let wasCancelled = Task.isCancelled
            await MainActor.run {
                guard let self else { return }
                // ALWAYS clean up the in-flight flag, even on cancel.
                // Earlier version returned before this line on
                // Task.isCancelled, which leaked the key forever:
                // a cancelled fetch left `artworkInFlight` containing
                // the key, so the next fetchArtworkIfNeeded() for the
                // SAME track silently bailed at the `if
                // artworkInFlight.contains(key) { return }` guard —
                // no artwork ever loaded for that track again. User
                // saw "Break My Heart" / Dua Lipa with the music-
                // note placeholder on screen and reported the bug.
                self.artworkInFlight.remove(key)
                // Skip publishing on cancellation — the next track's
                // fetch is already in flight and will publish its own
                // artwork; this stale result isn't useful.
                if wasCancelled { return }
                guard let data else { return }
                // Per BUG-039 fix: bounded LRU insert.
                self.insertArtworkCacheEntry(key: key, data: data)
                // Only re-publish if this is still the current track.
                // The user may have skipped to a different song while
                // the lookup was in flight; we don't want to slap the
                // wrong artwork onto a fresh snapshot.
                guard let last = self.lastInfo,
                      last.title == title,
                      last.artist == artist else { return }
                self.publish(last.with(artworkData: data))
            }
        }
    }

    /// URLSession used for artwork downloads. Tight per-request and
    /// per-resource timeouts (5s / 8s) so a slow CDN miss doesn't
    /// hang the artwork pipeline for the default 60 seconds — the
    /// user sees a placeholder or the track-app icon for at most a
    /// few seconds, then iTunes Search retries on the next track
    /// notification.
    ///
    /// boring.notch's `ImageService` uses `URLSession.shared` with
    /// no explicit timeout but RELIES on its `artworkFetchTask?.
    /// cancel()` pattern to interrupt slow fetches when the next
    /// track arrives. We use both: cancellation (above) AND a
    /// shorter session timeout, since our pill stays mounted longer
    /// per track than their notch HUD.
    private static let artworkURLSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 5.0
        config.timeoutIntervalForResource = 8.0
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    /// LRU bookkeeping: insert (or replace) an artwork cache
    /// entry, evicting the least-recently-used key once we go
    /// over the cap. Per BUG-039 fix.
    private func insertArtworkCacheEntry(key: String, data: Data) {
        if artworkCache[key] != nil {
            // Replace + promote.
            artworkCache[key] = data
            promoteArtworkCacheKey(key)
            return
        }
        artworkCache[key] = data
        artworkCacheOrder.append(key)
        while artworkCacheOrder.count > artworkCacheLimit {
            let oldest = artworkCacheOrder.removeFirst()
            artworkCache.removeValue(forKey: oldest)
        }
    }

    /// Move `key` to the most-recently-used end of
    /// `artworkCacheOrder`. Per BUG-039 fix.
    private func promoteArtworkCacheKey(_ key: String) {
        if let idx = artworkCacheOrder.firstIndex(of: key) {
            artworkCacheOrder.remove(at: idx)
            artworkCacheOrder.append(key)
        }
    }

    /// One-shot iTunes Search query. Returns the first matching song's
    /// artwork as JPEG/PNG bytes, or nil if anything along the way
    /// failed (no matches, network timeout, decode error). iTunes
    /// serves 100×100 by default; URL-substituting `100x100bb` for
    /// `600x600bb` gets us a sharp asset for the panel's 180pt artwork
    /// at retina densities without any extra round trip.
    /// Strip the noise iTunes Search hates from a track title:
    ///   - "(feat. WILLOW)" / "(feat. Olivia Rodrigo)" parentheticals
    ///   - "(Sped Up)" / "(Slowed Down)" variant labels
    ///   - "(Remastered 2024)" / "(Live)" / "(Acoustic)" annotations
    ///   - " - Remastered 2024" / " - Sped Up" trailing dash segments
    /// iTunes Search relevance scoring drops the result when these
    /// extras don't exactly match its catalog metadata. Stripping
    /// them gets us a clean "Title Artist" query that hits reliably.
    /// Per the research finding on Atoll's `lookupArtwork` cleanup
    /// pattern.
    private static func sanitizeForITunesSearch(_ raw: String) -> String {
        var s = raw
        // Drop parenthetical content
        while let range = s.range(of: "\\s*\\([^)]*\\)", options: .regularExpression) {
            s.removeSubrange(range)
        }
        while let range = s.range(of: "\\s*\\[[^\\]]*\\]", options: .regularExpression) {
            s.removeSubrange(range)
        }
        // Drop trailing " - <variant>" segments
        if let dashRange = s.range(of: " - ") {
            s.removeSubrange(dashRange.lowerBound..<s.endIndex)
        }
        // Drop "feat." / "ft." mentions if any survived
        s = s.replacingOccurrences(of: "feat\\..*", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "ft\\..*", with: "", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Get the URL of the active tab in the given browser via
    /// AppleScript, parse a YouTube video ID if present, and
    /// fetch `https://i.ytimg.com/vi/{ID}/hqdefault.jpg`.
    /// Returns nil if not a YouTube URL or fetch fails.
    ///
    /// Supported browsers: Safari, Chrome, Arc, Brave. Each has
    /// a slightly different AppleScript dictionary for getting
    /// the active tab URL.
    private static func lookupYouTubeThumbnail(bundleID: String) async -> Data? {
        // Get the URL via AppleScript on the calling browser.
        let script: String
        switch bundleID {
        case "com.apple.Safari":
            script = "tell application \"Safari\" to return URL of current tab of front window"
        case "com.google.Chrome":
            script = "tell application \"Google Chrome\" to return URL of active tab of front window"
        case "company.thebrowser.Browser":
            // Arc uses Chrome's scripting interface.
            script = "tell application \"Arc\" to return URL of active tab of front window"
        case "com.brave.Browser":
            script = "tell application \"Brave Browser\" to return URL of active tab of front window"
        default:
            return nil
        }
        // Run the AppleScript synchronously in a detached task so
        // we don't block the main thread. NSAppleScript blocks
        // ~100-300ms per call; we're already in a Task.detached
        // path so this is fine.
        guard let urlString = await withCheckedContinuation({ (cont: CheckedContinuation<String?, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let appleScript = NSAppleScript(source: script) else {
                    cont.resume(returning: nil)
                    return
                }
                var error: NSDictionary?
                let result = appleScript.executeAndReturnError(&error)
                if error != nil {
                    cont.resume(returning: nil)
                    return
                }
                cont.resume(returning: result.stringValue)
            }
        }) else {
            return nil
        }
        // Extract YouTube video ID from the URL. Supports:
        //   • https://www.youtube.com/watch?v=VIDEO_ID&...
        //   • https://youtu.be/VIDEO_ID
        //   • https://music.youtube.com/watch?v=VIDEO_ID
        //   • https://www.youtube.com/shorts/VIDEO_ID
        guard let videoID = extractYouTubeVideoID(from: urlString) else {
            return nil
        }
        // Fetch hqdefault.jpg — public CDN, no auth needed,
        // ~480x360px which is plenty for the 22pt pill artwork.
        guard let thumbURL = URL(string: "https://i.ytimg.com/vi/\(videoID)/hqdefault.jpg") else {
            return nil
        }
        do {
            let (data, response) = try await artworkURLSession.data(from: thumbURL)
            // YouTube returns a 120x90 placeholder image (~1.5KB) for
            // videos that don't have an hqdefault thumbnail. Reject
            // anything under 5KB so we fall through to iTunes Search.
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  data.count > 5000 else {
                return nil
            }
            NSLog("nox: YouTube thumb fetched videoID=\(videoID) bytes=\(data.count)")
            return data
        } catch {
            return nil
        }
    }

    /// Extract a YouTube video ID from a URL string. Handles
    /// the common YouTube URL shapes (watch?v=, youtu.be/, shorts/, music).
    private static func extractYouTubeVideoID(from urlString: String) -> String? {
        guard let url = URL(string: urlString),
              let host = url.host?.lowercased() else { return nil }

        if host.contains("youtu.be") {
            // https://youtu.be/VIDEO_ID
            let id = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return id.isEmpty ? nil : id
        }

        if host.contains("youtube.com") {
            // /watch?v=ID OR /shorts/ID OR /embed/ID
            if url.path == "/watch" {
                let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
                return comps?.queryItems?.first(where: { $0.name == "v" })?.value
            }
            if url.path.hasPrefix("/shorts/") {
                return String(url.path.dropFirst("/shorts/".count))
                    .components(separatedBy: "/").first
            }
            if url.path.hasPrefix("/embed/") {
                return String(url.path.dropFirst("/embed/".count))
                    .components(separatedBy: "/").first
            }
        }
        return nil
    }

    private static func lookupArtwork(title: String, artist: String) async -> Data? {
        // Sanitize both fields independently — title gets the
        // parenthetical/variant scrub; artist usually doesn't have
        // those but gets trimmed for safety.
        let cleanTitle = sanitizeForITunesSearch(title)
        let cleanArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let term = "\(cleanTitle) \(cleanArtist)".trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else { return nil }

        var components = URLComponents(string: "https://itunes.apple.com/search")
        components?.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "1")
        ]
        guard let url = components?.url else { return nil }

        do {
            let (data, _) = try await artworkURLSession.data(from: url)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = json["results"] as? [[String: Any]],
                  let first = results.first,
                  let artUrl100 = first["artworkUrl100"] as? String else {
                NSLog("nox: artwork lookup miss for \"\(term)\"")
                return nil
            }
            // 100×100 → 600×600. iTunes serves the larger asset off the
            // same CDN; this is just a URL rewrite, no extra negotiation.
            let upscaled = artUrl100.replacingOccurrences(of: "100x100bb", with: "600x600bb")
            guard let imageURL = URL(string: upscaled) else { return nil }
            let (imgData, _) = try await artworkURLSession.data(from: imageURL)
            NSLog("nox: artwork lookup hit for \"\(term)\" (\(imgData.count) bytes)")
            return imgData
        } catch {
            NSLog("nox: artwork lookup error for \"\(term)\": \(error)")
            return nil
        }
    }

    /// Pull the current Spotify track's artwork URL via AppleScript,
    /// then download the bytes. THIS IS THE CRITICAL PATH ON MACOS 26.
    ///
    /// Why we need this: macOS 15.4+ tightened MediaRemote so that
    /// `MRMediaRemoteGetNowPlayingInfo`'s `playbackQueue` read returns
    /// "Operation not permitted" for our app — observed in Console.app
    /// as `Error Domain=kMRMediaRemoteFrameworkErrorDomain Code=3`.
    /// That means Spotify's bundled artwork bytes never reach us via
    /// MediaRemote on this OS. iTunes Search is one fallback, but it
    /// misses tracks (regional restrictions, explicit-version mismatches,
    /// recent releases not yet indexed — observed: "Pain" by
    /// PinkPantheress).
    ///
    /// Spotify's AppleScript dictionary `artwork url of current track`
    /// returns the EXACT current track's Spotify CDN URL. Format is
    /// usually `https://i.scdn.co/image/ab67616d0000b273...` (HTTPS)
    /// directly — no URI-conversion needed. Some older Spotify versions
    /// return `spotify:image:HASH` URIs, which we convert to
    /// `https://i.scdn.co/image/HASH` before fetching.
    ///
    /// Reference: TheBoredTeam/boring.notch's
    /// `boringNotch/MediaControllers/SpotifyController.swift` lines
    /// 176-199 use the same AS approach.
    private static func lookupSpotifyArtworkURL() async -> Data? {
        let urlString: String? = await Task.detached(priority: .userInitiated) {
            let script = """
            tell application "Spotify"
                if it is running then
                    try
                        return artwork url of current track
                    on error
                        return ""
                    end try
                end if
            end tell
            return ""
            """
            var error: NSDictionary?
            guard let osa = NSAppleScript(source: script) else { return nil }
            let result = osa.executeAndReturnError(&error)
            if let err = error {
                NSLog("nox: Spotify artwork-url AS error: \(err)")
                return nil
            }
            guard let str = result.stringValue, !str.isEmpty else { return nil }
            return str
        }.value

        guard let raw = urlString else { return nil }
        // Convert Spotify URI scheme to HTTPS if needed.
        let httpsURL: String
        if raw.hasPrefix("spotify:image:") {
            let hash = raw.replacingOccurrences(of: "spotify:image:", with: "")
            httpsURL = "https://i.scdn.co/image/\(hash)"
        } else {
            httpsURL = raw
        }
        guard let url = URL(string: httpsURL) else { return nil }
        do {
            let (imgData, _) = try await artworkURLSession.data(from: url)
            guard !imgData.isEmpty else { return nil }
            NSLog("nox: Spotify AS artwork hit (\(imgData.count) bytes) URL=\(httpsURL)")
            return imgData
        } catch {
            NSLog("nox: Spotify AS artwork fetch error: \(error)")
            return nil
        }
    }
}
