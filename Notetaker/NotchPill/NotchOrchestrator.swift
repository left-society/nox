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

    /// External now-playing observer. AppDelegate installs this to
    /// forward MediaRemote snapshots into PanelPresenter so the
    /// notes-panel can render its own music page (MusicPanelView)
    /// without having to know about the orchestrator. Fires for
    /// every snapshot — including nil when nothing's playing —
    /// because PanelPresenter's `visibleTabs` and "auto-bounce off
    /// .music when playback stops" logic both depend on the nil
    /// transition arriving promptly.
    var onNowPlayingChange: ((NowPlayingInfo?) -> Void)?

    /// Send a media command (play/pause/skip) into whichever app owns
    /// the now-playing slot. Exposed publicly so MusicPanelView's
    /// transport buttons (routed via `PanelPresenter.onMediaCommand`)
    /// can drive playback the same way the notch HUD's transport
    /// buttons already do. Both paths terminate at the same
    /// `MediaRemoteService.send` call.
    func sendMediaCommand(_ command: MediaRemoteService.Command) {
        mediaService.send(command)
    }

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
        // Trampoline through a weak box: the watchers capture closures
        // for their lifetime, and we don't want them to keep the
        // orchestrator alive past explicit stop()/dealloc. Each closure
        // routes back to a handler via [weak target].
        let box = WeakBox()
        self.powerWatcher = PowerSourceWatcher { state in
            box.target?.handlePowerState(state)
        }
        self.mediaService.onChange = { [weak box] info in
            box?.target?.handleNowPlayingChange(info)
        }
        // Forward HUD button taps into the media service.
        self.hudController.onMediaCommand = { [weak box] command in
            box?.target?.mediaService.send(command)
        }
        box.target = self
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
    }

    /// Tear down all watchers and dismiss any visible HUD. Useful at
    /// app shutdown so runloop sources / notification observers aren't
    /// leaked into the next process spawn (relevant during dev; AppKit
    /// usually reaps these on quit, but explicit teardown keeps the
    /// behavior deterministic).
    func stop() {
        powerWatcher.stop()
        mediaService.stop()
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

        hudController.show(
            presentation: .charging(
                percent: state.percent,
                isCharging: state.isCharging
            )
        )
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
        NSLog("Notetaker: orchestrator forwarding nowPlaying title=\(info?.title ?? "nil") isPlaying=\(info?.isPlaying ?? false)")
        onNowPlayingChange?(info)
    }
}
