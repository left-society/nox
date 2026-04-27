import AppKit
import Foundation

/// Single owner of the notch HUD subsystem. Wires the
/// `PowerSourceWatcher` (event source) to the
/// `NotchHUDWindowController` (visual surface), with a dash of
/// debouncing in between so we only bloom the pill on real
/// transitions — not on the periodic refresh notifications IOKit
/// sometimes emits while a battery is steady-state on AC.
///
/// Future HUDs (now-playing, AirPods, focus mode, etc.) plug in here
/// the same way: a watcher emits a state, the orchestrator decides
/// whether the new state warrants a presentation, and the HUD
/// controller takes care of the rest. Keeping this in one place means
/// future HUDs can compete for notch real estate (queue / preempt) in
/// a single coordinated spot rather than fighting each other across
/// scattered modules.
@MainActor
final class NotchOrchestrator {
    private let hudController: NotchHUDWindowController
    private let powerWatcher: PowerSourceWatcher
    private let mediaService: MediaRemoteService
    /// Fallback browser-tab probe — used when MediaRemote is
    /// restricted (macOS 15.4+ revokes private framework access)
    /// and we need SOMETHING to publish for YouTube/SoundCloud/etc.
    private let browserProbe: BrowserMediaProbe
    /// Universal "what app is producing audio" detector via
    /// CoreAudio. Catches everything (YouTube, WhatsApp, Discord,
    /// VLC, etc.) that the browser probe misses. Publishes the
    /// app name + bundle ID; the pill's existing icon-fallback
    /// fills in the artwork from the app bundle.
    private let audioWatcher: SystemAudioWatcher
    private let lockScreenWatcher: LockScreenWatcher
    /// Wall-clock time of the last MediaRemote publish — drives
    /// the browserProbe's `isMediaRemoteSilent` gate so we don't
    /// clobber real MediaRemote data when it eventually arrives.
    private var lastMediaRemoteAt: Date = .distantPast
    private var quietWatchdog: Timer?

    /// External now-playing observer. AppDelegate installs this to
    /// forward MediaRemote snapshots into PanelPresenter so the
    /// notes-panel can render its own music page (MusicPanelView)
    /// without having to know about the orchestrator. Fires for
    /// every snapshot — including nil when nothing's playing —
    /// because PanelPresenter's `visibleTabs` and "auto-bounce off
    /// .music when playback stops" logic both depend on the nil
    /// transition arriving promptly.
    var onNowPlayingChange: ((NowPlayingInfo?) -> Void)?

    /// Charging plug-in / unplug events. Routed to AppDelegate
    /// which sets `presenter.pendingSystemEvent`, causing the
    /// resting pill to morph into a transient charging indicator
    /// for a few seconds, then revert to music. Replaces the
    /// previous separate-HUD pill that floated below the notch.
    var onChargingChange: ((Int, Bool) -> Void)?

    /// Edges from LockScreenWatcher. AppDelegate routes this into
    /// `presenter.isLocked` so the lock-screen music card window
    /// can show/hide based on session state.
    var onLockStateChange: ((Bool) -> Void)?

    /// Send a media command (play/pause/skip) into whichever app owns
    /// the now-playing slot. Exposed publicly so MusicPanelView's
    /// transport buttons (routed via `PanelPresenter.onMediaCommand`)
    /// can drive playback the same way the notch HUD's transport
    /// buttons already do.
    ///
    /// Dispatch:
    ///   - Browser sources (the bundle ID matches a tab the
    ///     BrowserMediaProbe is currently tracking) → run an
    ///     AppleScript that activates the audible tab and
    ///     synthesizes the page's keystroke (k for YouTube
    ///     play/pause, etc.). MRMediaRemoteSendCommand is restricted
    ///     on macOS 15.4+ and won't reach Chrome anyway, so this is
    ///     the only path that actually controls a YouTube tab.
    ///   - Everything else → MediaRemoteService.send, which
    ///     dispatches to AppleScript for Spotify/Music and
    ///     MRMediaRemoteSendCommand for the rest.
    func sendMediaCommand(_ command: MediaRemoteService.Command) {
        if let ref = browserProbe.lastAudibleTab,
           ref.bundleID == lastForwardedBundleID {
            if browserProbe.sendCommandToAudibleTab(command) {
                return
            }
        }
        mediaService.send(command)
    }

    /// Bring the source app for the currently-displayed track to the
    /// front. For browser audio, jumps to the specific tab playing
    /// (via BrowserMediaProbe's cached AudibleTabRef). For everything
    /// else, just opens the app by bundle ID.
    ///
    /// PanelPresenter.onOpenSourceApp is wired here from AppDelegate
    /// so MusicPanelView's artwork tap travels through this single
    /// dispatch instead of doing NSWorkspace.openApplication itself
    /// (which would always open the app to its default window — not
    /// the YouTube tab the user actually wants to look at).
    func openSourceApp() {
        if let ref = browserProbe.lastAudibleTab,
           ref.bundleID == lastForwardedBundleID {
            if browserProbe.openAudibleTab() {
                return
            }
        }
        guard let bundleID = lastForwardedBundleID else { return }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in
            if let error {
                NSLog("Notetaker: failed to open \(bundleID): \(error)")
            }
        }
    }

    /// Mirrors the most recently forwarded NowPlayingInfo's source
    /// bundle so transport / open-source dispatch can decide whether
    /// the displayed pill came from a browser tab. Updated inside
    /// `handleNowPlayingChange`.
    private var lastForwardedBundleID: String?

    /// Tracked separately from PowerSourceWatcher's internal dedup so
    /// we can apply orchestrator-level rules (only show on transition,
    /// not on every IOKit emit). Nil until the first state lands.
    private var lastPowerState: PowerState?
    private var didReceiveInitialPowerState = false

    // Now-playing dedup state used to live here, when the orchestrator
    // also bloomed the notch HUD on title / play-state changes. After
    // unifying the pill with the main panel (Alcove-style), the panel
    // itself owns now-playing presentation: it sits at resting-pill
    // geometry whenever there's a current track and morphs into the
    // full music page on hover. The orchestrator's only remaining
    // responsibility for now-playing is to forward every snapshot to
    // the external subscriber (PanelPresenter via AppDelegate), so
    // there is no decision left for it to make and no state to track.

    init() {
        self.hudController = NotchHUDWindowController()
        self.mediaService = MediaRemoteService()
        self.browserProbe = BrowserMediaProbe()
        self.audioWatcher = SystemAudioWatcher()
        self.lockScreenWatcher = LockScreenWatcher()
        let box = WeakBox()
        self.powerWatcher = PowerSourceWatcher { state in
            box.target?.handlePowerState(state)
        }
        self.mediaService.onChange = { [weak box] info in
            box?.target?.handleMediaRemoteChange(info)
        }
        self.browserProbe.onChange = { [weak box] info in
            box?.target?.handleBrowserProbeChange(info)
        }
        self.audioWatcher.onChange = { [weak box] info in
            box?.target?.handleAudioWatcherChange(info)
        }
        self.lockScreenWatcher.onChange = { [weak box] locked in
            box?.target?.onLockStateChange?(locked)
        }
        self.hudController.onMediaCommand = { [weak box] command in
            box?.target?.mediaService.send(command)
        }
        box.target = self
    }

    /// MediaRemote-source publish path. Only marks "real" data as
    /// active when the source is actively PLAYING — paused-but-loaded
    /// tracks (Spotify keeping metadata after the user pauses it)
    /// shouldn't lock out the browser probe. Otherwise a paused
    /// Spotify session perpetually wins over a YouTube tab the user
    /// is actively watching, which is exactly the bug the user
    /// reported: "when I'm playing a YouTube video, it has the
    /// overlay of Spotify."
    private func handleMediaRemoteChange(_ info: NowPlayingInfo?) {
        if let info, info.isPlaying {
            lastMediaRemoteAt = Date()
            browserProbe.isMediaRemoteSilent = false
        } else if info == nil {
            // Explicit clear from MediaRemote — let the probe step in
            // immediately, no need to wait for the watchdog.
            browserProbe.isMediaRemoteSilent = true
        }
        // For paused-but-loaded info: forward it (so the pill still
        // shows the track data and pause-state correctly) BUT don't
        // refresh `lastMediaRemoteAt`. After 5s of paused state,
        // the watchdog will mark MediaRemote silent and the browser
        // probe will start publishing — taking precedence over the
        // stale paused metadata.
        handleNowPlayingChange(info)
    }

    /// Browser-probe fallback publish path. Only used when MediaRemote
    /// has been silent for a while (the gate is enforced by the probe
    /// itself). Routes through the same handler so downstream
    /// (PanelPresenter) doesn't need to distinguish sources.
    private func handleBrowserProbeChange(_ info: NowPlayingInfo?) {
        handleNowPlayingChange(info)
    }

    /// Audio-watcher fallback publish path. Wins when MediaRemote
    /// has nothing AND the browser probe has nothing (or yields
    /// the same data). Provides app-name + bundle ID for any
    /// process producing audio system-wide.
    private func handleAudioWatcherChange(_ info: NowPlayingInfo?) {
        // Only publish if MediaRemote isn't currently active. If
        // the user is playing Spotify, we don't want to overwrite
        // its rich metadata with the watcher's app-name fallback.
        let mediaRemoteSilent = Date().timeIntervalSince(lastMediaRemoteAt) > 5.0
        guard mediaRemoteSilent else { return }
        handleNowPlayingChange(info)
    }

    /// Tiny weak holder so the watcher's closure can resolve back to
    /// self without retaining it. Plain `[weak self]` doesn't work
    /// directly because `self` isn't fully initialized at the point
    /// the watcher is constructed.
    private final class WeakBox {
        weak var target: NotchOrchestrator?
    }

    // MARK: - Lifecycle

    /// Begin observing power and media events. Idempotent — repeat
    /// calls don't double-register with IOKit or MediaRemote.
    func start() {
        powerWatcher.start()
        mediaService.start()
        browserProbe.start()
        audioWatcher.start()
        lockScreenWatcher.start()
        // Quiet-window watchdog: flip the probe's gate to "silent"
        // when MediaRemote hasn't published in 5s. This is what
        // lets the browser probe step in for YouTube/SoundCloud
        // when MediaRemote is restricted on macOS 15.4+.
        quietWatchdog?.invalidate()
        quietWatchdog = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let silent = Date().timeIntervalSince(self.lastMediaRemoteAt) > 5.0
                self.browserProbe.isMediaRemoteSilent = silent
            }
        }
    }

    /// Tear down all watchers and dismiss any visible HUD. Useful at
    /// app shutdown so runloop sources / notification observers aren't
    /// leaked into the next process spawn (relevant during dev; AppKit
    /// usually reaps these on quit, but explicit teardown keeps the
    /// behavior deterministic).
    func stop() {
        powerWatcher.stop()
        mediaService.stop()
        browserProbe.stop()
        audioWatcher.stop()
        lockScreenWatcher.stop()
        quietWatchdog?.invalidate()
        quietWatchdog = nil
        hudController.hide()
        lastPowerState = nil
        didReceiveInitialPowerState = false
    }

    // MARK: - Power events

    /// Decide whether the freshly-reported power state warrants a HUD
    /// bloom. Rules:
    /// - Drop the very first emission. PowerSourceWatcher always emits
    ///   once on start() so callers know the baseline; we don't want
    ///   the HUD to bloom every time the app launches just because the
    ///   user happens to be on AC.
    /// - Only bloom when the *charging signal* flips. A change in
    ///   percentage alone (87% → 88% while plugged in) is not a HUD
    ///   event — that would spam the user during long charges.
    /// - Forward the resulting presentation to the controller; the
    ///   controller handles auto-hide and animation.
    private func handlePowerState(_ state: PowerState) {
        defer { lastPowerState = state }

        guard didReceiveInitialPowerState else {
            didReceiveInitialPowerState = true
            return
        }

        // Only show on plug-in / unplug transitions. This is the
        // moment the user wants visual confirmation that the cable
        // registered. Percentage updates while the charging state is
        // unchanged are silent.
        let chargingChanged = state.isCharging != lastPowerState?.isCharging
        guard chargingChanged else {
            return
        }

        // Route the event into the unified pill (via AppDelegate →
        // presenter.pendingSystemEvent) instead of opening a
        // separate floating HUD pill. The pill morphs in place
        // from music → charging indicator → music. User: "the pill
        // should have animations for different kinds of actions
        // ... should transform the music into that charging
        // animation, into the same size."
        onChargingChange?(state.percent, state.isCharging)
    }

    // MARK: - Now-playing events

    /// Forward the latest now-playing snapshot to the external
    /// subscriber (PanelPresenter via AppDelegate). The orchestrator no
    /// longer drives a separate now-playing HUD pill — that role moved
    /// to the unified panel/pill, which sits at resting-pill geometry
    /// whenever a track is current and morphs into the full music page
    /// on hover. AppDelegate observes this stream to call
    /// `enterRestingMode` / `exitRestingMode` on the panel controller.
    ///
    /// We forward EVERY snapshot — including artwork-only updates and
    /// nil — so the panel's `nowPlaying` published var (and the
    /// resting-mode lifecycle) stay in sync without dedup. The pill
    /// shows whenever info is non-nil (playing or paused, matching
    /// Alcove's "ambient indicator" behavior); it collapses the
    /// instant the source app stops publishing.
    private func handleNowPlayingChange(_ info: NowPlayingInfo?) {
        lastForwardedBundleID = info?.sourceBundleID
        NSLog("Notetaker: orchestrator forwarding nowPlaying title=\(info?.title ?? "nil") isPlaying=\(info?.isPlaying ?? false)")
        onNowPlayingChange?(info)
        // When the source is a known browser, kick off a title-based
        // tab scan so `openSourceApp` / `sendMediaCommand` know which
        // tab to act on. MediaRemote tells us "Chrome is playing
        // 'Cruel Summer'" — but not WHICH Chrome tab. AppleScript
        // closes the loop. See BrowserMediaProbe.refreshAudibleTab
        // for the full rationale (this is the Alcove-decoded pattern).
        refreshBrowserTabIfNeeded(for: info)
    }

    /// Last (bundle, title) we already kicked off a title-scan for.
    /// Prevents firing a fresh AppleScript for every artwork-only
    /// update — MediaRemote sends ~1/s while a track plays, but the
    /// tab doesn't change between artwork ticks.
    private var lastBrowserScanKey: String?

    private func refreshBrowserTabIfNeeded(for info: NowPlayingInfo?) {
        guard let info,
              let bundleID = info.sourceBundleID,
              !info.title.isEmpty,
              BrowserMediaProbe.isKnownBrowser(bundleID: bundleID) else {
            // Not a browser source (or no title) — clear the scan
            // dedup so the next browser publish triggers a fresh scan
            // instead of being suppressed.
            lastBrowserScanKey = nil
            return
        }
        let key = "\(bundleID)|\(info.title)"
        if key == lastBrowserScanKey { return }
        lastBrowserScanKey = key
        browserProbe.refreshAudibleTab(forBundleID: bundleID, titleHint: info.title) { found in
            if !found {
                // Title scan didn't land — most likely TCC denied or
                // the song name doesn't appear verbatim in the tab
                // title. Clear dedup so a follow-up publish (with a
                // possibly different title) gets retried.
                self.lastBrowserScanKey = nil
            }
        }
    }
}
