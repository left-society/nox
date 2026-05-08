import AppKit
import Combine
import SwiftUI

/// NSHostingView subclass that accepts the FIRST mouse click before
/// the panel becomes key. The panel is `.nonactivatingPanel` so it
/// doesn't auto-activate on click — the default macOS behavior is
/// "first click activates, second click delivers the action," which
/// means a single drag gesture on the SwiftUI progress bar gets
/// eaten as the activation event and never reaches SwiftUI.
///
/// Returning true from `acceptsFirstMouse(for:)` lets every click
/// and drag flow straight through to the SwiftUI gesture
/// recognizers below — the bar becomes draggable on first contact,
/// no second-click required.
///
/// User reported "the audio progress bar it's still not interactive
/// i cant move it" — earlier fix on PanelDropContainer wasn't
/// enough because hit-testing lands on this hosting view (the
/// deeper subview), not the wrapper.
private final class ClickThroughHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// AppKit's default behavior is to clamp window frames to the
    /// visible screen area (`visibleFrame`, which EXCLUDES the menu
    /// bar). Our entire "emerge from the notch" trick depends on the
    /// panel's TOP edge sitting at the literal `screen.frame.maxY` —
    /// i.e. ABOVE the menu bar, with the upper portion of the panel
    /// hidden BEHIND the notch hardware and menu strip. Without this
    /// override, AppKit silently snaps the y-origin we set in
    /// `closedPillFrame` / `openSlabFrame` back down by
    /// `safeAreaInsets.top` (~37pt), and the panel renders as a
    /// floating block in the middle of the screen instead of bleeding
    /// out of the notch.
    ///
    /// Returning the rect unchanged hands frame ownership entirely to
    /// us — the cost is that we're responsible for keeping the panel
    /// somewhere reasonable on screen, which we already do via
    /// `closedPillFrame(for:)` and `openSlabFrame(for:)`. This matters
    /// during the morph too: `panel.animator().setFrame(...)` calls
    /// inside `animateOpen` / `animateClose` would otherwise be
    /// clamped per-frame, breaking the smooth bloom.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        return frameRect
    }

    /// Trackpad two-finger swipe handler. Hooked up by
    /// PanelWindowController so the resting music pill responds to
    /// Alcove-style swipes:
    ///
    ///   • horizontal swipe (left)  → next track
    ///   • horizontal swipe (right) → previous track
    ///   • vertical swipe (up)      → expand the panel into the slab
    ///   • vertical swipe (down)    → close, with rubber-band feedback
    ///                                 (visible drag, springs back if
    ///                                 not committed past threshold)
    ///
    /// AppKit forwards trackpad scrolls to the focused window; this
    /// override hands the event to the controller's gesture state
    /// machine and consumes it (no super call) so the panel doesn't
    /// also try to scroll its content.
    var onScrollWheel: ((NSEvent) -> Bool)?
    override func scrollWheel(with event: NSEvent) {
        if onScrollWheel?(event) == true { return }
        super.scrollWheel(with: event)
    }
}

@MainActor
final class PanelWindowController {
    /// Outer NSPanel frame — much larger than the visible rounded
    /// content. The extra `haloPadding` on the left, top, and bottom is
    /// where we paint the depth halo: the same `.behindWindow` blur as
    /// the inner panel, fading to clear at the outer edges. That smears
    /// content immediately next to the panel (matching Apple's music
    /// widget) instead of leaving sharp text right against a hard edge.
    /// Right side stays flush with the inner panel because the panel
    /// docks at the screen edge — there's nothing to halo into.
    ///
    /// First pass used 20pt of halo, which the user flagged as "not
    /// even close to soft" — the music widget reference has a wide
    /// cloudy halo extending 60-80pt past the widget. Pushed to 60pt
    /// here so the fade has real distance to play out.
    static let panelWidth: CGFloat = 730
    static let panelHeight: CGFloat = 730
    /// The visible rounded-glass slab the user sees. Anchored trailing
    /// inside the outer panel so the right edge stays at the same screen
    /// position as before; the halo wraps it on three sides.
    ///
    /// Width 530 / height 480: side-by-side comparison against Alcove's
    /// expanded slab showed ours noticeably narrower — Alcove's slab
    /// silhouette runs ~1.4× wider so the music card's transport row
    /// has room for shuffle/prev/play/next/AirPlay. 530 matches Alcove
    /// at the silhouette level; the music card's transport row stays
    /// the simpler 3-button cluster but now has comfortable breathing
    /// room around it. Image/video grids also get more horizontal
    /// space — the two-column layout no longer feels cramped.
    static let innerPanelWidth: CGFloat = 530
    static let innerPanelHeight: CGFloat = 480
    /// Music tab gets a much shorter slab — the Alcove-style layout
    /// (small artwork tile + title/artist + waveform → progress bar →
    /// transport row → source badge) packs into ~210pt of content,
    /// vs the ~410pt the heavier tabs (Notes, Images, Videos, Files)
    /// need for their grids and lists. Sizing the slab to the content
    /// is the user-visible reason: the previous fixed 480pt slab left
    /// a ~250pt empty band below the music HUD, which read as the
    /// content "spilling" or "not filling" — when really the slab
    /// just couldn't shrink. Per-tab heights make the black silhouette
    /// always wrap its content, no awkward empty space.
    ///
    /// 2026-05-04 bumped 290 → 360. The nowPlayingCard (artwork tile +
    /// 3-line text + ~12pt vertical padding) hits ~96pt, then progressBar
    /// (~30pt), then iosStyleTransportRow (~50pt with inline volume) +
    /// 36pt VStack spacing + padding = ~225pt of content. With the old
    /// 290pt slab and ~90pt of header chrome, available content height
    /// was only ~200pt — transport row was getting clipped at the
    /// bottom. 360pt restores comfortable headroom.
    static let innerPanelHeightMusic: CGFloat = 360

    /// Inner slab height for a given active tab. Single source of truth
    /// for the per-tab sizing — `openSlabFrame(for:tab:)` uses it on
    /// open, and `handleActiveTabChange(to:)` uses it to animate the
    /// resize when the user switches tabs while the panel is open.
    static func innerPanelHeight(for tab: PanelTab) -> CGFloat {
        switch tab {
        case .music: return innerPanelHeightMusic
        default: return innerPanelHeight
        }
    }
    /// Transparent margin baked into the NSPanel frame on left/right/bottom
    /// (top stays anchored to the menu bar). Gives SwiftUI's `.shadow`
    /// modifier room to bleed the soft drop-shadow halo OUTSIDE the visible
    /// silhouette without being clipped by the rectangular NSPanel boundary
    /// — without this padding the shadow simply doesn't render past the
    /// silhouette edge, and the panel reads as a pasted-on rectangle
    /// instead of a floating Alcove-style HUD.
    ///
    /// 50pt is enough headroom for a 30pt-radius gaussian shadow with
    /// ~20pt of slack to fade past visual perceptibility. Larger values
    /// would let us push the shadow softer, but the panel's transparent
    /// margin has to be at least this big in EVERY frame (closed pill,
    /// tease, slab) — going much further wastes pixels at the closed-pill
    /// end where the visible silhouette is only 200×14.
    static let haloPadding: CGFloat = 100
    /// Corner radius of the inner glass panel itself. Tuned through
    /// 20 → 28 → 34: the latest bump pushes us into squircle territory
    /// (radius/min-side ≈ 0.09 at 380pt width) so the bottom corners
    /// read as a smooth continuous curve instead of a clipped arc.
    /// This is the same proportion Apple uses on the Dynamic Island
    /// expanded card on iPhone — the visual cue users associate most
    /// strongly with "notch HUD" surfaces.
    static let innerCornerRadius: CGFloat = 34
    /// Closed-pill geometry. The morph is now driven entirely by
    /// `NSAnimationContext.runAnimationGroup` animating
    /// `panel.animator().setFrame(...)` between these two frames — pure
    /// Core Animation, GPU-driven. SwiftUI inside the panel is STATIC
    /// during the morph (no `.animation(value:)` on width/height/radius),
    /// so body re-evaluation cost during the bloom is zero. The visible
    /// silhouette change (wide-pill bottom curve → tall slab with subtle
    /// rounding) comes for free from SwiftUI re-clipping `Color.black`
    /// with a fixed-radius `UnevenRoundedRectangle` against the morphing
    /// NSHostingView bounds — no shape rebuild per frame, no path-data
    /// interpolation. This pattern is lifted from ComfyNotch's
    /// `ScrollOpening.swift` (open-source notch HUD), which we
    /// benchmarked against after the user said the previous SwiftUI-
    /// only morph was "not even close to smooth."
    /// Closed-pill width. **Locked at 259pt — pixel-measured Alcove
    /// parity, do not tweak without re-running the side-by-side
    /// screenshot test against `/Applications/Alcove.app`.** This value
    /// comes from a fresh PIL pixel measurement of Alcove's resting
    /// pill captured against a colored wallpaper: the dark silhouette
    /// is 518px = 259pt wide at its body, with rounded bottom corners
    /// curving in to ~229pt by the time it meets the menu-bar bottom
    /// edge. Wider than the M-series notch hardware (~190pt physical),
    /// so the pill paints OVER the menu bar on both sides of the notch
    /// — that horizontal extension is what reads as "the notch got
    /// bigger / there's a media widget integrated with the bar". The
    /// user iterated through 380 → 100 → 600 → 320 → 290 → 280 → 260 →
    /// 240 → 220 across many rounds of eyeballed A/B comparison before
    /// we measured pixels and discovered the right answer was 259.
    static let closedPillWidth: CGFloat = 278
    /// Visible bump height below the menu-bar bottom. **14pt** —
    /// matches `pillCornerRadius` so the entire bottom-corner
    /// curve happens BELOW the menu bar (fully visible against the
    /// desktop). Earlier values either hid the curve inside the
    /// menu-bar zone (bump 0-8pt) or made the silhouette feel
    /// oversized (bump 18pt, matching Alcove exactly). 14pt is
    /// the sweet spot: visible enough that the rounded shoulders
    /// read as a real curve, not so much that the pill encroaches
    /// on the desktop.
    static let closedPillBump: CGFloat = 0
    /// Bottom-corner radius for the closed pill silhouette. **8pt** —
    /// dropped from 14 to match the actual hardware notch's
    /// subtle corner curvature (~4-6pt).
    ///
    /// At our close-end frame (201pt × 32pt visual notch), 14pt
    /// bottom corners were taking ~43% of the silhouette's vertical
    /// height — the curves dominated the visual, making the
    /// silhouette read as a "compressed pill" rather than the
    /// mostly-rectangular notch shape. The user described this as
    /// "squizy when ending."
    ///
    /// 8pt corners take only 25% of the close-end height, leaving
    /// 50% as straight vertical body and 19% as the inverse-bow
    /// top — matches the actual notch's flat-bottomed character
    /// with subtle corner rounding. The resting music pill (44pt
    /// tall) also reads cleaner with 8pt corners since the curves
    /// fit fully within the 12pt visible halo without clipping.
    /// Slab uses `innerCornerRadius` (34pt); silhouette morphs
    /// 8 → 34 via `.smooth` interpolation.
    static let pillCornerRadius: CGFloat = 8
    /// Tease (hover-intent) geometry. When the cursor enters the notch
    /// hot zone, the panel grows from resting → tease pill to give
    /// immediate visual feedback. User direction 2026-05-05: "when I
    /// move my cursor there it should feel like I am working on the
    /// notch, not like it's coming from up."
    ///
    /// Previous 340×40 (340pt wide, 32 overlap + 40pt bump = 72pt
    /// total) was too big — read as "panel descending from above"
    /// rather than "notch reacting to cursor." 340 ≈ 1.7× the actual
    /// notch hardware width (~200pt), making it feel like a separate
    /// pill below the notch.
    ///
    /// Now 213×8 — fourth-pass tune calibrated to the FIRM TEASE
    /// state captured in Alcove's frame-by-frame recording.
    ///
    /// Alcove has multiple tease tiers measured across 1706 frames:
    ///   • IDLE         247-251 × 41-46 px (~185 × 33 pt total)
    ///   • LIGHT TEASE  252-269 × 44-50 px (cursor near hot zone)
    ///   • FIRM TEASE   270-319 × 65-74 px (cursor about to commit)
    ///   • EXPANDED     320-440 × varies
    ///   • OPEN         440-450 × 46-74
    ///
    /// FIRM TEASE peak (286 × 69 px ≈ 213 × 52 pt total) is the
    /// state the user wants to match — that's the "I see you, hold
    /// to commit" character with a clear sideways spread AND a
    /// visible drop. Deltas vs idle:
    ///   • Width:  185 → 213 pt = +28 pt (~+15% wider)
    ///   • Height: 33 → 52 pt total, visible portion ~ +8pt
    ///   Width-grow magnitude is ~3.5× the height-grow.
    ///
    /// Earlier 200×22 build was the OPPOSITE asymmetry: +15pt width
    /// vs +22pt visible bump, so the eye read it as height-dominant
    /// → "only moving down of the notch not the other sides." The
    /// fix is to flip the ratio: width grow > height grow.
    ///
    ///   • teasePillWidth = 213 → +28pt past hardware notch
    ///     (14pt visible spread on each side)
    ///   • teasePillBump = 8 → modest visible drop below menu bar
    static let teasePillWidth: CGFloat = 213
    static let teasePillBump: CGFloat = 8
    /// Track-change announcement banner — Alcove parity, measured
    /// from the user-supplied frame-by-frame screen recording in
    /// `~/Downloads/alcove/Alcove 2/` (frames 750–870). When a new
    /// track starts, the resting pill silhouette grows DOWN (and a
    /// touch wider) into a banner that drops a visible apron below
    /// the notch hardware. The apron carries the artwork tile +
    /// "♪ Title · Artist" single-line label + a tiny equalizer.
    /// Auto-dismisses after the SystemEvent timeout (3.5s);
    /// geometry returns to closedPillFrame.
    ///
    /// Width 285 → barely wider than the resting pill (closedPillWidth
    /// 278). Alcove's banner sits very close to the notch silhouette
    /// horizontally; the announcement reads as the pill flexing DOWN
    /// rather than EXPANDING SIDEWAYS. Earlier 360 was too wide and
    /// looked like a separate notification card.
    /// Bump 32 → enough vertical room below notchOverlap (~32-37pt)
    /// to host one 22pt-tall row of content with a few pt of breathing
    /// room top and bottom.
    // The track-change banner is the SAME WIDTH as the resting
    // music pill (closedPillWidth = 278) — Alcove's pill EXPANDS,
    // it doesn't become a separate wider banner. Earlier 290pt
    // was 12pt wider than resting; the pill visibly grew sideways
    // during the announcement, breaking the "same pill, just
    // dropped a bit" feel the user described. Matching
    // closedPillWidth keeps the artwork and equalizer locked at
    // their resting positions throughout the announcement; the
    // only change is the apron dropping below the menu bar.
    // Slight expansion past closedPillWidth (278) — user feedback
    // 2026-05-07: "it should be expanding the whole thing a bit".
    // 285 = ~7pt wider than the resting pill, enough to read as a
    // visible expansion without becoming a separate-looking banner.
    // Matches Alcove's measured width in frame 850.
    static let trackBannerWidth: CGFloat = 285
    static let trackBannerBump: CGFloat = 32

    /// Volume HUD banner geometry — Alcove parity (round 7).
    ///
    /// Direct side-by-side comparison with the user's Alcove
    /// reference shows Alcove's pill is much NARROWER (≈280pt
    /// visible silhouette) than my prior 380pt, and content sits
    /// in a slim, fully-visible strip below the menu bar.
    ///
    /// Round 7:
    ///   • width: 380 → 300 (matches Alcove's compact silhouette)
    ///   • bump:  14  → 16 (tiny extra to host the "Sound" text +
    ///                       speaker glyph + bar without line-
    ///                       height clipping)
    /// MEASURED FROM ALCOVE SCREENSHOT (round 9, 2026-05-07):
    /// Cropped the user's screenshot, scanned pixels in Swift,
    /// converted to logical points (÷2 retina). Pill width is
    /// ~398-413pt across the silhouette body; height is ~32pt
    /// (essentially flush with menu bar, no apron). Content is
    /// just SPEAKER + BAR — no "Sound" text label (I hallucinated
    /// that earlier, the user explicitly pointed it out wasn't
    /// there).
    static let volumeBannerWidth: CGFloat = 400
    static let volumeBannerBump:  CGFloat = 0
    private static let edgeGap: CGFloat = 10
    private static let topGap: CGFloat = 40
    /// True Alcove-style placement: the NSPanel's TOP edge sits AT the
    /// physical screen top (frame.maxY) — i.e. ABOVE the menu bar, so the
    /// upper portion of the panel is hidden BEHIND the notch hardware /
    /// menu bar. The visible silhouette therefore appears to grow OUT OF
    /// the notch, not slide down from below the menu bar. The hidden
    /// vertical span equals this `notchOverlap` value — see
    /// PanelRootView's matching content offset.
    static func notchOverlap(for screen: NSScreen?) -> CGFloat {
        guard let s = screen ?? NSScreen.main else { return 0 }
        // Notched Mac → safeAreaInsets.top covers both the notch height
        // and the menu-bar strip (they're the same height by design).
        if s.safeAreaInsets.top > 0 { return s.safeAreaInsets.top }
        // Non-notched display → fall back to the menu-bar strip height
        // so our content still clears the bar. visibleFrame excludes the
        // bar at the top; the difference at maxY is the bar's height.
        return max(0, s.frame.maxY - s.visibleFrame.maxY)
    }

    static func panelSize(for screen: NSScreen?) -> NSSize {
        let available = (screen ?? NSScreen.main)?.visibleFrame.height ?? 800
        return NSSize(width: panelWidth, height: min(panelHeight, available - topGap - 24))
    }

    /// How the panel was last opened. Drives the dismissal policy:
    /// click-opened panels stay until the user explicitly clicks
    /// outside (mirrors how the user described the behavior — "when
    /// I click to open it, it should stay until I click somewhere").
    /// Hover-opened panels close as soon as the cursor leaves the
    /// panel for more than the grace period — same UX as Alcove's
    /// notch HUD ("when I move my cursor from the thing it should
    /// just close automatically"). Stored on the controller so hide()
    /// can be called without knowing the open mode.
    enum OpenMode: Equatable {
        case click
        case hover
    }

    /// Inner-silhouette rect — the panel.frame minus the transparent
    /// haloPadding margin on left/right/bottom. Click-outside and
    /// hover-leave detection use THIS rect, not the raw panel.frame —
    /// otherwise clicks landing in the transparent halo (visually outside
    /// the panel) would be considered "inside" and the panel wouldn't
    /// dismiss when the user clicks just-past the visible edge.
    ///
    /// **Extended 4pt at the top** so cursor positions at the very
    /// top of the screen (y == frame.maxY, e.g. when the user pushes
    /// the cursor "into the notch") still register as inside. Without
    /// this, `CGRect.contains` is half-open at maxY and excludes the
    /// exact top edge — the user perceived this as "panel auto-closes
    /// when I move the cursor deep into the notch."
    var visibleSilhouetteFrame: NSRect {
        let halo = PanelWindowController.haloPadding
        let f = panel.frame
        return NSRect(
            x: f.minX + halo,
            y: f.minY + halo,
            width: f.width - 2 * halo,
            height: f.height - halo + 4
        )
    }

    private let panel: NSPanel
    /// Exposed (read-only) so AppDelegate can wire external observers
    /// into the panel's published state — specifically, NotchOrchestrator's
    /// now-playing stream → presenter.nowPlaying, and the orchestrator's
    /// `sendMediaCommand` → presenter.onMediaCommand. Keeping the field
    /// itself `let` (vs a public setter) means external code can subscribe
    /// to the existing presenter but can't swap it out from under us.
    let presenter: PanelPresenter
    private let environment: AppEnvironment
    private(set) var isVisible = false
    /// True between `tease()` and either `dismissTease()` or
    /// `promoteToShow()`. Distinct from `isVisible` because a teasing
    /// panel is on screen but in an intermediate "pre-open" state — no
    /// dismissal monitors armed, no auto-routing run yet, content tree
    /// not mounted. The HoverActivator drives this lifecycle in
    /// response to cursor entry into the notch hot zone, then promotes
    /// to a full open if the user dwells, or dismisses if they leave.
    private(set) var isTeasing = false
    private var openMode: OpenMode = .click
    private var clickOutsideMonitor: Any?
    private var keyMonitor: Any?
    private var globalKeyMonitor: Any?
    private var quickPasteMonitor: Any?
    private var hoverGlobalMonitor: Any?
    private var hoverLocalMonitor: Any?

    /// Local event monitor for trackpad scroll-wheel events. Without
    /// this, scrollWheel events delivered to a SwiftUI hosting view
    /// can be eaten by deeper hit-testing (Buttons, Sliders, GestureRecognizers)
    /// before they bubble up to KeyablePanel.scrollWheel — so swipes
    /// over the EDGES of the music card or near transport buttons
    /// would silently fail. The local monitor sees every event
    /// dispatched to the app BEFORE it goes through the responder
    /// chain, so we can pre-empt and route to handleTrackpadSwipe
    /// regardless of cursor position within the panel.
    private var swipeMonitor: Any?
    private var hoverHasEnteredPanel = false
    private var hoverLeaveWorkItem: DispatchWorkItem?
    /// Bumped every time `animateOpen` / `animateClose` start a new
    /// morph. NSAnimationContext can't be cancelled — once started, the
    /// completion handler chain runs to completion. This token lets us
    /// detect "I'm a stale completion handler from a morph that was
    /// superseded by a newer one" and skip our work. Without it, a
    /// fast close-then-open would see the close's recoil completion
    /// fire AFTER the new open started — and since the close's recoil
    /// calls `panel.animator().setFrame(pillFrame)`, it would drag the
    /// panel back to pill mid-bloom.
    private var animationGeneration: UInt64 = 0
    /// In-flight spring animator for the open morph. Held so a
    /// follow-up open/close can cancel it cleanly instead of letting
    /// two springs race each other on the same window frame.
    private var currentSpring: SpringFrameAnimator?
    /// Frame the in-flight spring is animating TOWARD. Used by
    /// rapid-fire callers (held volume key fires showVolumeBanner
    /// 30×/sec) to skip the cancel+restart loop when we're already
    /// heading to that frame. Without this, the spring never
    /// settles and the morph reads as jittery/laggy.
    private var currentSpringTarget: NSRect?
    /// Full-screen scrim that dims + blurs the desktop behind the
    /// slab when expanded. Lazy because the BackdropController
    /// constructor builds an NSWindow + NSVisualEffectView, which
    /// we don't need until the user actually expands the panel.
    private lazy var backdrop: BackdropController = BackdropController()
    /// `NSPasteboard.general.changeCount` captured at the last hide().
    /// Initialized to -1 so the very first show() always evaluates the
    /// clipboard. Updated on every hide() so we only re-route when
    /// the user has actually copied something new in between.
    private var lastSeenChangeCount: Int = -1

    /// Trackpad two-finger swipe gesture state (Alcove-style).
    /// Tracks accumulated horizontal/vertical deltas during a single
    /// continuous trackpad swipe (begin → changed* → ended). On
    /// `.ended`, the controller decides which action to commit
    /// based on the dominant axis and total magnitude.
    ///
    ///   • horizontal commit (|x| > 60pt)         → next/prev track
    ///   • vertical-up commit  (y < -50pt)        → expand to slab
    ///   • vertical-down commit (y > 70pt)        → close
    ///
    /// During a partial vertical-down swipe (rubber-band feedback),
    /// the panel translates downward by `swipeDeltaY × 0.4` so the
    /// user sees the pill react in real time. If they release before
    /// the threshold, the panel springs back; past it, the close
    /// fires.
    private var swipeAccumX: CGFloat = 0
    private var swipeAccumY: CGFloat = 0
    private var swipeActive: Bool = false
    private var swipeBaseFrame: NSRect = .zero
    /// Set true once the user crosses an axis-commit threshold, so
    /// fingers continuing past the threshold don't re-trigger the
    /// same command (single-shot per gesture). Also prevents accidental
    /// dual-axis fires from sloppy diagonal swipes.
    private var swipeCommittedAxis: SwipeAxis? = nil
    private enum SwipeAxis { case horizontal, vertical }
    /// Mirrors Alcove's `_hasTriggeredVerticalSwipeAction`. Set true
    /// once an in-gesture vertical swipe blows past the auto-close
    /// threshold and fires the close — keeps a continuing finger
    /// motion from re-triggering the same close, and gates resets so
    /// .ended doesn't double-commit. Cleared on .began / .ended /
    /// .cancelled.
    private var swipeAutoCommitted: Bool = false
    /// Subscription that listens for `presenter.activeTab` changes and
    /// resizes the panel to that tab's preferred slab height. Lives for
    /// the controller's lifetime — the panel itself is created once and
    /// reused across show/hide cycles, so a single subscription is
    /// enough; we don't tear it down on hide().
    private var activeTabSubscription: AnyCancellable?

    /// Strong reference to the active AirDropShareDelegate. Need to
    /// hold this past performAirDrop returning because NSSharingService
    /// only WEAKLY retains its delegate — without this, the delegate
    /// would deallocate before AirDrop's callbacks fire and the
    /// debounce / pill plumbing would silently never run. Replaced
    /// each time the user kicks off a new send.
    private var airDropDelegate: AirDropShareDelegate?

    weak var menuBarController: MenuBarController?

    init(environment: AppEnvironment) {
        self.environment = environment
        let presenter = PanelPresenter()
        self.presenter = presenter
        let size = PanelWindowController.panelSize(for: NSScreen.main)
        let contentRect = NSRect(origin: .zero, size: size)

        // .borderless instead of .titled: every notch-HUD reference
        // implementation that's been benchmarked smooth (ComfyNotch,
        // Alcove tear-downs) uses borderless for this exact morph. The
        // titled style mask carries hidden titlebar machinery — auto-
        // resize subviews, NSToolbar attachment points, traffic-light
        // hit-test stubs — that all has to be invalidated/relaid-out
        // every time the window frame changes. With panel.animator()
        // .setFrame firing per CADisplayLink tick during the morph,
        // that's per-frame work the GPU shouldn't have to wait on.
        // Borderless ditches all of it. We never showed a title or
        // traffic lights anyway (titleVisibility=.hidden + buttons
        // hidden), so this is pure cleanup.
        panel = KeyablePanel(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        panel.isFloatingPanel = true
        // .statusBar (25) — high enough to draw over normal app windows
        // and over the menu-bar zone (via the panel's geometry that
        // intentionally overlaps the menu-bar/notch area), but below the
        // .modalPanel level (8) ceiling that AppKit uses for active
        // drag-and-drop tracking. The previous .popUpMenu (101) was
        // ABOVE that ceiling — AppKit treats popUpMenu-level windows as
        // transient overlays (menus, popovers) and DOES NOT register
        // them as drag-and-drop destinations. That's why
        // `draggingEntered` was never firing on PanelDropContainer:
        // not because of our wiring, but because AppKit was skipping
        // the panel entirely during drag-session destination polling.
        panel.level = .statusBar
        // .stationary keeps the panel anchored in screen space during
        // three-finger swipes between Spaces and during Mission Control
        // — the panel is part of the system surface (like the menu bar
        // / notch / Dynamic Island), not part of any one Space's
        // window contents. .ignoresCycle keeps Cmd+` from focusing it.
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle
        ]
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isMovableByWindowBackground = false
        // System shadow is rectangular (matches NSPanel bounds), so it
        // would show as a hard rectangle around our rounded SwiftUI
        // content. We draw our own rounded shadows in PanelRootView's
        // .shadow modifiers instead.
        panel.hasShadow = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hidesOnDeactivate = false
        // Disable window-drag-from-background. NSPanel defaults to
        // letting the user drag the entire window by clicking
        // anywhere on a transparent area — and our background IS
        // transparent (we draw the silhouette ourselves). With this
        // ON, click+drag on the SwiftUI progress bar gets intercepted
        // as "drag the window", so the scrub gesture never fires.
        // User reported the bar wasn't draggable; this is the actual
        // root cause (acceptsFirstMouse was already correct).
        panel.isMovableByWindowBackground = false
        panel.isMovable = false

        // 2026-05-04: NotchSpaceManager attach REMOVED for the main
        // panel. Adding the panel to a custom SkyLight space at level
        // 400 was excluding the window from normal user-space drag
        // tracking — AppKit's drag session captures destination
        // windows in the user's current space, and a window living
        // in a custom system-level space simply isn't enumerated.
        // Result: `draggingEntered` never fired on PanelDropContainer
        // regardless of panel.level (we tried .popUpMenu, .statusBar,
        // both produced zero "🟢 draggingEntered" entries in the
        // dlog at /tmp/notetaker-dictation.log).
        //
        // Lock-screen visibility for the now-playing pill is not
        // affected — that lives on the dedicated `LockMusicCardWindow`
        // (constructed in AppDelegate after this controller), which
        // does its OWN `NotchSpaceManager.attach`. The main panel
        // doesn't need lock-screen visibility; it's the music card
        // that carries that contract.

        // Inject each store as its own environment object so SwiftUI
        // only re-renders views that actually depend on the store
        // that mutated. (Used to inject just `environment` and
        // forward all child changes through it, which made a yt-dlp
        // progress tick re-evaluate every view in the panel.)
        let host = ClickThroughHostingView(
            rootView: PanelRootView()
                .environmentObject(environment)
                .environmentObject(environment.noteStore)
                .environmentObject(environment.imageStore)
                .environmentObject(environment.videoStore)
                .environmentObject(environment.fileStore)
                .environmentObject(environment.linkPreviewService)
                .environmentObject(environment.bluetoothDeviceService)
                .environmentObject(presenter)
        )
        host.frame = contentRect
        host.autoresizingMask = [.width, .height]
        // CRITICAL — disable NSHostingView's intrinsic-content-size
        // sizing on macOS 13+. The default sizingOptions
        // ([.minSize, .intrinsicContentSize, .maxSize]) installs
        // Auto Layout constraints based on what the SwiftUI tree
        // *wants* to be on its first layout pass — typically the
        // pill's tiny resting size (~220×20). When `enterRestingMode`
        // calls `panel.animator().setFrame(closedPillFrame, ...)`
        // for 278×32 on first launch, AppKit's Auto Layout pass
        // wins for one render and the host view shrinks to the
        // intrinsic SwiftUI size — user reported as "small music
        // pill looks shrunken on first launch, becomes stable after
        // opening the slab once." Clearing sizingOptions makes the
        // panel.frame the single source of truth: host fills the
        // contentView verbatim, no first-render shrink.
        if #available(macOS 13.0, *) {
            host.sizingOptions = []
        }

        // Wrap the SwiftUI host in an NSView that handles drag-destination
        // routing at the contentView level. This bypasses SwiftUI's
        // hit-testing entirely, so drops land regardless of which tab is
        // active or whether a child SwiftUI view registered the drag types.
        let container = PanelDropContainer(
            hosting: host,
            onVideo: { [weak presenter, weak environment] candidate in
                guard let presenter, let environment else { return }
                switch candidate {
                case .localFile(let url):
                    _ = try? environment.videoStore.saveLocalFile(url)
                case .remoteURL(let s):
                    _ = environment.videoStore.startDownload(url: s)
                }
                presenter.activeTab = .videos
            },
            onImage: { [weak presenter, weak environment] data, mime in
                guard let presenter, let environment else { return }
                // Deferred save — drops a placeholder into the grid
                // immediately, finalizes file + thumbnail off the main
                // actor. A 10MB browser-drag TIFF used to freeze the
                // panel for ~500ms; now the user sees the cell appear
                // instantly with a spinner that fades on completion.
                environment.imageStore.saveImageDeferred(
                    data: data,
                    mimeType: mime,
                    noteId: nil,
                    source: "drop"
                )
                presenter.activeTab = .images
            },
            onFile: { [weak presenter, weak environment] urls in
                guard let presenter, let environment else { return }
                environment.fileStore.stage(urls: urls)
                presenter.activeTab = .files
                HapticFeedback.levelChange()
            },
            onTargeted: { [weak presenter, weak self] flag in
                NSLog("🎯 onTargeted(\(flag)) isShown=\(presenter?.isShown ?? false) isVisible=\(self?.isVisible ?? false)")
                presenter?.isDropTargeted = flag
                // Drive the two-zone Save/AirDrop drop picker
                // overlay. The DropPickerView in PanelRootView is
                // gated on `dropPickerActive && isShown`. Without
                // this assignment the picker stays hidden and the
                // user just sees the accent ring with no Save vs
                // AirDrop choice — exactly the bug user reported.
                presenter?.dropPickerActive = flag
                // Auto-expand the slab when a drag enters while the
                // panel ISN'T currently showing the slab. Two cases
                // need to expand:
                //   • Panel fully hidden (no music) → orderFront +
                //     animateOpen
                //   • Panel at resting pill (music playing) →
                //     show() animates pill → slab so the drop
                //     picker (gated on `isShown == true`) renders
                // Earlier this only checked `!self.isVisible` which
                // missed the music-resting case — drag with music
                // playing showed no picker.
                if flag, let self, let presenter, !presenter.isShown {
                    presenter.activeTab = .files
                    self.show(mode: .hover)
                }
                // **Drop-freeze fix.** During a system drag-drop
                // session, the cursor's events are delivered through
                // NSDraggingDestination — NOT through the local/global
                // NSEvent.mouseMoved monitors that drive
                // hoverHasEnteredPanel. So the panel auto-expands on
                // drag-enter but `hoverHasEnteredPanel` stays false for
                // the whole drag. After the drag ends and the cursor
                // moves elsewhere, the hover-leave global monitor
                // short-circuits on `guard hoverHasEnteredPanel else {
                // return }`, hide() never schedules, and the panel
                // sits frozen with the picker overlay on screen.
                //
                // Treating drag-enter as an explicit panel-entry plugs
                // the gap: the eventual cursor-out then runs through
                // the normal hover-leave path and dismisses the panel
                // cleanly. Only flips on `flag == true` so a spurious
                // exit-debounce commit can't accidentally arm leave-
                // dismissal mid-drag.
                if flag, let self {
                    self.hoverHasEnteredPanel = true
                }
            },
            onZoneHover: { [weak presenter] zone in
                presenter?.dropPickerHoveredZone = zone
            },
            onAirDrop: { [weak self] urls in
                self?.performAirDrop(urls: urls)
            },
            onFileCount: { [weak presenter] count in
                presenter?.dropPickerFileCount = count
            }
        )
        container.frame = contentRect
        container.autoresizingMask = [.width, .height]

        panel.contentView = container

        // Trackpad two-finger swipe — TWO routes into the handler:
        //
        //   1) KeyablePanel.scrollWheel → fires when the panel is
        //      keyboard-active (rare for a non-activating panel)
        //      and AppKit naturally bubbles the scrollWheel event
        //      up the responder chain to the panel.
        //
        //   2) NSEvent.addLocalMonitorForEvents → catches the event
        //      BEFORE it goes to the responder chain, so SwiftUI
        //      buttons / hosting views can't eat it. Required for
        //      gestures over the edges and over interactive controls
        //      (transport buttons, etc.) — without this, swiping
        //      over a button silently failed because Button's hit
        //      testing consumed the event.
        //
        // Both routes funnel into handleTrackpadSwipe, which is
        // idempotent — only one will actually dispatch each event
        // because the local monitor runs first and consumes (returns
        // nil) when it dispatches.
        if let keyable = panel as? KeyablePanel {
            keyable.onScrollWheel = { [weak self] event in
                guard let self else { return false }
                return self.handleTrackpadSwipe(event)
            }
        }
        swipeMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.scrollWheel]
        ) { [weak self] event in
            guard let self else { return event }
            // Only intercept events targeted at OUR panel. Other
            // app windows (Settings, popout note window, etc.)
            // should keep their normal scroll behavior.
            guard event.window === self.panel else { return event }
            // Route to gesture handler; if it consumed (returned
            // true), swallow the event by returning nil. Otherwise
            // pass through so SwiftUI ScrollViews etc. work normally.
            if self.handleTrackpadSwipe(event) {
                return nil
            }
            return event
        }

        // 2026-05-04 GPU-accelerated shadow via CALayer.shadowPath.
        // Replaces the SwiftUI .shadow() modifiers in PanelRootView,
        // which were doing CPU-side gaussian convolution every frame
        // because SwiftUI couldn't tell Core Animation what shape
        // was being shadowed (the silhouette is custom Bezier).
        //
        // With shadowPath set, CA short-circuits the offscreen
        // alpha-analysis pass and renders the shadow directly on
        // the GPU as a single fill-with-blur operation. Documented
        // 50-80% performance gain. Confirmed by our diagnostic:
        // disabling SwiftUI .shadow() eliminated the 100ms+ frame
        // drops; this implementation keeps the shadow's lift but
        // moves the cost off the CPU.
        container.wantsLayer = true
        if let layer = container.layer {
            layer.masksToBounds = false  // critical: shadow extends beyond bounds
            layer.shadowColor = NSColor.black.cgColor
            layer.shadowOpacity = 0  // start hidden; flipped on by show/hide
            layer.shadowRadius = 24
            layer.shadowOffset = CGSize(width: 0, height: -14)
        }
        // Set initial shadowPath for the parked notch-hidden geometry.
        updateShadowPath()

        // Resize the slab when the user switches tabs while the panel
        // is open. The music tab gets a much shorter inner height than
        // the data-tab grids; without this hook, switching from .notes
        // to .music while open would leave a tall empty slab with the
        // compact music HUD floating at the top. `removeDuplicates`
        // protects against redundant body re-evals (SwiftUI fires the
        // publisher on every set, equal or not).
        activeTabSubscription = presenter.$activeTab
            .removeDuplicates()
            .sink { [weak self] newTab in
                self?.handleActiveTabChange(to: newTab)
            }

        // 2026-05-04 (user feedback: "the end point seems lower
        // in pt"): shadow opacity fade is now decoupled from the
        // isShown @Published flag. Earlier the Combine sink fired
        // updateShadowAppearance on every isShown change, which
        // ran the shadow opacity fade 0.55 → 0 in 200ms STARTING
        // at hide() entry. But the close spring takes 270-320ms,
        // so the last 70-120ms of the close had silhouette
        // visible WITHOUT its shadow halo. The user reads
        // (silhouette + shadow) as one visual boundary; without
        // shadow at the tail of close, the panel appeared to end
        // at a different (higher) point.
        //
        // New: this subscription only refreshes shadowPath when
        // silhouette character changes. Shadow opacity is set
        // manually at the right moments (open start, close
        // completion) so the shadow stays visible THROUGH the
        // entire close spring and fades only after the panel
        // actually arrives at notch-hidden.
        shadowStateSubscription = Publishers.CombineLatest4(
            presenter.$isShown,
            presenter.$isResting,
            presenter.$isAtNotchHidden,
            presenter.$nowPlaying
        )
        .sink { [weak self] _, _, _, _ in
            self?.updateShadowPath()
        }
    }

    private var shadowStateSubscription: AnyCancellable?

    /// Builds the silhouette CGPath in CALayer non-flipped coordinates
    /// (origin at bottom-left). The silhouette is the same shape
    /// rendered by `OutwardFlaredShape` in SwiftUI, but produced as a
    /// raw CGPath so CALayer can use it as `shadowPath` and skip the
    /// expensive alpha-analysis pass.
    ///
    /// Geometry mirrors `OutwardFlaredShape.path(in:)`:
    ///   • Inverse-bow shoulders at TOP (under the menu bar)
    ///   • Standard convex rounded corners at BOTTOM
    private static func silhouetteCGPath(
        in rect: CGRect,
        topFlareRadius: CGFloat,
        bottomCornerRadius: CGFloat
    ) -> CGPath {
        let path = CGMutablePath()
        let topR = max(0, min(topFlareRadius, rect.height / 2, rect.width / 2))
        let bottomR = max(0, min(bottomCornerRadius,
                                 rect.height - topR,
                                 max(0, rect.width / 2 - topR)))
        // CALayer non-flipped: y=0 at bottom, y=height at top
        let leftX = rect.minX
        let rightX = rect.maxX
        let topY = rect.maxY        // top edge in non-flipped
        let bottomY = rect.minY     // bottom edge in non-flipped
        let bodyLeftX = leftX + topR
        let bodyRightX = rightX - topR

        // Start at top-left rect corner (full width, at top edge)
        path.move(to: CGPoint(x: leftX, y: topY))

        // Top-left inverse-bow shoulder — quadratic curve down and in
        path.addQuadCurve(
            to: CGPoint(x: bodyLeftX, y: topY - topR),
            control: CGPoint(x: bodyLeftX, y: topY)
        )

        // Left body — vertical line down to bottom-left arc start
        path.addLine(to: CGPoint(x: bodyLeftX, y: bottomY + bottomR))

        // Bottom-left rounded corner (180° → 270° in non-flipped)
        path.addArc(
            center: CGPoint(x: bodyLeftX + bottomR, y: bottomY + bottomR),
            radius: bottomR,
            startAngle: .pi,
            endAngle: 3 * .pi / 2,
            clockwise: false
        )

        // Bottom edge
        path.addLine(to: CGPoint(x: bodyRightX - bottomR, y: bottomY))

        // Bottom-right rounded corner (270° → 0°)
        path.addArc(
            center: CGPoint(x: bodyRightX - bottomR, y: bottomY + bottomR),
            radius: bottomR,
            startAngle: 3 * .pi / 2,
            endAngle: 0,
            clockwise: false
        )

        // Right body — vertical line up to inverse-bow start
        path.addLine(to: CGPoint(x: bodyRightX, y: topY - topR))

        // Top-right inverse-bow shoulder — quadratic curve up and out
        path.addQuadCurve(
            to: CGPoint(x: rightX, y: topY),
            control: CGPoint(x: bodyRightX, y: topY)
        )

        path.closeSubpath()
        return path
    }

    /// The silhouette occupies a sub-region of the contentView: full
    /// width minus haloPadding on left/right, full height minus
    /// haloPadding on bottom (no top halo because the silhouette
    /// extends up into the menu-bar zone).
    private func currentSilhouetteRect() -> CGRect {
        guard let bounds = panel.contentView?.bounds else { return .zero }
        let halo = PanelWindowController.haloPadding
        return CGRect(
            x: halo,
            y: halo,                              // bottom halo (non-flipped: y=halo from bottom)
            width: bounds.width - 2 * halo,
            height: bounds.height - halo          // top of silhouette extends to bounds.height
        )
    }

    /// Compute current top-flare and bottom-corner radii based on
    /// presenter state. Mirrors the logic in PanelRootView's
    /// `panelTopRadius` / `panelBottomRadius` computed properties so
    /// the shadow silhouette matches the rendered silhouette.
    private func currentSilhouetteRadii() -> (topFlare: CGFloat, bottomCorner: CGFloat) {
        if presenter.isAtNotchHidden {
            return (0, 4)
        }
        if presenter.isShown {
            // Slab character
            return (22, PanelWindowController.innerCornerRadius)
        }
        if presenter.nowPlaying != nil {
            // Music pill character
            return (12, PanelWindowController.pillCornerRadius)
        }
        // Empty resting state
        return (0, 6)
    }

    /// Rebuild and apply the shadow path for the current silhouette
    /// geometry. Wrapped in a CATransaction with disabled actions so
    /// CA doesn't fire an implicit animation on shadowPath assignment
    /// (we drive the morph ourselves at spring-tick rate).
    func updateShadowPath() {
        guard let layer = panel.contentView?.layer else { return }
        let rect = currentSilhouetteRect()
        let (topR, bottomR) = currentSilhouetteRadii()
        let path = Self.silhouetteCGPath(
            in: rect,
            topFlareRadius: topR,
            bottomCornerRadius: bottomR
        )
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.shadowPath = path
        CATransaction.commit()
    }

    /// Set shadow opacity to an explicit target with a short
    /// easeOut animation. Called at:
    ///   • show() / animateOpen start — fade in to 0.55
    ///   • animateClose spring completion — fade out to 0 ONLY
    ///     after the panel has actually arrived at notch-hidden,
    ///     so the close animation stays visually anchored by the
    ///     shadow throughout.
    private func setShadowOpacity(_ target: Float, duration: CFTimeInterval = 0.18) {
        guard let layer = panel.contentView?.layer else { return }
        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        layer.shadowOpacity = target
        CATransaction.commit()
    }

    func toggle() {
        if isVisible {
            hide()
        } else {
            applyDefaultTabIfNeeded()
            show()
        }
    }

    /// Honor Settings → General → Default tab. Reads the stored
    /// raw value once per open and routes the panel there. The
    /// special `last` case is a no-op (keeps the previous active
    /// tab), which is also the default. Other values force the
    /// matching tab — useful for users who always want to land
    /// on Notes regardless of last interaction.
    private func applyDefaultTabIfNeeded() {
        guard let raw = UserDefaults.standard.string(forKey: "defaultTabRaw"),
              raw != "last" else { return }
        switch raw {
        case "music": if presenter.nowPlaying != nil { presenter.activeTab = .music }
        case "notes": presenter.activeTab = .notes
        case "images": presenter.activeTab = .images
        case "videos": presenter.activeTab = .videos
        case "files": presenter.activeTab = .files
        default: break
        }
    }

    func showOnTab(_ tab: PanelTab) {
        presenter.activeTab = tab
        if !isVisible { show() }
    }

    // MARK: - Trackpad swipe gestures (Alcove parity research applied)
    //
    // RESEARCH (extracted from /Applications/Alcove.app/Contents/
    // MacOS/Alcove via strings + class-dump):
    //
    //   Alcove's gesture state machine has these flags:
    //     _gestureHorizontalProgress / _gestureVerticalProgress
    //     _hasPassedHorizontalSwipeThreshold
    //     _hasTriggeredVerticalSwipeAction
    //     _isCollapsingSwipe
    //     _startedHorizontalSwipe
    //     _shouldResetSwipes
    //     _cycleSwipeReadyOnRelease
    //
    //   Their settings expose 4 separate gesture modes:
    //     swipeToSkip      — horizontal → next/previous track
    //     swipeToDismiss   — vertical up → close
    //     swipeToToggle    — vertical down → play/pause toggle
    //     swipeToCycleActivity — horizontal-on-pill → swap widgets
    //
    //   Visual feedback during the gesture:
    //     • Progressive blur tied to gesture progress
    //       (`Alcove.ProgressiveBlurView`, `_progressiveBlur`)
    //     • Accent color tint (`useAccentColorOnGestures`)
    //     • Spring-physics return (`alignmentSpringDamping/Mass/
    //       Stiffness`)
    //     • Haptic at commit (`alignment` pattern, same we use)
    //
    //   Threshold pattern: separate SUCCESS and RESET thresholds.
    //   Once gesture progress exceeds SUCCESS, action commits on
    //   release. If gesture falls back below RESET, the gesture
    //   "untriggers" — prevents jitter when user wobbles around the
    //   threshold.
    //
    // PORTED TO NOX:
    //
    //   On the RESTING music pill:
    //     swipe LEFT  → next track       (.skip)
    //     swipe RIGHT → previous track
    //     swipe DOWN  → expand into slab
    //     swipe UP    → close (with progressive blur + rubber-band)
    //
    //   On the EXPANDED slab when activeTab == .music:
    //     swipe LEFT/RIGHT → next/previous
    //     swipe UP         → close (progressive blur + rubber-band)
    //     (other tabs: gestures pass through to allow content scroll)
    //
    //   During the up-swipe gesture, presenter.swipeProgress (0–1)
    //   tracks progress from at-rest to commit threshold. SwiftUI
    //   reads this and applies:
    //     • blur radius:   progress * 18px
    //     • scale:         1 − progress * 0.04 (anchor: top — looks
    //                      like the panel is tucking up into the
    //                      notch, not just shrinking from the center)
    //     • The panel.frame translates by progress * cap (rubber-band
    //       at AppKit level)
    //
    //   Sign convention: gesture-phase events report fingers-up as
    //   POSITIVE deltaY consistently regardless of natural scrolling
    //   (gesture events use physical-finger semantics).
    private func handleTrackpadSwipe(_ event: NSEvent) -> Bool {
        let onRestingPill = presenter.isResting && !presenter.isShown
        let onMusicSlab   = presenter.isShown && presenter.activeTab == .music
        guard onRestingPill || onMusicSlab else { return false }

        guard event.hasPreciseScrollingDeltas,
              event.phase != []
        else { return false }

        // Alcove-style thresholds. Vertical "success" (commit) and
        // "reset" (un-trigger) at separate distances. Horizontal
        // single-shot at one threshold (track changes feel snappier
        // as instant fires than progressive).
        let H_THRESHOLD: CGFloat = 55                        // horizontal commit
        let V_SUCCESS:   CGFloat = onMusicSlab ? 130 : 80    // up-swipe commit (release-fires)
        let V_AUTO:      CGFloat = V_SUCCESS * 1.55          // up-swipe AUTO-fires mid-gesture
        let V_RESET:     CGFloat = onMusicSlab ? 30  : 18    // un-trigger (currently visual only)
        let V_DOWN:      CGFloat = 60                        // pill expand commit
        let V_CAP:       CGFloat = onMusicSlab ? 70  : 26    // rubber-band travel cap

        switch event.phase {
        case .began:
            swipeAccumX = 0
            swipeAccumY = 0
            swipeActive = true
            swipeBaseFrame = panel.frame
            swipeCommittedAxis = nil
            swipeAutoCommitted = false
            presenter.swipeProgress = 0

        case .changed:
            guard swipeActive else { return false }
            swipeAccumX += event.scrollingDeltaX
            swipeAccumY += event.scrollingDeltaY

            // HORIZONTAL — track progress for live button feedback,
            // commit at threshold (single-shot per gesture).
            if swipeCommittedAxis == nil {
                let isHorizontalDominant =
                    abs(swipeAccumX) > abs(swipeAccumY) * 1.5
                if isHorizontalDominant {
                    // Update signed horizontal progress (-1 to +1).
                    // -1 = full left swipe (next), +1 = full right
                    // swipe (previous). MusicPanelView's transport
                    // buttons read this and scale/glow accordingly.
                    let signedProgress = max(-1.0, min(1.0,
                        Double(swipeAccumX / H_THRESHOLD)))
                    presenter.swipeHorizontalProgress = signedProgress

                    if abs(swipeAccumX) > H_THRESHOLD {
                        swipeCommittedAxis = .horizontal
                        presenter.onMediaCommand?(
                            swipeAccumX < 0 ? .next : .previous
                        )
                        HapticFeedback.alignment()
                        // Bug fix: when the gesture started slightly
                        // diagonal, the vertical block in earlier
                        // ticks may have written a non-zero
                        // swipeProgress before the horizontal lock
                        // engaged. Without this reset, the blur from
                        // those ticks STICKS — once horizontal
                        // commits, the vertical block is skipped, the
                        // .ended branch then skips the reset (because
                        // swipeCommittedAxis != nil), and the panel
                        // is left blurred. Reset all gesture signals
                        // here. swipeOffsetY too — its
                        // .interactiveSpring will gracefully spring
                        // back to 0 visually.
                        presenter.swipeProgress = 0
                        presenter.swipeOffsetY = 0
                        // Frame snap back so the panel doesn't carry
                        // any rubber-band offset into the next state.
                        panel.setFrame(swipeBaseFrame, display: false)
                        // Brief settle — let the button's animation
                        // finish, then reset so a follow-up gesture
                        // doesn't see stale progress.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) {
                            [weak presenter] in
                            presenter?.swipeHorizontalProgress = 0
                        }
                    }
                } else if presenter.swipeHorizontalProgress != 0 {
                    // Vertical gesture started after a brief
                    // horizontal nudge — clear stale h-progress.
                    presenter.swipeHorizontalProgress = 0
                }
            }

            // VERTICAL — progressive close gesture (Alcove's
            // progressiveBlur + alignmentSpring model). Two
            // presenter signals carry the gesture state:
            //
            //   swipeProgress  0 → 1 — drives blur + scale-down
            //                          on the content
            //   swipeOffsetY   0 → V_CAP pt — drives a SwiftUI
            //                          .offset(y:) on the content,
            //                          smoothed with .interactiveSpring
            //                          for proper elastic feel
            //
            // The panel's NSWindow frame DOES NOT move during the
            // gesture anymore (was doing a linear setFrame translate
            // before — that's what felt non-springy). All gesture
            // motion is SwiftUI-driven so SwiftUI's spring physics
            // handle the elastic response, the release-spring, and
            // the ease-out tail in one continuous integration.
            //
            // On commit, the panel's frame is shifted UP by the
            // current offset (transferring the visual position into
            // the actual frame), then swipeOffsetY is reset and
            // hide() animates panel.frame the rest of the way to
            // closed — so the tucking motion flows smoothly into
            // the close animation with no snap.
            if swipeCommittedAxis != .horizontal && !swipeAutoCommitted {
                let upDist = max(0, swipeAccumY)
                let progress = min(1.0, Double(upDist / V_SUCCESS))
                presenter.swipeProgress = progress

                if upDist > 0 {
                    // Damped offset (0.45× input, capped). SwiftUI's
                    // .interactiveSpring on swipeOffsetY adds the
                    // elastic spring lag automatically — what we
                    // write here is the TARGET, the spring tracks it.
                    let offset = min(upDist * 0.45, V_CAP)
                    presenter.swipeOffsetY = offset
                } else {
                    presenter.swipeOffsetY = 0
                }

                // ── Mid-gesture AUTO-CLOSE (Alcove's
                // `_hasTriggeredVerticalSwipeAction` pattern).
                // If the user keeps swiping past V_SUCCESS without
                // releasing, fire the close as soon as accumulated
                // distance crosses V_AUTO. They don't need to lift
                // fingers — the panel closes the moment they
                // "swipe a little too much," matching Alcove's UX.
                //
                // swipeAutoCommitted gates this so a continuing
                // finger motion can't re-trigger after fire (and so
                // .ended below won't double-commit).
                if upDist > V_AUTO {
                    swipeAutoCommitted = true
                    swipeCommittedAxis = .vertical
                    HapticFeedback.alignment()
                    commitSwipeClose()
                    return true
                }
            }

        case .ended:
            guard swipeActive else { return false }
            swipeActive = false

            if swipeCommittedAxis == nil {
                if swipeAccumY > V_SUCCESS {
                    // Release past success threshold — commit close.
                    swipeCommittedAxis = .vertical
                    HapticFeedback.alignment()
                    commitSwipeClose()
                    swipeCommittedAxis = nil
                    return true
                } else if onRestingPill, swipeAccumY < -V_DOWN {
                    // Down-swipe on resting pill — expand to slab.
                    // Same snap-without-animation pattern so the
                    // pill doesn't spring back while the slab is
                    // already animating open.
                    swipeCommittedAxis = .vertical
                    HapticFeedback.alignment()
                    panel.setFrame(swipeBaseFrame, display: false)
                    var txn = Transaction()
                    txn.disablesAnimations = true
                    withTransaction(txn) {
                        presenter.swipeOffsetY = 0
                        presenter.swipeProgress = 0
                        presenter.swipeHorizontalProgress = 0
                    }
                    show(mode: .hover)
                    swipeCommittedAxis = nil
                    return true
                }
                // Else: below threshold — gesture cancels. SwiftUI's
                // .interactiveSpring naturally springs all three
                // values back to 0 when we set them below. WITH the
                // animation enabled (default), so we get the
                // release-spring + ease-out tail the user asked for.
            }
            // CANCEL path (gesture released below threshold, or any
            // axis other than commit): allow SwiftUI to spring back.
            // Default Transaction (animation enabled) lets
            // .interactiveSpring carry blur/scale/offset home with
            // its natural release-spring + ease-out tail.
            presenter.swipeProgress = 0
            presenter.swipeHorizontalProgress = 0
            presenter.swipeOffsetY = 0
            swipeCommittedAxis = nil
            swipeAutoCommitted = false

        case .cancelled:
            // System cancelled the gesture (Mission Control, Spaces
            // swipe, app switch). Snap the panel home + clear all
            // progress state so the next gesture starts clean.
            if swipeActive {
                panel.setFrame(swipeBaseFrame, display: false)
            }
            presenter.swipeProgress = 0
            presenter.swipeHorizontalProgress = 0
            presenter.swipeOffsetY = 0
            swipeActive = false
            swipeCommittedAxis = nil
            swipeAutoCommitted = false

        default:
            return false
        }

        return true
    }

    // MARK: - Close-swipe commit
    //
    // Shared by both auto-fire (mid-gesture, past V_AUTO) and
    // release-fire (.ended, past V_SUCCESS). Both close paths must
    // start the close FROM the current pinched visual state rather
    // than from full-open.
    //
    // BUG that drove this helper: earlier we Transaction-snapped
    // swipeProgress and swipeOffsetY to 0 SYNCHRONOUSLY before
    // calling hide(). That made the SwiftUI scale spring back from
    // ~0.93 (gesture-pinched) to 1.0 (full size) in one frame,
    // BEFORE hide()'s panel.frame animation began. The user saw it
    // exactly: "instade of closing from that position it's closing
    // from almost opening position" — for a single frame the pill
    // re-rendered at full open size, then the close animation
    // started from there.
    //
    // Fix: leave the gesture-pinched scale state in place during
    // the close. hide()'s panel.frame spring (158/25 ≈ 320ms for
    // notch-hidden close, 480/40 ≈ 440ms for music close) handles
    // the slab → pill morph; the silhouette stays at scale ~0.93
    // throughout, so panel.frame shrinking + scale-pinched together
    // read as ONE continuous shrink from the gesture position.
    //
    // After the close has visually completed (~0.55s, comfortably
    // beyond both spring durations), Transaction-snap the gesture
    // values to 0 so a subsequent open doesn't inherit stale state.
    // The pill is at resting size by then; the scale snap from
    // 0.93 → 1.0 changes the pill width by ~17pt and height by
    // ~1.5pt — sub-pixel for vertical, barely perceptible
    // horizontally, and lands in steady-state where there's no
    // adjacent motion to make it pop.
    //
    // Why we don't naturally spring scale → 1.0 during hide():
    // scale grows means silhouette extends DOWNWARD (anchor: .top);
    // panel.frame shrinking means silhouette's bottom rises UP.
    // Opposing motions on the bottom edge → "expanding back" feel.
    // Holding scale constant during the close avoids that conflict.
    private func commitSwipeClose() {
        // Horizontal progress doesn't affect the close visual; clear
        // it now so transport buttons stop showing swipe glow as
        // soon as the close fires.
        presenter.swipeHorizontalProgress = 0

        hide()

        // Defer the gesture-state reset until AFTER hide()'s visible
        // close animation lands, so the pill doesn't briefly render
        // at full open size before the close starts.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { [weak presenter] in
            guard let presenter else { return }
            var txn = Transaction()
            txn.disablesAnimations = true
            withTransaction(txn) {
                presenter.swipeProgress = 0
                presenter.swipeOffsetY = 0
            }
        }
    }

    func show(mode: OpenMode = .click) {
        // Clear any in-flight tease state — we're going to a full open
        // now, so the tease has served its purpose. If show() was called
        // from a non-tease entry point (click, hotkey), this is a no-op.
        // If we got here via tease promotion (HoverActivator dwell), the
        // existing `if !panel.isVisible` guard below correctly skips
        // the pillFrame snap so animateOpen blends smoothly from the
        // tease frame into the slab.
        isTeasing = false
        openMode = mode
        // Defensive reset of swipe progress signals at the start of
        // every show. Belt and suspenders alongside the matching
        // reset in hide() — guarantees the panel never opens with
        // stale blur, content offset, or button-glow state from a
        // previous gesture that ended unexpectedly.
        presenter.swipeProgress = 0
        presenter.swipeHorizontalProgress = 0
        presenter.swipeOffsetY = 0
        swipeActive = false
        swipeCommittedAxis = nil

        // Music-first auto-routing. When music is actively playing,
        // open the panel onto MusicPanelView regardless of what was
        // active last. The user described the desired behavior:
        // "When the music is opened, it will be very smooth because
        // we are only loading the music player, which is already
        // playing." MusicPanelView's first-paint cost is dominated
        // by one optional NSImage decode for the artwork — orders of
        // magnitude lighter than NotesListView (composer + LazyVStack
        // + onAppear hooks for link previews) or the image / video
        // grids (thumbnail decode + ScrollView content-size calc).
        //
        // We check this BEFORE the clipboard auto-routing so that if
        // a user copies text and music is also playing, music still
        // wins — the residual lag from a heavy first-paint dwarfs
        // the inconvenience of an extra tab tap to get to a freshly
        // captured note. Once on the panel the user can switch to
        // Notes manually, by which point the morph is settled and
        // the per-tab mount hitch is no longer visible inside the
        // open animation.
        // Auto-route to .music whenever there's a live now-playing
        // session — playing OR paused. The original gate required
        // isPlaying=true, which made the music page unreachable
        // through the open-the-panel flow whenever the user had
        // paused Spotify a second ago. The expanded music view is
        // still the most useful surface in that state (it's where
        // you'd hit Play to resume), so paused-but-loaded should
        // win for the same reasons playing does. The panel still
        // hides .music entirely when nowPlaying is nil — no risk
        // of routing to an empty page.
        //
        // Clipboard takes PRIORITY over music auto-route. User intent
        // expressed by a fresh copy ("I just grabbed this thing, take
        // me to where I can use it") trumps the ambient "music-is-
        // playing" default. Without this, copying text or a screenshot
        // while music plays would always land on Music — exactly the
        // friction reported: "when coping any text it should open the
        // note menu not the music. When coping any photo it should
        // open photo section not music."
        //
        // Order:
        //   1. If clipboard changed since last hide() → route to the
        //      tab matching its content type (text→notes, image→images,
        //      video URL→videos, files→files).
        //   2. Else if music is playing/paused → route to .music.
        //   3. Else leave activeTab as-is (last user choice persists).
        let currentCount = NSPasteboard.general.changeCount
        var routedFromClipboard = false
        if currentCount != lastSeenChangeCount {
            routedFromClipboard = applyAutoRouting()
            lastSeenChangeCount = currentCount
        }
        // Music fallback — only if the clipboard didn't route AND
        // there's an active now-playing session. So music wins when
        // there's nothing else to show; clipboard wins when the user
        // just expressed an intent.
        if !routedFromClipboard && presenter.nowPlaying != nil {
            presenter.activeTab = .music
        }

        // Use the screen the cursor is currently on for hover-mode
        // opens — on multi-display setups NSScreen.main is "the screen
        // with the key window," which can be a different display than
        // the one whose notch the user just hovered. For click-mode
        // opens (hotkey, menu bar) NSScreen.main is the right answer
        // (panel follows the focused app). The screen choice flows
        // through every frame calculation below, so resting-pill and
        // slab geometry both land on the right notch.
        let screen = (mode == .hover ? screenContainingCursor() : nil) ?? NSScreen.main
        let pillFrame = closedPillFrame(for: screen)
        let slabFrame = openSlabFrame(for: screen, tab: presenter.activeTab)

        // Position the panel at its starting geometry. Original
        // logic restored: snap only if panel was orderOut'd
        // (`!panel.isVisible`). User 2026-05-05: previous attempt
        // to FORCE the start frame caused "opening 2 times" feel —
        // the snap from current geometry to expectedStart, followed
        // by the open spring, read as TWO separate motions.
        //
        // Now that all closed-state radii are unified to notch
        // character (panelTopRadius=0 + panelBottomRadius=6, see
        // PanelRootView), the snap is unnecessary: the open
        // animation looks like notch silhouette growing into slab
        // regardless of whether the panel started at notch-hidden
        // (249×32), music-pill (302×44), or a transient-pill
        // geometry — because the SHAPE CHARACTER is identical at
        // every starting size, only the dimensions change.
        //
        // Velocity continuity is preserved: if a close is in
        // flight, animateOpen blends from the panel's current
        // moving frame to slab without a visible jump.
        panel.alphaValue = 1
        if !panel.isVisible {
            let hiddenStart = notchHiddenFrame(for: screen)
            panel.setFrame(hiddenStart, display: false)
        }
        // Deliberately NOT writing `presenter.isShown = false` here.
        // It's already false (hide() flips it before the close morph),
        // and @Published.publisher emits on EVERY set regardless of
        // equality — so a redundant assign here would force a SwiftUI
        // body re-evaluation immediately before the morph starts. Tiny
        // hitch, but exactly at the wrong moment: the panel is sitting
        // at pill geometry waiting for its dive frame, and we'd be
        // queuing layout work right as `animator().setFrame` is about
        // to fire.
        panel.orderFrontRegardless()
        // Deliberately NOT calling `panel.makeKey()` — that would steal
        // keyboard focus from whatever app the user was typing in.
        // The user reported "when [the panel] is opened i can't write any
        // message to any app" — that's `makeKey` redirecting all keystrokes
        // to us. The panel still becomes key when the user actively clicks
        // a text field inside it (NSPanel does this automatically because
        // `KeyablePanel.canBecomeKey` is true), so the search bar still
        // accepts input — it just doesn't grab focus the moment we appear.
        let screens = NSScreen.screens.map { "\($0.frame)" }.joined(separator: " | ")
        NSLog("nox: show() pill=\(pillFrame) slab=\(slabFrame) main=\(NSScreen.main?.frame ?? .zero) screens=\(screens)")

        isVisible = true

        // Flip `isShown` BEFORE the panel morph starts. PanelRootView's
        // content overlay is now ALWAYS-MOUNTED (see contentOverlay's
        // .opacity gate), so this assignment doesn't trigger any
        // SwiftUI mount work — it just kicks off the 0.18s opacity
        // fade-in of the already-laid-out content tree. That fade
        // runs in PARALLEL with the 450ms panel morph, so by the time
        // the panel reaches ~40% of its dive the content is already
        // fully visible. Net perception: panel and content arrive as
        // a single blooming surface, no perceptible hitch anywhere.
        //
        // This is a deliberate inversion of the previous strategy
        // (mount AFTER recoil): always-mount makes the SwiftUI cost
        // a one-time hit at app launch, so the show() path has nothing
        // to do but tick a published bool. Repeated open/close cycles
        // are now essentially free on the SwiftUI side.
        presenter.isShown = true
        // We're transitioning out of notch-hidden parking — clear the
        // flag so the silhouette uses slab radii (22 / innerCornerRadius)
        // during the open morph instead of the hardware-notch radii
        // (0 / 4). The shape's animatableData interpolates smoothly
        // between the two.
        presenter.isAtNotchHidden = false

        // Subtle haptic at the moment the morph begins — same idea
        // as Alcove (their bundle ships `HapticFeedback` symbols + a
        // `haptic.caf` sound file). `.alignment` is the firmest of
        // the three NSHapticFeedbackManager patterns; reads as a
        // single confident "click" through the trackpad. Silent on
        // non–Force Touch hardware. Auto-respects the user's
        // System Settings → Trackpad → Haptic feedback toggle.
        HapticFeedback.alignment()

        // 2026-05-04 setup-time instrumentation: log the wall time
        // from show() entry to animateOpen() being called. If this
        // is >5ms, there's main-thread blocking BEFORE the spring
        // even starts — would feel as "lag at the moment I clicked,"
        // distinct from per-frame stutter.
        let setupT0 = CACurrentMediaTime()
        // Start the pure-Core-Animation morph. NSAnimationContext drives
        // panel.animator().setFrame at the window-server level — GPU-
        // accelerated, no SwiftUI body re-evaluation per frame.
        animateOpen(to: slabFrame)
        let setupMs = (CACurrentMediaTime() - setupT0) * 1000
        if setupMs > 1.0 {
            DictationOrchestrator.dlog(
                "⏱ animateOpen() setup took \(String(format: "%.1f", setupMs))ms"
            )
        }

        // 2026-05-04 cascade reveal trigger. Tightened from 80ms
        // → 30ms after research confirmed the perceivable-lag
        // threshold. Per motion-to-photon latency studies, users
        // can detect delays as low as 17ms (JND) and reliably
        // notice 30-100ms. 80ms was squarely in the perceivable
        // range — that's why the user reported content "feeling
        // laggy" even though our spring detector showed zero
        // dropped frames. The lag was a *real perceived delay*
        // between panel arrival and content arrival.
        //
        // Now fires at 30ms — at the floor of perceivability,
        // small enough to feel "with the panel" but enough offset
        // that the cascade animation doesn't collide with the
        // steepest panel-growth frames. The GPU shadow fix
        // (CALayer.shadowPath) eliminated the per-frame budget
        // pressure that originally forced the longer 80ms gap.
        let cascadeGen = animationGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            guard let self, self.animationGeneration == cascadeGen else { return }
            self.presenter.cascadeReady = true
        }

        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self else { return }
            // Bail if the click landed inside our panel. The panel uses
            // `.nonactivatingPanel` so clicks on it don't activate our app;
            // because of that, those clicks ALSO fire this global monitor
            // (since the active app stays "elsewhere"). Without the frame
            // check, tapping a video cell or the dropped-image preview
            // would dismiss the panel before SwiftUI's onTap could run.
            // For global events, locationInWindow is in screen coordinates.
            if self.visibleSilhouetteFrame.contains(event.locationInWindow) {
                return
            }
            // Don't yank the panel away while a download is still running —
            // the user needs to see the progress bar to trust that the
            // hotkey actually worked. The jobs list auto-clears itself once
            // everything is in a terminal state, so this is self-resetting.
            let activeDownload = self.environment.videoStore.jobs
                .contains { !$0.state.isTerminal }
            if activeDownload {
                NSLog("nox: global mouse-down → keep panel up (download in flight)")
                return
            }
            NSLog("nox: global mouse-down → hide")
            self.hide()
        }

        // ⌘1–⌘9 quick paste — when the panel is key, intercept the
        // digit and copy the Nth visible item of the active tab to
        // the system clipboard. Local-only because the panel has to
        // actually be focused (i.e. the user clicked into it or is
        // interacting with it) for these to fire — we don't want
        // ⌘1 in another app to dispatch our quick paste.
        quickPasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            // Only ⌘ as the modifier — ⌃⌘N or ⌥⌘N should fall through
            // so we don't trample shortcuts the user expects elsewhere.
            let mods = event.modifierFlags.intersection([.command, .control, .option, .shift])
            guard mods == .command else { return event }
            let chars = event.charactersIgnoringModifiers ?? ""
            guard chars.count == 1,
                  let digit = chars.first?.wholeNumberValue,
                  (1...9).contains(digit) else { return event }
            if self.handleQuickPaste(index: digit - 1) {
                return nil
            }
            return event
        }

        // Two ESC monitors because the panel may or may not be key:
        // - Local fires when the panel IS key (user clicked the search
        //   field). It consumes the event so the field doesn't ding.
        // - Global fires when the panel is NOT key (user is typing in
        //   another app and just wants the overlay to go away). Global
        //   monitors can only observe — they can't consume — so the
        //   foreground app still sees ESC. That's intentional: ESC
        //   tends to be a benign "cancel" everywhere, so propagating
        //   it doesn't break anything but lets the panel dismiss
        //   from anywhere on screen.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                self?.hide()
                return nil
            }
            return event
        }
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                self?.hide()
            }
        }

        // Hover-mode dismissal: when opened by cursor-into-notch, the
        // panel should close as soon as the cursor leaves it (with a
        // short grace period for accidental side-trips). Click-opened
        // panels skip this entirely — they're sticky and dismiss only
        // on click-outside / ESC. Two monitors because cursor events
        // route differently inside vs outside our panel:
        //
        // - Local monitor fires when cursor is inside our panel →
        //   marks "has entered" + cancels any pending hide.
        // - Global monitor fires when cursor is in another app →
        //   if we've registered an entry, schedules a hide.
        //
        // The "has entered" flag prevents instant dismissal when a
        // user skims the cursor across the notch hot zone but doesn't
        // actually intend to interact (the bloom completes, then
        // dismisses 200ms later — annoying). Only after the cursor
        // lands inside the panel do we arm the leave-to-hide path.
        if mode == .hover {
            panel.acceptsMouseMovedEvents = true
            hoverHasEnteredPanel = false

            // Local monitor catches BOTH mouseMoved AND mouseDown — if
            // the user clicks a transport button without nudging the
            // cursor first, mouseMoved alone never fires and
            // hoverHasEnteredPanel stays false, which means the global
            // monitor's leave path can never arm. Including the click
            // event types ensures any meaningful interaction inside the
            // panel marks it as "entered."
            hoverLocalMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseDragged]
            ) { [weak self] event in
                guard let self, self.isVisible, self.openMode == .hover else { return event }
                self.hoverHasEnteredPanel = true
                self.hoverLeaveWorkItem?.cancel()
                self.hoverLeaveWorkItem = nil
                return event
            }

            hoverGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
                guard let self, self.isVisible, self.openMode == .hover else { return }
                // Frame check FIRST — if the cursor is still inside
                // our silhouette, never schedule a hide regardless
                // of whether we've registered an "entry" yet. The
                // open animation can complete with the cursor already
                // inside the slab without a new mouseMoved event
                // firing on the panel's local monitor (e.g. cursor
                // sat still during the dwell + open). Treating "inside
                // silhouette" as implicit entry plugs that gap.
                if self.visibleSilhouetteFrame.contains(NSEvent.mouseLocation) {
                    self.hoverHasEnteredPanel = true
                    self.hoverLeaveWorkItem?.cancel()
                    self.hoverLeaveWorkItem = nil
                    return
                }
                guard self.hoverHasEnteredPanel else { return }
                if self.hoverLeaveWorkItem != nil { return }
                // **Snappy dismissal** — user explicitly asked: "and
                // cursor left the black zoon it should close so it look
                // snapier." 60ms grace is short enough that the panel
                // closes essentially instantly when the cursor leaves
                // the silhouette, but not so short that a single
                // pixel-level cursor jitter at the boundary fires
                // dismissal mid-interaction. Earlier 250ms felt
                // sluggish ("when am I going to be free of this thing").
                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    // Final ground-truth check at fire time. Use a
                    // 6pt-tolerant rect so cursor jitter near the
                    // silhouette edge — or the cursor sitting at
                    // exactly y == frame.maxY (the deep-notch case) —
                    // doesn't false-trigger dismissal. Same boundary
                    // tolerance pattern used in HoverActivator.
                    let tolerant = self.visibleSilhouetteFrame.insetBy(dx: -6, dy: -6)
                    if tolerant.contains(NSEvent.mouseLocation) {
                        self.hoverLeaveWorkItem = nil
                        return
                    }
                    self.hide()
                }
                self.hoverLeaveWorkItem = work
                // Bump the dismissal grace from 60ms → 120ms so a
                // cursor briefly straying outside (e.g. when the user
                // tries to move into the notch and macOS warps the
                // cursor around the camera area) doesn't immediately
                // tear down. Still feels snappy; less prone to
                // false-dismissals on cursor warp / hand jitter.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
            }
        }
    }

    /// Immediately remove the notch panel from the window list with no
    /// animation. Used by the onboarding flow which lowers its window
    /// level to .normal so system permission dialogs render above it
    /// — without this orderOut, the panel at .popUpMenu (level 101)
    /// would still float over the onboarding window. Pair with
    /// `parkAtNotchHidden()` afterward to bring the panel back online.
    func orderOutImmediately() {
        currentSpring?.cancel()
        currentSpring = nil
        panel.alphaValue = 0
        panel.orderOut(nil)
        isVisible = false
        presenter.isShown = false
        isTeasing = false
    }

    func hide() {
        NSLog("nox: hide() called, isVisible=\(isVisible)")
        guard isVisible else { return }
        // Snapshot the clipboard so the next show() can tell whether
        // the user copied something new in between.
        lastSeenChangeCount = NSPasteboard.general.changeCount
        removeMonitors()
        // Defensive reset of all swipe-progress signals. If hide()
        // was triggered mid-gesture by something other than the
        // swipe handler (click-outside, hotkey, system event), the
        // gesture's .ended path may never fire and SwiftUI would
        // re-render with the stale blur next time we open. Clearing
        // here guarantees a clean state for the next show().
        presenter.swipeProgress = 0
        presenter.swipeHorizontalProgress = 0
        presenter.swipeOffsetY = 0
        swipeActive = false
        swipeCommittedAxis = nil
        // Flip `isShown=false` to start the 0.18s content fade-out
        // (PanelRootView gates the always-mounted content overlay's
        // opacity on this flag). The fade runs IN PARALLEL with the
        // ~350ms close morph, so content disappears smoothly as the
        // panel shrinks back into the notch — no abrupt content snap
        // mid-morph, no still-rendering subviews fighting the shrink.
        presenter.isShown = false
        // 2026-05-04: also flip cascadeReady=false so the cascade
        // animates OUT in parallel with the close morph (close was
        // already smooth without sequencing — opposite of open).
        presenter.cascadeReady = false
        // Backstop drop-picker state. The picker visibility gate is
        // `dropPickerActive && isShown` — once isShown flips false the
        // overlay hides anyway, but if a drag's exit-debounce ever got
        // canceled mid-cycle by a frame-morph re-enter, dropPickerActive
        // can stick true. Wiping the slot on every hide() guarantees
        // the next show() doesn't briefly render a stale picker before
        // a fresh drag arrives.
        presenter.dropPickerActive = false
        presenter.dropPickerHoveredZone = nil
        presenter.dropPickerFileCount = 0
        presenter.isDropTargeted = false
        isVisible = false

        // Music-aware close target.
        //
        // WITH music (presenter.isResting == true): close target is the
        //   pill frame. Two-stage CA dive + recoil lands the silhouette
        //   at the resting music-pill geometry where it stays as the
        //   always-on now-playing indicator.
        //
        // WITHOUT music: close target is the NOTCH-HIDDEN frame
        //   (height = notchOverlap, no halo bump → fully occluded by
        //   the hardware notch). The slab visibly retreats ALL THE WAY
        //   into the notch instead of landing at the pill silhouette
        //   first — closing the no-music panel to pill geometry was
        //   what made it "look like there's a music player" even
        //   though there wasn't. animateClose adapts its curve based
        //   on the target: dive+recoil for pill (visible landing
        //   beat), single ease-out shrink with alpha fade for the
        //   notch-hidden case (no recoil — there's nothing to land at).
        let screen = panel.screen ?? NSScreen.main
        let target = presenter.isResting
            ? closedPillFrame(for: screen)
            : notchHiddenFrame(for: screen)
        // Flip the silhouette mode BEFORE animateClose runs the spring
        // so SwiftUI's animatableData interpolates radii in lockstep
        // with the frame shrink:
        //   • No-music close: radii morph 22 → 0 (top) and
        //     innerCornerRadius → 4 (bottom) over the same ~680ms as
        //     the frame morph slab → 185×32. End state is a clean
        //     hardware-notch silhouette (sharp 90° top, subtle rounded
        //     bottom) merged invisibly with the actual notch cutout.
        //   • Music close: radii morph 22 → 6 and innerCornerRadius
        //     → 8 over ~230ms, frame slab → 278×32. End state is
        //     the music-pill silhouette with its characteristic
        //     inverse-bow shoulder + 8pt bottom flare.
        // Setting this in animateClose's completion handler instead
        // would cause radii to SNAP at the end, producing a visible
        // "second morph" pop after the frame settled. With this
        // ordering, frame and shape morph as ONE continuous motion.
        presenter.isAtNotchHidden = !presenter.isResting
        animateClose(to: target)
    }

    // MARK: - Hover-intent tease
    //
    // Two-stage hover gesture, matching what the user described from
    // Alcove / Elkhob: "When I'm going to the cursor into that thing,
    // it just moves a little bit; it doesn't open the whole thing.
    // When I'm placing the cursor for like 0.2 seconds or a little bit
    // longer, it opens." So:
    //
    // 1. Cursor enters notch hot zone → `tease()` orderFronts the panel
    //    at a slightly-larger-than-resting pill geometry. Subtle visual
    //    cue: "the notch noticed you." No content tree mounted, no
    //    dismissal monitors armed — this is a transient pre-bloom state.
    // 2. Cursor stays for HoverActivator's dwellSeconds → AppDelegate
    //    calls `show(mode: .hover)`, which transitions seamlessly from
    //    tease geometry to full slab via the existing animator-based
    //    morph (no setFrame snap, no orderFront re-do — see the
    //    `if !panel.isVisible` guard in show()).
    // 3. Cursor leaves before dwell → AppDelegate calls `dismissTease()`,
    //    which animates back to the closed-pill frame and orders out.

    /// Order the panel front at tease geometry. No-op if already
    /// teasing or if a full panel is open.
    ///
    /// In RESTING mode (panel already on screen at closed-pill frame
    /// because music is playing), we skip the orderFront / setFrame
    /// snap and just animate from the current frame to teaseFrame.
    /// That's how Alcove reads as "the pill noticed you" rather than
    /// "a new window appeared" — the persistent pill IS the same
    /// element that grows on hover.
    func tease() {
        if isTeasing { return }
        if isVisible { return }

        isTeasing = true

        // MUSIC-PILL HOVER REACTION (Alcove-inspired). User 2026-05-05:
        // "when you move the cursor closer it should react ... like
        // alcove does." Cursor proximity should give a subtle visual
        // cue that the pill noticed the user, while still requiring
        // dwell time before the full open fires.
        //
        // For music pill state, animate to a SLIGHTLY BIGGER pill
        // than the resting music pill (not smaller — that's the
        // squeeze user rejected). +14pt width and +6pt height bump
        // — barely perceptible growth but registers as "I see you,
        // hold the cursor for a moment."
        if presenter.isResting && presenter.nowPlaying != nil {
            let screen = screenContainingCursor() ?? NSScreen.main
            let frame = screen?.frame ?? .zero
            let overlap = PanelWindowController.notchOverlap(for: screen)
            let halo = PanelWindowController.haloPadding
            let visibleWidth = PanelWindowController.closedPillWidth + 14
            let visibleBump: CGFloat = 6
            let teaseFrameMusic = NSRect(
                x: frame.midX - (visibleWidth + 2 * halo) / 2,
                y: frame.maxY - (overlap + visibleBump + halo),
                width: visibleWidth + 2 * halo,
                height: overlap + visibleBump + halo
            )
            animateTease(to: teaseFrameMusic)
            return
        }

        // Tease is always cursor-driven (HoverActivator fires it on
        // notch entry), so resolve the cursor's screen rather than the
        // key-window screen — otherwise on multi-display the tease
        // would bloom from the wrong notch.
        let screen = screenContainingCursor() ?? NSScreen.main
        let teaseFrame = teasePillFrame(for: screen)

        // Decide the START frame for the tease spring:
        //   • In RESTING mode (music pill on screen) the panel is
        //     ALREADY at closedPillFrame. Skip setFrame — animateTease
        //     blends from current to teaseFrame for one continuous
        //     pill→tease motion.
        //   • If the panel is NOT visible at all (no music): start at
        //     notchHiddenFrame (matches the actual notch hardware
        //     dimensions). The spring grows from notch-shape → tease.
        //     Earlier we started at closedPillFrame here, which made
        //     the panel POP IN at music-pill geometry for one frame
        //     before the spring ran — the user described this as
        //     "jumping" instead of smooth. Starting at notchHidden
        //     means the silhouette is invisible at frame 0 (matches
        //     hardware notch black-on-black) and grows visibly into
        //     the tease pill via the spring.
        if !panel.isVisible {
            let hiddenStart = notchHiddenFrame(for: screen)
            panel.setFrame(hiddenStart, display: false)
            panel.alphaValue = 1
            panel.orderFrontRegardless()
        }
        // Content overlay must stay invisible — tease should NOT include
        // a flash of header/segmented content. PanelRootView's content
        // overlay is always-mounted now (one-time launch cost) and gated
        // on `presenter.isShown` via opacity; asserting false here keeps
        // the overlay at alpha 0 during the tease in case some path
        // left it true.
        presenter.isShown = false

        // 2026-05-06 (user feedback: "we give a touch effect when
        // there is a music pill — need the same effect in the
        // empty state too"): fade the GPU shadow in during empty-
        // state tease. Without this the silhouette grows from
        // hidden into the visible bump as a FLAT black ribbon
        // under the notch — no depth, doesn't read as a "touch
        // reaction." Music pill tease already has shadow at
        // opacity 0.40 (set by enterRestingMode) so its grow has
        // visible lift; matching that here for parity. 0.30 is a
        // subtle drop shadow — enough to give the empty pill
        // depth without making it feel like a heavy slab.
        setShadowOpacity(0.30)

        animateTease(to: teaseFrame)
    }

    /// Cursor left the notch zone before dwell completed — collapse the
    /// tease and either return to resting (if music is playing) or order
    /// the panel out. No-op if not currently teasing.
    ///
    /// In RESTING mode (now-playing pill always on screen), the panel
    /// stays visible at closedFrame after the tease retracts — the user
    /// just gets the pill back. orderOut would yank the persistent pill
    /// off screen, contradicting the always-on contract.
    func dismissTease() {
        guard isTeasing else { return }
        isTeasing = false

        let screen = panel.screen ?? NSScreen.main
        // CRITICAL bug fixed 2026-05-06: was unconditionally retracting
        // to `closedPillFrame` which is the MUSIC pill geometry
        // (278pt wide). In no-music state this caused the panel to
        // briefly grow WIDER mid-retract (from teasePill 200pt → music
        // pill 278pt) before orderOut. User saw it as "going
        // horizontally and creating a weird effect" — fast cursor hid
        // the artifact, slow cursor exposed the morph.
        //
        // Mirror what hide() does: pick close target based on
        // whether music is resting. No-music goes to notchHiddenFrame
        // (matches hardware notch dimensions, the genuinely-closed
        // state) instead of the wider music pill.
        let closedFrame = presenter.isResting
            ? closedPillFrame(for: screen)
            : notchHiddenFrame(for: screen)

        animationGeneration &+= 1
        let myGen = animationGeneration

        // 2026-05-06: fade shadow back out during dismiss for
        // empty state (matches the fade-in we added in tease()).
        // If music is resting, leave shadow at its 0.40 resting
        // opacity — the pill stays visible afterward.
        if !presenter.isResting {
            setShadowOpacity(0, duration: 0.14)
        }

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.16
            // Quick ease-in retract — the tease was a "maybe" and the
            // user said "no thanks." Snappy collapse, no bounce.
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.6, 1)
            ctx.allowsImplicitAnimation = true
            self.panel.animator().setFrame(closedFrame, display: true)
        }, completionHandler: { [weak self] in
            guard let self, self.animationGeneration == myGen else { return }
            // Stay visible at closedFrame if we're an always-on now-
            // playing pill. orderOut would visually remove the pill
            // and force enterRestingMode to re-orderFront on the next
            // mouse twitch, which is both wasted work and a visible
            // flicker.
            if !self.presenter.isResting {
                self.panel.orderOut(nil)
            }
        })
    }

    /// ⌘N quick paste — copies the Nth visible item of the currently
    /// active tab to the system clipboard, then hides the panel after
    /// a brief beat so the user can paste with ⌘V wherever they were
    /// typing. Returns true iff the index resolved to a real item; if
    /// false, the local-monitor closure passes the event through.
    @discardableResult
    private func handleQuickPaste(index: Int) -> Bool {
        switch presenter.activeTab {
        case .music:
            // ⌘1–⌘9 has no meaningful target on the music page —
            // there's no list of items to copy, just the now-playing
            // info and 3 transport buttons. Pass the keystroke through
            // so the user's underlying app still sees ⌘1 / ⌘2 / etc.
            return false
        case .notes:
            let texts = environment.noteStore.notes.prefix(9).map(\.body)
            if case .text(let s) = QuickPasteRouter.itemAt(index: index, texts: Array(texts)) {
                ClipboardService.copy(text: s)
                quickPasteFeedback()
                return true
            }
        case .images:
            let urls = environment.imageStore.images.prefix(9).map { rec in
                environment.imageStore.fullURL(for: rec)
            }
            if case .fileURL(let u) = QuickPasteRouter.itemAt(index: index, urls: Array(urls)) {
                if let img = NSImage(contentsOf: u) {
                    ClipboardService.copy(images: [img], fileURLs: [u])
                    quickPasteFeedback()
                    return true
                }
            }
        case .videos:
            let urls = environment.videoStore.videos.prefix(9).map { rec in
                environment.videoStore.fullURL(for: rec)
            }
            if case .fileURL(let u) = QuickPasteRouter.itemAt(index: index, urls: Array(urls)) {
                ClipboardService.copy(fileURLs: [u])
                quickPasteFeedback()
                return true
            }
        case .files:
            let urls = environment.fileStore.files.prefix(9).map(\.url)
            if case .fileURL(let u) = QuickPasteRouter.itemAt(index: index, urls: Array(urls)) {
                ClipboardService.copy(fileURLs: [u])
                quickPasteFeedback()
                return true
            }
        }
        return false
    }

    private func quickPasteFeedback() {
        HapticFeedback.alignment()
        // 180ms gives the haptic time to register and the user time
        // to register the panel as having "responded" before we yank
        // it. Faster than that feels like a glitchy flash; slower
        // feels like the panel is dragging its feet.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
            self?.hide()
        }
    }

    /// Calls into ClipboardRouter and reacts to its decision. Only
    /// invoked when changeCount has advanced since the last hide().
    /// Returns true iff the decision actually routed somewhere — the
    /// caller can fall back to music auto-route on a `.none` decision
    /// (clipboard changed but we don't recognize what's on it).
    @discardableResult
    private func applyAutoRouting() -> Bool {
        let decision = ClipboardRouter.decide()
        NSLog("nox: auto-route decision = \(decision)")
        switch decision {
        case .none:
            return false
        case .notes(let text):
            do {
                let note = try environment.noteStore.createNote()
                try environment.noteStore.updateBody(id: note.id, body: text)
                presenter.activeTab = .notes
            } catch {
                NSLog("nox: auto-route notes failed: \(error)")
            }
        case .images(let data, let mime):
            environment.imageStore.saveImageDeferred(
                data: data,
                mimeType: mime,
                noteId: nil,
                source: "clipboard"
            )
            presenter.activeTab = .images
        case .videos(let url):
            if url.isFileURL {
                _ = try? environment.videoStore.saveLocalFile(url)
            } else {
                _ = environment.videoStore.startDownload(url: url.absoluteString)
            }
            presenter.activeTab = .videos
        case .files(let urls):
            environment.fileStore.stage(urls: urls)
            presenter.activeTab = .files
        }
        HapticFeedback.alignment()
        return true
    }

    private func removeMonitors() {
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
            clickOutsideMonitor = nil
        }
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
        if let monitor = globalKeyMonitor {
            NSEvent.removeMonitor(monitor)
            globalKeyMonitor = nil
        }
        if let monitor = quickPasteMonitor {
            NSEvent.removeMonitor(monitor)
            quickPasteMonitor = nil
        }
        // Hover monitors only exist when the panel was opened in
        // .hover mode, but clean them up unconditionally — leaking
        // a global mouseMoved monitor across show/hide cycles would
        // cost CPU on every cursor movement system-wide.
        if let monitor = hoverLocalMonitor {
            NSEvent.removeMonitor(monitor)
            hoverLocalMonitor = nil
        }
        if let monitor = hoverGlobalMonitor {
            NSEvent.removeMonitor(monitor)
            hoverGlobalMonitor = nil
        }
        hoverLeaveWorkItem?.cancel()
        hoverLeaveWorkItem = nil
        hoverHasEnteredPanel = false
        // Reset the move-event flag so the next click-mode show()
        // doesn't pay for mouseMoved tracking it doesn't need.
        panel.acceptsMouseMovedEvents = false
    }

    /// Resolve the screen currently containing the cursor. Returns nil
    /// if the cursor is somehow off all screens (rare — only happens
    /// during display reconfigure). Callers fall back to NSScreen.main.
    private func screenContainingCursor() -> NSScreen? {
        let p = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { $0.frame.contains(p) })
    }

    // MARK: - Morph frames

    /// Closed-pill frame: a 200pt-wide bump centered horizontally below
    /// the notch, with the upper `notchOverlap` portion sitting BEHIND
    private func closedPillFrame(for screen: NSScreen?) -> NSRect {
        let frame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let overlap = PanelWindowController.notchOverlap(for: screen)
        let halo = PanelWindowController.haloPadding
        let height = overlap + PanelWindowController.closedPillBump + halo
        let width = PanelWindowController.closedPillWidth + 2 * halo
        return NSRect(
            x: frame.midX - width / 2,
            y: frame.maxY - height,
            width: width,
            height: height
        )
    }

    /// "Notch-hidden" frame — geometry sized to the ACTUAL hardware
    /// notch so the panel's silhouette merges with the physical
    /// notch cutout when the close lands.
    ///
    /// Width: derived from `NSScreen.auxiliaryTopLeftArea` /
    /// `auxiliaryTopRightArea`. Those rects describe the menu-bar
    /// pieces FLANKING the notch; the gap between them IS the notch
    /// hardware width (185pt on 16" MBP, ~200pt on 14" MBP). Falls
    /// back to `closedPillWidth` on non-notched displays.
    ///
    /// Height: `safeAreaInsets.top` (= notch height = menu-bar height
    /// on notched Macs).
    ///
    /// Why this matters: the panel runs at level `.popUpMenu` (above
    /// the menu bar), so when the close lands here the silhouette
    /// draws OVER the menu-bar zone. If the silhouette is wider than
    /// the hardware notch the user sees the panel's black silhouette
    /// extending past the notch over the menu bar — exactly the
    /// "bizarre shape" regression: a wider-than-notch black bar
    /// briefly sitting against the wallpaper. Sized to match the
    /// notch precisely, the silhouette is black-on-black with the
    /// hardware cutout and the close lands cleanly.
    ///
    /// Frame matched to the VISUAL notch hardware dimensions, not
    /// just the auxiliary-area gap.
    ///
    /// Why the difference matters:
    ///   • `NSScreen.auxiliaryTopLeftArea` / `auxiliaryTopRightArea`
    ///     report the menu-bar regions where items can be SAFELY
    ///     placed without bumping the notch bezel. The gap between
    ///     them is 185pt on this 16" MBP.
    ///   • The actual VISUAL notch hardware is wider (~200pt per
    ///     Apple's docs and developer reports) because there's a
    ///     ~8pt safety padding on each side of the bezel where
    ///     menu bar items aren't placed but the hardware cutout
    ///     still extends.
    ///
    /// Adding +8pt on each side (16pt total) brings our close
    /// target from 185pt to ≈201pt — matches the visual notch.
    /// Earlier the panel was ending narrower than the visual notch
    /// and reading as "shrinking past it" instead of "attaching
    /// to it."
    ///
    /// Used SYMMETRICALLY:
    ///   • OPEN (from hidden) starts here and grows to slab
    ///   • CLOSE (no music) shrinks here from slab, then orderOut
    private func notchHiddenFrame(for screen: NSScreen?) -> NSRect {
        let s = screen ?? NSScreen.main
        let frame = s?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let overlap = PanelWindowController.notchOverlap(for: screen)
        let halo = PanelWindowController.haloPadding

        // 2026-05-04 (user feedback: "no pill closing... should be
        // just like the notch of real macbook while closing"):
        // close target now matches the SYSTEM-REPORTED hardware
        // notch exactly (auxGap = the gap between menu-bar items
        // flanking the notch, typically 185pt on 16" MBP). The
        // earlier two-stage close (249pt → settleSpring shrink to
        // 185pt) was the source of the user-reported "bump at
        // last time" — that 64pt width reduction in a separate
        // 120ms spring after the main close. By targeting the
        // hardware notch directly here, the close lands in ONE
        // smooth motion. The settleSpring block in animateClose's
        // completion handler is now a no-op (target == start) and
        // can be removed.
        let visualNotchWidth: CGFloat = {
            guard let s,
                  let auxL = s.auxiliaryTopLeftArea,
                  let auxR = s.auxiliaryTopRightArea
            else {
                return PanelWindowController.closedPillWidth - 64
            }
            return s.frame.width - auxL.width - auxR.width
        }()

        // visibleBump = 0 — silhouette is flush with the menu-bar
        // boundary, fully tucked into the hardware notch. Tested
        // visibleBump=8 briefly (2026-05-06) to give an Alcove-style
        // visible idle nub, but the resulting silhouette overlapped
        // browser tabs / window title bars sitting just below the
        // menu bar — user reported "it's touching my bars." The
        // hardware-notch close character is more important than
        // matching Alcove's idle exactly.
        //
        // The Alcove-like tease feel still works without an idle
        // nub because:
        //   1. Tease draws with rounded shoulders (panelTopRadius=4
        //      in the no-music state), so the grow reads as a
        //      soft pill flexing rather than a sharp rectangle
        //      sprouting from nothing.
        //   2. teasePillBump is 22pt — substantial enough that the
        //      tease pill is unambiguously visible even though the
        //      idle state is invisible.
        let visibleBump: CGFloat = 0
        let width = visualNotchWidth + 2 * halo
        let height = overlap + visibleBump + halo

        return NSRect(
            x: frame.midX - width / 2,
            y: frame.maxY - height,
            width: width,
            height: height
        )
    }

    /// TRANSIENT-ONLY PILL FRAME — used for screenshot/charging/bluetooth
    /// pills when NO MUSIC is playing. Smaller than the music pill so
    /// the silhouette matches the actual notch hardware (~200pt) rather
    /// than the wider music pill (302pt). User 2026-05-05: "when a
    /// screenshot is taken in empty state ... it's taking a shape of
    /// the music pill ... it should be from inside of the notch."
    ///
    /// 220pt wide × 8pt visible bump below menu bar — slightly past
    /// the notch hardware boundary so the transient pill content is
    /// readable, but visually merged with the notch instead of being
    /// a separate music-pill-sized blob.
    private func transientPillFrame(for screen: NSScreen?) -> NSRect {
        let frame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let overlap = PanelWindowController.notchOverlap(for: screen)
        let halo = PanelWindowController.haloPadding
        let visibleWidth: CGFloat = 220
        let visibleBump: CGFloat = 8
        let height = overlap + visibleBump + halo
        let width = visibleWidth + 2 * halo
        return NSRect(
            x: frame.midX - width / 2,
            y: frame.maxY - height,
            width: width,
            height: height
        )
    }

    private func teasePillFrame(for screen: NSScreen?) -> NSRect {
        let frame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let overlap = PanelWindowController.notchOverlap(for: screen)
        let halo = PanelWindowController.haloPadding
        let height = overlap + PanelWindowController.teasePillBump + halo
        let width = PanelWindowController.teasePillWidth + 2 * halo
        return NSRect(
            x: frame.midX - width / 2,
            y: frame.maxY - height,
            width: width,
            height: height
        )
    }

    /// Track-change announcement banner geometry — the panel grows
    /// out of the resting pill into a wider, taller silhouette that
    /// drops a visible apron below the notch hardware. The PILL ROOT
    /// view positions trackChanged content at `.padding(.top, notchOverlap)`
    /// so artwork/title/artist render in this apron, not behind the
    /// hardware. Restores to `closedPillFrame` when the SystemEvent
    /// timeout (3.5s) clears the announcement.
    private func trackBannerFrame(for screen: NSScreen?) -> NSRect {
        let frame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let overlap = PanelWindowController.notchOverlap(for: screen)
        let halo = PanelWindowController.haloPadding
        let height = overlap + PanelWindowController.trackBannerBump + halo
        let width = PanelWindowController.trackBannerWidth + 2 * halo
        return NSRect(
            x: frame.midX - width / 2,
            y: frame.maxY - height,
            width: width,
            height: height
        )
    }

    /// Volume HUD banner geometry — same anchoring pattern as the
    /// track banner (top edge welded to screen top so the panel
    /// appears to grow OUT of the hardware notch). The PILL ROOT
    /// view positions volume content at `.padding(.top, notchOverlap)`
    /// so the speaker glyph + bar render in the visible apron.
    /// Restores to `closedPillFrame` when the SystemEvent timeout
    /// (1.5s) clears the announcement.
    private func volumeBannerFrame(for screen: NSScreen?) -> NSRect {
        let frame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let overlap = PanelWindowController.notchOverlap(for: screen)
        let halo = PanelWindowController.haloPadding
        let height = overlap + PanelWindowController.volumeBannerBump + halo
        let width = PanelWindowController.volumeBannerWidth + 2 * halo
        return NSRect(
            x: frame.midX - width / 2,
            y: frame.maxY - height,
            width: width,
            height: height
        )
    }

    private func openSlabFrame(for screen: NSScreen?, tab: PanelTab) -> NSRect {
        let frame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let overlap = PanelWindowController.notchOverlap(for: screen)
        let halo = PanelWindowController.haloPadding
        let inner = PanelWindowController.innerPanelHeight(for: tab)
        let height = overlap + inner + halo
        let width = PanelWindowController.innerPanelWidth + 2 * halo
        return NSRect(
            x: frame.midX - width / 2,
            y: frame.maxY - height,
            width: width,
            height: height
        )
    }

    // MARK: - Tab-change resize
    //
    // When the user picks a different tab in the segmented bar, the
    // slab animates from the current frame to the new tab's preferred
    // frame. This is intentionally a SHORTER animation than
    // open/close: the panel is already visible and stable, so the
    // resize should feel like a confident snap, not a fresh bloom.

    private func handleActiveTabChange(to newTab: PanelTab) {
        // Bail when not visible — show()/animateOpen handles sizing
        // for fresh opens (they read presenter.activeTab directly when
        // computing the target frame, so a mid-close tab change still
        // gets picked up on the next open).
        guard isVisible else { return }
        // Skip if the tab change didn't actually require a height change
        // (e.g., notes→images→files all use the same default height).
        let screen = panel.screen ?? NSScreen.main
        let target = openSlabFrame(for: screen, tab: newTab)
        if panel.frame == target { return }

        // Bump the generation token so any in-flight open/close
        // completion handlers from before the tab change skip their
        // setFrame work — we don't want a stale recoil step from
        // animateOpen yanking the panel back to the prior tab's size
        // while we're animating to the new one.
        animationGeneration &+= 1
        let myGen = animationGeneration

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.28
            // EaseInOut — the slab starts and ends at rest, no kick.
            // A spring/overshoot here would feel showy; this is a
            // calm "panel adjusted to fit" gesture.
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            ctx.allowsImplicitAnimation = true
            self.panel.animator().setFrame(target, display: true)
        }, completionHandler: { [weak self] in
            guard let self, self.animationGeneration == myGen else { return }
            // Sub-pixel snap to defeat any Core Animation residual.
            self.panel.setFrame(target, display: true)
        })
    }

    /// Settle any in-flight `NSAnimationContext` animation on
    /// `panel.frame` at its current value, instantly. Used by
    /// `animateOpen` and `animateClose` before they kick off their
    /// own SpringFrameAnimator-driven motion, so a previously-
    /// started tease (which uses NSAnimationContext, not the
    /// spring) doesn't continue writing to panel.frame in
    /// parallel with the new spring's per-tick setFrame calls.
    ///
    /// Mechanism: a zero-duration `panel.animator().setFrame`
    /// inside its own NSAnimationContext group. Window-server
    /// receives "animate to current frame in 0s," which collapses
    /// any pending animation to the current visible frame and
    /// emits no further geometry updates. Cheap, surgical, and
    /// correctly scoped — doesn't touch the SpringFrameAnimator
    /// path or the SwiftUI side at all.
    ///
    /// Without this, opening/closing the panel during the tease's
    /// 0.18s ease-out window produces a visible "double opening"
    /// hitch because both animation systems are concurrently
    /// driving panel.frame. See animateOpen's comment for the
    /// full timeline.
    private func haltInflightFrameAnimation() {
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        panel.animator().setFrame(panel.frame, display: false)
        NSAnimationContext.endGrouping()
    }

    // MARK: - Two-stage Core Animation morph
    //
    // ComfyNotch's `ScrollOpening.swift` (open-source notch HUD) uses
    // exactly this pattern: NSAnimationContext.runAnimationGroup with
    // `panel.animator().setFrame(...)` for the geometry change. It's
    // pure Core Animation at the window-server level — GPU-driven, no
    // SwiftUI body re-evaluation per frame, no Metal/CALayer
    // reconfiguration. Two-stage dive/recoil emulates a spring without
    // the unpredictability of CASpringAnimation: a "dive" phase
    // overshoots the target by 2pt, then a "recoil" phase settles back
    // to the resting frame. Cubic-bezier control points push past 1.0
    // (e.g. y=1.2 in the dive curve) for the overshoot kick; the
    // recoil curve uses an even stronger early-bias control point
    // (y=1.8) so the settle arrives quickly without a visible bounce.

    /// Single-stage ease-out grow for the hover tease. No overshoot —
    /// this is a calm "noticed you" cue, not a dramatic bloom. The
    /// shorter duration (0.18s vs the open path's 0.45s combined) keeps
    /// the visual feedback feeling responsive: you flick the cursor
    /// up there and the panel is already done acknowledging by the time
    /// you'd finish dwelling.
    private func animateTease(to target: NSRect) {
        animationGeneration &+= 1
        let myGen = animationGeneration

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 1.0, 0.5, 1.0)
            ctx.allowsImplicitAnimation = true
            self.panel.animator().setFrame(target, display: true)
        }, completionHandler: { [weak self] in
            guard let self, self.animationGeneration == myGen else { return }
            // Sub-pixel snap — same reason as animateOpen's final snap.
            self.panel.setFrame(target, display: true)
        })
    }

    /// Spring constants — calibrated against frame-by-frame audit of
    /// NotchNook's open/close animations (the user's reference app).
    ///
    /// Reference timing (Built-in Retina Display 1300→1340 open,
    /// 1850→1900 close, ~30fps capture):
    ///   open  ~30 frames ≈ 1.0s with progressive blur on content
    ///   close ~50 frames ≈ 1.7s with soft/glowy silhouette
    ///
    /// We don't need to match those durations literally — NotchNook
    /// is on the slow end. But "snap in 120ms" felt awful because
    /// there's no time to PERCEIVE the morph (especially with the
    /// progressive blur on content). Aiming for ~250-300ms so the
    /// blur fade-in / fade-out is visible.
    ///
    ///   OPEN  k=300 d=32 ω_n≈17.3 ratio≈0.92  settle ~270ms
    ///   CLOSE k=350 d=37 ω_n≈18.7 ratio≈0.99  settle ~230ms
    ///
    /// Both just-under-critical (0.92 / 0.99). Visible motion in
    /// the 200-300ms window where the eye reads it as a real
    /// animation, with the SwiftUI content-overlay blur (40pt → 0
    /// over the same window) playing through. Close edges a hair
    /// faster than open — confident retreat.
    private func animateOpen(to target: NSRect) {
        animationGeneration &+= 1
        let myGen = animationGeneration

        // 2026-05-06: HALT IN-FLIGHT NSANIMATIONCONTEXT before
        // starting the spring. Root cause of the "double opening"
        // hitch the user reported when hovering the music pill
        // too fast.
        //
        // Timeline of the bug:
        //   t=0      cursor enters hot zone
        //   t=50ms   tease() runs → animateTease starts an
        //            NSAnimationContext animation (0.18s
        //            ease-out toward teaseFrame). Window-server
        //            level — keeps running until completion.
        //   t=150ms  dwell timer fires (100ms after tease) →
        //            show() → animateOpen starts a SpringFrame
        //            Animator ticking panel.setFrame(lerped) at
        //            60Hz toward slabFrame.
        //   t=150-230ms  TWO animation systems write to the same
        //            panel.frame from different sources. They
        //            visibly fight — the user sees the panel
        //            grow, hitch back, then grow again. Reads
        //            as "double opening."
        //
        // `currentSpring?.cancel()` only cancels in-flight
        // SpringFrameAnimators; NSAnimationContext animations
        // are window-server-side and oblivious to it.
        //
        // Fix: zero-duration `panel.animator().setFrame(...)`
        // inside its own NSAnimationContext group. Forces the
        // window-server to immediately settle the in-flight
        // animation at the current frame; the spring then takes
        // over from a stable position with no competing writer.
        haltInflightFrameAnimation()

        // CADisplayLink/Timer-driven spring physics. Constants
        // tuned from a frame-by-frame teardown of Alcove's actual
        // morph (recorded at 60fps, frames 282–290 of the user's
        // reference clip). Alcove's full pill→slab transition is
        // **~165ms** — silhouette grows in ~7 frames, content
        // ghosts in concurrently, no perceptible overshoot. Anything
        // slower than that exposes Timer pacing variance as jitter:
        // over 360ms (our previous 200/22 spring) there are 22 frames
        // at 60Hz, every one a chance for the spring's sub-pixel
        // step to disagree with the display refresh. Over 150ms
        // there are 9 frames and the motion is gone before the eye
        // can lock onto wobble.
        //
        // Constants (matched to Alcove's measured curve):
        //   mass = 1.0
        //   stiffness = 450  — ω_n ≈ 21.2 rad/s, period ≈ 0.30s
        //   damping = 40     — ratio ≈ 0.943. Just kissing critical,
        //                      no visible overshoot, full settle in
        //                      ~150ms. Frame-by-frame Alcove showed
        //                      no bounce-back — the silhouette grows
        //                      and stops; the "jelly" feel comes
        //                      from the smooth acceleration profile,
        //                      not from oscillation.
        currentSpring?.cancel()
        // Mark "morph in flight" so the sphere visualizer pauses
        // its 60Hz redraw loop while the spring is integrating.
        // Sphere + spring on the same main runloop at 60Hz each
        // were competing for ticks — visible as jelly jitter.
        presenter.isMorphing = true
        // 182/22 — subtle bloom calibrated to OUR slab size, no
        // "double motion" feel. User feedback iteration:
        //   • 380/30 (0.77 ratio, 3% bloom) → "static, lifeless"
        //   • 380/22 (0.56 ratio, 13% bloom) → "weird shapes during bounce"
        //   • 250/22 (0.70 ratio, 4.6% bloom) → "too fast" then "two
        //     opens / glitch feel" (the bloom-and-settle phase reads
        //     as a separate motion on our 480pt-tall slab)
        //   • 182/22 (0.82 ratio, ~1.2% bloom) → THIS: subtle bloom
        //     barely past slab, no perceptible "second motion"
        //
        // Math: ω_n=√182≈13.5, ratio=22/(2·13.5)=0.815. Overshoot
        // peak only ~1.2% (e^(-π·0.815/√(1-0.664)) = e^(-π·1.41)
        // = 0.012) — visible only as a hint of liveliness, not as
        // a separate growth pulse. Settle ~362ms (matched to slab
        // proportions: 3.31× taller than Alcove → √3.31 = 1.82×
        // longer spring → ~362ms).
        //
        // Same duration as the previous 250/22, just lower
        // amplitude on the overshoot phase. The "alive" feel comes
        // from the spring CURVE (smooth ease-out), not from a big
        // bounce.
        // OPEN spring uses current panel.frame as starting position.
        // Reverted setFrame snap to music pill — user reported
        // "small is bouncing" when the snap was active. The snap
        // from notch-hidden → music pill before spring was reading
        // as a discrete bounce of the small panel.
        let start = panel.frame

        // Apple's signature smooth spring: .smooth(duration: 0.45)
        //   stiffness = 195, damping = 28
        //   ratio = 1.003 (critically damped, no overshoot)
        //   Settles ~286ms with smooth ease-out.
        let spring = SpringFrameAnimator(stiffness: 195, damping: 28, mass: 1.0)
        // Wire the GPU shadowPath update into each spring tick so
        // the shadow follows the morphing panel size in real time.
        spring.shadowTickHandler = { [weak self] in
            self?.updateShadowPath()
        }
        // Fade shadow IN at open start. By the time the panel has
        // grown noticeably, the shadow is already at full opacity
        // anchoring it to the desktop.
        setShadowOpacity(0.55)
        currentSpring = spring
        spring.animate(panel: panel, from: start, to: target) { [weak self] in
            guard let self, self.animationGeneration == myGen else { return }
            self.panel.setFrame(target, display: true)
            self.updateShadowPath()
            self.currentSpring = nil
            self.presenter.isMorphing = false
        }
    }

    private func animateClose(to target: NSRect) {
        animationGeneration &+= 1
        let myGen = animationGeneration

        // Cancel any in-flight open spring so the close doesn't fight
        // a still-running grow.
        currentSpring?.cancel()
        currentSpring = nil

        // Same NSAnimationContext halt as animateOpen — see comment
        // there for the full root-cause analysis. A close that
        // interrupts a still-running tease (e.g., user hovers,
        // tease starts, then immediately decides to dismiss)
        // would otherwise compete with the tease's window-server
        // animation for ~30ms of overlap.
        haltInflightFrameAnimation()

        // Branch the close spring on target type so apparent velocity
        // reads similarly in both cases.
        //
        // Music close (target = pillFrame): slab → pill is a
        //   moderate distance (480→302 wide, 360→44 tall). 380/44
        //   gives ~230ms settle, no overshoot, decisive feel.
        //
        // No-music close (target = notchHiddenFrame): slab → notch
        //   is MUCH bigger (480→191 wide, 360→32 tall). At 380/44
        //   the larger distance translates to higher peak velocity
        //   so the close READS as "snap-vanished" even though the
        //   duration is the same as the music close — that's the
        //   "still too fast" feel the user reported. A softer spring
        //   (240/36, ratio≈1.16 overdamped, ~330ms settle) gives
        //   the no-music close more breathing room — the user can
        //   see the slab visibly retreating into the notch instead
        //   of vanishing.
        //
        // Both kept overdamped (no overshoot phase) to avoid the
        // jitter from the 60Hz Timer / 120Hz display desync.
        let start = panel.frame
        presenter.isMorphing = true

        let halo = PanelWindowController.haloPadding
        let notchOnly = PanelWindowController.notchOverlap(for: panel.screen)
        // 2026-05-08 audit H10: closedPillBump=0 and visibleBump=0
        // make notchHiddenFrame.height == closedPillFrame.height,
        // so the height-only test couldn't tell music close from
        // notch-hidden close — both got the soft 158/25 spring,
        // and the music close that should bounce-snap into the
        // pill instead arrived mushy. Discriminate by WIDTH too:
        // closedPillFrame is `closedPillWidth + 2*halo` (~290pt
        // total); notchHiddenFrame is the hardware notch width
        // (~185-205pt + 2*halo ~= 220pt). 240pt is the unambiguous
        // midpoint — if target.width is below it, it's the
        // hardware-notch close path.
        let closedPillFullWidth = PanelWindowController.closedPillWidth + 2 * halo
        let widthMidpoint = (closedPillFullWidth + 220) / 2
        let isNotchHiddenTarget =
            abs(target.height - notchOnly) < halo / 2 &&
            target.width < widthMidpoint

        // Close spring calibrated against PIXEL-LEVEL measurement of
        // Alcove's close (frames 2150-2190 in /Users/apple/Downloads/
        // SS/SS 2, 40 frames at 60fps = ~667ms total close).
        //
        //   Frame 2150: 448px wide (expanded)
        //   Frame 2160: 344/442/445 (top contracts first — non-uniform)
        //   Frame 2170: 267px (full contraction reached)
        //   Frame 2180-2190: 253px (settled at resting pill)
        //
        //   Main motion (f2150→f2170): 20 frames = 333ms
        //   Settle phase (f2170→f2190): 20 frames = 333ms
        //   Total: ~667ms
        //
        // 100/22 spring (was 60/18 = 680ms Alcove-matched):
        //   ω_n   = √100 = 10.0
        //   ratio = 22/(2·10) = 1.10 (slightly overdamped, no overshoot)
        //   95% settle ≈ ~440ms
        //
        // User direction 2026-05-04: "almost but I think it should
        // be a little bit faster." Bumped stiffness 60→100 (×1.67)
        // = ~35% faster close while keeping the overdamped ratio so
        // there's no oscillation/overshoot. Faster than Alcove's
        // 667ms reference but matches user preference.
        let spring: SpringFrameAnimator
        if isNotchHiddenTarget {
            // No-music close — Apple .smooth(duration: 0.50)
            //   stiffness = (2π/0.50)² ≈ 158
            //   damping   = 2·1.0·√158 ≈ 25
            //   ratio = 0.994 (critically damped, no overshoot)
            //   Settles ~320ms with smooth ease-out landing.
            // Matches Apple's signature smooth spring for the close.
            spring = SpringFrameAnimator(stiffness: 158, damping: 25, mass: 1.0)
        } else {
            // Music close — slight bloom (ratio 0.91, near-critical
            // with ~1% overshoot). The close lands at the music
            // pill which is a VISIBLE silhouette below the menu
            // bar, so a subtle bloom reads as "the pill snapping
            // into place" — like a magnet clicking. Was 480/49
            // (overdamped, ratio 1.12). Reduced damping 49 → 40
            // adds the perceptible-but-not-bouncy snap.
            spring = SpringFrameAnimator(stiffness: 480, damping: 40, mass: 1.0)
        }
        spring.shadowTickHandler = { [weak self] in
            self?.updateShadowPath()
        }
        currentSpring = spring
        spring.animate(panel: panel, from: start, to: target) { [weak self] in
            guard let self, self.animationGeneration == myGen else { return }
            self.updateShadowPath()
            // Shadow fades out ONLY after panel has arrived at the
            // close target (notch-hidden / pill). Keeps the close
            // visually anchored by the shadow halo throughout the
            // spring — fixes user-reported "end point seems lower
            // in pt" feeling that happened when shadow disappeared
            // 70-120ms before the panel finished closing.
            //
            // For close-to-pill (music playing): keep shadow visible
            // since the pill should still cast a subtle drop shadow.
            // For close-to-notch-hidden: fade shadow out — there's
            // no visible silhouette there, no shadow needed.
            if isNotchHiddenTarget {
                self.setShadowOpacity(0, duration: 0.14)
            }
            self.currentSpring = nil
            self.presenter.isMorphing = false
            // ALWAYS keep the panel visible at the close target.
            //
            // Why: AppKit drag-and-drop tracks destination windows
            // captured at the START of the drag session. A panel that
            // orderOut's after a close is NOT a drag target — when the
            // user later drags a file from Finder toward the notch,
            // the drag-session simply doesn't see our panel and no
            // draggingEntered fires → DropPickerView never renders.
            //
            // Keeping the panel alive at notchHiddenFrame (185×32 =
            // EXACT hardware notch dimensions) makes it black-on-black
            // with the physical notch cutout — visually invisible —
            // while staying registered as a drag-target so AppKit can
            // route drag-into-notch events to it. This is the real
            // structural fix for "drop picker not showing while
            // dragging."
            //
            // For the music case, the resting pill stays visible at
            // pillFrame as the now-playing indicator (existing
            // behavior). For the no-music case, isResting is cleared
            // but the panel STAYS visible at notch-hidden geometry —
            // there's no visible silhouette below the menu bar, so
            // the user's experience is identical to "panel hidden,"
            // but AppKit knows the window is alive.
            let hasMusic = self.presenter.nowPlaying != nil
            self.panel.setFrame(target, display: true)
            if !(self.presenter.isResting && hasMusic) {
                // No-music path: panel STAYS visible at notch-hidden
                // (black-on-black with hardware) as a drag target.
                // Clear isResting so future show() flows start clean.
                self.presenter.isResting = false

                // 2026-05-04 (user feedback: "no pill closing should
                // be just like the notch of real macbook"): the
                // settleSpring stage that used to shrink the panel
                // from 249pt → 185pt as a SECOND animation here has
                // been REMOVED. notchHiddenFrame now targets the
                // hardware notch width directly (auxGap), so the
                // close lands at the right size in ONE smooth motion
                // — no "bump at last time."
                //
                // Flag the silhouette as notch-hidden so PanelRootView
                // renders the close-end as a clean hardware-notch shape
                // (sharp 90° top corners + 4pt bottom corners). Flag
                // is cleared the moment the panel starts opening again.
                self.presenter.isAtNotchHidden = isNotchHiddenTarget
            } else {
                // Music close path lands at the music pill (278×32
                // visible silhouette, wider than hardware notch). The
                // 6/8 inverse-bow + bottom-flare radii read fine here
                // — the per-side narrowing is only ~5% of the width,
                // not ~7.5% like at notch-hidden. So clear the flag
                // (defensive) so the music pill always uses pill radii.
                self.presenter.isAtNotchHidden = false
            }
        }
    }

    // MARK: - Resting mode (always-on now-playing pill)

    /// Bring the panel up at closed-pill geometry as a persistent now-
    /// playing indicator. Idempotent — repeat calls just verify the
    /// flag and return.
    ///
    /// This is the entry into Alcove's "pill is always there" contract:
    /// once the user has music loaded (playing OR paused), the pill is
    /// on screen continuously, and hovering over it expands to the
    /// music slab. AppDelegate calls this from the orchestrator's
    /// onNowPlayingChange callback when `info != nil`.
    ///
    /// Three states this method handles:
    /// - Panel hidden, no music yet → orderFront at closedFrame, set
    ///   isResting=true. Pill content (artwork+waveform) appears via
    ///   PanelRootView's pill overlay.
    /// - Panel already shown (user has music slab open via hotkey or
    ///   hover) → just flip isResting=true. The next hide()/animateClose
    /// Drive an AirDrop send via NSSharingService and surface a pill
    /// with the result.
    ///
    /// Apple's AirDrop service is famously unreliable for completion
    /// callbacks: `didShareItems` sometimes fires on cancel, and
    /// `didFailToShareItems` often fires AFTER the spurious success
    /// callback. To not lie to the user we use a 350ms debounce —
    /// when `didShareItems` fires we SCHEDULE the success pill, and
    /// if `didFailToShareItems` lands within that window, we cancel
    /// the pending success and show the failure pill instead. The
    /// 350ms is empirically the upper bound on how long the failure
    /// callback trails the spurious success in practice.
    ///
    /// Strong ref to the delegate is held on `self` so it lives past
    /// this function returning — NSSharingService only weakly retains
    /// its delegate. Released the next time performAirDrop runs (and
    /// at app shutdown).
    private func performAirDrop(urls: [URL]) {
        guard let service = NSSharingService(named: .sendViaAirDrop) else {
            DictationOrchestrator.dlog("    ⚠️ AirDrop service unavailable")
            return
        }
        DictationOrchestrator.dlog("    → AirDrop service.perform(\(urls.count) URL(s))")

        let delegate = AirDropShareDelegate(
            count: urls.count,
            onSuccess: { [weak self] count in
                self?.presenter.setPendingSystemEvent(.airDropSent(count: count))
            },
            onFailure: { [weak self] in
                self?.presenter.setPendingSystemEvent(.airDropFailed)
            }
        )
        service.delegate = delegate
        airDropDelegate = delegate

        service.perform(withItems: urls)
        HapticFeedback.levelChange()
    }

    ///   will land at closedFrame and stay there instead of orderOut'ing.
    /// - Panel teasing → flip isResting=true. Either dismissTease (cursor
    ///   left) keeps the pill, or activate (dwell completed) opens the
    ///   slab and isResting carries through to the eventual close.
    /// Bring the panel up at notch-hidden geometry (185×32 = exact
    /// hardware notch dimensions) and order it front. The silhouette
    /// is black-on-black with the physical notch cutout — visually
    /// invisible — but the window is alive and registered for
    /// dragged types so AppKit can route drag-into-notch events to
    /// it. Called once at app launch so the very first drag works
    /// without requiring a prior hover.
    ///
    /// Idempotent — safe to call repeatedly.
    func parkAtNotchHidden() {
        let screen = NSScreen.main
        let target = notchHiddenFrame(for: screen)
        panel.setFrame(target, display: false)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        // Don't flip isResting — this isn't a music resting pill,
        // just an invisible drag-target perch.
        presenter.isShown = false
        // Flag the silhouette as notch-hidden — the panel is parked at
        // 185×32 hardware-notch dimensions, so the rendered shape uses
        // sharp 90° top corners + 4pt bottom corners (matching the
        // hardware notch's actual character) instead of the inverse-bow
        // flare that reads as a "triangle" at this small width.
        presenter.isAtNotchHidden = true

        NSLog("nox: parkAtNotchHidden — panel alive at \(target)")
        // Mirror to dlog so we can verify from /tmp/notetaker-dictation.log
        // whether the park ran (NSLog content is private-redacted in
        // unified logging by default, so it never shows in `log show`).
        DictationOrchestrator.dlog("🅿️ parkAtNotchHidden frame=\(target) windowNumber=\(panel.windowNumber) level=\(panel.level.rawValue) alpha=\(panel.alphaValue) visible=\(panel.isVisible) registeredTypes=\((panel.contentView as? PanelDropContainer).map { _ in "yes" } ?? "NO")")

        // Pre-warm SwiftUI rendering for the slab content. The first
        // user-triggered open was paying a one-time first-render
        // cost (image decoding for app icons + segmented tab assets,
        // text measurement for headers, drag-and-drop overlay
        // construction, Metal texture allocation for blur targets)
        // that showed up as visible jitter during the spring
        // animation.
        //
        // 2026-05-04 v2: kick warmup IMMEDIATELY (was on a 0.5s
        // delay, which the user was beating to the panel — log
        // showed `🔥 prewarm SKIPPED` every time). Also resize the
        // panel to slab dimensions DURING the warmup (alpha=0 so
        // it stays invisible) so SwiftUI lays out at slab size,
        // not the 185×32 notch-hidden size where most of the
        // expensive content gets clipped out of layout.
        DispatchQueue.main.async { [weak self] in
            self?.prewarmSwiftUIContent()
        }
    }

    /// Triggers a layout pass on the slab content while the panel is
    /// invisible (alpha=0, briefly resized to slab dimensions) so
    /// the first user-triggered open doesn't pay first-render cost.
    /// See call site in `parkAtNotchHidden` for rationale.
    private func prewarmSwiftUIContent() {
        guard presenter.isAtNotchHidden, !presenter.isShown else {
            DictationOrchestrator.dlog("🔥 prewarm SKIPPED — user opened panel before warmup ran")
            return
        }
        let t0 = CACurrentMediaTime()
        DictationOrchestrator.dlog("🔥 prewarm START")

        // Capture original geometry so we can restore exactly.
        let originalFrame = panel.frame
        guard let screen = panel.screen ?? NSScreen.main else {
            DictationOrchestrator.dlog("🔥 prewarm ABORT — no screen")
            return
        }
        let slabFrame = openSlabFrame(for: screen, tab: presenter.activeTab)

        // 1) Hide the panel (alpha=0). The window stays alive for
        //    drag tracking; only its rendered output is suppressed.
        panel.alphaValue = 0

        // 2) Resize to slab dimensions WITHOUT display so the
        //    window-server doesn't paint mid-resize.
        panel.setFrame(slabFrame, display: false)

        // 3) Flip isShown=true with animations disabled — SwiftUI
        //    lays out the full slab content tree at slab size,
        //    decodes images, allocates Metal textures, measures
        //    text. This is the costly first-render work we want
        //    to amortize at launch.
        var transaction = SwiftUI.Transaction()
        transaction.disablesAnimations = true
        SwiftUI.withTransaction(transaction) {
            self.presenter.isShown = true
        }

        // 4) Force a synchronous display so all the layout +
        //    rasterization work actually completes before we
        //    revert. Without this, SwiftUI might defer the layout
        //    pass to the next runloop tick — by which point we'd
        //    already have flipped isShown back and unmounted the
        //    slab content (so nothing got warmed).
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()

        // 5) Give async image decoding 2 frames to land, then
        //    revert the geometry + state.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            var t = SwiftUI.Transaction()
            t.disablesAnimations = true
            SwiftUI.withTransaction(t) {
                self.presenter.isShown = false
            }
            self.panel.setFrame(originalFrame, display: false)
            self.panel.alphaValue = 1
            let elapsed = (CACurrentMediaTime() - t0) * 1000
            DictationOrchestrator.dlog(
                "🔥 prewarm DONE in \(String(format: "%.0f", elapsed))ms " +
                "(slab=\(slabFrame.size))"
            )
        }
    }

    func enterRestingMode() {
        if presenter.isResting { return }
        presenter.isResting = true

        // If a full panel is currently shown, the user is interacting
        // with it — don't reach in and forcibly resize. The next hide()
        // path will collapse to pill geometry naturally now that
        // isResting=true.
        if isVisible { return }
        // Same logic for teasing — animateTease is in flight; let it
        // play out, dismissTease/activate now know to keep the panel
        // visible after the morph settles.
        if isTeasing { return }

        let screen = NSScreen.main
        // CHOOSE PILL GEOMETRY based on music state:
        //   • Music playing → music pill (302pt × 44pt) so the
        //     artwork+waveform+transient overlays have room
        //   • No music (transient pill in empty state) → smaller
        //     transientPillFrame (220pt × 40pt) so the silhouette
        //     matches the notch hardware area instead of looking
        //     like a music pill. User 2026-05-05: "when a screenshot
        //     is taken in empty state ... it's taking a shape of
        //     the music pill ... it should be from inside of the notch."
        let pillFrame: NSRect = (presenter.nowPlaying != nil)
            ? closedPillFrame(for: screen)
            : transientPillFrame(for: screen)
        // Only snap to hiddenStart if panel is currently OFF-SCREEN.
        // User screenshot evidence 2026-05-05: previously this ALWAYS
        // snapped panel to notch-hidden (185pt) before animating to
        // music pill (302pt) — if panel was at e.g. 249pt close-end
        // or mid-settle when music started, user saw panel JUMP DOWN
        // to 185 → grow back up to 302 = "small bouncing" effect.
        // With panel always visible after parkAtNotchHidden, the snap
        // is unnecessary; animate from current frame to music pill
        // directly so the motion is one smooth grow, not snap+grow.
        if !panel.isVisible {
            let hiddenStart = notchHiddenFrame(for: screen)
            panel.setFrame(hiddenStart, display: false)
        }
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        // Defensive: make sure isShown is false so PanelRootView's
        // content overlay doesn't render full panel UI on top of the
        // pill body. The pill content is gated on
        // `isResting && !isShown`.
        presenter.isShown = false
        // We were parked at notch-hidden (radii 0/4 — clean hardware
        // notch silhouette). Now growing into the music pill (278×32),
        // which uses 6/8 inverse-bow + bottom-flare radii for the
        // pill character. Clear the flag BEFORE the spring starts so
        // SwiftUI's animatableData interpolates radii (0→6, 4→8) in
        // lockstep with the frame morph (185→278 wide), no popping.
        presenter.isAtNotchHidden = false

        // Soft spring grow from notch-hidden → pillFrame. Matches the
        // motion language of the open spring but to a smaller end
        // target. ~270ms, slightly under-critical for a tactile
        // landing.
        let start = panel.frame
        currentSpring?.cancel()
        // Music pill animation — RESTORED to original 300/32
        // (locked by design per user 2026-05-05). ω_n=17.3,
        // ratio=0.924 (slightly underdamped), settle ~270ms with
        // a tactile landing character. Don't replace with Apple
        // .smooth — the music pill has its own iconic feel.
        let spring = SpringFrameAnimator(stiffness: 300, damping: 32, mass: 1.0)
        spring.shadowTickHandler = { [weak self] in
            self?.updateShadowPath()
        }
        currentSpring = spring
        // Fade shadow IN gently as the music pill emerges from
        // notch-hidden — pill is small but should cast a soft
        // drop shadow so it reads as a physical surface.
        setShadowOpacity(0.40)
        spring.animate(panel: panel, from: start, to: pillFrame) { [weak self] in
            self?.currentSpring = nil
            self?.panel.setFrame(pillFrame, display: true)
            self?.updateShadowPath()
        }

        NSLog("nox: enterRestingMode — animating notchHidden → pillFrame=\(pillFrame)")
    }

    /// Tear down the persistent pill — music has stopped or the source
    /// app went away, so the always-on contract no longer holds. Hides
    /// the panel UNLESS the user has a full slab open / teasing right
    /// now (in which case we just flip the flag; the next dismiss will
    /// orderOut as in pre-resting behavior).
    func exitRestingMode() {
        if !presenter.isResting { return }
        presenter.isResting = false

        if isVisible { return }   // active full panel → dismiss handles orderOut
        // Tease in flight when music stops: dismissTease's completion
        // handler now sees `isResting=false` and will orderOut, but
        // ONLY if the tease retract has already been requested. Without
        // this nudge, a tease that's still expanding when music quits
        // would settle at tease geometry forever (the user gets a stuck
        // pre-bloom blob next time they look at the screen). Force the
        // collapse path so the panel returns to a known orderOut state.
        if isTeasing {
            dismissTease()
            return
        }

        // Animate the resting pill back to notch-hidden geometry and
        // STAY visible there (panel is now always alive at notch-
        // hidden so AppKit can route drag-into-notch events). The
        // silhouette at notch-hidden is black-on-black with the
        // hardware notch cutout — visually invisible — but the
        // window is still a registered drag target.
        //
        // Mirror the enterRestingMode entrance: spring shrink from
        // current frame back to notch-hidden geometry.
        let screen = panel.screen ?? NSScreen.main
        let target = notchHiddenFrame(for: screen)
        let start = panel.frame
        currentSpring?.cancel()
        // Match the entrance spring (300/32 ~270ms) for symmetric
        // appear/disappear motion. Music pill spring locked by
        // design per user 2026-05-05.
        let spring = SpringFrameAnimator(stiffness: 300, damping: 32, mass: 1.0)
        currentSpring = spring
        // Flip to hardware-notch radii (0/4) BEFORE the spring starts
        // so SwiftUI's animatableData interpolates radii (6→0, 8→4) in
        // lockstep with the frame shrink (278→185 wide). Setting the
        // flag in the spring's completion handler instead would snap
        // the radii at the end — the user perceives this as "the corners
        // popped sharper at the very end" rather than a continuous
        // morph. With this ordering, the silhouette gradually transforms
        // from a music-pill shape into a hardware-notch-shaped rect
        // over the same ~270ms as the frame shrink — one fluid morph.
        presenter.isAtNotchHidden = true
        spring.animate(panel: panel, from: start, to: target) { [weak self] in
            guard let self else { return }
            self.currentSpring = nil
            self.panel.setFrame(target, display: true)
            NSLog("nox: exitRestingMode — settled at notch-hidden (alive as drag target)")
        }
    }

    // MARK: - Track-change banner

    /// Animate the resting pill into the wider/taller banner geometry
    /// for a track-change announcement. NO-OP if the user is currently
    /// hovering the slab open / teasing — the announcement stays out
    /// of the way of explicit interactions. After ~3.5s
    /// `dismissTrackBanner()` returns the panel to closedPillFrame.
    func showTrackBanner() {
        // Only valid in resting mode and only when the resting pill
        // is the visible chrome (not slab, not tease in flight).
        guard presenter.isResting else { return }
        if isVisible { return }
        if isTeasing { return }

        let screen = panel.screen ?? NSScreen.main
        let target = trackBannerFrame(for: screen)
        let start = panel.frame
        if start == target { return }

        currentSpring?.cancel()

        // SINGLE-STAGE GROW. User feedback 2026-05-07: "animation
        // can be a little more smoother". Earlier 380/28 (ζ=0.72)
        // had visible 4% overshoot which read as a tiny bounce —
        // user wants smoother. Damped closer to critical so the
        // silhouette settles without overshoot.
        //
        // stiffness 320 / damping 33 / mass 1
        // → ω_n=17.9, ζ=0.92, settle ~245ms.
        // ζ=0.92 is right under critical (1.0). The landing has
        // no visible overshoot but isn't fully critically damped
        // either — keeps just enough organic feel to not read as
        // a hard mechanical ramp.
        let spring = SpringFrameAnimator(stiffness: 320, damping: 33, mass: 1.0)
        spring.shadowTickHandler = { [weak self] in
            self?.updateShadowPath()
        }
        currentSpring = spring
        spring.animate(panel: panel, from: start, to: target) { [weak self] in
            self?.currentSpring = nil
            self?.panel.setFrame(target, display: true)
            self?.updateShadowPath()
        }
        NSLog("nox: showTrackBanner — single-stage grow to banner=\(target)")
    }

    /// Reverse of `showTrackBanner()`. Animates back to the regular
    /// resting pill frame (closedPillFrame if music is alive,
    /// transientPillFrame otherwise). Calls `completion` when the
    /// spring lands so the caller (AppDelegate) can clear the
    /// pendingSystemEvent in lockstep — that ordering keeps content
    /// (.trackChanged → musicPillContent) aligned with geometry
    /// (banner → resting pill). Without it, two independent timers
    /// would race and the user would see content/geometry mismatch.
    func dismissTrackBanner(completion: (() -> Void)? = nil) {
        guard presenter.isResting else {
            completion?()
            return
        }
        if isVisible {
            completion?()
            return
        }
        if isTeasing {
            completion?()
            return
        }

        let screen = panel.screen ?? NSScreen.main
        let target: NSRect = (presenter.nowPlaying != nil)
            ? closedPillFrame(for: screen)
            : transientPillFrame(for: screen)
        let start = panel.frame
        if start == target {
            completion?()
            return
        }

        currentSpring?.cancel()
        let spring = SpringFrameAnimator(stiffness: 600, damping: 45, mass: 1.0)
        spring.shadowTickHandler = { [weak self] in
            self?.updateShadowPath()
        }
        currentSpring = spring
        spring.animate(panel: panel, from: start, to: target) { [weak self] in
            self?.currentSpring = nil
            self?.panel.setFrame(target, display: true)
            self?.updateShadowPath()
            completion?()
        }
        NSLog("nox: dismissTrackBanner — returning to pill=\(target)")
    }

    // MARK: - Volume HUD banner
    //
    // Same morph recipe as the track-change banner, retargeted to
    // `volumeBannerFrame`. The user described the desired visual:
    // "it's going to open up from the notch, which is the hardware
    // notch, and then expands sideways" — the notch-anchored frame
    // morph (top edge welded to screen top, width grows) does
    // exactly that.
    //
    // Idempotent: if the panel is already at the volume banner
    // frame, calling showVolumeBanner again is a no-op (the held-key
    // tick spam wouldn't otherwise fire dozens of redundant
    // animations). The pendingSystemEvent push from AppDelegate
    // still resets the dismiss timer per tick, so the HUD stays
    // pinned for the duration of the keypress.

    /// Animate the resting pill into the volume HUD banner geometry.
    /// NO-OP if the user is currently in slab / tease — volume HUD
    /// stays out of the way of explicit interactions, just like the
    /// track banner.
    func showVolumeBanner() {
        guard presenter.isResting else { return }
        if isVisible { return }
        if isTeasing { return }

        let screen = panel.screen ?? NSScreen.main
        let target = volumeBannerFrame(for: screen)
        let start = panel.frame
        if start == target { return }

        // ANTI-THRASH: if a spring is already animating to the
        // volume banner target, let it finish — don't cancel and
        // restart. Held volume keys fire showVolumeBanner ~30×/sec
        // and each restart resets the spring from a mid-flight
        // position, which never settles → jittery/laggy morph.
        if currentSpringTarget == target { return }

        currentSpring?.cancel()

        // ── PREMIUM ANIMATION via NSAnimationContext + Apple's
        // signature out-quint cubic-bezier (0.32, 0.72, 0, 1).
        // Off-thread Core Animation (no main-thread spring
        // contention). Source: WWDC23 / DynamicNotchKit pattern.
        currentSpring?.cancel()
        currentSpring = nil
        currentSpringTarget = target
        // HIDE SHADOW during the morph. The CALayer drop shadow
        // uses a SHAPE PATH (silhouette CGPath) that's only valid
        // for the CURRENT panel.frame. When the frame morphs, the
        // shadowPath stays at the OLD shape — visible as a
        // rectangular black halo around the morphing silhouette
        // (the user's "black square glitch"). Per-tick
        // updateShadowPath() would fix it but causes main-thread
        // lag. Best compromise: shadow fades to 0 at morph start,
        // updateShadowPath() at completion, then shadow fades
        // back in.
        setShadowOpacity(0, duration: 0.10)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.40
            ctx.timingFunction = CAMediaTimingFunction(
                controlPoints: 0.32, 0.72, 0, 1
            )
            ctx.allowsImplicitAnimation = true
            panel.animator().setFrame(target, display: true, animate: true)
        }, completionHandler: { [weak self] in
            guard let self else { return }
            self.currentSpringTarget = nil
            self.panel.setFrame(target, display: true)
            self.updateShadowPath()
            // Shadow fades back in over 0.20s using the new path.
            self.setShadowOpacity(0.18, duration: 0.20)
        })
    }

    /// Reverse of `showVolumeBanner`. Animates back to whichever
    /// resting pill is appropriate (closedPillFrame if music is
    /// alive, transientPillFrame otherwise). Calls `completion`
    /// when the spring lands so AppDelegate can clear the pending
    /// event in lockstep with the geometry settling.
    func dismissVolumeBanner(completion: (() -> Void)? = nil) {
        guard presenter.isResting else {
            completion?()
            return
        }
        if isVisible {
            completion?()
            return
        }
        if isTeasing {
            completion?()
            return
        }

        let screen = panel.screen ?? NSScreen.main
        let target: NSRect = (presenter.nowPlaying != nil)
            ? closedPillFrame(for: screen)
            : transientPillFrame(for: screen)
        let start = panel.frame
        if start == target {
            completion?()
            return
        }
        // Anti-thrash: skip if already dismissing to the same frame.
        if currentSpringTarget == target {
            completion?()
            return
        }

        // SAME PATTERN as showVolumeBanner. Hide shadow during
        // the morph (avoids "black square halo" glitch from stale
        // shadowPath), updateShadowPath at completion, fade
        // shadow back in over 0.20s.
        currentSpring?.cancel()
        currentSpring = nil
        currentSpringTarget = target
        setShadowOpacity(0, duration: 0.10)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.40
            ctx.timingFunction = CAMediaTimingFunction(
                controlPoints: 0.32, 0.72, 0, 1
            )
            ctx.allowsImplicitAnimation = true
            panel.animator().setFrame(target, display: true, animate: true)
        }, completionHandler: { [weak self] in
            guard let self else { return }
            self.currentSpringTarget = nil
            self.panel.setFrame(target, display: true)
            self.updateShadowPath()
            self.setShadowOpacity(0.40, duration: 0.20)
            completion?()
        })
    }

}

// MARK: - Spring frame animator
//
// CASpringAnimation can't be attached to NSWindow.frame (the only
// way to animate a window's frame is via NSAnimationContext, which
// only accepts CAMediaTimingFunction — a cubic bezier). To get true
// multi-oscillation spring physics on the panel's frame we step
// through it ourselves on a 60Hz Timer, computing a single fraction
// 0→1 with damped harmonic motion and lerping start↔target each tick.
//
// Why a single fraction (not 4 independent springs per frame
// component): the panel grows/shrinks proportionally — height,
// MARK: - AirDropShareDelegate

/// NSSharingServiceDelegate wrapper that papers over Apple's
/// unreliable AirDrop completion callbacks.
///
/// Empirically, when a user CANCELS an AirDrop sheet, Apple often
/// fires `didShareItems` first (a spurious "success") and then a few
/// dozen-to-hundred milliseconds later fires `didFailToShareItems`
/// with the real cancellation. Trusting the first callback would
/// mean showing a "Sent" pill on a cancelled send.
///
/// This delegate handles that with a debounce:
///   • didShareItems → schedule the success pill for 350ms in the
///     future and wait.
///   • didFailToShareItems → if a success is pending, cancel it; show
///     the failure pill now.
/// 350ms is generous enough to swallow Apple's race in practice
/// without making real-success cases feel laggy (the pill shows up
/// roughly when the recipient's device finishes the haptic confirm).
///
/// All callbacks are forced onto the main actor — NSSharingService
/// makes no thread guarantee, and our presenter is @MainActor.
@MainActor
final class AirDropShareDelegate: NSObject, NSSharingServiceDelegate {
    private let count: Int
    private let onSuccess: (Int) -> Void
    private let onFailure: () -> Void
    private var didFail = false
    private var pendingSuccess: Task<Void, Never>?

    /// 350ms — long enough to swallow Apple's spurious-success race,
    /// short enough that real success still feels prompt.
    private static let debounceNanos: UInt64 = 350_000_000

    init(count: Int,
         onSuccess: @escaping (Int) -> Void,
         onFailure: @escaping () -> Void) {
        self.count = count
        self.onSuccess = onSuccess
        self.onFailure = onFailure
    }

    nonisolated func sharingService(_ sharingService: NSSharingService,
                                    didShareItems items: [Any]) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            // If we've already decided this was a cancel, ignore the
            // delayed-success that Apple sometimes still fires.
            if self.didFail { return }
            self.pendingSuccess?.cancel()
            self.pendingSuccess = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: AirDropShareDelegate.debounceNanos)
                guard !Task.isCancelled, let self, !self.didFail else { return }
                self.onSuccess(self.count)
            }
        }
    }

    nonisolated func sharingService(_ sharingService: NSSharingService,
                                    didFailToShareItems items: [Any],
                                    error: Error) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.didFail = true
            self.pendingSuccess?.cancel()
            self.pendingSuccess = nil
            self.onFailure()
        }
    }
}

// MARK: - SpringFrameAnimator

// width, x, and y all reach their targets at the same beat. One
// spring drives them together, the lerp distributes the motion.
@MainActor
final class SpringFrameAnimator: NSObject {
    let stiffness: Double
    let damping: Double
    let mass: Double

    private weak var panel: NSPanel?
    private var startFrame: NSRect = .zero
    private var targetFrame: NSRect = .zero
    private var fraction: Double = 0
    private var velocity: Double = 0
    private var lastTickTime: CFTimeInterval = 0
    /// Display-synced ticking via CADisplayLink (macOS 14+) so the
    /// spring runs at the actual display refresh rate — 120Hz on
    /// ProMotion (16" MBP), 60Hz on standard displays. On a 16" MBP
    /// the previous Timer(1/60) ticked at fixed 60Hz while the
    /// display refreshes at 120Hz, dropping every other frame and
    /// producing visible jitter ("not smooth" per user 2026-05-04).
    /// CADisplayLink fires on EVERY vsync — twice as many samples
    /// per second on ProMotion = visibly smoother motion, especially
    /// during the slow no-music close (~680ms).
    ///
    /// Why CADisplayLink and not CVDisplayLink: CVDisplayLink fires
    /// on its own thread and requires `DispatchQueue.main.async`
    /// to hop back for the setFrame call — the hop costs a frame
    /// of latency, so each tick lands AFTER the vsync window. The
    /// macOS-14+ CADisplayLink (created via `NSScreen.displayLink`)
    /// runs directly on the main runloop, no cross-thread hop, and
    /// the tick fires inside the vsync window so setFrame lands
    /// in time for the next render pass. Earlier Timer-based code
    /// kept the same single-thread guarantee but at fixed 60Hz —
    /// CADisplayLink keeps it AND tracks display rate.
    ///
    /// Fallback: macOS 13 (deployment target) doesn't have the
    /// NSScreen.displayLink API yet. On those systems we keep the
    /// 60Hz Timer (still works, just less smooth on ProMotion).
    ///
    /// Type-erased to AnyObject so the property declaration itself
    /// doesn't require macOS 14 (CADisplayLink class is iOS-rooted
    /// and only became macOS-available in 14). The runtime cast at
    /// each touch site is the standard pattern for this.
    private var displayLink: AnyObject?
    private var timer: Timer?
    private var completion: (() -> Void)?
    /// Optional per-tick callback used by PanelWindowController to
    /// keep the CALayer shadowPath in sync with the morphing
    /// panel.frame. Called AFTER the setFrame call so the
    /// contentView has already resized to the lerped frame.
    var shadowTickHandler: (() -> Void)?
    // Frame-drop detector accumulators (v2 instrumentation, 2026-05-04)
    private var tickCount: Int = 0
    private var tickDtSum: Double = 0
    private var tickDtMax: Double = 0
    private var startWallTime: CFTimeInterval = 0

    init(stiffness: Double, damping: Double, mass: Double) {
        self.stiffness = stiffness
        self.damping = damping
        self.mass = mass
        super.init()
    }

    func animate(panel: NSPanel, from start: NSRect, to target: NSRect, initialVelocity: Double = 0, completion: @escaping () -> Void) {
        self.panel = panel
        self.startFrame = start
        self.targetFrame = target
        self.fraction = 0
        // Initial velocity in fraction-units per second.
        // NEGATIVE = anticipation (panel briefly moves AWAY from
        // target before reversing toward it — Disney "anticipation"
        // principle, used for open animation to give "tucks into
        // the notch then bursts out" feel).
        // POSITIVE = follow-through (panel arrives with momentum,
        // overshoots more — useful for "snap into place" feel).
        // Default 0 = standard spring start from rest.
        self.velocity = initialVelocity
        self.lastTickTime = 0
        self.completion = completion
        // Reset per-morph instrumentation (v2 frame-drop detector)
        self.tickCount = 0
        self.tickDtSum = 0
        self.tickDtMax = 0
        self.startWallTime = CACurrentMediaTime()
        if #available(macOS 14.0, *) {
            // Prefer the screen the panel is on so the displayLink
            // is bound to that display's vsync timer.
            let screen = panel.screen ?? NSScreen.main
            if let link = screen?.displayLink(target: self, selector: #selector(tickFromDisplayLink)) {
                // 2026-05-04: lock to 60Hz instead of letting
                // ProMotion adaptively scale between 60Hz and
                // 120Hz. ProMotion was producing variable tick
                // timing (8.3ms when fast, 16.7ms when adaptive
                // dropped to 60Hz, sometimes 25ms in transition)
                // which read as inconsistent morph smoothness in
                // the spring detector data — some morphs avgDt
                // 10ms, others 16ms, others 25ms. Locking to a
                // CONSTANT 60Hz gives predictable 16.7ms ticks.
                // Spring physics gets a stable dt, no rate-change
                // jitter mid-morph.
                //
                // The visible motion is at 60Hz instead of 120Hz —
                // one frame of detail less smooth on ProMotion
                // displays — but consistent timing wins over
                // variable-rate visibility for animation feel.
                link.preferredFrameRateRange = CAFrameRateRange(
                    minimum: 60, maximum: 60, preferred: 60
                )
                link.add(to: .main, forMode: .common)
                displayLink = link
                return
            }
        }
        // Fallback: 60Hz Timer on macOS 13 or if displayLink fails.
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    @objc private func tickFromDisplayLink() {
        tick()
    }

    func cancel() {
        if #available(macOS 14.0, *), let link = displayLink as? CADisplayLink {
            link.invalidate()
        }
        displayLink = nil
        timer?.invalidate()
        timer = nil
        completion = nil
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let isFirstTick = lastTickTime == 0
        let rawDt = isFirstTick ? 1.0 / 60.0 : (now - lastTickTime)
        let dt = isFirstTick ? 1.0 / 60.0 : min(1.0 / 30.0, now - lastTickTime)
        lastTickTime = now
        // 2026-05-04 FRAME-DROP DETECTOR — slow-tick dlog REMOVED.
        // The per-tick dlog became the lag itself: each call did
        // synchronous file I/O (FileHandle open + seek + write +
        // close = 3 syscalls), plus NSLog, plus a fresh
        // ISO8601DateFormatter allocation. With threshold 11ms
        // on a 120Hz display (baseline 8.3ms), any pacing
        // variance pushed ticks above 11ms → dlog → main-thread
        // block → NEXT tick now also above 11ms → another dlog
        // → runaway feedback loop. The instrumentation was
        // CAUSING the lag it was meant to measure.
        //
        // Accumulators kept (cheap arithmetic) so the morph-end
        // summary still works for diagnostic purposes when
        // explicitly requested.
        if !isFirstTick {
            tickCount += 1
            tickDtSum += rawDt
            if rawDt > tickDtMax { tickDtMax = rawDt }
        }

        // Damped harmonic motion on `fraction` toward target = 1.0.
        // F = -k(x - target) - c·v
        // a = F / m
        let displacement = fraction - 1.0
        let force = -stiffness * displacement - damping * velocity
        let acceleration = force / mass
        velocity += acceleration * dt
        fraction += velocity * dt

        let lerped = NSRect(
            x: lerp(startFrame.minX, targetFrame.minX, fraction),
            y: lerp(startFrame.minY, targetFrame.minY, fraction),
            width: lerp(startFrame.width, targetFrame.width, fraction),
            height: lerp(startFrame.height, targetFrame.height, fraction)
        )
        // `display: false` — the Core Animation system batches the
        // pending visual update with the next render pass instead
        // of forcing an immediate window-server flush. Reduces
        // window-server traffic by ~30% on long morphs.
        panel?.setFrame(lerped, display: false)

        // 2026-05-04: keep the CALayer shadowPath in sync with the
        // morphing panel size. Cheap (single CGPath rebuild +
        // shadowPath assignment, all GPU-bound) compared to the
        // SwiftUI .shadow() it replaces. shadowTickHandler is set
        // by PanelWindowController in animateOpen so we don't have
        // to import the whole controller into this physics class.
        shadowTickHandler?()

        // 2026-05-04 FINAL: settle threshold 3.5pt/30pt-s. The
        // tighter 1.5pt/12pt-s value forced the spring to
        // integrate through ~22 extra ticks of sub-pixel motion
        // at the tail — last ~100ms became invisible motion
        // that the eye perceives as "stalled" or "lagging."
        // Looser threshold ends the spring decisively before
        // the sub-pixel phase. The 3.5pt snap is below the
        // perceptual threshold for instantaneous repositioning
        // at this animation duration; user confirmed this
        // version reads as smoother.
        let amplitude = max(abs(targetFrame.width - startFrame.width),
                            abs(targetFrame.height - startFrame.height))
        let positionError = abs(fraction - 1.0) * amplitude
        let velocityMag = abs(velocity) * amplitude
        if positionError < 3.5 && velocityMag < 30 {
            // 2026-05-04 morph-summary: total ticks, avg dt, max dt,
            // wall time. Lets us see e.g. "30 ticks over 280ms,
            // avg=9.3ms (perfect 120Hz), max=18ms" — single-glance
            // verdict on whether the spring path was smooth even if
            // no individual tick crossed the slow-tick threshold.
            let wallTime = (CACurrentMediaTime() - startWallTime) * 1000
            let avgDt = tickCount > 0 ? (tickDtSum / Double(tickCount)) * 1000 : 0
            let maxDt = tickDtMax * 1000
            DictationOrchestrator.dlog(
                "✅ morph done ticks=\(tickCount) " +
                "wall=\(String(format: "%.0f", wallTime))ms " +
                "avgDt=\(String(format: "%.1f", avgDt))ms " +
                "maxDt=\(String(format: "%.1f", maxDt))ms"
            )
            if #available(macOS 14.0, *), let link = displayLink as? CADisplayLink {
                link.invalidate()
            }
            displayLink = nil
            timer?.invalidate()
            timer = nil
            let cb = completion
            completion = nil
            cb?()
        }
    }

    private func lerp(_ a: CGFloat, _ b: CGFloat, _ t: Double) -> CGFloat {
        a + (b - a) * CGFloat(t)
    }
}
