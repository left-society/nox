import AppKit
import SwiftUI

/// Discriminated union of every HUD presentation the notch can show.
/// Equatable so the SwiftUI root view can use `.onChange(of: presentation)`
/// to drive its morph-in animation when the orchestrator swaps in a new
/// payload. Each new HUD type means adding a case here and a matching
/// pill-view branch in `NotchHUDRoot`.
enum NotchPresentation: Equatable {
    case charging(percent: Int, isCharging: Bool)
    /// Now-playing HUD — Spotify, Apple Music, YouTube tabs, podcasts,
    /// anything that publishes via macOS's MediaRemote pipeline. The
    /// presentation carries the full info snapshot; the orchestrator
    /// re-emits a new presentation whenever the track or play state
    /// changes so the SwiftUI view can animate the swap.
    case nowPlaying(NowPlayingInfo)
}

/// Top-level SwiftUI root for the HUD window. Owns the `isShown` flag
/// that drives the morph animation — the controller flips it in tandem
/// with show()/hide() so the pill blooms after the window is on screen
/// (and collapses before the window orders out).
///
/// The `onCommand` closure routes media-control button taps back up to
/// the controller / orchestrator without leaking the MediaRemote service
/// dependency into the SwiftUI tree (keeps previews compilable in
/// isolation). For non-music presentations the closure is a no-op.
private struct NotchHUDRoot: View {
    let presentation: NotchPresentation?
    let isShown: Bool
    let onCommand: (MediaRemoteService.Command) -> Void

    var body: some View {
        ZStack(alignment: .top) {
            switch presentation {
            case .charging(let percent, let isCharging):
                ChargingPillView(
                    percent: percent,
                    isCharging: isCharging,
                    isShown: isShown
                )
            case .nowPlaying(let info):
                NowPlayingPillView(
                    info: info,
                    isShown: isShown,
                    onCommand: onCommand
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
    /// Outer NSPanel size. The window's content size is pinned to the
    /// largest pill we'll show (now-playing at 340×56 + 30pt padding
    /// for downward shadow + 24pt horizontal slack for animation
    /// breathing room) so the morph never gets clipped against the
    /// window edge during a smaller-pill (charging) presentation.
    private static let windowWidth: CGFloat = 380
    private static let windowHeight: CGFloat = 140
    /// Auto-dismiss after this many seconds. Long enough to read
    /// "100% Charging" without rushing, short enough that the HUD
    /// doesn't loiter and feel obtrusive.
    private static let autoHideDelay: TimeInterval = 4.0
    /// Now-playing pills stay longer than charging pills — the user
    /// often wants a few seconds to glance at the track name and reach
    /// for the play/pause button if they were going to. 6s is also
    /// what Alcove uses for the equivalent presentation.
    private static let nowPlayingHideDelay: TimeInterval = 6.0
    /// Brief pause after isShown=false before orderOut — gives the
    /// SwiftUI collapse spring time to play to completion. Matches the
    /// main panel's hide cadence.
    private static let collapseDuration: TimeInterval = 0.32

    /// Routes media-control button taps from the now-playing pill to
    /// whoever owns the controller (typically NotchOrchestrator, which
    /// forwards to MediaRemoteService.send). Charging presentations
    /// never invoke this closure.
    var onMediaCommand: ((MediaRemoteService.Command) -> Void)?

    private let panel: NSPanel
    private let state = NotchHUDState()
    private var hideWorkItem: DispatchWorkItem?
    private var orderOutWorkItem: DispatchWorkItem?
    /// Tracks whether the cursor is currently inside the pill's
    /// hit-testable area. Now-playing presentations cancel the
    /// auto-hide timer while hovered; charging presentations ignore
    /// this flag entirely (they have no buttons to hover).
    private var isHovered = false
    private var hoverMonitor: Any?

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
        // Defaults to ignoring mouse events (charging behavior). show()
        // flips this off when an interactive presentation lands so the
        // play/pause/skip buttons can receive clicks.
        panel.ignoresMouseEvents = true

        let host = NSHostingView(
            rootView: NotchHUDRootHost(
                state: state,
                onCommand: { [weak self] command in
                    self?.handleCommand(command)
                }
            )
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

        // Two presentations have different interactivity rules:
        // - Charging: passive HUD, never accepts mouse events. We want
        //   clicks to fall through to the menu bar / desktop beneath.
        // - Now-playing: needs to accept clicks on the play/pause/skip
        //   buttons. Hovering also pauses the auto-hide timer.
        let isInteractive: Bool
        switch presentation {
        case .charging:
            isInteractive = false
        case .nowPlaying:
            isInteractive = true
        }
        panel.ignoresMouseEvents = !isInteractive

        state.presentation = presentation
        positionAtNotch()
        panel.orderFrontRegardless()
        // Deliberately NOT calling makeKey — same rule as the main
        // panel. The HUD is non-interactive (or only point-interactive
        // for now-playing buttons) and must never take focus from
        // whatever the user is currently typing in.

        // Flip on the next runloop tick so SwiftUI sees a false→true
        // transition and runs the spring. Setting it synchronously
        // here would coincide with the window appearing, and SwiftUI
        // sometimes coalesces both into the initial render.
        DispatchQueue.main.async { [weak self] in
            self?.state.isShown = true
        }

        if isInteractive {
            installHoverMonitor()
        } else {
            removeHoverMonitor()
        }

        // Schedule auto-hide unless the cursor is already on the pill
        // (rare but possible during rapid track changes).
        scheduleAutoHide(for: presentation)
    }

    /// Collapse the pill and order the window out after the spring
    /// finishes. Safe to call from anywhere — re-entrant calls just
    /// reset the existing schedule.
    func hide() {
        cancelTimers()
        removeHoverMonitor()
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

    /// Pick the right auto-hide delay and arm the timer. Hovering on a
    /// now-playing pill suppresses the schedule entirely — the user is
    /// engaging with the controls, so the HUD should stay until they
    /// move on.
    private func scheduleAutoHide(for presentation: NotchPresentation) {
        if isHovered {
            switch presentation {
            case .nowPlaying:
                return
            case .charging:
                break
            }
        }

        let delay: TimeInterval
        switch presentation {
        case .charging:
            delay = NotchHUDWindowController.autoHideDelay
        case .nowPlaying:
            delay = NotchHUDWindowController.nowPlayingHideDelay
        }

        let item = DispatchWorkItem { [weak self] in
            self?.hide()
        }
        hideWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func cancelTimers() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        orderOutWorkItem?.cancel()
        orderOutWorkItem = nil
    }

    /// Local + global mouseMoved monitors that watch for the cursor
    /// entering / leaving the pill's frame. While hovered: cancel the
    /// pending hide. On exit: reschedule the hide with the full delay
    /// (so leaving the pill effectively "resets" the timer instead of
    /// hiding instantly).
    private func installHoverMonitor() {
        removeHoverMonitor()
        let monitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.checkHoverState()
            }
        }
        hoverMonitor = monitor
        // Run once now to establish initial state.
        checkHoverState()
    }

    private func removeHoverMonitor() {
        if let monitor = hoverMonitor {
            NSEvent.removeMonitor(monitor)
            hoverMonitor = nil
        }
        isHovered = false
    }

    private func checkHoverState() {
        guard let presentation = state.presentation else { return }
        let inside = panel.frame.contains(NSEvent.mouseLocation)
        if inside == isHovered { return }
        isHovered = inside
        if inside {
            // Cancel any pending hide while the user is engaging.
            hideWorkItem?.cancel()
            hideWorkItem = nil
        } else {
            // Cursor left → restart the auto-hide cycle so the user
            // gets the full delay's worth of "I might come back".
            scheduleAutoHide(for: presentation)
        }
    }

    private func handleCommand(_ command: MediaRemoteService.Command) {
        // Reset the auto-hide timer when the user interacts — they're
        // clearly engaged, no point yanking the HUD mid-tap.
        if let presentation = state.presentation {
            cancelTimers()
            scheduleAutoHide(for: presentation)
        }
        onMediaCommand?(command)
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
    let onCommand: (MediaRemoteService.Command) -> Void

    var body: some View {
        NotchHUDRoot(
            presentation: state.presentation,
            isShown: state.isShown,
            onCommand: onCommand
        )
    }
}
