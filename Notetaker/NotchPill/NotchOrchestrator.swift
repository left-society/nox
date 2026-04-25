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

    /// Tracked separately from PowerSourceWatcher's internal dedup so
    /// we can apply orchestrator-level rules (only show on transition,
    /// not on every IOKit emit). Nil until the first state lands.
    private var lastPowerState: PowerState?
    private var didReceiveInitialPowerState = false

    /// Most recent now-playing snapshot we received from the media
    /// service. Used to decide whether a fresh notification represents
    /// a meaningful enough change to bloom the HUD again — title swap
    /// or play↔pause warrants a re-bloom; an artwork-only update
    /// (which some apps fire frequently) does not.
    private var lastNowPlaying: NowPlayingInfo?
    private var didReceiveInitialNowPlaying = false

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
        lastNowPlaying = nil
        didReceiveInitialNowPlaying = false
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

    /// Decide whether the latest now-playing snapshot warrants a HUD
    /// bloom. Rules:
    /// - First emission after start() is silent (we want the HUD to
    ///   bloom on the *next* track change, not on launch with whatever
    ///   was already playing — that would feel intrusive).
    /// - Title or play-state change → bloom. Those are the moments
    ///   the user is glancing at the notch for confirmation.
    /// - Artwork-only or artist-only change without a title flip is
    ///   ignored — some apps reload the artwork mid-playback (Spotify
    ///   does this when the device finishes prefetching the next track),
    ///   and we don't want the HUD to chatter on those.
    /// - nil snapshot (nothing playing) hides any visible HUD.
    private func handleNowPlayingChange(_ info: NowPlayingInfo?) {
        defer { lastNowPlaying = info }

        guard didReceiveInitialNowPlaying else {
            didReceiveInitialNowPlaying = true
            return
        }

        guard let info else {
            // Nothing playing → if a now-playing pill is visible, hide
            // it. Charging pills aren't affected by media events.
            return
        }

        let titleChanged = info.title != lastNowPlaying?.title
            || info.artist != lastNowPlaying?.artist
        let playStateChanged = info.isPlaying != (lastNowPlaying?.isPlaying ?? !info.isPlaying)
        guard titleChanged || playStateChanged else { return }

        hudController.show(presentation: .nowPlaying(info))
    }
}
