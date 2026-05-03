import AppKit
import SwiftUI

/// Manages the first-launch onboarding window. Created lazily by
/// `OnboardingManager` and torn down when the user reaches the
/// "you're all set" CTA OR closes the window.
///
/// Window chrome:
///   • Titled (so traffic lights work + the window can be dragged
///     by the title bar) but with the title-bar transparent and
///     the title hidden, so the dark slab background reads as
///     edge-to-edge.
///   • `.fullSizeContentView` so SwiftUI content paints behind
///     the title-bar zone — that's how the "premium dark slab
///     all the way to the top" feel works.
///   • Fixed size, non-resizable. Onboarding content is hand-tuned
///     to a specific frame; resizing would just expose padding.
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {

    private let onComplete: () -> Void

    init(onComplete: @escaping () -> Void) {
        self.onComplete = onComplete

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 540),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to nox"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("NotetakerOnboardingWindow")
        // Dark traffic lights look right on the dark background;
        // light controls would clash. Setting the appearance
        // explicitly makes the lights match regardless of system
        // light/dark mode.
        window.appearance = NSAppearance(named: .darkAqua)
        // Tighten the corner radius slightly — default macOS
        // window corners are 10pt, the slab elsewhere uses ~14pt.
        // We don't override the corner radius here (NSWindow's
        // corners are managed by the WM), but the dark background
        // bleeds to the edges so the corners read as continuous
        // with the system frame.

        super.init(window: window)

        let host = NSHostingController(
            rootView: OnboardingView(onComplete: { [weak self] in
                self?.completeOnboarding()
            })
        )
        host.view.frame = NSRect(x: 0, y: 0, width: 720, height: 540)
        window.contentViewController = host
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("OnboardingWindowController doesn't support coder init")
    }

    func show() {
        // Bring the app fully forward — onboarding is a focused
        // task that needs keyboard focus + a dock icon temporarily
        // (so users can switch back if they navigate away to copy
        // their Groq key). Dock icon recedes when the window
        // closes, just like the Settings flow.
        NSApp.setActivationPolicy(.regular)
        if #available(macOS 14, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        // CRITICAL: the notch panel sits at NSWindow.Level.popUpMenu
        // (101) so it always floats above normal app windows. A
        // regular `.normal`-level onboarding window would render
        // BEHIND the panel and the user would never see it (this is
        // exactly the "I can't see any onboard page" symptom on the
        // M2 Air). Bump to a custom raw value (200) — above the
        // panel's level but well below `.screenSaver` (1000) so we
        // don't compete with Mission Control / Spotlight / system
        // overlays.
        //
        // The panel itself is also told to hide (`AppDelegate
        // .panelController?.hide()`) before the controller is
        // constructed — see `OnboardingManager.present()`. Belt +
        // suspenders: even if hide() is a no-op (resting-pill state
        // doesn't trigger the slab-close path), the higher level
        // keeps the window visible.
        window?.level = NSWindow.Level(rawValue: 200)
        window?.makeKeyAndOrderFront(nil)
    }

    private func completeOnboarding() {
        UserDefaults.standard.set(true, forKey: "onboardingCompletedV1")
        onComplete()
        window?.performClose(nil)
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        // User dismissed the window without finishing — still mark
        // as "shown" so we don't pester them every launch. The
        // unfinished flow is fine; everything's reachable from
        // Settings.
        UserDefaults.standard.set(true, forKey: "onboardingCompletedV1")
        // Drop back to menu-bar-only mode (matches Settings close
        // behavior so we don't leak a Dock icon).
        NSApp.setActivationPolicy(.accessory)
    }
}

/// Decides whether onboarding should run, and runs it. AppDelegate
/// instantiates one of these and asks `presentIfNeeded()` once at
/// `applicationDidFinishLaunching`.
@MainActor
final class OnboardingManager {
    private var windowController: OnboardingWindowController?

    /// Show onboarding if we haven't already completed it.
    /// Returns `true` if the window was shown.
    @discardableResult
    func presentIfNeeded() -> Bool {
        let alreadyDone = UserDefaults.standard.bool(forKey: "onboardingCompletedV1")
        DictationOrchestrator.dlog("OnboardingManager.presentIfNeeded — alreadyDone=\(alreadyDone)")
        guard !alreadyDone else {
            return false
        }
        present()
        return true
    }

    /// Show onboarding unconditionally — useful for a "Show
    /// onboarding" Settings button so existing users can re-run
    /// the flow.
    func present() {
        DictationOrchestrator.dlog("OnboardingManager.present — creating window")
        // Hide the resting pill / open slab so it doesn't compete
        // with the onboarding window for attention. The panel
        // auto-restores on hover / events after onboarding closes
        // — no need to track or restore state ourselves.
        (NSApp.delegate as? AppDelegate)?.panelController?.hide()

        let controller = OnboardingWindowController(onComplete: { [weak self] in
            self?.windowController = nil
        })
        windowController = controller
        controller.show()
        DictationOrchestrator.dlog("OnboardingManager.present — show() complete, isVisible=\(controller.window?.isVisible ?? false)")
    }
}
