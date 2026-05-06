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
        window.setFrameAutosaveName("NoxOnboardingWindow")
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
        // 2026-05-06 — window level reset to .normal.
        //
        // The earlier code put this window at NSWindow.Level(rawValue: 200)
        // to keep it above the notch panel (level .popUpMenu = 101).
        // But 200 is ALSO above the level system permission dialogs
        // sit at (TCC alerts render at ~.modalPanel / .normal). User
        // feedback: "all the permission [prompts] are coming in the
        // background layer of the onboarding."
        //
        // Onboarding now fires BEFORE the notch panel is built (see
        // AppDelegate.applicationDidFinishLaunching — the
        // `presentIfNeeded` call moved to the top of that method),
        // so the "panel covers onboarding" race the level=200 hack
        // was guarding against doesn't exist anymore. And
        // `OnboardingManager.present()` calls `panelController?
        // .panel.orderOut(nil)` if the panel does happen to be up,
        // so on the rare path where re-presenting onboarding from
        // Settings finds the panel already visible, we explicitly
        // hide it for the duration.
        //
        // Result: onboarding sits at .normal, system permission
        // dialogs render on top of it as the user expects, and
        // there's no race with the notch panel.
        window?.level = .normal
        window?.makeKeyAndOrderFront(nil)
    }

    private func completeOnboarding() {
        UserDefaults.standard.set(true, forKey: "onboardingCompletedV2")
        onComplete()
        window?.performClose(nil)
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        // User dismissed the window without finishing — still mark
        // as "shown" so we don't pester them every launch. The
        // unfinished flow is fine; everything's reachable from
        // Settings.
        UserDefaults.standard.set(true, forKey: "onboardingCompletedV2")
        // Drop back to menu-bar-only mode (matches Settings close
        // behavior so we don't leak a Dock icon).
        NSApp.setActivationPolicy(.accessory)
        // Bring the notch panel back online. OnboardingManager.present()
        // orderOut'd it for the duration; if the user closed the
        // window via the red traffic light (not the Continue button
        // which routes through completeOnboarding → onComplete),
        // we still need to restore the panel here.
        DispatchQueue.main.async {
            (NSApp.delegate as? AppDelegate)?.panelController?.parkAtNotchHidden()
        }
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
        let alreadyDone = UserDefaults.standard.bool(forKey: "onboardingCompletedV2")
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
        // Fully orderOut the notch panel for the duration of
        // onboarding. Earlier this called .hide() which animates
        // the slab/pill down to notchHiddenFrame but keeps the
        // panel ordered front — the resting pill could still
        // appear over the onboarding window in some states. With
        // the onboarding window now at .normal level (so system
        // permission dialogs can render above it), even an
        // invisible-silhouette notch panel at level .popUpMenu
        // (101) would render above onboarding. orderOut takes the
        // panel completely off the screen until the user finishes
        // / dismisses onboarding; the panel auto-restores via the
        // existing parkAtNotchHidden / orderFrontRegardless paths
        // when music plays / hover fires / etc.
        (NSApp.delegate as? AppDelegate)?.panelController?.orderOutImmediately()

        let controller = OnboardingWindowController(onComplete: { [weak self] in
            self?.windowController = nil
            // Bring the notch panel back online so hover / music /
            // drag events work again. parkAtNotchHidden is the
            // standard "panel ready and waiting at the notch"
            // entry point.
            (NSApp.delegate as? AppDelegate)?.panelController?.parkAtNotchHidden()
        })
        windowController = controller
        controller.show()
        DictationOrchestrator.dlog("OnboardingManager.present — show() complete, isVisible=\(controller.window?.isVisible ?? false)")
    }
}
