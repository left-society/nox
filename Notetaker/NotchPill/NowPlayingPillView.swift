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

/// Alcove-style now-playing HUD pill — the COLLAPSED indicator that
/// emerges out of the notch / top-middle of the screen whenever the
/// user has audio playing. It is intentionally minimal: a tiny album-art
/// tile on the left, a tiny waveform on the right, and nothing else.
///
/// Why so small? The user wants Alcove parity ("we need exactly the
/// same as theirs"). Alcove's collapsed HUD is a status indicator first,
/// not a remote control. Title, artist, and transport buttons live on
/// the EXPANDED music panel (PanelRootView's .music tab) — the user
/// reaches them by tapping the pill, which opens the full panel via
/// the orchestrator's hover-intent dwell.
///
/// The earlier version of this view rendered a 380×56 strip with title,
/// artist, waveform, and three transport buttons all in the closed
/// state. The user described that as "Down one is ours top one is their,
/// we need exactly the same as theirs" — i.e. shrink to a glanceable
/// indicator and let the panel handle the heavy lifting. This rewrite
/// strips the closed pill back to the artwork + waveform pair shown in
/// Alcove.
struct NowPlayingPillView: View {
    let info: NowPlayingInfo
    let isShown: Bool
    let onCommand: (MediaRemoteService.Command) -> Void

    /// Inner pill geometry. Matches Alcove's resting pill — about 320pt
    /// wide, ~32pt tall, with a 16pt bottom-corner radius. On notched
    /// MacBooks (M1/M2/M3 Pro) the ~210pt notch sits inside the middle
    /// of this width: artwork on the LEFT of the notch, waveform on
    /// the RIGHT, black middle bleeding across (and behind) the notch
    /// hardware. That wraparound is what makes the pill read as a
    /// Dynamic Island, not a floating bar. On non-notched displays it
    /// just reads as a wide compact pill fused with the menu bar.
    ///
    /// The earlier 600pt value was too wide — the user pointed out
    /// "now it's too large and not even on the top." 320pt matches
    /// Alcove's exact geometry and reads correctly on both notched
    /// and non-notched displays.
    private static let pillWidth: CGFloat = 320
    private static let pillHeight: CGFloat = 32
    private static let pillBottomRadius: CGFloat = 16

    private var currentWidth: CGFloat { isShown ? Self.pillWidth : 0 }
    private var currentHeight: CGFloat { isShown ? Self.pillHeight : 0 }
    private var currentRadius: CGFloat { isShown ? Self.pillBottomRadius : 0 }

    /// Motion-blur radius keyed to `isShown`. When the pill is settled
    /// (steady-state visible OR fully collapsed) the value is 0 so the
    /// content reads crisp; during the spring transition this animates
    /// past a peak of ~5pt, which masks per-frame jank that's otherwise
    /// visible when the spring crosses zero. Smaller peak than the old
    /// fat pill (was 7pt) because the smaller silhouette has less area
    /// for the eye to read jank in — too much blur on a 30pt-tall pill
    /// reads as broken rendering instead of motion.
    private var motionBlurRadius: CGFloat {
        isShown ? 0 : 5
    }

    var body: some View {
        ZStack(alignment: .top) {
            innerPill.frame(width: currentWidth, height: currentHeight)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Motion blur during the bloom/collapse transition. Applied
        // OUTSIDE the spring-animated frame so the blur tracks the
        // outer animation curve directly. We animate it with the same
        // spring so blur and size move in lockstep — that lockstep is
        // what makes the blur read as motion blur rather than as a
        // separate "pill went out of focus" effect.
        .blur(radius: motionBlurRadius)
        // Same spring family as the charging pill — keeps notch HUD
        // animations cohesive across presentations.
        .animation(
            isShown
                ? .spring(response: 0.42, dampingFraction: 0.78)
                : .spring(response: 0.32, dampingFraction: 0.96),
            value: isShown
        )
        // 2026-05-17: right-click → context menu (Alcove parity).
        // Single-line hookup; the controller in PillContextMenu.swift
        // installs a local right-click monitor scoped to this pill's
        // host window, builds the NSMenu from
        // `PillContextMenuPolicy.entries`, and dispatches selected
        // actions through the existing `onCommand` closure (for
        // transport) plus AppDelegate / NSWorkspace / NSPasteboard
        // (for utility items). See the doc comment at the top of
        // PillContextMenu.swift for the full rationale.
        .pillContextMenu(info: info, onCommand: onCommand)
    }

    // MARK: - Inner pill

    private var innerPill: some View {
        // Closed-pill layout: just artwork on the left, waveform on the
        // right. Title, artist, and transport controls intentionally
        // omitted — they live in the EXPANDED music panel. The user
        // explicitly compared this against Alcove and asked for parity.
        HStack(spacing: 8) {
            artwork
            Spacer(minLength: 0)
            WaveformView(
                isPlaying: info.isPlaying,
                // Sized up per user request: "audio visualizer is
                // fine, just make it more in real frame, in small
                // pill it's too small." Bumped 16×14 → 26×18 with
                // 2.8pt-wide bars (was 2.0pt) so the equalizer reads
                // at a glance without squinting at the pill.
                width: 26,
                height: 18,
                lineWidth: 2.8,
                // Album-color accent — matches the visualizer in the
                // open slab. Falls back to white when artwork hasn't
                // loaded yet so the pill never goes invisibly dark.
                tint: ArtworkColor.dominant(from: info.artworkData) ?? .white,
                opacity: 0.95,
                isCompactResting: true
            )
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
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
        .background(Color.black)
        .clipShape(NowPlayingNotchShape(bottomRadius: currentRadius))
        // Downward-only drop shadow, same as charging pill.
        .shadow(color: Color.black.opacity(0.45), radius: 10, x: 0, y: 6)
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
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
        }
        .frame(width: 22, height: 22)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
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
                title: "Paused",
                artist: "—",
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
    .frame(width: 200, height: 120)
    .background(Color.gray.opacity(0.2))
}
