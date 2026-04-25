import AppKit
import SwiftUI

/// Discriminated union of every HUD presentation the notch can show.
/// Equatable so the SwiftUI root view can use `.onChange(of: presentation)`
/// to drive its morph-in animation when the orchestrator swaps in a new
/// payload. Adding a music HUD later means adding a `case music(...)`
/// here and a `MusicPillView` branch in `NotchHUDRoot`.
enum NotchPresentation: Equatable {
    case charging(percent: Int, isCharging: Bool)
}

/// Top-level SwiftUI root for the HUD window. Owns the `isShown` flag
/// that drives the morph animation — the controller flips it in tandem
/// with show()/hide() so the pill blooms after the window is on screen
/// (and collapses before the window orders out).
private struct NotchHUDRoot: View {
    let presentation: NotchPresentation?
    let isShown: Bool

    var body: some View {
        ZStack(alignment: .top) {
            switch presentation {
            case .charging(let percent, let isCharging):
                ChargingPillView(
                    percent: percent,
                    isCharging: isCharging,
                    isShown: isShown
                )
            case .none:
                // Empty placeholder so the window has something hosted
                // even before the first show() call lands.
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// Observable shim that lets the controller mutate state from outside
/// SwiftUI while the hosted view tree reacts via `@ObservedObject`.
/// Kept private because nothing else in the app should be poking the
/// HUD's internals directly — go through the controller's API.
@MainActor
private final class NotchHUDState: ObservableObject {
    @Published var presentation: NotchPresentation? = nil
    @Published var isShown: Bool = false
}

/// Window controller for the notch HUD. Hosts a borderless,
/// non-activating NSPanel that floats at status-bar level and joins
/// every Space — the HUD must be reachable wherever the user is, and
/// must NEVER steal keyboard focus from whatever they're typing in
/// (mirrors the rule we enforce on the main panel: no `makeKey()`).
///
/// The window itself is bigger than the visible pill (320×140) on
/// purpose: the inner SwiftUI view paints a downward drop shadow that
/// would clip against a tight window frame. The extra 100pt of vertical
/// slack and 40pt of horizontal slack give the shadow room to fade
/// fully to alpha 0 before hitting the NSPanel boundary.
@MainActor
final class NotchHUDWindowController {
    /// Outer NSPanel size. Pill renders inside, anchored top-center.
    private static let windowWidth: CGFloat = 320
    private static let windowHeight: CGFloat = 140
    /// Auto-dismiss after this many seconds. Long enough to read
    /// "100% Charging" without rushing, short enough that the HUD
    /// doesn't loiter and feel obtrusive.
    private static let autoHideDelay: TimeInterval = 4.0
    /// Brief pause after isShown=false before orderOut — gives the
    /// SwiftUI collapse spring time to play to completion. Matches the
    /// main panel's hide cadence.
    private static let collapseDuration: TimeInterval = 0.32

    private let panel: NSPanel
    private let state = NotchHUDState()
    private var hideWorkItem: DispatchWorkItem?
    private var orderOutWorkItem: DispatchWorkItem?

    init() {
        let contentRect = NSRect(
            x: 0,
            y: 0,
            width: NotchHUDWindowController.windowWidth,
            height: NotchHUDWindowController.windowHeight
        )

        // Borderless + non-activating: the HUD must appear without
        // bringing the app to the foreground (the user is likely in
        // another app when they plug their charger in — flipping focus
        // would be hostile).
        panel = NSPanel(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )

        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // System shadow is rectangular — would show as a hard rectangle
        // around our rounded SwiftUI pill. We render our own shadow
        // inside ChargingPillView instead.
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.ignoresMouseEvents = true

        let host = NSHostingView(
            rootView: NotchHUDRootHost(state: state)
        )
        host.frame = contentRect
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
    }

    // MARK: - Public API

    /// Bloom the pill with a presentation. If a pill is already on
    /// screen, the new presentation replaces it (the SwiftUI .onChange
    /// in the pill view will animate the morph). Re-calling show()
    /// resets the auto-hide timer — a rapid plug/unplug doesn't risk
    /// the pill disappearing mid-animation.
    func show(presentation: NotchPresentation) {
        cancelTimers()

        state.presentation = presentation
        positionAtNotch()
        panel.orderFrontRegardless()
        // Deliberately NOT calling makeKey — same rule as the main
        // panel. The HUD is non-interactive and must never take focus
        // from whatever the user is currently typing in.

        // Flip on the next runloop tick so SwiftUI sees a false→true
        // transition and runs the spring. Setting it synchronously
        // here would coincide with the window appearing, and SwiftUI
        // sometimes coalesces both into the initial render.
        DispatchQueue.main.async { [weak self] in
            self?.state.isShown = true
        }

        // Schedule auto-hide.
        let item = DispatchWorkItem { [weak self] in
            self?.hide()
        }
        hideWorkItem = item
        DispatchQueue.main.asyncAfter(
            deadline: .now() + NotchHUDWindowController.autoHideDelay,
            execute: item
        )
    }

    /// Collapse the pill and order the window out after the spring
    /// finishes. Safe to call from anywhere — re-entrant calls just
    /// reset the existing schedule.
    func hide() {
        cancelTimers()
        state.isShown = false

        let item = DispatchWorkItem { [weak self] in
            self?.panel.orderOut(nil)
            self?.state.presentation = nil
        }
        orderOutWorkItem = item
        DispatchQueue.main.asyncAfter(
            deadline: .now() + NotchHUDWindowController.collapseDuration,
            execute: item
        )
    }

    // MARK: - Internals

    private func cancelTimers() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        orderOutWorkItem?.cancel()
        orderOutWorkItem = nil
    }

    /// Place the panel so its TOP edge sits flush with the menu bar's
    /// bottom (visibleFrame.maxY) and it's horizontally centered on
    /// screen — directly under the physical notch on a notched MacBook.
    /// Same anchoring rule the main panel uses.
    private func positionAtNotch() {
        let screen = NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = NSSize(
            width: NotchHUDWindowController.windowWidth,
            height: NotchHUDWindowController.windowHeight
        )
        let x = visible.midX - size.width / 2
        // panel.frame.y is the BOTTOM in screen coords; we want the TOP
        // at visible.maxY, so y = visible.maxY - height.
        let y = visible.maxY - size.height
        panel.setContentSize(size)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

/// SwiftUI host that observes the controller's state object. Kept as a
/// separate file-private struct so the controller can hand the host a
/// fresh instance bound to the state without leaking the state type
/// into the public API.
private struct NotchHUDRootHost: View {
    @ObservedObject var state: NotchHUDState

    var body: some View {
        NotchHUDRoot(
            presentation: state.presentation,
            isShown: state.isShown
        )
    }
}
