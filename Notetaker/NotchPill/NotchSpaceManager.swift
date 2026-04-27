import AppKit
import Foundation

/// Creates a private SkyLight (WindowServer) space at the
/// "Notification Center at Screen Lock" absolute level (400) and
/// adds the panel window to it. This is what makes the notch pill
/// visible on the lock screen — the same technique Apple's own
/// system widgets use to draw on top of `loginwindow`'s shield.
///
/// **Why level 400.** SkyLight defines a fixed set of space
/// "absolute levels" that determine compositor z-order across the
/// entire system, including the lock-screen surface:
///
///     0   kCGSSpaceAbsoluteLevelDefault                          ← user spaces, full-screen apps
///     100 kCGSSpaceAbsoluteLevelSetupAssistant
///     200 kCGSSpaceAbsoluteLevelSecurityAgent
///     300 kCGSSpaceAbsoluteLevelScreenLock                       ← `loginwindow`'s lock UI
///     400 kSLSSpaceAbsoluteLevelNotificationCenterAtScreenLock   ← OUR LEVEL (above lock)
///     500 kCGSSpaceAbsoluteLevelBootProgress
///     600 kCGSSpaceAbsoluteLevelVoiceOver
///
/// Level 400 is exactly where Apple's own Notification Center widgets
/// draw on the lock screen. Using it puts our window in the same
/// system-blessed compositor pool — visible everywhere including
/// during lock, screensaver, and Mission Control.
///
/// **Why this works where `CGShieldingWindowLevel + 1` doesn't.**
/// `NSWindow.level` only controls z-order WITHIN a window's existing
/// space membership. Public API (.canJoinAllSpaces) only joins the
/// USER spaces — the lock-screen system space is not enumerated.
/// Even at the highest possible window level, our window doesn't get
/// composited on the lock-screen surface because it isn't a member
/// of that space group. The fix is to create our own space ABOVE
/// the lock-screen one and put the window in it.
///
/// **Why SkyLight, not CGS.** The older `CGSAddWindowsToSpaces` /
/// `CGSCopySpaces` aliases (in CoreGraphics) only operate on user
/// spaces — they can't enumerate or target system spaces like the
/// lock-screen one. The `SLS*` symbols in
/// `/System/Library/PrivateFrameworks/SkyLight.framework` are the
/// real underlying API and CAN target system levels. Decoded from
/// open-source notch apps (mew-notch, DynamicNotch) that successfully
/// ship lock-screen visibility on macOS Tahoe.
///
/// **Lifecycle.** Created once at app start, lives for the lifetime
/// of the app. The space is destroyed in `deinit` so we don't leak
/// a phantom space if the app exits cleanly.
final class NotchSpaceManager {
    static let shared: NotchSpaceManager? = NotchSpaceManager()

    private let connection: Int32
    private let space: Int32

    // MARK: - SkyLight function pointers
    //
    // Loaded once at init from `SkyLight.framework`. Stored as
    // typed function pointers so we can call them like normal C
    // functions throughout the lifetime of this object.

    private let SLSMainConnectionID: @convention(c) () -> Int32
    private let SLSSpaceCreate: @convention(c) (Int32, Int32, Int32) -> Int32
    private let SLSSpaceDestroy: @convention(c) (Int32, Int32) -> Int32
    private let SLSSpaceSetAbsoluteLevel: @convention(c) (Int32, Int32, Int32) -> Int32
    private let SLSShowSpaces: @convention(c) (Int32, CFArray) -> Int32
    private let SLSHideSpaces: @convention(c) (Int32, CFArray) -> Int32
    private let SLSSpaceAddWindowsAndRemoveFromSpaces: @convention(c) (Int32, Int32, CFArray, Int32) -> Int32

    /// Notification Center at Screen Lock — the level Apple's own
    /// widgets use to draw on top of the lock UI.
    private static let notificationCenterAtScreenLockLevel: Int32 = 400

    private init?() {
        guard let bundle = CFBundleCreate(
            kCFAllocatorDefault,
            NSURL(fileURLWithPath: "/System/Library/PrivateFrameworks/SkyLight.framework")
        ) else {
            NSLog("Notetaker: SkyLight.framework load failed — lock-screen visibility disabled")
            return nil
        }

        // Load each symbol via name; fail the whole init if any are
        // missing (Apple may add/remove symbols across macOS
        // versions; if even one is gone our whole stack is unsafe).
        guard
            let p_main = CFBundleGetFunctionPointerForName(bundle, "SLSMainConnectionID" as CFString),
            let p_create = CFBundleGetFunctionPointerForName(bundle, "SLSSpaceCreate" as CFString),
            let p_destroy = CFBundleGetFunctionPointerForName(bundle, "SLSSpaceDestroy" as CFString),
            let p_setLevel = CFBundleGetFunctionPointerForName(bundle, "SLSSpaceSetAbsoluteLevel" as CFString),
            let p_show = CFBundleGetFunctionPointerForName(bundle, "SLSShowSpaces" as CFString),
            let p_hide = CFBundleGetFunctionPointerForName(bundle, "SLSHideSpaces" as CFString),
            let p_add = CFBundleGetFunctionPointerForName(bundle, "SLSSpaceAddWindowsAndRemoveFromSpaces" as CFString)
        else {
            NSLog("Notetaker: SkyLight symbol resolution failed — lock-screen visibility disabled")
            return nil
        }

        SLSMainConnectionID = unsafeBitCast(p_main, to: (@convention(c) () -> Int32).self)
        SLSSpaceCreate = unsafeBitCast(p_create, to: (@convention(c) (Int32, Int32, Int32) -> Int32).self)
        SLSSpaceDestroy = unsafeBitCast(p_destroy, to: (@convention(c) (Int32, Int32) -> Int32).self)
        SLSSpaceSetAbsoluteLevel = unsafeBitCast(p_setLevel, to: (@convention(c) (Int32, Int32, Int32) -> Int32).self)
        SLSShowSpaces = unsafeBitCast(p_show, to: (@convention(c) (Int32, CFArray) -> Int32).self)
        SLSHideSpaces = unsafeBitCast(p_hide, to: (@convention(c) (Int32, CFArray) -> Int32).self)
        SLSSpaceAddWindowsAndRemoveFromSpaces = unsafeBitCast(p_add, to: (@convention(c) (Int32, Int32, CFArray, Int32) -> Int32).self)

        // Get our process's WindowServer connection (each app has one).
        connection = SLSMainConnectionID()

        // Create a new space. The "1" flag is the standard "managed
        // space" flag; the third argument is options (0 = none).
        space = SLSSpaceCreate(connection, 1, 0)

        // Pin the new space at level 400 — above lock-screen shield
        // (300), same level as Notification Center.
        _ = SLSSpaceSetAbsoluteLevel(connection, space, Self.notificationCenterAtScreenLockLevel)

        // Make the space visible. Without this it exists but the
        // compositor doesn't draw it.
        _ = SLSShowSpaces(connection, [space] as CFArray)

        NSLog("Notetaker: NotchSpaceManager — created space \(space) at level \(Self.notificationCenterAtScreenLockLevel)")
    }

    deinit {
        _ = SLSHideSpaces(connection, [space] as CFArray)
        _ = SLSSpaceDestroy(connection, space)
    }

    /// Add an `NSWindow` to our custom space WITHOUT removing it
    /// from existing spaces (mask 0). Idempotent.
    ///
    /// **Why mask 0, not 7.** With mask=7 the window is removed
    /// from every regular space type (user desktops, full-screen,
    /// etc.) and only lives in our custom one — that breaks the
    /// normal compositor's spring/animation pipeline because the
    /// panel is no longer "of" any user space, and it caused
    /// animation regressions in our hover-open spring (user
    /// reported the morph "got broken"). With mask=0 the window
    /// is in BOTH the user's current space AND our level-400
    /// custom space — it composites normally on desktop AND
    /// renders on lock. mew-notch uses the equivalent
    /// `CGSAddWindowsToSpaces` (no-remove variant) for the same
    /// reason.
    ///
    /// Effect: the window stays in normal compositor flow on
    /// desktop, AND gains lock-screen visibility through the
    /// level-400 space membership.
    func attach(_ window: NSWindow) {
        _ = SLSSpaceAddWindowsAndRemoveFromSpaces(
            connection,
            space,
            [window.windowNumber] as CFArray,
            0  // mask 0 = ADD ONLY, don't remove from any space
        )
        NSLog("Notetaker: attached window #\(window.windowNumber) to NotchSpace (additive, mask=0)")
    }
}
