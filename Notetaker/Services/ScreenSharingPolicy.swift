import AppKit

/// Centralized authority for which `NSWindow.SharingType` every nox
/// window should adopt right now.
///
/// Background: macOS draws windows into screen recordings (Cmd+Shift+5,
/// QuickTime, OBS, ScreenCaptureKit) by default — every panel, every
/// helper window, the notch HUD itself, all of it. For users
/// recording a screencast or doing a live demo, the floating notch HUD
/// is intrusive: it pops into frame whenever music plays / a file is
/// dropped / a screenshot lands, and it appears in the recording even
/// if the viewer wasn't supposed to see it.
///
/// Setting `window.sharingType = .none` removes the window from
/// screencaps + ScreenCaptureKit feeds + AVCaptureScreenInput — the
/// user still SEES nox as normal, but nothing downstream of the
/// compositor does. (The default is `.readOnly`, which is "visible
/// to recordings, can't be modified by other apps.")
///
/// Inspired by SuperIsland's `IslandWindow.setVisibleInScreenRecordings`.
/// Audit-pass note: the implementation here also drives the AppDelegate's
/// "apply on every controller" plumbing and walks NSApp.windows as a
/// fallback so any window we haven't explicitly tracked still gets the
/// right policy.
enum ScreenSharingPolicy {

    /// UserDefaults key — read directly to avoid pulling in
    /// SwiftUI's @AppStorage from a non-View context.
    static let userDefaultsKey = "hideFromScreenRecordings"

    /// Resolve the policy from the user's saved preference. Default
    /// is `.readOnly` — visible to recordings, which matches macOS
    /// out-of-the-box behavior. Users opt-in to `.none` from
    /// Settings → General.
    static var current: NSWindow.SharingType {
        let hide = UserDefaults.standard.bool(forKey: userDefaultsKey)
        return hide ? .none : .readOnly
    }

    /// Apply the current policy to one specific window. Call this from
    /// every window/panel creation site so newly-spawned windows
    /// adopt the user's preference without a separate "refresh all"
    /// dance.
    static func apply(to window: NSWindow) {
        window.sharingType = current
    }

    /// Walk every visible NSApp window and apply the current policy.
    /// Called from AppDelegate when the user flips the Settings
    /// toggle so the change is immediate without a relaunch.
    @MainActor
    static func refreshAll() {
        let policy = current
        for window in NSApp.windows {
            // Don't touch windows that have an explicit policy
            // already (e.g. system-owned windows we shouldn't be
            // mutating). Guard on our own panel subclasses by
            // class membership: any borderless / nonactivating
            // panel is presumed ours.
            if window.styleMask.contains(.borderless) ||
               window.styleMask.contains(.nonactivatingPanel) {
                window.sharingType = policy
            }
        }
    }
}
