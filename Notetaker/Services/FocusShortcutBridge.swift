import Foundation
import AppKit
import Combine

/// Silent toggle of macOS Focus / Do-Not-Disturb via Apple's
/// Shortcuts CLI (`/usr/bin/shortcuts`).
///
/// Why this and not anything else:
///   • `INFocusStatusCenter` — read-only. Apple's public read-only
///     Focus API.
///   • `DoNotDisturbKit.framework` — private. macOS 26 strips the
///     setter symbols (verified via `nm`/`strings` — historical
///     methods like `setMode:` are no longer reachable).
///   • AppleScript-driven Control Centre — works mechanically, but
///     opens Control Centre full-screen and steals focus from any
///     hover panel mid-tap. User feedback 2026-05-08:
///     "this thing is opening the whole macbook which should not
///     happen."
///   • `defaults write com.apple.notificationcenterui doNotDisturb`
///     — the historical pre-Big-Sur path. Broken since 2020.
///   • **Shortcuts CLI** — Apple-blessed, runs entirely in-process,
///     no UI surfaces. Tradeoff: requires the user to create a
///     named Shortcut once. We surface that as a "Set up" CTA on
///     first use.
///
/// Reference flow (verified via Apple's own Shortcuts docs +
/// HeyFocus / Session / Stay-in-Session blog posts):
///   1. User opens Shortcuts.app, creates a shortcut named
///      `kShortcutName` containing one action: "Set Focus" with
///      Mode = "Do Not Disturb", Action = "Toggle".
///   2. nox runs `shortcuts run "<kShortcutName>"` whenever the
///      Focus toggle is tapped.
///   3. Apple's INFocusStatusCenter distributed notification
///      fires; our `FocusStatusService` observer flips
///      `presenter.isFocused`; the dashboard's session timer
///      starts (or stops) automatically.
///
/// First-launch detection: we scan `shortcuts list` once on
/// init and on `applicationDidBecomeActive` (so coming back from
/// Shortcuts.app refreshes the state without a panel restart).
@MainActor
final class FocusShortcutBridge: ObservableObject {
    static let shared = FocusShortcutBridge()

    /// Exact name the user must give the shortcut. We surface this
    /// in the setup CTA so the user knows what to type.
    static let kShortcutName = "nox: Toggle Focus"

    /// Path to the Shortcuts CLI. Stable since macOS 12 (Monterey).
    private static let cliPath = "/usr/bin/shortcuts"

    /// Whether `kShortcutName` was found in the user's Shortcuts
    /// library on the most recent scan. Drives the Focus detail
    /// row's UI state — toggle vs. setup CTA.
    @Published private(set) var shortcutExists: Bool = false

    /// True while a `shortcuts run` invocation is mid-flight.
    /// Drives the optimistic-UI lock — the dashboard binding can
    /// show pending state without flickering back to the old
    /// `presenter.isFocused` value while the FocusStatusService
    /// observer catches up.
    @Published private(set) var isToggling: Bool = false

    private var activeObserver: NSObjectProtocol?

    init() {
        refresh()
        // Re-scan whenever the user comes back from Shortcuts.app
        // (the most likely path: tap "Set up", create the
        // shortcut, switch back to nox). NSWorkspace fires this
        // for any application bringing the user back to nox.
        activeObserver = NSWorkspace.shared.notificationCenter
            .addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
    }

    deinit {
        if let activeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activeObserver)
        }
    }

    // MARK: - Public API

    /// Re-scan the user's Shortcuts library for `kShortcutName`.
    /// Idempotent + safe to call on every focus event. Runs the
    /// CLI off-thread so a slow disk doesn't stall the UI.
    func refresh() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let exists = Self.detectShortcut(named: Self.kShortcutName)
            DispatchQueue.main.async {
                self?.shortcutExists = exists
            }
        }
    }

    /// Tap handler when the user has the shortcut set up. Runs
    /// `shortcuts run "<name>"` off-thread — the CLI typically
    /// returns in 200-500ms, well under any perceptible lag.
    /// Sets `isToggling = true` for the duration so the UI can
    /// optimistically flip the visual.
    func runToggle(completion: ((Bool) -> Void)? = nil) {
        guard shortcutExists else {
            completion?(false)
            return
        }
        isToggling = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let ok = Self.runShortcut(named: Self.kShortcutName)
            DispatchQueue.main.async {
                self?.isToggling = false
                completion?(ok)
            }
        }
    }

    /// Tap handler when the shortcut is NOT set up. Opens
    /// Shortcuts.app to a fresh-shortcut creation page with the
    /// expected name pre-filled. The user adds one "Set Focus"
    /// action and saves — when they cmd-tab back to nox, the
    /// `applicationDidBecomeActive` observer fires, `refresh()`
    /// detects the new shortcut, and the row swaps from CTA to
    /// real toggle.
    func openSetup() {
        guard let nameEncoded = Self.kShortcutName.addingPercentEncoding(
            withAllowedCharacters: .urlQueryAllowed
        ) else { return }
        // shortcuts://create-shortcut?name=… opens Shortcuts.app
        // and pre-fills the name field. Doesn't pre-add the
        // action (Apple doesn't expose that depth via URL), so
        // we still need a UI nudge for the user to add the
        // "Set Focus" step. The detail panel's CTA row will show
        // brief inline instructions.
        if let url = URL(string: "shortcuts://create-shortcut?name=\(nameEncoded)") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - CLI helpers

    /// Synchronous `shortcuts list` scan. Returns true if the
    /// requested shortcut name appears verbatim in the listing.
    /// Output of `shortcuts list` is one shortcut name per line,
    /// so a contains-check on the line set is sufficient (and
    /// avoids false positives from substring matches on other
    /// shortcuts).
    private static func detectShortcut(named target: String) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: cliPath)
        task.arguments = ["list"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return false
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return false }
        return output
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .contains(target)
    }

    /// Synchronous `shortcuts run "<name>"`. Returns true on exit
    /// code 0. The Shortcuts CLI is non-interactive — it doesn't
    /// surface any UI even when the shortcut runs, which is the
    /// whole point of using this path instead of UI-scripting
    /// Control Centre.
    @discardableResult
    private static func runShortcut(named target: String) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: cliPath)
        task.arguments = ["run", target]
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch {
            return false
        }
    }
}
