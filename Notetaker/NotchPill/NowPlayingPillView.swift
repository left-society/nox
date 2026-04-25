import SwiftUI
import AppKit

/// Same notch silhouette as the charging pill / main panel — flat top,
/// rounded bottom corners only. Duplicated here rather than imported
/// because the original lives inside file-scoped types in Panel/PanelRootView
/// and ChargingPillView; promoting it to public would pollute three
/// modules' API surface to save 20 lines.
private struct NowPlayingNotchShape: Shape {
    var bottomRadius: CGFloat

    var animatableData: CGFloat {
        get { bottomRadius }
        set { bottomRadius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let r = max(0, min(bottomRadius, min(rect.width, rect.height) / 2))
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        p.addArc(
            center: CGPoint(x: rect.maxX - r, y: rect.maxY - r),
            radius: r,
            startAngle: .degrees(0),
            endAngle: .degrees(90),
            clockwise: false
        )
        p.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        p.addArc(
            center: CGPoint(x: rect.minX + r, y: rect.maxY - r),
            radius: r,
            startAngle: .degrees(90),
            endAngle: .degrees(180),
            clockwise: false
        )
        p.closeSubpath()
        return p
    }
}

/// Alcove-style now-playing HUD pill. Extends out of the notch with the
/// current track artwork, title, artist, and a play/pause + skip control
/// strip. Same vocabulary as the charging pill (solid black slab, flat
/// top, rounded bottom, downward shadow) — just bigger and interactive.
///
/// The view receives a fully-resolved `NowPlayingInfo` from the
/// orchestrator. Commands are dispatched up via `onCommand` so the
/// view stays free of MediaRemote dependencies (testable in previews
/// without the framework loaded).
struct NowPlayingPillView: View {
    let info: NowPlayingInfo
    let isShown: Bool
    let onCommand: (MediaRemoteService.Command) -> Void

    /// Inner pill geometry. Wider than the charging pill (380 vs 240)
    /// because we have artwork + two text rows + waveform + three transport
    /// buttons to fit. Height 56 vs charging's 40 — a hair taller so the
    /// artwork has room to breathe without choking the text rows.
    private static let pillWidth: CGFloat = 380
    private static let pillHeight: CGFloat = 56
    private static let pillBottomRadius: CGFloat = 22

    private var currentWidth: CGFloat { isShown ? Self.pillWidth : 0 }
    private var currentHeight: CGFloat { isShown ? Self.pillHeight : 0 }
    private var currentRadius: CGFloat { isShown ? Self.pillBottomRadius : 0 }

    var body: some View {
        ZStack(alignment: .top) {
            innerPill.frame(width: currentWidth, height: currentHeight)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Same spring family as the charging pill — keeps notch HUD
        // animations cohesive across presentations.
        .animation(
            isShown
                ? .spring(response: 0.42, dampingFraction: 0.78)
                : .spring(response: 0.32, dampingFraction: 0.96),
            value: isShown
        )
    }

    // MARK: - Inner pill

    private var innerPill: some View {
        // Closed-pill layout: artwork on the FAR LEFT, title+artist
        // filling the middle, then a small waveform tell, and finally
        // a 3-button transport cluster (back / play-pause / forward) on
        // the FAR RIGHT. The user reported the prior layout (waveform
        // only, no transport) as missing functionality — they want to
        // be able to pause/skip without opening the main panel. This
        // mirrors the OPEN state of Alcove's pill, which IS a remote;
        // the slight loss of glanceability vs the strict "status only"
        // interpretation is worth it for the one-cursor-flick control
        // surface the user explicitly asked for.
        HStack(spacing: 8) {
            artwork
            titleStack
                .frame(maxWidth: .infinity, alignment: .leading)
            WaveformView(
                isPlaying: info.isPlaying,
                width: 22,
                height: 14,
                lineWidth: 1.4,
                tint: .white,
                opacity: 0.78
            )
            controls
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        // Content fades in AFTER the shell finishes growing — same
        // pattern as ChargingPillView and the main panel. Mirrors the
        // perceived "shell first, then UI" sequence the user reads as
        // a piece of hardware coming alive.
        .opacity(isShown ? 1 : 0)
        .animation(
            isShown
                ? .easeOut(duration: 0.18).delay(0.16)
                : .easeIn(duration: 0.06),
            value: isShown
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(pillBackground)
        .clipShape(NowPlayingNotchShape(bottomRadius: currentRadius))
        // Downward-only drop shadow, same as charging pill.
        .shadow(color: Color.black.opacity(0.45), radius: 14, x: 0, y: 8)
    }

    // MARK: - Gradient artwork backdrop
    //
    // The user asked for the pill to "take the color from the thumbnail
    // with gradient" — Alcove parity. We achieve that by stacking three
    // layers behind the content row:
    //
    //   1. Color.black — the fallback / unconditional base, so when no
    //      artwork is published (Safari without og:image, podcasts with
    //      missing art) the pill still reads as the same solid slab the
    //      charging pill uses. Also acts as the "cake" the artwork blur
    //      sits on top of, so a partially-transparent blur composites
    //      against black instead of the desktop wallpaper.
    //
    //   2. The blurred artwork itself, scaled to fill and blurred at a
    //      large radius (40pt). The aspect-fill + blur produces an
    //      organic colored wash — dominant hues bleed across the whole
    //      pill instead of showing a recognizable mini album cover. The
    //      0.7 opacity keeps colors saturated enough to read as "this
    //      pill belongs to the song" without overwhelming the text.
    //
    //   3. A horizontal black gradient layered ON TOP of the artwork
    //      backdrop. The gradient is lightest at the leading edge (where
    //      the actual album thumbnail lives — letting the artwork's
    //      colors visibly blend with the blurred wash behind it) and
    //      darkest at the trailing edge (where the title/artist text
    //      and transport controls live — guaranteeing legibility against
    //      light/colorful artwork like Sabrina Carpenter's pink covers).
    //      Without this gradient, white text on a busy bright artwork
    //      would smear into illegibility.
    //
    // The crisp foreground album-art tile (rendered by `artwork` above
    // and clipped to a small rounded rect) sits ON TOP of all of this,
    // so the user sees both the recognizable thumbnail AND the colorful
    // backdrop derived from it — same dual-layer trick Apple Music's
    // mini-player uses.
    private var pillBackground: some View {
        ZStack {
            Color.black
            if let data = info.artworkData, let img = NSImage(data: data) {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .blur(radius: 40, opaque: true)
                    .opacity(0.7)
                    .allowsHitTesting(false)
                LinearGradient(
                    colors: [
                        Color.black.opacity(0.25),
                        Color.black.opacity(0.50),
                        Color.black.opacity(0.65)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            }
        }
    }

    // MARK: - Artwork

    private var artwork: some View {
        Group {
            if let data = info.artworkData, let img = NSImage(data: data) {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                // Placeholder when the source app didn't publish art
                // (a Safari YouTube tab without the og:image set, for
                // instance). We render a tinted music glyph instead of
                // an empty rect — keeps the pill's anchor cell from
                // looking broken.
                ZStack {
                    Color.white.opacity(0.08)
                    Image(systemName: "music.note")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
        }
        .frame(width: 40, height: 40)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    // MARK: - Title / artist text

    private var titleStack: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(info.title.isEmpty ? "Unknown title" : info.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)

            Text(info.artist.isEmpty ? " " : info.artist)
                .font(.system(size: 10.5))
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    // MARK: - Playback controls

    private var controls: some View {
        HStack(spacing: 2) {
            ControlButton(
                systemName: "backward.fill",
                size: 10,
                action: { onCommand(.previous) }
            )
            ControlButton(
                // Filled glyph swap on play state. Apple uses the same
                // pattern in Control Center — viewers parse it as
                // "press here to do the OPPOSITE of what's shown".
                systemName: info.isPlaying ? "pause.fill" : "play.fill",
                size: 13,
                action: { onCommand(.togglePlayPause) }
            )
            ControlButton(
                systemName: "forward.fill",
                size: 10,
                action: { onCommand(.next) }
            )
        }
    }
}

/// Round, hover-tinted icon button. Sized to fit the 56-tall pill
/// without crowding the artwork or text. Each button is its own
/// invisible 24×24 hit target so users with larger cursors don't
/// miss-click between glyphs.
private struct ControlButton: View {
    let systemName: String
    let size: CGFloat
    let action: () -> Void

    @State private var isHovered = false
    @State private var isPressed = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.white.opacity(isHovered ? 0.95 : 0.78))
                .frame(width: 24, height: 24)
                .background(
                    Circle()
                        .fill(Color.white.opacity(isHovered ? 0.10 : 0))
                )
                .scaleEffect(isPressed ? 0.92 : 1.0)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
        // Press visual feedback — gives the button some life on click,
        // since macOS buttons don't get the auto-tilt that iOS gives
        // them. Tracks via a TapGesture wrapped in DragGesture so we
        // catch press-in/press-out states.
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !isPressed {
                        withAnimation(.easeOut(duration: 0.08)) {
                            isPressed = true
                        }
                    }
                }
                .onEnded { _ in
                    withAnimation(.easeOut(duration: 0.12)) {
                        isPressed = false
                    }
                }
        )
    }
}

#Preview {
    VStack(spacing: 20) {
        NowPlayingPillView(
            info: NowPlayingInfo(
                title: "Espresso",
                artist: "Sabrina Carpenter",
                album: "Short n' Sweet",
                artworkData: nil,
                isPlaying: true,
                sourceBundleID: "com.spotify.client",
                duration: 175,
                elapsedTime: 42,
                infoTimestamp: Date()
            ),
            isShown: true,
            onCommand: { _ in }
        )
        NowPlayingPillView(
            info: NowPlayingInfo(
                title: "A Really Long Track Title That Will Truncate",
                artist: "Some Long Artist Name",
                album: nil,
                artworkData: nil,
                isPlaying: false,
                sourceBundleID: nil,
                duration: nil,
                elapsedTime: nil,
                infoTimestamp: nil
            ),
            isShown: true,
            onCommand: { _ in }
        )
    }
    .frame(width: 380, height: 200)
    .background(Color.gray.opacity(0.2))
}
