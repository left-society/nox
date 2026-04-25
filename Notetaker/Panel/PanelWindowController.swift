import AppKit
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
    /// `originUnderNotch` back down by `safeAreaInsets.top` (~37pt),
    /// and the panel renders as a floating block in the middle of the
    /// screen instead of bleeding out of the notch.
    ///
    /// Returning the rect unchanged hands frame ownership entirely to
    /// us — the cost is that we're responsible for keeping the panel
    /// somewhere reasonable on screen, which we already do via
    /// `originUnderNotch(for:)`.
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
    /// Distance from the inner panel to the outer NSPanel edges on the
    /// left, top, and bottom. The halo mask blur (see PanelRootView)
    /// has to fully fade to alpha 0 within this distance — otherwise the
    /// rectangular outer NSPanel boundary clips a still-non-zero halo
    /// and the user sees a boxy edge. 100pt gives a 70pt mask blur ~30pt
    /// of slack to fade cleanly.
    static let haloPadding: CGFloat = 100
    /// Corner radius of the inner glass panel itself. Tuned through
    /// 20 → 28 → 34: the latest bump pushes us into squircle territory
    /// (radius/min-side ≈ 0.09 at 380pt width) so the bottom corners
    /// read as a smooth continuous curve instead of a clipped arc.
    /// This is the same proportion Apple uses on the Dynamic Island
    /// expanded card on iPhone — the visual cue users associate most
    /// strongly with "notch HUD" surfaces.
    static let innerCornerRadius: CGFloat = 34
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

    private let panel: NSPanel
    private let presenter: PanelPresenter
    private let environment: AppEnvironment
    private(set) var isVisible = false
    private var openMode: OpenMode = .click
    private var clickOutsideMonitor: Any?
    private var keyMonitor: Any?
    private var globalKeyMonitor: Any?
    private var quickPasteMonitor: Any?
    private var hoverGlobalMonitor: Any?
    private var hoverLocalMonitor: Any?
    private var hoverHasEnteredPanel = false
    private var hoverLeaveWorkItem: DispatchWorkItem?
    private var hideWorkItem: DispatchWorkItem?
    /// `NSPasteboard.general.changeCount` captured at the last hide().
    /// Initialized to -1 so the very first show() always evaluates the
    /// clipboard. Updated on every hide() so we only re-route when
    /// the user has actually copied something new in between.
    private var lastSeenChangeCount: Int = -1

    weak var menuBarController: MenuBarController?

    init(environment: AppEnvironment) {
        self.environment = environment
        let presenter = PanelPresenter()
        self.presenter = presenter
        let size = PanelWindowController.panelSize(for: NSScreen.main)
        let contentRect = NSRect(origin: .zero, size: size)

        panel = KeyablePanel(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
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
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
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
        openMode = mode
        hideWorkItem?.cancel()
        hideWorkItem = nil

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

        let size = PanelWindowController.panelSize(for: NSScreen.main)
        panel.setContentSize(size)
        panel.setFrameOrigin(originUnderNotch(for: size))
        panel.alphaValue = 1
        presenter.isShown = false
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
        NSLog("Notetaker: show() panel.frame=\(panel.frame) main=\(NSScreen.main?.frame ?? .zero) screens=\(screens)")

        // Hold the pill state for ~50ms BEFORE flipping isShown.
        // Without a hold the pill shows for a single runloop tick and
        // the user just sees a slab drop into place; the "emerging
        // from the notch" cue is lost. 50ms (≈ 6 frames at 120Hz) is
        // the minimum that still registers as a deliberate two-stage
        // bloom. Earlier 90ms felt like an artificial delay before
        // the panel responded.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.presenter.isShown = true
        }
        isVisible = true

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
            if self.panel.frame.contains(event.locationInWindow) {
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
                if self.panel.frame.contains(NSEvent.mouseLocation) { return }
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
        presenter.isShown = false
        isVisible = false

        let item = DispatchWorkItem { [weak self] in
            self?.panel.orderOut(nil)
        }
        hideWorkItem = item
        // 0.36s matches the close spring (.spring(response: 0.32,
        // dampingFraction: 0.94)) — close finishes ~4 frames after
        // the spring's nominal response time. Yanking earlier shows
        // a snap-cut as the panel disappears mid-collapse; waiting
        // longer leaves an invisible window in front of clicks for
        // no visual benefit.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.36, execute: item)
    }

    /// ⌘N quick paste — copies the Nth visible item of the currently
    /// active tab to the system clipboard, then hides the panel after
    /// a brief beat so the user can paste with ⌘V wherever they were
    /// typing. Returns true iff the index resolved to a real item; if
    /// false, the local-monitor closure passes the event through.
    @discardableResult
    private func handleQuickPaste(index: Int) -> Bool {
        switch presenter.activeTab {
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

    private func originOnRightEdge(for size: NSSize) -> NSPoint {
        let screen = NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        // Right edge of the OUTER panel lands at the same gap from the
        // screen edge as before — the inner panel is anchored trailing
        // and stays at exactly the same screen position. The y origin
        // shifts up by `haloPadding` so the inner panel's TOP also stays
        // put; only the halo zone extends further upward (within the
        // visibleFrame, which excludes the menu bar).
        let x = visible.maxX - size.width - PanelWindowController.edgeGap
        let y = visible.maxY - size.height
            - PanelWindowController.topGap
            + PanelWindowController.haloPadding
        return NSPoint(x: x, y: y)
    }

    /// True Alcove placement: NSPanel TOP at the SCREEN top (frame.maxY),
    /// not the menu-bar bottom. The upper `safeAreaInsets.top` portion
    /// of the panel sits ABOVE the menu bar — physically hidden behind
    /// the notch hardware and the menu bar strip. SwiftUI offsets the
    /// content downward by the same amount so the header, tabs, and
    /// grid still appear below the menu bar. Net effect: the visible
    /// silhouette starts INSIDE the notch and grows DOWN from there,
    /// instead of dropping out from below the menu bar.
    private func originUnderNotch(for size: NSSize) -> NSPoint {
        let screen = NSScreen.main
        let frame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let x = frame.midX - size.width / 2
        // panel.frame.y is the NSPanel's BOTTOM in screen coords; we want
        // its TOP at frame.maxY (the very top of the display). Top = y +
        // size.height, so y = frame.maxY - size.height.
        let y = frame.maxY - size.height
        return NSPoint(x: x, y: y)
    }
}
