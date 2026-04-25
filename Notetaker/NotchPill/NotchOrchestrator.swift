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

    /// Tracked separately from PowerSourceWatcher's internal dedup so
    /// we can apply orchestrator-level rules (only show on transition,
    /// not on every IOKit emit). Nil until the first state lands.
    private var lastPowerState: PowerState?
    private var didReceiveInitialPowerState = false

    init() {
        self.hudController = NotchHUDWindowController()
        // Trampoline through a weak box: PowerSourceWatcher captures
        // the closure for its lifetime, and we don't want it to keep
        // the orchestrator alive past the explicit stop()/dealloc. The
        // closure routes back to handlePowerState via [weak self].
        let box = WeakBox()
        self.powerWatcher = PowerSourceWatcher { state in
            box.target?.handlePowerState(state)
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

    /// Begin observing power events. Idempotent — calling start()
    /// twice doesn't double-register with IOKit.
    func start() {
        powerWatcher.start()
    }

    /// Tear down the IOKit registration and dismiss any visible HUD.
    /// Useful at app shutdown so the runloop source isn't leaked into
    /// the next process spawn (relevant during development; AppKit
    /// usually reaps these on quit, but explicit teardown keeps the
    /// behavior deterministic).
    func stop() {
        powerWatcher.stop()
        hudController.hide()
        lastPowerState = nil
        didReceiveInitialPowerState = false
    }

    // MARK: - Event handling

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
}
