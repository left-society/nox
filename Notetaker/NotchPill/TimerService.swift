import Foundation
import Combine

/// Lightweight countdown timer service driving the notch timer pill.
/// One timer at a time — starting a new one cancels any in-flight
/// countdown. Driven by a 1Hz wall-clock tick rather than absolute
/// CFRunLoop scheduling so a brief stutter (e.g. system resuming
/// from sleep) doesn't desync the displayed remaining time.
///
/// State exposed via `@Published` so SwiftUI views (and the pill's
/// system-event consumer in AppDelegate) re-render on every tick
/// and on start/stop/finish edges.
@MainActor
final class TimerService: ObservableObject {
    /// Remaining time in seconds. 0 when no timer is running.
    @Published private(set) var remaining: TimeInterval = 0
    /// True while a timer is actively counting down.
    @Published private(set) var isRunning: Bool = false

    /// Fires once when a timer reaches zero (not when manually
    /// stopped). AppDelegate uses this to play the "ding" haptic
    /// and show a "Timer done" pill.
    var onFinish: (() -> Void)?

    private var deadline: Date?
    private var ticker: Timer?

    /// Start a fresh countdown. Replaces any running timer.
    func start(seconds: TimeInterval) {
        guard seconds > 0 else { return }
        cancel()
        deadline = Date().addingTimeInterval(seconds)
        remaining = seconds
        isRunning = true
        ticker = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
    }

    /// Stop the timer immediately without firing `onFinish`. Called
    /// when the user dismisses the pill or starts a new timer.
    func cancel() {
        ticker?.invalidate()
        ticker = nil
        deadline = nil
        remaining = 0
        isRunning = false
    }

    private func tick() {
        guard let deadline else { cancel(); return }
        let remainingSeconds = deadline.timeIntervalSinceNow
        if remainingSeconds <= 0 {
            ticker?.invalidate()
            ticker = nil
            self.deadline = nil
            self.remaining = 0
            self.isRunning = false
            onFinish?()
        } else {
            remaining = remainingSeconds
        }
    }
}
