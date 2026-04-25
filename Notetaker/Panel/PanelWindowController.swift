import AppKit
import Combine
import SwiftUI

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
    static let panelWidth: CGFloat = 480
    static let panelHeight: CGFloat = 680
    /// The visible rounded-glass slab the user sees. Anchored trailing
    /// inside the outer panel so the right edge stays at the same screen
    /// position as before; the halo wraps it on three sides.
    ///
    /// Width 380 / height 480: previous 340×620 read as a tall column
    /// that ate a lot of vertical real estate. Bumping the width by 40pt
    /// gives image/video grids breathing room (two-column layout no
    /// longer feels cramped) while the 140pt height cut leaves the
    /// wallpaper visible below — the panel feels like a HUD, not a
    /// document window. Aspect ratio shifts from 0.55 (very portrait)
    /// to 0.79 (gentle portrait) — closer to Alcove's roughly square
    /// expanded state.
    static let innerPanelWidth: CGFloat = 380
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
    static let innerPanelHeightMusic: CGFloat = 330

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
    static let haloPadding: CGFloat = 50
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
    static let closedPillWidth: CGFloat = 259
    /// Visible bump height below the menu-bar bottom. **Locked at 0pt
    /// — pixel-measured Alcove parity.** This was the missing insight
    /// across nine rounds of width tweaking: Alcove's resting pill
    /// doesn't extend below the menu bar AT ALL. The dark silhouette
    /// in our pixel measurement of `/Applications/Alcove.app` ends at
    /// y=31.5pt — half a point shy of the menu-bar bottom (32pt). The
    /// pill sits ENTIRELY within the notch + menu-bar zone, painting
    /// over part of the menu bar around the notch hardware to look
    /// like an extended notch with content in it. That's why the user
    /// described Alcove as "running only on the menu" and "doesn't
    /// affect any other thing" — windowed apps below lose zero real
    /// estate because the pill never touches the desktop area. We had
    /// 20pt of bump previously (creating a 19.5pt visible strip below
    /// the bar), which is exactly what made our pill feel too tall.
    static let closedPillBump: CGFloat = 0
    /// Bottom-corner radius for the closed pill silhouette. With
    /// bump=0pt the silhouette's bottom edge sits at the menu-bar
    /// bottom, and the 16pt corner radius makes it taper from the
    /// 259pt full body width down to ~229pt at the bottom — matching
    /// the curvature we measured from Alcove's pill (which tapers
    /// from 258pt at y=20px down to 229pt at y=63px, a ~12-15pt
    /// effective corner radius). Slab uses `innerCornerRadius` (34pt)
    /// instead; the silhouette morphs between the two as the panel
    /// expands. Animatable via SwiftUI's `.smooth` implicit animation
    /// (PanelRootView), matching the literal `smooth` Animation
    /// preset Alcove ships in their binary.
    static let pillCornerRadius: CGFloat = 16
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
    var visibleSilhouetteFrame: NSRect {
        let halo = PanelWindowController.haloPadding
        let f = panel.frame
        return NSRect(
            x: f.minX + halo,
            y: f.minY + halo,
            width: f.width - 2 * halo,
            height: f.height - halo
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

        // Inject each store as its own environment object so SwiftUI
        // only re-renders views that actually depend on the store
        // that mutated. (Used to inject just `environment` and
        // forward all child changes through it, which made a yt-dlp
        // progress tick re-evaluate every view in the panel.)
        let host = NSHostingView(
            rootView: PanelRootView()
                .environmentObject(environment)
                .environmentObject(environment.noteStore)
                .environmentObject(environment.imageStore)
                .environmentObject(environment.videoStore)
                .environmentObject(environment.fileStore)
                .environmentObject(environment.linkPreviewService)
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
                NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
            },
            onTargeted: { [weak presenter] flag in
                presenter?.isDropTargeted = flag
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
            show()
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
        if presenter.nowPlaying != nil {
            presenter.activeTab = .music
        } else {
            // Smart auto-routing — only fires if the clipboard has
            // changed since the last hide(). Avoids the annoying case
            // where the user closes the panel on Notes, switches apps,
            // and reopens the panel only to be teleported off Notes
            // because there's still a stale text payload on the clipboard.
            let currentCount = NSPasteboard.general.changeCount
            if currentCount != lastSeenChangeCount {
                applyAutoRouting()
            }
            lastSeenChangeCount = currentCount
        }

        let screen = NSScreen.main
        let pillFrame = closedPillFrame(for: screen)
        let slabFrame = openSlabFrame(for: screen, tab: presenter.activeTab)

        // Position the panel at its CLOSED-pill geometry BEFORE
        // ordering it front — but only if the panel is not currently
        // visible (i.e. fresh open after a completed close). If a
        // close is still in flight (panel mid-shrink, orderOut not yet
        // fired), DON'T snap it back to the pill frame: that would
        // cause a visible jump. Instead, let `animateOpen`'s animator
        // call take over from the panel's current frame — Core
        // Animation handles the velocity blend smoothly.
        if !panel.isVisible {
            panel.setFrame(pillFrame, display: false)
        }
        panel.alphaValue = 1
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

            hoverLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
                guard let self, self.isVisible, self.openMode == .hover else { return event }
                self.hoverHasEnteredPanel = true
                self.hoverLeaveWorkItem?.cancel()
                self.hoverLeaveWorkItem = nil
                return event
            }

            hoverGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
                guard let self, self.isVisible, self.openMode == .hover else { return }
                guard self.hoverHasEnteredPanel else { return }
                // Belt-and-suspenders frame check — if the location is
                // somehow still inside our rect, don't schedule a hide.
                if self.visibleSilhouetteFrame.contains(NSEvent.mouseLocation) { return }
                if self.hoverLeaveWorkItem != nil { return }
                // 250ms grace period — gives the user time to flick the
                // cursor through a corner and back without triggering
                // dismissal. Shorter felt jumpy in testing; longer
                // started feeling sluggish ("when am I going to be free
                // of this thing").
                let work = DispatchWorkItem { [weak self] in
                    self?.hide()
                }
                self.hoverLeaveWorkItem = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
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

        // Pure-CA close: dive past the pill into a slight undershoot,
        // then recoil up to the resting pill frame. orderOut fires in
        // the recoil completion handler so the panel disappears
        // exactly as the morph settles — no invisible window left in
        // front of clicks, no premature snap-cut mid-shrink.
        let screen = panel.screen ?? NSScreen.main
        let pillFrame = closedPillFrame(for: screen)
        animateClose(to: pillFrame)
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

        let screen = NSScreen.main
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
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
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
    private func applyAutoRouting() {
        let decision = ClipboardRouter.decide()
        NSLog("Notetaker: auto-route decision = \(decision)")
        switch decision {
        case .none:
            return
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
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
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

    // MARK: - Morph frames

    /// Closed-pill frame: a 200pt-wide bump centered horizontally below
    /// the notch, with the upper `notchOverlap` portion sitting BEHIND
    /// the menu bar / notch hardware. Only the bottom `closedPillBump`
    /// (14pt) is visible on screen.
    private func closedPillFrame(for screen: NSScreen?) -> NSRect {
        let frame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let overlap = PanelWindowController.notchOverlap(for: screen)
        let halo = PanelWindowController.haloPadding
        // Inner content is the visible silhouette; outer frame adds halo
        // margin on left/right/bottom so the SwiftUI shadow has room to
        // bleed. Top stays at frame.maxY (anchored to the menu bar — the
        // notch overlap is already baked into the inner height).
        let height = overlap + PanelWindowController.closedPillBump + halo
        let width = PanelWindowController.closedPillWidth + 2 * halo
        return NSRect(
            x: frame.midX - width / 2,
            y: frame.maxY - height,
            width: width,
            height: height
        )
    }

    /// Tease-pill frame: a 220pt-wide, 24pt-bump pre-bloom geometry.
    /// Slightly wider AND taller than the resting closed pill — enough
    /// for the size delta to register as "the notch noticed you" without
    /// reading as a misfired full open. Used during the hover-intent
    /// dwell (see `tease()`).
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

    /// Open-slab frame: the full HUD silhouette for a given tab. Same
    /// upper-edge anchoring as the pill — the top sits at
    /// `screen.frame.maxY` so the notch-overlap portion stays hidden,
    /// and only `innerPanelHeight(for:)` of bump emerges below the
    /// menu bar. Tab-aware because `.music` uses a much shorter slab
    /// (Alcove-style compact HUD) than the grid/list tabs.
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

    private func animateOpen(to target: NSRect) {
        animationGeneration &+= 1
        let myGen = animationGeneration

        // SINGLE-STAGE critically-damped spring morph. The previous
        // two-stage dive/recoil (y2=1.2 overshoot then y2=1.8 recoil)
        // gave the panel a "boingy" personality — easy to feel as
        // out-of-character once you A/B against Alcove. Alcove's
        // binary contains the literal `smooth` Animation preset plus
        // `alignmentSpringDamping` / `alignmentSpringStiffness`
        // symbols — a damping fraction near 1.0 (no perceptible
        // overshoot, just a settled landing). We match that with a
        // single-stage cubic-bezier whose control points approximate
        // SwiftUI's `.smooth(duration: 0.5)`: starts gently, builds
        // momentum through the middle, and decelerates into the
        // target without passing through it.
        //
        // 0.5s aligns with the SwiftUI radius animation (`.smooth` on
        // PanelRootView's body), so the frame and the bottom-corner
        // morph land on the same beat. Both timelines are still
        // independent (NSPanel Core Animation vs SwiftUI implicit
        // animation), matching Alcove's `expandedTransitionTask` /
        // `expandedRadiusTransitionTask` split.
        let duration: TimeInterval = 0.5
        let springCurve = CAMediaTimingFunction(controlPoints: 0.32, 0.72, 0.32, 1.0)

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = duration
            ctx.timingFunction = springCurve
            ctx.allowsImplicitAnimation = true
            self.panel.animator().setFrame(target, display: true)
        }, completionHandler: { [weak self] in
            guard let self, self.animationGeneration == myGen else { return }
            // Snap the frame exactly to target. Core Animation can
            // leave sub-pixel residuals at the end of a long ease;
            // an explicit setFrame fixes that without a visible jump.
            //
            // Note: `presenter.isShown=true` was already flipped at
            // the START of show() (before animateOpen). The content
            // tree is always-mounted (see PanelRootView), so by the
            // time we get here the opacity fade has already run to
            // completion alongside the morph — nothing left to do.
            self.panel.setFrame(target, display: true)
        })
    }

    private func animateClose(to target: NSRect) {
        animationGeneration &+= 1
        let myGen = animationGeneration

        // 2pt undershoot in width and height — mirror image of the
        // open dive. The frame is anchored at the top (the upper
        // notch-overlap portion stays hidden behind the menu bar), so
        // shrinking means smaller width AND smaller height with `y`
        // moving UP (larger minY) to keep the top edge pinned.
        let undershoot: CGFloat = 2
        let underFrame = NSRect(
            x: target.minX + undershoot / 2,
            y: target.minY + undershoot,
            width: target.width - undershoot,
            height: target.height - undershoot
        )

        // Close is faster than open. ComfyNotch uses 0.20s + 0.15s
        // (we mirror that). Dynamic Island's collapse is also visibly
        // tighter than its bloom — a slow close reads as "panel
        // dragging its feet" once the user has decided to dismiss.
        let diveDuration: TimeInterval = 0.20
        let recoilDuration: TimeInterval = 0.15
        // Close curves emphasize ease-out without overshoot — the
        // panel should "snap back into the notch," not bounce.
        let diveCurve = CAMediaTimingFunction(controlPoints: 0.65, 1.0, 0.5, 1.0)
        let recoilCurve = CAMediaTimingFunction(controlPoints: 0.75, 1.0, 0.8, 1.0)

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = diveDuration
            ctx.timingFunction = diveCurve
            ctx.allowsImplicitAnimation = true
            self.panel.animator().setFrame(underFrame, display: true)
        }, completionHandler: { [weak self] in
            guard let self, self.animationGeneration == myGen else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = recoilDuration
                ctx.timingFunction = recoilCurve
                ctx.allowsImplicitAnimation = true
                self.panel.animator().setFrame(target, display: true)
            }, completionHandler: { [weak self] in
                guard let self, self.animationGeneration == myGen else { return }
                // Settle exactly at target — Core Animation can leave
                // sub-pixel residuals after a recoil; an explicit
                // setFrame fixes that without a visible jump.
                self.panel.setFrame(target, display: true)
                // RESTING mode: panel stays on screen at closedFrame
                // as the persistent now-playing pill. orderOut would
                // dismiss the always-on indicator, which is exactly
                // the contract the user described ("the pill should
                // be always there"). The shown↔resting transition is
                // pure frame morph — no window lifecycle change.
                //
                // Non-resting (music has stopped, or panel was opened
                // standalone via ⌥Space): orderOut so we don't leave
                // an invisible window intercepting clicks.
                if !self.presenter.isResting {
                    self.panel.orderOut(nil)
                }
            })
        })
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
        if isTeasing { return }   // tease in flight → its completion handles orderOut

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
