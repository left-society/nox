import AppKit
import SwiftUI
import Combine

/// Lock-screen notch indicator. A small pill-shaped panel that
/// hangs from the notch hardware while the screen is locked, with
/// a lock glyph + "Locked" label. Tapping it triggers a shake
/// animation — the "you can't do anything until you unlock" cue
/// the user pointed out from Alcove (2026-05-06).
///
/// Architecture parallels `LockMusicCardWindowController`:
///   • Separate NSPanel attached to the same SkyLight level-400
///     space as the music card, so it survives the lock-screen
///     compositor filter via `canBecomeVisibleWithoutLogin = true`.
///   • Eager-create at app start, kept alive across lock cycles.
///   • Combine-bound to `presenter.$isLocked` for show/hide.
///
/// Why a separate panel instead of merging with LockMusicCardWindow:
///   1. The two pieces sit in different parts of the screen (notch
///      area vs center-bottom). One window covering both would need
///      a giant frame mostly full of transparent pixels — wasteful.
///   2. Show conditions differ slightly: the music card waits for
///      now-playing data, the notch indicator should appear the
///      instant the lock fires.
///   3. Independent z-order / hit-testing — the notch indicator
///      shouldn't accidentally block clicks meant for the music
///      card or vice-versa.
private final class LockNotchIndicatorPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class LockNotchHostingView<Content: View>: NSHostingView<Content> {
    /// Same `acceptsFirstMouse` trick the music card uses — without
    /// this the very first tap after lock-screen render is consumed
    /// as a "make-key" event and the SwiftUI tap recognizer never
    /// sees it. With it, taps work cleanly the moment the panel
    /// becomes visible.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Closure forwarded from the SwiftUI view's hover state. Set
    /// by the controller after the host is constructed. Fires on
    /// every mouse-entered / mouse-exited delivered to the
    /// explicit NSTrackingArea below.
    var onHoverChange: ((Bool) -> Void)?

    private var trackingArea: NSTrackingArea?

    /// Re-register the tracking area whenever the view's bounds
    /// change. Without this the tracking rect stays at the old
    /// size after a frame change and hover detection breaks.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        // `.activeAlways` is the critical option: tracking areas
        // default to `.activeInKeyWindow`, which means they only
        // fire when the host window is the key window. On lock
        // screen our panel is NOT key (loginwindow is), so the
        // default would silently drop every mouse-moved event.
        // `.activeAlways` removes that gate so tracking fires
        // regardless of key state. SwiftUI's built-in `.onHover`
        // doesn't expose this option and registers tracking areas
        // with the default `.activeInKeyWindow` — which is why
        // hover never fired on the lock pill before this fix.
        let options: NSTrackingArea.Options = [
            .mouseEnteredAndExited,
            .activeAlways,
            .inVisibleRect
        ]
        let area = NSTrackingArea(
            rect: .zero,  // ignored when `.inVisibleRect` is set
            options: options,
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        DictationOrchestrator.dlog("🖱️ LockNotchIndicator NSTrackingArea ENTER")
        onHoverChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        DictationOrchestrator.dlog("🖱️ LockNotchIndicator NSTrackingArea EXIT")
        onHoverChange?(false)
    }
}

/// Bridge object — bound to the SwiftUI view via @ObservedObject
/// so the NSView's mouse-entered/exited callbacks can drive
/// SwiftUI state without going through SwiftUI's broken `.onHover`
/// path. Lives on the controller, passed into the SwiftUI view.
final class LockHoverState: ObservableObject {
    @Published var isHovering: Bool = false
}

@MainActor
final class LockNotchIndicatorController {
    private let panel: LockNotchIndicatorPanel
    let presenter: PanelPresenter
    private var cancellables = Set<AnyCancellable>()
    private var hasAttachedToSpace = false
    /// Drives the SwiftUI pill's hover state from the host view's
    /// explicit NSTrackingArea callbacks.
    private let hoverState = LockHoverState()

    init(presenter: PanelPresenter) {
        self.presenter = presenter

        // 2026-05-06 (rev 2): user feedback "lock should visually
        // be in the small pill, just like music pill." The
        // previous 140×30 pill with text was too chunky and read
        // as a separate UI element. Sizing now matches the
        // desktop alcove resting pill (220×20, locked dimensions
        // per memory) — same silhouette as the music pill the
        // user already sees on desktop, so the lock state reads
        // as "the pill, but in lock state" rather than a foreign
        // notification chip. Glyph-only inside (no "Locked" text);
        // the visual is the entire message.
        let initialFrame = NSRect(x: 0, y: 0, width: 220, height: 20)
        self.panel = LockNotchIndicatorPanel(
            contentRect: initialFrame,
            styleMask: [
                .borderless,
                .nonactivatingPanel,
                .fullSizeContentView,
                .hudWindow,
                .utilityWindow
            ],
            backing: .buffered,
            defer: false
        )

        panel.isFloatingPanel = true
        // Same level as the music card so they stack predictably
        // during lock screen render. popUpMenu sits above the
        // menu bar zone where the notch hardware lives.
        panel.level = .popUpMenu
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle
        ]
        // CRITICAL — this is the property that lets WindowServer
        // composite us on the lock-screen surface. Without it the
        // `loginwindow` filter rejects our window even though it's
        // in the level-400 SkyLight space. Same flag the music
        // card sets (LockMusicCardWindow.swift:95).
        panel.canBecomeVisibleWithoutLogin = true
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.hasShadow = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hidesOnDeactivate = false
        panel.acceptsMouseMovedEvents = true
        ScreenSharingPolicy.apply(to: panel)

        let host = LockNotchHostingView(
            rootView: LockNotchIndicatorView(hoverState: hoverState)
        )
        // Forward NSTrackingArea hover events into the bound
        // ObservableObject so the SwiftUI view re-renders.
        host.onHoverChange = { [weak hoverState] hovering in
            hoverState?.isHovering = hovering
        }
        host.frame = initialFrame
        host.autoresizingMask = [.width, .height]
        host.translatesAutoresizingMaskIntoConstraints = true
        panel.contentView = host

        bindToPresenter()
    }

    /// Subscribe to `presenter.$isLocked` and toggle visibility.
    /// `.removeDuplicates()` because @Published emits on every
    /// assignment regardless of equality — without dedup, every
    /// re-publish would re-run the show/hide animation.
    private func bindToPresenter() {
        presenter.$isLocked
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] locked in
                self?.refreshVisibility(locked: locked)
            }
            .store(in: &cancellables)
    }

    private func refreshVisibility(locked: Bool) {
        if locked {
            positionAtNotch()
            attachToSpaceIfNeeded()
            DictationOrchestrator.dlog("🔒 LockNotchIndicator SHOW frame=\(panel.frame) windowNumber=\(panel.windowNumber) level=\(panel.level.rawValue) canBecomeKey=\(panel.canBecomeKey) acceptsMouseMoved=\(panel.acceptsMouseMovedEvents)")
            if !panel.isVisible || panel.alphaValue < 1 {
                panel.alphaValue = 0
                panel.orderFrontRegardless()
                // 2026-05-06: REMOVED `panel.makeKey()`. The music
                // card's lock pill works WITHOUT it, and the user
                // reported clicks/hover stopped responding right
                // after I added it. On lock screen the active app
                // is `loginwindow`; calling makeKey from a third-
                // party panel can fight with that and end up
                // breaking event delivery rather than enabling it.
                // Match the music card pattern: just orderFront
                // and rely on the panel's `acceptsMouseMovedEvents`
                // + the hosting view's `acceptsFirstMouse` for
                // event routing.
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.32
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    panel.animator().alphaValue = 1
                }
            }
        } else {
            guard panel.isVisible else { return }
            DictationOrchestrator.dlog("🔓 LockNotchIndicator HIDE")
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.32
                ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                panel.animator().alphaValue = 0
            }, completionHandler: { [weak panel] in
                panel?.orderOut(nil)
            })
        }
    }

    /// 2026-05-06 (rev 6): EXACT match for the desktop music pill.
    /// Pulled the real value from `PanelWindowController.closedPillWidth`
    /// — it's **278pt**, not 220pt (the 220 came from a stale
    /// memory entry that didn't reflect the current code). Pill
    /// height matches the menu-bar / notch zone exactly
    /// (`notchOverlap`), so the lock pill is the SAME shape and
    /// SAME size as the music pill the user sees on desktop.
    ///
    /// Width 278 centered on the notch midX → 46.5pt of visible
    /// pill flanking each side of the 185pt notch hardware. The
    /// notch hardware physically occludes the middle of the pill
    /// (just like it does for the music pill), so what the user
    /// sees is two arc-end portions of the pill emerging from
    /// each side of the notch — the canonical alcove silhouette.
    private func positionAtNotch() {
        guard let screen = NSScreen.main else { return }
        let frame = screen.frame
        // Pulled directly from PanelWindowController.closedPillWidth
        // (line 165). This is the SAME width the desktop music pill
        // uses. Don't hand-set it.
        let pillWidth = PanelWindowController.closedPillWidth  // 278pt

        // Notch midX — match the actual hardware cutout, not
        // screen midX (which can differ by 0.5-1pt on some
        // hardware revisions).
        let notchMidX: CGFloat
        if let leftArea = screen.auxiliaryTopLeftArea,
           let rightArea = screen.auxiliaryTopRightArea {
            notchMidX = (leftArea.maxX + rightArea.minX) / 2
        } else {
            notchMidX = frame.midX
        }

        let notchHeight = screen.safeAreaInsets.top > 0
            ? screen.safeAreaInsets.top
            : 24  // fallback for non-notched: standard menu bar

        let x = notchMidX - pillWidth / 2
        // Window spans the menu-bar / notch zone exactly:
        //   • top edge at frame.maxY (top of screen, behind notch)
        //   • height = notchOverlap (the menu-bar zone height)
        // The middle ~185pt of pill is occluded by the physical
        // notch cutout. The visible left + right strips flank
        // the notch — same silhouette as the desktop music pill.
        let y = frame.maxY - notchHeight
        panel.setFrame(
            NSRect(x: x, y: y, width: pillWidth, height: notchHeight),
            display: false
        )
    }

    private func attachToSpaceIfNeeded() {
        guard !hasAttachedToSpace else { return }
        NotchSpaceManager.shared?.attach(panel)
        hasAttachedToSpace = true
    }
}

// MARK: - SwiftUI content

/// The lock pill. Uses the SAME `OutwardFlaredShape` the desktop
/// resting alcove pill uses — inverse-bow top shoulders that
/// "tuck under" the menu bar at the notch edges + 8pt rounded
/// bottom corners. Capsule is wrong here: alcove pills don't have
/// symmetric oval ends; they have a flat top with subtle inverse-
/// bow shoulders that fuse with the menu-bar zone.
///
/// Radii pulled from PanelRootView's resting-pill values (line
/// 326 / 314): topFlareRadius = 6, bottomCornerRadius = 8.
/// `pillCornerRadius` is `PanelWindowController.pillCornerRadius`
/// (= 8pt), referenced through the public type.
private struct LockNotchIndicatorView: View {
    /// Hover state — driven externally by the host view's
    /// NSTrackingArea (NOT SwiftUI's broken-on-lock-screen
    /// `.onHover`). Updated through `LockHoverState.isHovering`.
    @ObservedObject var hoverState: LockHoverState

    /// Scale-pulse driver. Tap → drops to 0.96, then springs back
    /// to 1.0 with a bouncy 320ms response. Anchored at .top so
    /// the pill stays glued to the notch.
    @State private var isPressed: Bool = false
    /// Press-glow opacity. Brief glyph brightening on tap, fades
    /// over 420ms.
    @State private var glowOpacity: CGFloat = 0

    /// EXACT alcove silhouette — same shape struct + same radii
    /// the desktop resting pill renders with.
    private var alcoveShape: OutwardFlaredShape {
        OutwardFlaredShape(
            topFlareRadius: 6,
            bottomCornerRadius: PanelWindowController.pillCornerRadius
        )
    }

    /// Glyph opacity — base 85%, hover bump +8%, press bump +15%.
    /// (No more border / stroke — user reported the faint white
    /// outline as visible on lock-screen wallpapers. Pill is now
    /// pure black with no border at all.)
    private var glyphOpacity: CGFloat {
        var v: CGFloat = 0.85
        if hoverState.isHovering { v += 0.08 }
        v += glowOpacity * 0.15
        return min(v, 1.0)
    }

    var body: some View {
        ZStack {
            // Pure black silhouette, NO stroke / border. The
            // alcove pill on desktop has a hairline stroke for
            // separation against the wallpaper but on lock
            // screen the user wants the pill to merge cleanly
            // into the notch zone — no white edge.
            alcoveShape
                .fill(Color.black)

            // Lock icon at the LEFT visible strip — mirrors the
            // album-art position in the music pill. With a 278pt
            // pill centered on a 185pt notch, the left visible
            // strip is ~46.5pt wide. ~14pt leading inset centers
            // the glyph inside that strip.
            HStack {
                Image(systemName: "lock.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(glyphOpacity))
                    .padding(.leading, 14)
                Spacer()
            }
        }
        // Scale-pulse + spring-back. Anchor at .top keeps the pill
        // glued to the notch.
        .scaleEffect(isPressed ? 0.96 : 1.0, anchor: .top)
        .animation(NoxAnimations.quickAnticipation,
                   value: isPressed)
        .animation(.easeOut(duration: 0.18), value: hoverState.isHovering)
        .animation(.easeOut(duration: 0.42), value: glowOpacity)
        .contentShape(Rectangle())
        .onTapGesture {
            DictationOrchestrator.dlog("🖱️ LockNotchIndicator TAP")
            isPressed = true
            glowOpacity = 1
            HapticFeedback.alignment()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                isPressed = false
                glowOpacity = 0
            }
        }
    }
}
