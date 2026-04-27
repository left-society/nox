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

        // Card geometry: 420×160 — matches Alcove's lock-screen
        // music card. Was 190 initially; trimmed because the
        // visible content fits in ~155pt and the extra 30pt of
        // padding made the card look stretched compared to
        // Alcove's tighter proportions.
        let initialFrame = NSRect(x: 0, y: 0, width: 420, height: 160)
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
        Publishers.CombineLatest(
            presenter.$isLocked.removeDuplicates(),
            presenter.$nowPlaying
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
    private func refreshVisibility(locked: Bool, info: NowPlayingInfo?) {
        let shouldShow = locked && info != nil
        if shouldShow {
            positionForLockScreen()
            attachToSpaceIfNeeded()
            panel.alphaValue = 1
            panel.orderFrontRegardless()
        } else {
            panel.orderOut(nil)
        }
    }

    /// Center the card horizontally and position it at the lock-
    /// screen card y-coordinate (about 60% down the screen, where
    /// macOS's own widget area sits).
    private func positionForLockScreen() {
        guard let screen = NSScreen.main else { return }
        let frame = screen.frame
        let cardWidth: CGFloat = 420
        let cardHeight: CGFloat = 160
        let x = frame.midX - cardWidth / 2
        // 18% from the bottom — empirically matches Alcove's card
        // placement (it sits clearly above the password prompt
        // with breathing room, not centered).
        let y = frame.minY + frame.height * 0.18
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
    private var cardScreenFrame: NSRect {
        guard let screen = NSScreen.main else { return .zero }
        let cardWidth: CGFloat = 420
        let cardHeight: CGFloat = 160
        let x = screen.frame.midX - cardWidth / 2
        let y = screen.frame.minY + screen.frame.height * 0.18
        return NSRect(x: x, y: y, width: cardWidth, height: cardHeight)
    }

    var body: some View {
        let cardShape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        return cardContent
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(width: 420, height: 160)
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
                    WallpaperBackdrop(cardScreenFrame: cardScreenFrame)
                        // Lensing strength was 22 — too aggressive,
                        // showed the displacement obviously which
                        // read as "warped wrong" instead of "real
                        // glass." Pulled back to 10 (subtle) +
                        // aberration 3 so it whispers rather than
                        // shouts. This matches what real glass at
                        // this thickness would do — a slight
                        // refraction at the edges, almost
                        // imperceptible chromatic fringe.
                        .liquidGlass(strength: 10, aberration: 3)
                        .clipShape(cardShape)
                    VisualEffectBlur(material: .menu, blendingMode: .behindWindow)
                        .clipShape(cardShape)
                        .opacity(0.45)
                    cardShape
                        .strokeBorder(Color.white.opacity(0.30), lineWidth: 0.5)
                }
                .environment(\.colorScheme, .light)
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

    private var cardContent: some View {
        VStack(spacing: 10) {
            headerRow
            progressRow
            transportRow
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
