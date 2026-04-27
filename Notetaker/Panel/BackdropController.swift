import AppKit

/// Full-screen scrim window that sits BEHIND the main panel and dims
/// + blurs everything underneath when the slab is expanded. Without
/// it the slab silhouette has to compete visually with whatever's
/// on the desktop (the user reported the panel feeling lost against
/// a busy game window). With it, the panel reads as the active
/// surface and the rest of the screen recedes into a calm backdrop —
/// same convention iOS sheets use for modal focus.
///
/// Implementation notes:
///   • A separate NSWindow at level `.floating - 1`, just below
///     PanelWindowController's panel. Window-level ordering is what
///     guarantees the scrim is BEHIND our content even when other
///     apps are active.
///   • Background = NSVisualEffectView with `.fullScreenUI` material
///     (translucent dark blur) plus a `Color.black` overlay at low
///     opacity for additional darkening. NSVisualEffectView's
///     internal blur kernel is GPU-accelerated; the cost is one-time
///     when the window appears, free thereafter.
///   • Mouse events pass through to whatever's beneath (the user
///     can still click the desktop / other apps through the scrim).
///     Without this you'd intercept clicks the user expected to
///     reach Finder, the dock, etc.
///   • Show/hide via alphaValue with explicit Core Animation fade.
///     Matches the panel's open/close timing so dim and slab arrive
///     and leave together.
@MainActor
final class BackdropController {

    private let window: NSWindow

    init() {
        let mainScreen = NSScreen.main ?? NSScreen.screens.first!
        let frame = mainScreen.frame
        let w = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        // Ignore mouse events so clicks pass through to the
        // desktop / other apps. The user can still interact with
        // whatever's behind the dimmed scrim.
        w.ignoresMouseEvents = true
        // Sit just below our panel's window level. PanelWindowController
        // uses .floating; we use one tier below so the panel stays
        // on top of the scrim regardless of focus changes.
        w.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        w.alphaValue = 0  // start invisible
        // Animate via NSWindow's standard alpha animator on
        // setShown calls. NSAnimationContext handles the fade.

        // Build the content: visual effect view full-frame, plus
        // a black overlay for extra darkness. NSVisualEffectView
        // alone gives a soft blur but doesn't darken much against
        // bright desktops; the overlay caps the brightness.
        let visualEffect = NSVisualEffectView(frame: frame)
        visualEffect.autoresizingMask = [.width, .height]
        visualEffect.material = .fullScreenUI
        visualEffect.blendingMode = .behindWindow
        visualEffect.state = .active

        let darken = NSView(frame: frame)
        darken.autoresizingMask = [.width, .height]
        darken.wantsLayer = true
        darken.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.28).cgColor

        let container = NSView(frame: frame)
        container.autoresizingMask = [.width, .height]
        container.addSubview(visualEffect)
        container.addSubview(darken)

        w.contentView = container
        self.window = w
    }

    /// Cross-fade the scrim. Duration matches the panel-frame morph
    /// so the dim arrives with the slab and leaves with it.
    func setShown(_ shown: Bool, duration: TimeInterval) {
        if shown {
            // Make sure the window is on the active space and on
            // screen before animating its alpha.
            window.orderFront(nil)
            // Ensure the frame matches the current screen bounds —
            // user might have moved the panel between screens.
            if let screen = NSScreen.main {
                window.setFrame(screen.frame, display: false)
            }
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = duration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = shown ? 1.0 : 0.0
        }, completionHandler: { [weak self] in
            guard let self else { return }
            // After the fade completes, if we're hidden, orderOut
            // so the window isn't still consuming GPU compositing
            // resources for an invisible scrim.
            if !shown { self.window.orderOut(nil) }
        })
    }
}
