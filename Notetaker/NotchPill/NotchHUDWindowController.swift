import AppKit
import SwiftUI

/// AppKit clamps NSPanel frames to `visibleFrame` (the screen area
/// EXCLUDING the menu bar) by default. The whole "emerge from the
/// notch" trick depends on the HUD window's TOP edge sitting at the
/// SCREEN's max-Y — i.e. ABOVE the menu bar, with the upper portion
/// of the window hidden BEHIND the notch hardware / menu-bar strip.
/// Without this override, AppKit silently snaps our y-origin back
/// down by `safeAreaInsets.top` (~37pt), and the pill renders below
/// the menu bar instead of bleeding out of the notch — which is the
/// "showing under the hood" bug the user reported. Returning the
/// rect unchanged hands frame ownership to us, same pattern as
/// `KeyablePanel` in `PanelWindowController.swift`.
private final class NotchHUDPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        return frameRect
    }
}

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
/// The `topInset` parameter is the height of the window's upper region
/// that sits BEHIND the menu bar / notch hardware. The visible pill
/// content is pushed down by exactly that amount so the bottom of the
/// menu bar visually flushes against the top of the pill — reads as
/// the pill emerging from the notch, not floating below it.
///
/// The `onCommand` closure routes media-control button taps back up to
/// the controller / orchestrator without leaking the MediaRemote service
/// dependency into the SwiftUI tree (keeps previews compilable in
/// isolation). For non-music presentations the closure is a no-op.
private struct NotchHUDRoot: View {
    let presentation: NotchPresentation?
    let isShown: Bool
    let topInset: CGFloat
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
        // Push the pill below the menu-bar zone. Without this, the
        // pill renders at the window's top edge — which is ABOVE the
        // menu bar, so the visible portion would sit hidden behind
        // the notch hardware. With `topInset` ≈ safeAreaInsets.top
        // (~37pt), the pill's top lands exactly at the menu bar's
        // bottom edge, so it visually drops out of the notch.
        .padding(.top, topInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea(.all, edges: .top)
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
    /// Vertical inset between the window's top edge and the visible
    /// pill's top edge, in points. Matches the screen's notch overlap
    /// (`safeAreaInsets.top` ~= 37pt on a notched MacBook). The window
    /// itself sits ABOVE the menu bar — its upper `topInset` points
    /// are hidden behind the menu-bar strip / notch hardware. Pushing
    /// the visible pill content down by this amount makes the pill
    /// appear to drop OUT of the menu bar's bottom edge rather than
    /// floating below it.
    @Published var topInset: CGFloat = 0
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
    /// Outer NSPanel size. The window must be wider than the visible
    /// pill so the Core Animation drop-shadow has room to bleed past
    /// the pill's edges before hitting the panel boundary. With a
    /// 600pt pill we give 40pt of horizontal slack on each side
    /// (= 680pt window), and 100pt of vertical slack for the downward
    /// shadow + the upper region that hides behind the notch / menu
    /// bar.
    private static let windowWidth: CGFloat = 680
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
        //
        // NotchHUDPanel (subclass) overrides constrainFrameRect so we
        // can position above the menu bar — required for the "emerge
        // from the notch" silhouette. A plain NSPanel here would get
        // clamped to visibleFrame and the pill would render below the
        // menu bar instead, which is the bug the user reported as
        // "showing under the hood."
        panel = NotchHUDPanel(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )

        panel.isFloatingPanel = true
        // .popUpMenu (101) draws OVER the menu bar — same level the
        // main panel uses. .statusBar (25) draws AT the menu bar's
        // level: in a z-order tie the system menu wins, so portions
        // of our pill that overlap the menu-bar strip would be hidden.
        // popUpMenu makes the overlap explicit. We only ever overlap
        // the dead zone around the notch (no app menus there to
        // trample), so this is safe.
        panel.level = .popUpMenu
        // .canJoinAllSpaces — pill stays visible across every Space.
        // .fullScreenAuxiliary — pill stays visible during fullscreen apps.
        // .stationary — pill does NOT animate during three-finger swipe
        //   between Spaces or during Mission Control. Without this the
        //   window slides off and back with the desktop, which the user
        //   described as "the whole thing just got like different
        //   phases, like different windows for different applications."
        //   Alcove's pill stays rock-solid in screen space; this flag is
        //   how it does that.
        // .ignoresCycle — Cmd+` doesn't cycle to the pill (it's a HUD,
        //   not a window the user wants to focus).
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle
        ]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        ScreenSharingPolicy.apply(to: panel)
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

        // Per BUG-115 fix: the work item closure mutates @MainActor
        // state (`panel.orderOut`, `state.presentation = nil`).
        // DispatchWorkItem closures are NOT in the actor's
        // isolation domain even when dispatched to .main queue —
        // same pattern BUG-010 / BUG-111 / BUG-112 / BUG-113 hit.
        // Wrap the body in `Task { @MainActor in ... }` to hop
        // properly into the actor before touching its state.
        // Strict-concurrency build will flag the old form; future
        // Swift may turn it into a runtime crash.
        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.panel.orderOut(nil)
                self?.state.presentation = nil
            }
        }
        orderOutWorkItem = item
        DispatchQueue.main.asyncAfter(
            deadline: .now() + NotchHUDWindowController.collapseDuration,
            execute: item
        )
    }

    /// Collapse the pill iff the current presentation is now-playing.
    /// Used by the orchestrator when MediaRemote reports "nothing
    /// playing" so we can clear the music HUD without disturbing a
    /// charging pill that happens to be on screen at the same time.
    /// (Charging is rare-but-possible to coincide with a track change
    /// — e.g. plugging in a laptop while listening.)
    func hideIfShowingNowPlaying() {
        if case .nowPlaying = state.presentation {
            hide()
        }
    }

    /// Refresh the displayed presentation WITHOUT re-blooming. Used
    /// when the underlying info changes but the user-visible "this is
    /// a new event" semantics don't apply — primarily artwork landing
    /// from the iTunes Search fallback after the title/artist already
    /// rendered.
    ///
    /// Without this path, the orchestrator's "only bloom on title or
    /// play-state change" dedup blocks artwork-only updates from ever
    /// reaching the SwiftUI tree — which is why the user reported "no
    /// music thumbnail on the live thing." YouTube tabs don't carry
    /// artwork in MediaRemote's dict, so the first publish lands with
    /// `artworkData == nil` and the iTunes lookup fills it in seconds
    /// later. Without an update path, that fill never makes it to the
    /// pill.
    ///
    /// Two things this method DOES NOT do compared to `show(_:)`:
    ///   - No `cancelTimers` / `scheduleAutoHide` round-trip — the
    ///     timer the bloom set up is still appropriate for the same
    ///     track. Resetting it would extend "auto-hide in 6s" every
    ///     time artwork lands, which feels wrong.
    ///   - No `panel.orderFrontRegardless` — the panel is already on
    ///     screen by definition; re-fronting can briefly steal the
    ///     pointer focus on some macOS versions.
    ///
    /// If the panel is hidden when this is called, we silently bail.
    /// Reviving a collapsed pill on artwork arrival would be more
    /// surprising than helpful — if the user dismissed it, they don't
    /// want it back without a fresh user-visible event.
    func updateContent(_ presentation: NotchPresentation) {
        guard panel.isVisible else { return }
        // Same case match — refuse to swap kinds via this path; that's
        // a real presentation change and should go through show().
        switch (state.presentation, presentation) {
        case (.nowPlaying, .nowPlaying):
            state.presentation = presentation
        case (.charging, .charging):
            state.presentation = presentation
        default:
            return
        }
    }

    // MARK: - Internals

    /// Pick the right auto-hide delay and arm the timer. Two cases
    /// suppress the schedule entirely:
    ///
    /// 1. **Hovering on a now-playing pill** — the user is engaging
    ///    with the controls, yanking the HUD mid-tap would feel hostile.
    ///
    /// 2. **Now-playing while music is actively playing** — Alcove
    ///    parity. The pill becomes an ambient indicator that stays on
    ///    screen the whole time the user has tunes going, only
    ///    collapsing when playback pauses or the source app goes away.
    ///    The user explicitly asked for this ("It should be playing
    ///    music. It should be showing music just like Elkhob does").
    ///    Charging still auto-hides because nothing about a plugged
    ///    charger needs constant glanceability — once "100% Charging"
    ///    has registered, the HUD is just visual noise.
    private func scheduleAutoHide(for presentation: NotchPresentation) {
        if isHovered {
            switch presentation {
            case .nowPlaying:
                return
            case .charging:
                break
            }
        }

        // Persistent presentations stay until externally cleared — no
        // timer armed. Switching to a non-persistent presentation (e.g.
        // music pauses) re-enters scheduleAutoHide via show(), which
        // takes the normal path below.
        switch presentation {
        case .nowPlaying(let info) where info.isPlaying:
            return
        case .charging, .nowPlaying:
            break
        }

        let delay: TimeInterval
        switch presentation {
        case .charging:
            delay = NotchHUDWindowController.autoHideDelay
        case .nowPlaying:
            delay = NotchHUDWindowController.nowPlayingHideDelay
        }

        // 2026-05-08 audit H8: the original closure was a bare
        // [weak self] in self?.hide() — `hide()` is @MainActor, so
        // strict-concurrency compiles flagged the unhopped call.
        // The other call site in this file (lines 313-318) was
        // already fixed under BUG-115 by wrapping in
        // Task { @MainActor in ... }. This site was missed; same
        // wrap brings them into parity.
        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.hide() }
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
        // Per BUG-010 follow-up: matches the same fix MediaRemoteService
        // got — `MainActor.assumeIsolated` only asserts that we're on the
        // main thread, NOT that we're in the main actor's isolation
        // domain. Global NSEvent monitors deliver on the main thread but
        // outside any actor context, so the prior code was lying to the
        // compiler. `Task { @MainActor in ... }` properly hops into the
        // actor and is safe under strict concurrency.
        let monitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            Task { @MainActor in
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

    /// Pin the panel's TOP edge flush with the SCREEN's TOP edge
    /// (= `frame.maxY`), and push the SwiftUI pill content down by the
    /// notch / menu-bar overlap so the visible silhouette emerges out of
    /// the bottom of the notch hardware (notched Macs) or the bottom of
    /// the menu-bar strip (non-notched). The user described the previous
    /// "anchored at visibleFrame.maxY" placement as floating BELOW the
    /// menu bar with a visible gap — "it should be in the dynamic
    /// island." This restores the canonical Alcove / Dynamic Island
    /// silhouette: the pill's upper `notchOverlap` points are hidden
    /// behind the notch hardware (or the menu-bar strip on non-notched),
    /// and only the lower bump is visible, fused against the notch's
    /// bottom edge.
    ///
    /// The earlier non-notched-display gap bug came from leaving
    /// `state.topInset = 0` while still pushing the WINDOW above the
    /// menu bar — the SwiftUI pill drew at the window's top, which on a
    /// non-notched Mac was at screen.frame.maxY, well above the menu-bar
    /// bottom. The fix is symmetric: the window goes above the bar AND
    /// the SwiftUI content gets pushed down by exactly the menu-bar /
    /// notch height, computed identically for both display types via
    /// `safeAreaInsets.top` (notched) or `frame.maxY - visibleFrame.maxY`
    /// (non-notched). Both paths produce a flush bottom-of-notch landing.
    private func positionAtNotch() {
        // 2026-05-24 multi-monitor fix — prefer the notched display
        // unconditionally. NSScreen.main returns the screen with the
        // ACTIVE menu bar, which on a multi-display setup can be
        // either the MacBook or the external (user-configurable in
        // System Settings → Displays → arrange). If the user has
        // the external set as primary, NSScreen.main = external and
        // this HUD positions on the external monitor — appearing
        // as the "stuck overlay on external" the user reported on
        // 2026-05-24. The notch is physical hardware on exactly
        // ONE display (the MacBook built-in); position the HUD
        // there regardless of which display is "primary" in the
        // OS sense. Fall through to NSScreen.main only when no
        // notched display exists (clamshell, external-only).
        let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 })
            ?? NSScreen.main
        let frame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let visible = screen?.visibleFrame ?? frame

        // Hidden-overlap = how much of the panel sits BEHIND the notch
        // hardware / menu-bar strip. Notched Mac → safeAreaInsets.top
        // exactly equals the notch height; non-notched → fall back to
        // frame.maxY - visibleFrame.maxY (the menu-bar strip height).
        let notchOverlap: CGFloat
        if let s = screen, s.safeAreaInsets.top > 0 {
            notchOverlap = s.safeAreaInsets.top
        } else {
            notchOverlap = max(0, frame.maxY - visible.maxY)
        }

        let size = NSSize(
            width: NotchHUDWindowController.windowWidth,
            height: NotchHUDWindowController.windowHeight
        )
        let x = frame.midX - size.width / 2
        // Window TOP at SCREEN TOP (frame.maxY). The upper `notchOverlap`
        // pixels are hidden behind the notch / menu bar; the visible
        // pill silhouette emerges out of the bottom of that zone.
        let y = frame.maxY - size.height
        panel.setContentSize(size)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        // Push SwiftUI content down by notchOverlap so the visible pill
        // starts exactly at the menu-bar / notch bottom edge.
        state.topInset = notchOverlap
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
            topInset: state.topInset,
            onCommand: onCommand
        )
    }
}
