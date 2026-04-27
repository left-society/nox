import Foundation
import Intents
import Combine
import AppKit

/// Watches the system Focus / Do-Not-Disturb state and exposes a
/// single `@Published var isFocused: Bool` that the rest of the app
/// gates non-essential notch pills on.
///
/// macOS 13+ exposes Focus through `INFocusStatusCenter`. The user
/// has to grant authorization (`NSFocusStatusUsageDescription` is
/// required in Info.plist) — once granted, we observe
/// `INFocusStatusCenter.focusStatusDidChange` AND the lower-level
/// distributed notification `com.apple.focus.focus-status-changed-notification`
/// (the latter fires even when our authorization status is undetermined,
/// which lets us nudge re-authorization at the right moment).
///
/// When auth is denied or undetermined we keep `isFocused = false`
/// permanently and the gating becomes a no-op — the user simply
/// doesn't get the auto-hide feature, which fails open. We never
/// pop a system permission dialog without the user opting in via
/// Settings → General → "Auto-hide pills during Focus" — popping
/// it on launch would be a poor introduction.
@MainActor
final class FocusStatusService: ObservableObject {
    /// True iff a Focus or DND mode is active right now AND we have
    /// authorization to read Focus status. Default false; flips on
    /// the first observed transition after `start()`.
    @Published private(set) var isFocused: Bool = false

    /// Whether the Intents authorization prompt has been answered.
    /// `.notDetermined` means we should ask before assuming gating
    /// works; `.authorized` means we'll get live updates;
    /// `.denied`/`.restricted` means the gate stays no-op forever.
    @Published private(set) var authorizationStatus: INFocusStatusAuthorizationStatus = .notDetermined

    private var distributedObserver: NSObjectProtocol?

    init() {
        authorizationStatus = INFocusStatusCenter.default.authorizationStatus
        // Pre-populate from the current status so a focus that was
        // already active at launch doesn't have to wait for the
        // first transition to register.
        if authorizationStatus == .authorized {
            isFocused = INFocusStatusCenter.default.focusStatus.isFocused ?? false
        }
    }

    /// Begin observing Focus state changes. Idempotent — calling
    /// repeatedly just refreshes the current snapshot.
    func start() {
        // Distributed notification fires regardless of our auth state,
        // so even when we're notDetermined we can re-read the status
        // (which will return a meaningful value once the user grants
        // authorization later via Settings).
        if distributedObserver == nil {
            distributedObserver = DistributedNotificationCenter.default()
                .addObserver(
                    forName: NSNotification.Name("com.apple.focus.focus-status-changed-notification"),
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor [weak self] in self?.refresh() }
                }
        }
        refresh()
    }

    /// Stop observing and release the distributed-notification
    /// observer. Called on app termination — for a long-lived app
    /// this isn't strictly necessary but keeps the lifecycle tidy.
    func stop() {
        if let observer = distributedObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
            distributedObserver = nil
        }
    }

    /// Request user authorization to read Focus status. Pops the
    /// standard system dialog the first time; subsequent calls are
    /// no-ops once the user has answered. Wired to the Settings →
    /// General → "Auto-hide pills during Focus" toggle so the user
    /// only gets prompted when they're explicitly opting in.
    func requestAuthorization(completion: ((INFocusStatusAuthorizationStatus) -> Void)? = nil) {
        INFocusStatusCenter.default.requestAuthorization { [weak self] status in
            Task { @MainActor [weak self] in
                self?.authorizationStatus = status
                self?.refresh()
                completion?(status)
            }
        }
    }

    /// Re-read current Focus state. Called both internally (on the
    /// distributed notification) and by AppDelegate after the user
    /// flips the auto-hide toggle off (so we settle back to the
    /// fail-open default immediately rather than after the next
    /// system transition).
    func refresh() {
        authorizationStatus = INFocusStatusCenter.default.authorizationStatus
        if authorizationStatus == .authorized {
            isFocused = INFocusStatusCenter.default.focusStatus.isFocused ?? false
        } else {
            isFocused = false
        }
    }

    deinit {
        // Best-effort cleanup on dealloc. Same observer the start()
        // path created — DistributedNotificationCenter is fine to
        // remove from any queue.
        if let observer = distributedObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
    }
}
