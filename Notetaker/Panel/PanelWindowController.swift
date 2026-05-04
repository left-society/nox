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
    /// Bottom-corner radius for the closed pill silhouette. **14pt**
    /// — modest enough that the silhouette BODY stays at full
    /// 259pt width through most of its height, with only the last
    /// 14pt of vertical tapering into rounded corners. The user
    /// explicitly rejected the previous 30pt approach as "the curve
    /// is shrinking i didn't meant that"; that radius made the
    /// bottom edge 60pt narrower than the body, producing a
    /// stadium-arc shape rather than a proper rounded rectangle.
    /// With 14pt radius and 12pt bump, the bottom edge meets the
    /// desktop at 259 - 2*14 = 231pt — only 28pt narrower than
    /// the body, so the pill reads as "wide rectangle with rounded
    /// corners" rather than "tapered teardrop." This matches
    /// Alcove's visual treatment in the Mission Control reference
    /// the user shared. Slab uses `innerCornerRadius` (34pt);
    /// silhouette morphs 14 → 34 via `.smooth`.
    static let pillCornerRadius: CGFloat = 14
    /// Tease (hover-intent) geometry. When the cursor enters the notch
    /// hot zone, we animate the panel from resting closed-pill geometry
    /// to a slightly-wider, slightly-taller pill to give immediate visual
    /// feedback that the system noticed. If the cursor stays for
    /// `HoverActivator.dwellSeconds`, the tease promotes to a full slab
    /// open. If the cursor leaves first, the tease retracts to closed.
    ///
    /// The size delta is small on purpose — the user described the
    /// reference behavior (Alcove / Elkhob) as "it just moves a little
    /// bit; it doesn't open the whole thing." Bumped from 220×24 →
    /// 340×40 to track the new 320×32 closed pill: the proportional
    /// delta (~6% width, +25% height) is what reads as "noticed you"
    /// without misfiring as a full open.
    static let teasePillWidth: CGFloat = 340
    static let teasePillBump: CGFloat = 40
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
        // .popUpMenu (101) draws OVER the menu bar — required so the
        // panel visibly overlaps the menu-bar zone and merges with the
        // physical notch. .statusBar (25) sits at the same level as the
        // menu bar's status icons, so z-order ties can leave our panel
        // BEHIND the bar; the popUpMenu level removes that ambiguity.
        // We only overlap the menu bar's empty middle area (around the
        // notch), so this doesn't trample app/system menu items.
        panel.level = .popUpMenu
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

        // Attach the panel to the custom SkyLight space at level
        // 400 (kSLSSpaceAbsoluteLevelNotificationCenterAtScreenLock).
        // This is what makes the pill visible on the lock screen
        // — the same compositor pool Apple's own Notification
        // Center widgets live in. Public NSWindow API has no path
        // to this; we go through SkyLight private symbols. See
        // NotchSpaceManager for the full mechanism. If SkyLight
        // load fails (future macOS removes the symbols) the
        // attach is a no-op and the pill behaves as a normal
        // desktop-only window.
        NotchSpaceManager.shared?.attach(panel)

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
                presenter?.isDropTargeted = flag
                // Drive the two-zone Save/AirDrop drop picker
                // overlay. The DropPickerView in PanelRootView is
                // gated on `dropPickerActive && isShown`. Without
                // this assignment the picker stays hidden and the
                // user just sees the accent ring with no Save vs
                // AirDrop choice — exactly the bug user reported.
                presenter?.dropPickerActive = flag
                // Auto-expand the slab when a drag enters while the
                // panel is at resting-pill geometry. Without this,
                // the user would drag a file over the pill and see
                // no feedback (slab content is invisible at opacity
                // 0). Expanding routes them directly to the Files
                // tab so the drop ring + tray are immediately
                // visible — same UX NotchNook uses for their notch
                // file shelf.
                if flag, let self, !self.isVisible {
                    presenter?.activeTab = .files
                    self.show(mode: .hover)
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

        // Position the panel at its starting geometry BEFORE ordering
        // it front. If a close is still in flight (panel mid-shrink,
        // orderOut not yet fired), DON'T snap it — let animateOpen
        // blend from the panel's CURRENT frame so velocity continues
        // smoothly (no visible jump).
        //
        // The starting frame depends on whether the panel was hidden
        // or already visible:
        //   • Already visible (resting music pill OR mid-close):
        //     skip setFrame; spring blends from current frame to slab.
        //   • Fully hidden (no music, panel was orderOut'd): start at
        //     notchHiddenFrame — height = notchOverlap only, fully
        //     occluded by the hardware notch. The spring grows from
        //     "invisible behind the notch" → slab. No "pill flash"
        //     frame to worry about, no alpha fade required, pure
        //     spring physics from frame 1. Matches the symmetric
        //     close-to-notch endpoint.
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
        NSLog("Notetaker: show() pill=\(pillFrame) slab=\(slabFrame) main=\(NSScreen.main?.frame ?? .zero) screens=\(screens)")

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

        // Subtle haptic at the moment the morph begins — same idea
        // as Alcove (their bundle ships `HapticFeedback` symbols + a
        // `haptic.caf` sound file). `.alignment` is the firmest of
        // the three NSHapticFeedbackManager patterns; reads as a
        // single confident "click" through the trackpad. Silent on
        // non–Force Touch hardware. Auto-respects the user's
        // System Settings → Trackpad → Haptic feedback toggle.
        HapticFeedback.alignment()

        // Start the pure-Core-Animation morph. NSAnimationContext drives
        // panel.animator().setFrame at the window-server level — GPU-
        // accelerated, no SwiftUI body re-evaluation per frame.
        animateOpen(to: slabFrame)

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
                NSLog("Notetaker: global mouse-down → keep panel up (download in flight)")
                return
            }
            NSLog("Notetaker: global mouse-down → hide")
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

    func hide() {
        NSLog("Notetaker: hide() called, isVisible=\(isVisible)")
        guard isVisible else { return }
        // Snapshot the clipboard so the next show() can tell whether
        // the user copied something new in between.
        lastSeenChangeCount = NSPasteboard.general.changeCount
        removeMonitors()
        // Flip `isShown=false` to start the 0.18s content fade-out
        // (PanelRootView gates the always-mounted content overlay's
        // opacity on this flag). The fade runs IN PARALLEL with the
        // ~350ms close morph, so content disappears smoothly as the
        // panel shrinks back into the notch — no abrupt content snap
        // mid-morph, no still-rendering subviews fighting the shrink.
        presenter.isShown = false
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

        // Tease is always cursor-driven (HoverActivator fires it on
        // notch entry), so resolve the cursor's screen rather than the
        // key-window screen — otherwise on multi-display the tease
        // would bloom from the wrong notch.
        let screen = screenContainingCursor() ?? NSScreen.main
        let closedFrame = closedPillFrame(for: screen)
        let teaseFrame = teasePillFrame(for: screen)

        // Only snap to closed-pill frame if the panel isn't already on
        // screen. In resting mode the panel is ALREADY at closedFrame
        // (PanelPresenter.isResting == true, `enterRestingMode` did the
        // orderFront), so a redundant setFrame here would force AppKit
        // to repaint the existing pill identically right before the
        // animator starts — burning a frame for no visual gain. Letting
        // animateTease blend from the panel's current frame is what
        // makes the resting-pill → tease feel like one continuous
        // surface.
        if !panel.isVisible {
            panel.setFrame(closedFrame, display: false)
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
        let closedFrame = closedPillFrame(for: screen)

        animationGeneration &+= 1
        let myGen = animationGeneration

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
        NSLog("Notetaker: auto-route decision = \(decision)")
        switch decision {
        case .none:
            return false
        case .notes(let text):
            do {
                let note = try environment.noteStore.createNote()
                try environment.noteStore.updateBody(id: note.id, body: text)
                presenter.activeTab = .notes
            } catch {
                NSLog("Notetaker: auto-route notes failed: \(error)")
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

        // Visual-notch padding: aux gap + 8pt each side.
        // Bezel safety zone where menu bar items don't go but the
        // hardware notch still extends.
        let bezelPadding: CGFloat = 8
        let auxGapWidth: CGFloat = {
            guard let s,
                  let auxL = s.auxiliaryTopLeftArea,
                  let auxR = s.auxiliaryTopRightArea
            else {
                // Non-notched display — fall back to pill width.
                return PanelWindowController.closedPillWidth - 2 * bezelPadding
            }
            return s.frame.width - auxL.width - auxR.width
        }()
        let visualNotchWidth = auxGapWidth + 2 * bezelPadding

        return NSRect(
            x: frame.midX - visualNotchWidth / 2,
            y: frame.maxY - overlap,
            width: visualNotchWidth,
            height: overlap
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
        let start = panel.frame
        currentSpring?.cancel()
        // Mark "morph in flight" so the sphere visualizer pauses
        // its 60Hz redraw loop while the spring is integrating.
        // Sphere + spring on the same main runloop at 60Hz each
        // were competing for ticks — visible as jelly jitter.
        presenter.isMorphing = true
        // 300/32 — paced so the SwiftUI content-overlay blur
        // (40pt → 0) has time to play through visibly during the
        // morph. ω_n≈17.3, ratio≈0.92, settle ~270ms. Faster than
        // 240/26 (~330ms which felt laggy without blur), slower
        // than 450/40 (~150ms which snapped before blur could read).
        let spring = SpringFrameAnimator(stiffness: 300, damping: 32, mass: 1.0)
        currentSpring = spring
        spring.animate(panel: panel, from: start, to: target) { [weak self] in
            guard let self, self.animationGeneration == myGen else { return }
            self.panel.setFrame(target, display: true)
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
        let isNotchHiddenTarget = abs(target.height - notchOnly) < halo / 2

        // Close spring calibrated against frame-by-frame audit of
        // NotchNook's close (Built-in Retina Display 1865→1898 ≈
        // 33 frames at 60fps capture ≈ 550ms total close).
        //
        // Previous tries documented:
        //   300/36  ~290ms — user: "closing too fast"
        //   300/32  ~270ms — user: "almost perfect, too fast"
        //   110/26  ~510ms — user: "still not similar" (heavy
        //                    overdamp character was wrong, even
        //                    though the duration was close)
        //
        // Settled on 150/28 — moderate stiffness with just-over-
        // critical damping:
        //   ω_n   = √150 ≈ 12.25
        //   ratio = 28/(2·12.25) ≈ 1.14 (overdamped, no overshoot)
        //   λ₁    = ω_n*(ζ - √(ζ²-1)) ≈ 7.23
        //   95% settle ≈ 3/λ₁ ≈ 415ms
        //
        // Splits the difference: visibly slower than 290ms (matches
        // the user's "too fast" complaint) without sliding into the
        // sluggish heavy-overdamp character of 110/26.
        let spring: SpringFrameAnimator
        if isNotchHiddenTarget {
            spring = SpringFrameAnimator(stiffness: 150, damping: 28, mass: 1.0)
        } else {
            // Music close: lands punchy at the resting pill.
            spring = SpringFrameAnimator(stiffness: 380, damping: 44, mass: 1.0)
        }
        currentSpring = spring
        spring.animate(panel: panel, from: start, to: target) { [weak self] in
            guard let self, self.animationGeneration == myGen else { return }
            self.currentSpring = nil
            self.presenter.isMorphing = false
            // Decide whether to stay (music resting pill) or orderOut
            // (no music). Recheck nowPlaying at completion in case
            // it changed during the spring — a fresh now-playing
            // session that started mid-close should keep the pill.
            let hasMusic = self.presenter.nowPlaying != nil
            if self.presenter.isResting && hasMusic {
                // Settle exactly at target — Core Animation can leave
                // sub-pixel residuals after a spring; an explicit
                // setFrame fixes that without a visible jump. The
                // panel STAYS visible at pill geometry as the
                // always-on now-playing indicator.
                self.panel.setFrame(target, display: true)
            } else {
                // No music to anchor a pill → orderOut. Spring has
                // settled at exact notch dimensions; the silhouette
                // is now the same shape as the hardware notch, so
                // orderOut is visually a no-op (black on black).
                // Clear isResting so the next show() starts clean.
                self.presenter.isResting = false
                self.panel.orderOut(nil)
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
        let pillFrame = closedPillFrame(for: screen)
        // Snap into pill geometry BEFORE orderFront so the pill doesn't
        // pop in at any default frame and then jump to position.
        panel.setFrame(pillFrame, display: false)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        // Defensive: make sure isShown is false so PanelRootView's
        // content overlay doesn't render full panel UI on top of the
        // pill body. The pill content is gated on
        // `isResting && !isShown`.
        presenter.isShown = false

        NSLog("Notetaker: enterRestingMode — panel shown at pillFrame=\(pillFrame)")
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

        // Resting pill currently on screen → collapse it off. We don't
        // run a full close animation here; the music stopped, the pill
        // is already at its smallest geometry, an immediate orderOut
        // reads as "music ended" without any drawn-out theatrics. If
        // we ever want to fade it out, do alphaValue + orderOut on a
        // 0.15s ease-out — but plain orderOut matches Alcove's behavior
        // (the pill just isn't there anymore once the source quits).
        panel.orderOut(nil)
        NSLog("Notetaker: exitRestingMode — panel ordered out")
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
final class SpringFrameAnimator {
    let stiffness: Double
    let damping: Double
    let mass: Double

    private weak var panel: NSPanel?
    private var startFrame: NSRect = .zero
    private var targetFrame: NSRect = .zero
    private var fraction: Double = 0
    private var velocity: Double = 0
    private var lastTickTime: CFTimeInterval = 0
    /// 60Hz Timer firing on main runloop. CVDisplayLink with a
    /// `DispatchQueue.main.async` hop was tried and felt LAGGIER
    /// than the Timer — the cross-thread hop adds enough latency
    /// that the setFrame call lands AFTER the vsync window we
    /// wanted to hit, so the tick effectively renders one frame
    /// late. Pure-main Timer keeps the spring physics, the
    /// setFrame call, and the SwiftUI re-render all on the same
    /// runloop iteration, even at the cost of phase-mismatch on
    /// 120Hz displays.
    private var timer: Timer?
    private var completion: (() -> Void)?

    init(stiffness: Double, damping: Double, mass: Double) {
        self.stiffness = stiffness
        self.damping = damping
        self.mass = mass
    }

    func animate(panel: NSPanel, from start: NSRect, to target: NSRect, completion: @escaping () -> Void) {
        self.panel = panel
        self.startFrame = start
        self.targetFrame = target
        self.fraction = 0
        self.velocity = 0
        self.lastTickTime = 0
        self.completion = completion
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
        completion = nil
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let dt = lastTickTime == 0 ? 1.0 / 60.0 : min(1.0 / 30.0, now - lastTickTime)
        lastTickTime = now

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

        // Settled: snap to target as soon as the residual motion
        // is below the perceptible threshold. Earlier values
        // (0.5pt position, 0.5pt/s velocity) were strict to the
        // point of rendering invisible sub-pixel oscillations —
        // exactly when Timer pacing variance produces the most
        // visible jitter. 1.5pt and 12pt/s are below human
        // perception of motion at ~60Hz but well above the wobble
        // floor where pacing irregularity dominates.
        let amplitude = max(abs(targetFrame.width - startFrame.width),
                            abs(targetFrame.height - startFrame.height))
        let positionError = abs(fraction - 1.0) * amplitude
        let velocityMag = abs(velocity) * amplitude
        if positionError < 1.5 && velocityMag < 12 {
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
