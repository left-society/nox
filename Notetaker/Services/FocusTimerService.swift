import Foundation
import Combine
import AppKit

/// Pomodoro-style countdown timer bound to a Focus session. The
/// user picks a duration from the Focus detail panel (15 / 25 / 45 /
/// 90 min or custom), the timer counts down, the panel chimes +
/// pops at zero. Pause/resume keeps the user in control if they
/// step away mid-session.
///
/// **Distinct from `TimerService`** — that one observes the macOS
/// Clock app's timer (when the user starts one via Siri / Control
/// Centre / the Clock app itself) and surfaces it as a transient
/// notch pill. This service is *internal* to the Focus dashboard
/// and only runs when the user explicitly starts one from there.
///
/// **Persistence:** UserDefaults snapshot on every state change,
/// hydrated on init. Survives panel-close *and* app-quit, so a 25-
/// minute session that gets interrupted by a force-restart still
/// has the right remaining time when nox launches again. Computed
/// remaining = `targetDuration - elapsedAtPause - (now - startedAt)`
/// when running, just `targetDuration - elapsedAtPause` when paused.
///
/// **State machine:**
/// ```
/// idle ──start──> running ──pause──> paused ──resume──> running
///   ▲              │                 │                    │
///   │              │ (remaining=0)   │                    │
///   ├──stop────────┤                 ├──stop──────────────┤
///   │              ▼                 │                    │
///   └──acknowledge── expired ◀───────┘ (only via running) │
/// ```
///
/// All access is `@MainActor`. Consumers (PanelRootView, dashboard,
/// AppDelegate) are already on main, no queue-hopping needed.
@MainActor
final class FocusTimerService: ObservableObject {
    static let shared = FocusTimerService()

    /// Where the timer is in its lifecycle. SwiftUI switches the
    /// dashboard's timer card on this — chips when idle, big
    /// countdown when running/paused, celebration when expired.
    enum TimerState: String, Codable {
        case idle      // no timer set; show duration chips
        case running   // counting down
        case paused    // frozen; user pressed pause
        case expired   // hit zero; awaiting user acknowledgment
    }

    /// Current state. `@Published` so SwiftUI re-renders on every
    /// transition. AppDelegate's recompute also reads this on Focus
    /// falling-edge to auto-stop a running timer.
    @Published private(set) var state: TimerState = .idle

    /// Total duration the user picked when they hit start. Stays
    /// fixed for the life of this run (pause/resume don't change it
    /// — `elapsedAtPause` is what tracks "how much of the target
    /// have we burned"). Reset to 0 when state goes back to idle.
    @Published private(set) var targetDuration: TimeInterval = 0

    /// Wall-clock instant the CURRENT run leg started. Nil when
    /// paused or idle. After resume, this is the resume instant —
    /// not the original start — because the elapsed-before-pause is
    /// already baked into `elapsedAtPause`.
    @Published private(set) var startedAt: Date? = nil

    /// Cumulative elapsed time across all completed run legs (i.e.
    /// "every running stretch before the latest pause"). Adding the
    /// current leg's `now - startedAt` to this gives total elapsed.
    @Published private(set) var elapsedAtPause: TimeInterval = 0

    // MARK: - Persistence
    //
    // One UserDefaults key holds a JSON snapshot — simpler than
    // four parallel keys, and atomic on read/write so we can't end
    // up with partial state on crash.
    private static let storageKey = "noxFocusTimerSnapshot"

    private struct Snapshot: Codable {
        let state: TimerState
        let targetDuration: TimeInterval
        let startedAt: Date?
        let elapsedAtPause: TimeInterval
    }

    // MARK: - Tick driver
    //
    // 1Hz Foundation timer that polls remaining(). When it hits zero
    // we transition to .expired and fire the chime/notification —
    // even if no SwiftUI view is currently observing. Runs only
    // while `.running`; invalidated on every other state.
    private var tickTimer: Timer?

    /// Hook for the panel to "vibrate" (run its expand-pop-retract
    /// morph cycle) when the timer expires. AppDelegate hangs the
    /// real implementation off this in init — we keep the closure
    /// here so FocusTimerService doesn't directly depend on
    /// PanelWindowController.
    var onExpire: (() -> Void)?

    private init() {
        hydrate()
        // If we hydrated into .running, the timer was running when
        // the app last quit. Restart the ticker so expiry detection
        // resumes. The state itself stays the same — `remaining()`
        // already accounts for time elapsed during the off-app
        // window via the wall-clock math.
        if state == .running {
            startTicker()
            // Could already be past zero if the app was quit for
            // longer than the timer's duration. Check immediately
            // rather than waiting for the next tick.
            checkExpiry()
        }
    }

    // MARK: - Public API

    /// Start a fresh countdown. Replaces any in-flight timer
    /// (running, paused, or expired-awaiting-ack — caller's
    /// problem if they didn't `stop()` first).
    func start(duration: TimeInterval) {
        guard duration > 0 else { return }
        targetDuration = duration
        elapsedAtPause = 0
        startedAt = Date()
        state = .running
        startTicker()
        persist()
    }

    /// Pause a running timer. Captures the current run leg's
    /// elapsed seconds into `elapsedAtPause` so resume picks up
    /// from there. No-op if not running.
    func pause() {
        guard state == .running, let leg = startedAt else { return }
        elapsedAtPause += Date().timeIntervalSince(leg)
        startedAt = nil
        state = .paused
        stopTicker()
        persist()
    }

    /// Resume a paused timer. Starts a fresh run leg from now;
    /// the previously-elapsed time stays in `elapsedAtPause`.
    /// No-op if not paused.
    func resume() {
        guard state == .paused else { return }
        startedAt = Date()
        state = .running
        startTicker()
        persist()
        // Edge case: target was reached while paused (impossible
        // since paused doesn't tick) — just kick the expiry check
        // anyway in case `targetDuration` was somehow tampered with
        // via UserDefaults edits.
        checkExpiry()
    }

    /// Stop the timer entirely. Used for the "Stop" button (running
    /// or paused) and as the auto-cleanup when Focus mode turns
    /// off mid-session.
    func stop() {
        state = .idle
        targetDuration = 0
        startedAt = nil
        elapsedAtPause = 0
        stopTicker()
        persist()
    }

    /// Acknowledge an expired timer — clears the celebration card
    /// back to the idle duration-chips state. Called by the "Done"
    /// button on the expired card.
    func acknowledge() {
        guard state == .expired else { return }
        stop()
    }

    // MARK: - Computed views

    /// Remaining seconds. 0 when idle/expired. Negative would mean
    /// "we should have expired already" — clamped to 0 for safety.
    func remaining(now: Date = Date()) -> TimeInterval {
        max(0, targetDuration - totalElapsed(now: now))
    }

    /// Fraction of the target completed (0...1). Drives the
    /// circular progress ring around the running countdown.
    func progress(now: Date = Date()) -> Double {
        guard targetDuration > 0 else { return 0 }
        return min(1, totalElapsed(now: now) / targetDuration)
    }

    /// True when the user has a non-idle timer (running, paused,
    /// or expired-awaiting-ack). Pill mirroring uses this to
    /// decide whether to swap the count-up label for the countdown.
    var isActive: Bool {
        state != .idle
    }

    /// Total burned seconds across every run leg + the current
    /// running leg's contribution.
    private func totalElapsed(now: Date) -> TimeInterval {
        if let leg = startedAt, state == .running {
            return elapsedAtPause + now.timeIntervalSince(leg)
        }
        return elapsedAtPause
    }

    // MARK: - Internals

    private func startTicker() {
        tickTimer?.invalidate()
        tickTimer = Timer.scheduledTimer(
            withTimeInterval: 1.0, repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkExpiry()
            }
        }
    }

    private func stopTicker() {
        tickTimer?.invalidate()
        tickTimer = nil
    }

    /// Called every second while running. Transitions to .expired
    /// the moment remaining hits zero. Idempotent — safe to call
    /// outside a tick (e.g. on resume edge or hydrate restore).
    private func checkExpiry() {
        guard state == .running else { return }
        if remaining(now: Date()) <= 0 {
            markExpired()
        }
    }

    /// Flip to .expired + fire side effects (chime, notification,
    /// panel vibrate). Side effects fire ONCE per expiry — the
    /// `.expired` guard in checkExpiry prevents repeats.
    private func markExpired() {
        state = .expired
        startedAt = nil
        // Pin elapsed to target so remaining() == 0 exactly,
        // regardless of any sub-second drift.
        elapsedAtPause = targetDuration
        stopTicker()
        persist()

        // Audible "done" — same Glass sound the macOS-Clock-bound
        // TimerService uses, so users hear a familiar chime.
        // Skipped if the user has flipped Settings → Timer →
        // Sound on finish off (default true).
        let soundEnabled = UserDefaults.standard.object(
            forKey: "noxFocusTimerSoundOnFinish"
        ) as? Bool ?? true
        if soundEnabled {
            NSSound(named: NSSound.Name("Glass"))?.play()
        }

        // Visual: panel "vibrates" (its standard event-morph
        // animation). Wired up by AppDelegate at init.
        onExpire?()

        // Internal NotificationCenter post so other parts of the
        // app (analytics, future macOS-banner integration) can
        // observe the expiry without coupling to FocusTimerService
        // directly. Today the chime + panel vibrate above are the
        // only user-facing signals; UN banner support is a future
        // enhancement gated behind a permission flow.
        NotificationCenter.default.post(
            name: .focusTimerExpired,
            object: nil,
            userInfo: ["duration": targetDuration]
        )
    }

    // MARK: - Persistence

    private func persist() {
        let snap = Snapshot(
            state: state,
            targetDuration: targetDuration,
            startedAt: startedAt,
            elapsedAtPause: elapsedAtPause
        )
        if let data = try? JSONEncoder().encode(snap) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    private func hydrate() {
        guard let data = UserDefaults.standard.data(
            forKey: Self.storageKey
        ),
        let snap = try? JSONDecoder().decode(Snapshot.self, from: data)
        else { return }
        self.state = snap.state
        self.targetDuration = snap.targetDuration
        self.startedAt = snap.startedAt
        self.elapsedAtPause = snap.elapsedAtPause
    }
}

extension Notification.Name {
    /// Fired by FocusTimerService when a timer reaches zero.
    /// AppDelegate observes this to (a) pop a notification banner
    /// and (b) trigger the panel's expand-pop-retract morph for
    /// the visual "vibrate" the user requested.
    static let focusTimerExpired = Notification.Name("noxFocusTimerExpired")
}
