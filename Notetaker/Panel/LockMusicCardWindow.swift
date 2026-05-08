import AppKit
import SwiftUI
import Combine

/// Lock-screen music card. A second NSPanel positioned center-bottom
/// of the screen, drawing the now-playing artwork + scrubber +
/// transport controls. Visible only when the session is locked AND
/// `presenter.nowPlaying` is non-nil.
///
/// Architecture: separate NSPanel from the main notch panel, but
/// attached to the same `NotchSpaceManager` SkyLight space so it
/// renders on the lock-screen surface (same compositor pool Apple's
/// Now Playing widget uses). Eager-created at app start, kept
/// alive across lock/unlock cycles — we just `orderFront` /
/// `orderOut` based on state. No teardown/recreate per cycle.
///
/// Privacy: the card content is the same data that the system's
/// own Now Playing widget would show. No personal info from
/// Notetaker (notes, screenshots, files) ever leaks here.
/// Custom NSPanel for the lock-screen music card. Three overrides
/// matter for it to actually work on lock:
///
///   • `canBecomeVisibleWithoutLogin = true` (set in init): the
///     property that tells WindowServer this window is allowed on
///     the lock-screen surface. Without this, even with a custom
///     SkyLight space attachment, the system filters us out.
///     Confirmed in mew-notch's MewPanel and Apple's NSPanel docs.
///   • `canBecomeKey = true`: lets the panel become the key window
///     so SwiftUI Button taps deliver. NSPanel default is false.
///   • `acceptsFirstMouse(for:) = true` (on the hosting view, via
///     `LockCardHostingView` below): without this, the first click
///     after the panel comes onscreen is consumed as a "make key"
///     event and SwiftUI never sees it. Same trick our main panel
///     uses (`ClickThroughHostingView`).
private final class LockMusicCardPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class LockCardHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class LockMusicCardWindowController {
    private let panel: LockMusicCardPanel
    let presenter: PanelPresenter
    private var cancellables = Set<AnyCancellable>()
    private var hasAttachedToSpace = false

    /// Closure that handles button taps. AppDelegate wires this to
    /// the orchestrator's `sendMediaCommand` so play / pause /
    /// skip drive the underlying media app.
    var onMediaCommand: ((MediaRemoteService.Command) -> Void)?

    /// Closure invoked when the user taps the artwork — typically
    /// "open the source app" (jump to YouTube tab, focus Spotify).
    /// Wired to `orchestrator.openSourceApp`.
    var onOpenSourceApp: (() -> Void)?

    init(presenter: PanelPresenter) {
        self.presenter = presenter

        // 2026-05-06 (rev 3): user said the previous state was
        // better and asked for SMALLER + HIGHER on the lock
        // screen. Reverting from 520×190 → 380×140 (smaller than
        // even the original 420×160), and y-anchor moves up to
        // 0.22 in `positionForLockScreen()`. The card no longer
        // tries to match Alcove's exact size — the user prefers
        // a more compact card sitting higher above the password
        // prompt.
        let initialFrame = NSRect(x: 0, y: 0, width: 380, height: 140)
        self.panel = LockMusicCardPanel(
            contentRect: initialFrame,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView, .hudWindow, .utilityWindow],
            backing: .buffered,
            defer: false
        )

        // Window setup: transparent background, no shadow (we draw
        // our own via the SwiftUI material), floating to ride
        // above other windows on desktop. The SkyLight space attach
        // (below) is what makes it visible on lock screen.
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle
        ]
        // **Lock-screen visibility flag.** This is the property
        // that gives WindowServer permission to draw the window
        // on the lock-screen surface. Without it, even a window
        // attached to the right SkyLight space gets filtered out
        // by `loginwindow`'s allowlist. Decoded from mew-notch's
        // MewPanel — the missing piece for lock-screen rendering.
        panel.canBecomeVisibleWithoutLogin = true
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isMovableByWindowBackground = false
        panel.isMovable = false
        panel.hasShadow = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hidesOnDeactivate = false
        ScreenSharingPolicy.apply(to: panel)
        // Mouse moved events — required so SwiftUI knows the
        // cursor is over a button before clicking. Default is
        // false on NSPanel; without it, hover state never fires
        // and clicks may not register cleanly on lock.
        panel.acceptsMouseMovedEvents = true

        // SwiftUI content. The custom hosting view returns true
        // from `acceptsFirstMouse(for:)` so the very first click
        // (when the panel becomes active on lock) is delivered
        // straight to SwiftUI — not consumed as a "make key"
        // activation event. Same trick the main notch panel uses.
        let weakBox = WeakBox()
        weakBox.target = self
        let host = LockCardHostingView(
            rootView: LockMusicCardView(
                presenter: presenter,
                onCommand: { cmd in weakBox.target?.onMediaCommand?(cmd) },
                onArtworkTap: { weakBox.target?.onOpenSourceApp?() }
            )
        )
        host.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = host

        // React to lock + nowPlaying state changes. Show whenever
        // BOTH (a) screen is locked AND (b) something is playing.
        // Otherwise hide.
        //
        // Subscribe to presenter.$nowPlaying as a whole (not just
        // .map { title }) so we react to ANY change in the
        // now-playing state — including the nil transition that
        // signals music stopped. The earlier title-only mapping
        // could miss nil transitions when the title happens to
        // match the previous one (rare but real), leaving the
        // card stuck on screen.
        // Per BUG-082 mitigation: chain `.removeDuplicates()` so
        // byte-identical re-emissions from MediaRemoteService
        // don't churn this subscription's `refreshVisibility`
        // path. MediaRemoteService dedups before forwarding,
        // but the @Published publisher emits on every assignment
        // regardless — `.removeDuplicates()` here belt-and-
        // braces it.
        Publishers.CombineLatest(
            presenter.$isLocked.removeDuplicates(),
            presenter.$nowPlaying.removeDuplicates()
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] locked, info in
            self?.refreshVisibility(locked: locked, info: info)
        }
        .store(in: &cancellables)
    }

    /// Show or hide the card based on current state. Idempotent.
    /// Takes the latest `info` directly from the publisher rather
    /// than re-reading `presenter.nowPlaying` — guarantees we
    /// react to the exact state that triggered this refresh, no
    /// race against a same-tick second update.
    ///
    /// 2026-05-02: ALWAYS show on lock screen (info nil → lock-only
    /// minimal pill). Earlier the gate was `locked && info != nil`,
    /// so when nothing was playing the lock screen had no nox UI at
    /// all — meaning the user couldn't see the lock-pill / shake-to-
    /// hint affordance they asked for.
    ///
    /// Also: show/hide is now animated (0.30s ease) instead of a
    /// hard `orderOut(nil)`. The user reported "glitches instead of
    /// fading away with the lock screen" — that was the instant
    /// `orderOut` on the `screenIsUnlocked` edge popping the panel
    /// off in one frame while the lock-screen surface itself was
    /// still cross-fading. Animating alphaValue lets the card melt
    /// out in sync with the lock-screen dissolve.
    private func refreshVisibility(locked: Bool, info: NowPlayingInfo?) {
        let shouldShow = locked  // always-on while locked
        if shouldShow {
            positionForLockScreen()
            attachToSpaceIfNeeded()
            // Show with a fade. If already visible alphaValue is
            // already 1 — the runAnimationGroup is a no-op then.
            if !panel.isVisible || panel.alphaValue < 1 {
                panel.alphaValue = 0
                panel.orderFrontRegardless()
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.32
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    panel.animator().alphaValue = 1
                }
            }
        } else {
            // Fade out, then orderOut. If already hidden this is a
            // no-op (alpha 0, orderOut is idempotent).
            guard panel.isVisible else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.32
                ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                panel.animator().alphaValue = 0
            }, completionHandler: { [weak panel] in
                panel?.orderOut(nil)
            })
        }
    }

    /// Center the card horizontally and position it at the lock-
    /// screen card y-coordinate (about 60% down the screen, where
    /// macOS's own widget area sits).
    private func positionForLockScreen() {
        guard let screen = NSScreen.main else { return }
        let frame = screen.frame
        let cardWidth: CGFloat = 380
        let cardHeight: CGFloat = 140
        let x = frame.midX - cardWidth / 2
        // 18% from the bottom — empirically matches Alcove's card
        // placement (it sits clearly above the password prompt
        // with breathing room, not centered).
        // 2026-05-06 (rev 3): y-anchor moved UP to 0.22. User asked
        // to "move the music card above" after the 0.12 attempt
        // sat too close to the password prompt. With cardHeight
        // 140 on a 1080-tall display, 0.22 puts the card BOTTOM at
        // ~22% above screen bottom — clearly above the password
        // area but still in the lower-middle band where lock-screen
        // glance content typically sits.
        let y = frame.minY + frame.height * 0.22
        panel.setFrame(
            NSRect(x: x, y: y, width: cardWidth, height: cardHeight),
            display: false
        )
    }

    /// Add the card window to the SkyLight space at level 400 so
    /// it's visible on the lock-screen compositor. Done once on
    /// first show — `attach` is idempotent on the SkyLight side
    /// but the call itself does work, so we gate it.
    private func attachToSpaceIfNeeded() {
        guard !hasAttachedToSpace else { return }
        NotchSpaceManager.shared?.attach(panel)
        hasAttachedToSpace = true
    }

    /// Weak-box so the SwiftUI view can call back into the
    /// controller without creating a retain cycle through the
    /// hosting view.
    private final class WeakBox {
        weak var target: LockMusicCardWindowController?
    }
}

// MARK: - SwiftUI view

/// The actual card content. Layout (top to bottom):
///   1. Header row: artwork tile (left) + title/artist (center) +
///      audio waveform indicator (right)
///   2. Progress slider: thin track + filled portion + timestamps
///   3. Transport row: shuffle / prev / play-pause / next / AirPlay
struct LockMusicCardView: View {
    @ObservedObject var presenter: PanelPresenter
    let onCommand: (MediaRemoteService.Command) -> Void
    let onArtworkTap: () -> Void

    /// Live, recomputed-every-tick playhead position. We can't bind
    /// directly to `presenter.nowPlaying.elapsedTime` because that's
    /// just the snapshot value at the moment MediaRemote published —
    /// it doesn't tick on its own. mew-notch's pattern (and Apple's):
    /// drive a `Timer` that recomputes elapsed = snapshot.elapsed +
    /// (now - snapshot.timestamp) every 0.5s while playing.
    @State private var livePosition: TimeInterval = 0
    @State private var positionTimer: Timer?

    /// Card frame in screen coordinates — must match exactly what
    /// `LockMusicCardWindowController.positionForLockScreen()`
    /// computes, since `WallpaperBackdrop` uses this to align the
    /// loaded wallpaper image with what would actually be behind
    /// the card on screen. Read fresh on each render so it picks
    /// up the right `NSScreen` if the user changed displays.
    ///
    /// 2026-05-08 audit H6: y-anchor was 0.18 but the controller's
    /// positionForLockScreen() was bumped to 0.22 in 2026-05-06.
    /// The 4% offset (~43pt at 1080p) made the wallpaper backdrop
    /// sample the wrong region — the lens refracted displaced
    /// pixels behind the card. Synced to 0.22.
    private var cardScreenFrame: NSRect {
        guard let screen = NSScreen.main else { return .zero }
        let cardWidth: CGFloat = 380
        let cardHeight: CGFloat = 140
        let x = screen.frame.midX - cardWidth / 2
        let y = screen.frame.minY + screen.frame.height * 0.22
        return NSRect(x: x, y: y, width: cardWidth, height: cardHeight)
    }

    var body: some View {
        let cardShape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        return cardContent
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(width: 380, height: 140)
            .background {
                // Real Liquid Glass via wallpaper-image backdrop.
                //
                // We hit a wall trying to apply `.layerEffect()`
                // shaders on top of `NSVisualEffectView` —
                // NSVisualEffectView uses WindowServer-level
                // backdrop compositing (not a normal raster
                // framebuffer), so SwiftUI shaders can't sample
                // its output. The shader sees garbage and
                // produces visual artifacts.
                //
                // The fix: load the user's current wallpaper
                // FILE directly via `WallpaperBackdrop` (which
                // uses `NSWorkspace.desktopImageURL` — public
                // API, no permission prompts), render it as a
                // normal SwiftUI Image positioned to match the
                // screen region behind the card, and apply our
                // Metal liquid-glass shader to that. The shader
                // CAN sample a normal Image, so the
                // displacement (lensing) + chromatic aberration
                // actually render. The `.menu` material on top
                // at low opacity gives the frosted softness
                // and live wallpaper-tint that the static
                // wallpaper image alone wouldn't.
                ZStack {
                    // 2026-05-06 (rev 5): tiered glass strategy.
                    //
                    // macOS 26+ → Apple's native Liquid Glass
                    //   (`glassEffect(.regular, in: shape)`,
                    //   introduced WWDC25 session 219). One
                    //   modifier; uses the system's real lensing
                    //   + adaptive tinting + specular pipeline.
                    //   No backport exists, so anything older
                    //   gets the custom path below.
                    //
                    // macOS 13–25 → our custom Metal pipeline
                    //   (wallpaper sampled directly from disk
                    //   via NSWorkspace.desktopImageURL → blur
                    //   for frosted softness → liquidGlass
                    //   shader for edge refraction → clipShape).
                    //   Wallpaper-direct sampling is the ONLY
                    //   approach that survives the lock-screen
                    //   compositor — `NSVisualEffectView` and
                    //   `CABackdropLayer` both go black there.
                    //
                    // Both branches end with the same hairline
                    // stroke for silhouette definition.
                    if #available(macOS 26.0, *) {
                        Color.clear
                            .glassEffect(.regular, in: cardShape)
                    } else {
                        WallpaperBackdrop(cardScreenFrame: cardScreenFrame)
                            .blur(radius: 22)
                            .liquidGlass(strength: 22, aberration: 6)
                            .clipShape(cardShape)
                    }
                    cardShape
                        .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
                }
                // No forced colorScheme — let it adapt. The card's
                // text + controls are explicitly white, so dark
                // mode is the right default; light mode would make
                // the white text disappear against light wallpapers.
            }
        .onAppear { startPositionTimer() }
        .onDisappear { stopPositionTimer() }
        .onChange(of: presenter.nowPlaying?.title) { _ in
            updateLivePosition()
        }
        .onChange(of: presenter.nowPlaying?.isPlaying) { _ in
            updateLivePosition()
            // Restart the timer so the playing-state change takes
            // effect immediately (timer only ticks when playing).
            startPositionTimer()
        }
    }

    // MARK: - Live position timer

    private func startPositionTimer() {
        stopPositionTimer()
        updateLivePosition()
        // 0.5s tick — same cadence mew-notch uses. Fast enough that
        // the bar reads as continuously moving, slow enough that
        // we're not burning CPU on 60Hz updates for a 3-minute song.
        positionTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            updateLivePosition()
        }
    }

    private func stopPositionTimer() {
        positionTimer?.invalidate()
        positionTimer = nil
    }

    private func updateLivePosition() {
        guard let info = presenter.nowPlaying else {
            livePosition = 0
            return
        }
        livePosition = info.currentPosition() ?? info.elapsedTime ?? 0
    }

    /// Shake animation amplitude — sin-based horizontal nudge that
    /// mimics iOS's "wrong password" wiggle on the lock screen.
    /// Bumped on every click of the lock-only pill so the user gets
    /// a tactile "tap me again, but actually unlock first" cue.
    @State private var shakeAmount: CGFloat = 0

    @ViewBuilder
    private var cardContent: some View {
        // When something is playing, render the full music card.
        // When the lock screen is up but nothing is playing, render
        // a minimal lock-only pill (lock glyph + "Locked" label)
        // that shakes when clicked — same affordance as iOS uses
        // for the password field. The user explicitly asked for
        // both behaviors.
        if presenter.nowPlaying != nil {
            VStack(spacing: 10) {
                headerRow
                progressRow
                transportRow
            }
        } else {
            lockOnlyContent
                .modifier(ShakeEffect(animatableData: shakeAmount))
                .contentShape(Rectangle())
                .onTapGesture {
                    // Bump shake by a full unit; the GeometryEffect's
                    // sin curve gives ~3 oscillations per unit. Spring
                    // settles back to integer so the next tap starts
                    // from rest.
                    withAnimation(.spring(response: 0.42, dampingFraction: 0.32)) {
                        shakeAmount += 1
                    }
                }
        }
    }

    /// Compact lock-only pill content. Lock glyph in a tile that
    /// matches the artwork-tile vocabulary, plus "Locked" / "Tap to
    /// unlock" labels. Mirrors Alcove's lock-screen treatment.
    private var lockOnlyContent: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(0.10))
                Image(systemName: "lock.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 2) {
                Text("Locked")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                Text("Tap to unlock with Touch ID or password")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
                    .minimumScaleFactor(0.9)
            }

            Spacer(minLength: 0)
        }
    }

    private var headerRow: some View {
        HStack(spacing: 12) {
            // Artwork tile — falls back to a music-note glyph when
            // no artwork data is available (some browser sources
            // publish title only).
            Group {
                if let data = presenter.nowPlaying?.artworkData,
                   let img = NSImage(data: data) {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.white.opacity(0.12))
                        Image(systemName: "music.note")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                }
            }
            .frame(width: 50, height: 50)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .onTapGesture { onArtworkTap() }

            VStack(alignment: .leading, spacing: 2) {
                Text(presenter.nowPlaying?.title ?? "")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(presenter.nowPlaying?.artist ?? "")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            // Audio waveform indicator (decorative — same as
            // Alcove's). On macOS 14+ the symbol can pulse via
            // `.symbolEffect(.variableColor)`; on macOS 13 the
            // modifier doesn't exist, so we just render the
            // static glyph. The deployment target is 13.0.
            Group {
                if #available(macOS 14.0, *) {
                    Image(systemName: "waveform")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .symbolEffect(.variableColor.iterative,
                                      isActive: presenter.nowPlaying?.isPlaying ?? false)
                } else {
                    Image(systemName: "waveform")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
        }
    }

    private var progressRow: some View {
        VStack(spacing: 4) {
            // Progress bar — thin pill, white with subtle bg.
            // Width driven by `livePosition` (recomputed by the
            // 0.5s timer above) instead of the static snapshot
            // value, so it actually advances during playback.
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.18))
                    Capsule()
                        .fill(Color.white)
                        .frame(width: geo.size.width * progressFraction)
                }
            }
            .frame(height: 4)

            HStack {
                Text(formatDuration(livePosition))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                Spacer()
                Text("-" + formatDuration(remainingTime))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
    }

    private var transportRow: some View {
        HStack(spacing: 18) {
            // Shuffle — wired through MediaRemote's
            // `MRToggleShuffle` (command code 6, mirrors
            // mew-notch's adapter). The receiving media app
            // (Spotify / Music) toggles its own shuffle state.
            Button {
                onCommand(.toggleShuffle)
            } label: {
                Image(systemName: "shuffle")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer()

            transportButton(systemName: "backward.fill", size: 16) {
                onCommand(.previous)
            }

            transportButton(
                systemName: (presenter.nowPlaying?.isPlaying ?? false)
                    ? "pause.fill" : "play.fill",
                size: 22
            ) {
                onCommand(.togglePlayPause)
            }

            transportButton(systemName: "forward.fill", size: 16) {
                onCommand(.next)
            }

            Spacer()

            // AirPlay glyph — also a visual-parity placeholder.
            // Routes the user to the system AirPlay flow on tap
            // would be future work; for now it's just a static
            // icon at dimmer opacity.
            Image(systemName: "rectangle.inset.filled.and.person.filled")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
        }
    }

    private func transportButton(
        systemName: String,
        size: CGFloat,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Derived values

    private var progressFraction: CGFloat {
        guard let info = presenter.nowPlaying,
              let duration = info.duration,
              duration > 0
        else { return 0 }
        let raw = CGFloat(livePosition / duration)
        return min(max(raw, 0), 1)
    }

    private var remainingTime: TimeInterval {
        guard let info = presenter.nowPlaying,
              let duration = info.duration
        else { return 0 }
        return max(duration - livePosition, 0)
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - Shake animation

/// Horizontal shake/wiggle effect — same vocabulary iOS uses on the
/// lock screen when you submit a wrong passcode. We use it on the
/// nox lock-only pill: tapping it nudges `shakeAmount` by 1, which
/// drives a damped sin oscillation across the X axis. Three full
/// cycles per unit so the shake reads as a deliberate "no, you
/// need to actually unlock" feedback rather than a glitch.
// Module-internal (was `private`) so other lock-screen views in
// the same target — currently `LockNotchIndicatorView` — can reuse
// the exact same shake curve without copy-pasting it. Keeps the
// "tap-while-locked" gesture feeling identical across both pills.
struct ShakeEffect: GeometryEffect {
    var animatableData: CGFloat
    /// Pixels of horizontal travel per oscillation.
    private let amplitude: CGFloat = 6
    /// Number of half-cycles per unit of `animatableData`. 6 → three
    /// full back-and-forth cycles, which is the sweet spot for a
    /// "wrong passcode" feel without being cartoonish.
    private let cycles: CGFloat = 6

    func effectValue(size: CGSize) -> ProjectionTransform {
        let translateX = amplitude * sin(animatableData * .pi * cycles)
        return ProjectionTransform(CGAffineTransform(translationX: translateX, y: 0))
    }
}
