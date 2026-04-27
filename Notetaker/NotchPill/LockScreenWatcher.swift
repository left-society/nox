import AppKit
import Foundation

/// Subscribes to macOS's session-lock distributed notifications so
/// the lock-screen music card can be shown/hidden in sync with the
/// system lock state.
///
/// `com.apple.screenIsLocked` and `com.apple.screenIsUnlocked` are
/// stable public-but-undocumented strings that have lived on
/// `DistributedNotificationCenter.default` since macOS 10.6. Every
/// app that integrates with the lock state hooks these (Caffeine,
/// Hammerspoon, Alcove, mew-notch).
///
/// Note: this watcher is independent of the SkyLight space attach
/// in `NotchSpaceManager`. The space attach is what makes a window
/// VISIBLE on lock; this watcher is what tells us WHEN to swap UI
/// content (e.g. show the music card only while locked).
@MainActor
final class LockScreenWatcher {
    /// Fires `true` when the screen locks, `false` when it unlocks.
    var onChange: ((Bool) -> Void)?

    private(set) var isLocked: Bool = false
    private var lockObserver: NSObjectProtocol?
    private var unlockObserver: NSObjectProtocol?

    func start() {
        guard lockObserver == nil else { return }
        let center = DistributedNotificationCenter.default()
        lockObserver = center.addObserver(
            forName: NSNotification.Name("com.apple.screenIsLocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleChange(locked: true) }
        }
        unlockObserver = center.addObserver(
            forName: NSNotification.Name("com.apple.screenIsUnlocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleChange(locked: false) }
        }
    }

    func stop() {
        let center = DistributedNotificationCenter.default()
        if let lockObserver { center.removeObserver(lockObserver) }
        if let unlockObserver { center.removeObserver(unlockObserver) }
        lockObserver = nil
        unlockObserver = nil
    }

    private func handleChange(locked: Bool) {
        guard locked != isLocked else { return }
        isLocked = locked
        onChange?(locked)
    }
}
