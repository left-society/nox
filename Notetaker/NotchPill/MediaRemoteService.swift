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

    /// True when there's enough payload to bother showing a HUD. A
    /// title or artist plus any sign of playback (or known source) is
    /// enough; an empty info dict means "nothing playing" → hide.
    var isPresentable: Bool {
        !title.isEmpty || !artist.isEmpty
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

    /// Most recent snapshot, used for diffing across notifications and
    /// for command callbacks that want to read state synchronously.
    private var lastInfo: NowPlayingInfo?
    private var observers: [NSObjectProtocol] = []

    // MARK: - Lifecycle

    /// Resolve symbols and start listening. Idempotent — second call
    /// is a no-op. Returns silently on any framework-load or symbol-
    /// resolve failure; check `isAvailable` if you need to know.
    func start() {
        guard bundle == nil else { return }

        let url = URL(fileURLWithPath: "/System/Library/PrivateFrameworks/MediaRemote.framework")
        guard let cfBundle = CFBundleCreate(kCFAllocatorDefault, url as CFURL) else {
            NSLog("Notetaker: MediaRemote framework not found at \(url.path)")
            return
        }
        guard CFBundleLoadExecutable(cfBundle) else {
            NSLog("Notetaker: MediaRemote framework failed to load")
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
        NSLog("Notetaker: MediaRemote symbols — getInfo=\(getNowPlayingInfo != nil) getIsPlaying=\(getIsPlaying != nil) sendCommand=\(sendCommand != nil) registerNotifs=\(registerForNotifications != nil)")

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
            // Routed through MainActor.assumeIsolated to keep the call
            // site simple — these post on the main queue (we passed
            // `.main` to register), and the closure body calls into
            // @MainActor methods.
            let token = nc.addObserver(
                forName: Notification.Name(name),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
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
                MainActor.assumeIsolated {
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
                MainActor.assumeIsolated {
                    self?.applyAppNotification(note, sourceBundleID: entry.source)
                }
            }
            observers.append(token)
        }

        // Pull initial state so the orchestrator has a baseline before
        // the user changes tracks.
        refresh()
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

        NSLog("Notetaker: app-notif source=\(sourceBundleID) title=\"\(title)\" artist=\"\(artist)\" state=\(stateRaw)")

        // Stopped state with no track payload → publish nil (collapse
        // the HUD). We treat "Paused" as "still showing the pill but
        // marked paused" — same as MediaRemote behavior — so the user
        // can hit play in the HUD without re-summoning it.
        if title.isEmpty && artist.isEmpty && !isPlaying {
            if lastInfo != nil {
                lastInfo = nil
                onChange?(nil)
            }
            return
        }

        publish(NowPlayingInfo(
            title: title,
            artist: artist,
            album: album,
            artworkData: nil,
            isPlaying: isPlaying,
            sourceBundleID: sourceBundleID
        ))
    }

    func stop() {
        let dnc = DistributedNotificationCenter.default()
        let lnc = NotificationCenter.default
        for token in observers {
            dnc.removeObserver(token)
            lnc.removeObserver(token)
        }
        observers.removeAll()
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

    /// Fire a media command at whichever app currently owns the
    /// now-playing slot. Returns silently if the symbol wasn't
    /// resolved (e.g. on a future macOS that locks it down).
    func send(_ command: Command) {
        _ = sendCommand?(command.rawValue, nil)
    }

    // MARK: - State refresh

    /// Re-read the current now-playing info and isPlaying flag, build
    /// a NowPlayingInfo, dedupe against the last one, and fire onChange.
    /// Called from notification observers and on start().
    private func refresh() {
        guard let getInfo = getNowPlayingInfo else {
            // Without GetNowPlayingInfo there's nothing to publish.
            // This is the post-15.4 restricted path — fail closed.
            NSLog("Notetaker: MediaRemote.refresh() bailed — getNowPlayingInfo is nil (likely restricted on this macOS)")
            return
        }

        getInfo(.main) { [weak self] dict in
            // The closure may fire on .main asynchronously; route back
            // to MainActor via assumeIsolated since we passed .main.
            MainActor.assumeIsolated {
                guard let self else { return }
                self.applyInfoDict(dict)
            }
        }
    }

    private func applyInfoDict(_ dict: [String: Any]) {
        let keysPreview = dict.keys.sorted().prefix(8).joined(separator: ",")
        NSLog("Notetaker: MediaRemote.applyInfoDict empty=\(dict.isEmpty) keys=\(keysPreview)")
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

        // isPlaying needs a separate async call. If the symbol wasn't
        // resolved (post-15.4 restriction), fall back to "assume
        // playing whenever we have a title" — better to over-show the
        // pill than lose music HUDs entirely. The system will correct
        // us via the next NowPlayingApplicationIsPlayingDidChange
        // notification if that's wrong.
        if let getPlaying = getIsPlaying {
            getPlaying(.main) { [weak self] playing in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.publish(NowPlayingInfo(
                        title: title,
                        artist: artist,
                        album: album,
                        artworkData: artworkData,
                        isPlaying: playing,
                        sourceBundleID: nil // Resolved at view layer if needed
                    ))
                }
            }
        } else {
            // Symbol restricted — assume playing if we have a title.
            // Publish synchronously so we don't strand the dict.
            let assumed = !title.isEmpty || !artist.isEmpty
            publish(NowPlayingInfo(
                title: title,
                artist: artist,
                album: album,
                artworkData: artworkData,
                isPlaying: assumed,
                sourceBundleID: nil
            ))
        }
    }

    private func publish(_ info: NowPlayingInfo) {
        NSLog("Notetaker: MediaRemote.publish title=\"\(info.title)\" artist=\"\(info.artist)\" isPlaying=\(info.isPlaying)")
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
        lastInfo = info
        onChange?(info)
    }
}
