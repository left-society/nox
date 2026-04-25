import SwiftUI
import AppKit

/// Alcove-style compact music HUD — small album-art tile on the left,
/// title/artist stacked next to it, a small live-audio waveform on the
/// trailing edge, then a scrubbable progress bar and the three transport
/// controls beneath. This is the "music page" surface the panel routes
/// to when audio is playing.
///
/// Why this shape (vs. the earlier tall vertical column with a 180pt
/// album-art tile and a ~480pt total content height): the fixed-height
/// slab couldn't contain the previous layout — the bottom row of
/// controls and source badge spilled past the silhouette's rounded
/// bottom corners and into the haloPadding margin where the black
/// background was no longer painted. The user explicitly referenced
/// Alcove ("the alcove one is what i want") with a screenshot showing
/// a dense horizontal info-row + linear progress + 3-button cluster
/// that fits in roughly 200pt of vertical content. This file matches
/// that shape; `PanelWindowController.innerPanelHeight(for:)` separately
/// shrinks the slab when `.music` is the active tab so the black
/// background actually wraps the content.
///
/// Mount cost is still tiny — the heaviest thing in here is the
/// optional `NSImage(data:)` decode for artwork, which is fast because
/// the data is already in memory (came across the MediaRemote
/// notification payload). No async fetches, no scroll content, no
/// list — same lightweight first-paint posture that made this view the
/// auto-route default during playback.
///
/// Bindings:
/// - `presenter.nowPlaying`: source of truth, forwarded here from
///   `MediaRemoteService` via `NotchOrchestrator`. Re-renders happen
///   exactly when the snapshot changes — title flip, play↔pause,
///   artwork swap.
/// - `presenter.onMediaCommand`: closure to dispatch play/pause/skip.
///   Owned by NotchOrchestrator's MediaRemoteService; wired in once
///   at launch.
struct MusicPanelView: View {
    @EnvironmentObject var presenter: PanelPresenter

    var body: some View {
        VStack(spacing: 14) {
            infoRow
            progressBar
            transportControls
            sourceBadge
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.Spacing.md)
        .padding(.top, DS.Spacing.md)
        .padding(.bottom, DS.Spacing.md)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: - Top info row
    //
    // Artwork + title/artist + waveform, all in a single horizontal
    // strip. This is the primary visual anchor of the music HUD —
    // mirrors the Alcove reference where the art tile reads as the
    // "what's playing" surface and the text reads to the right of it.
    // The waveform on the trailing edge is the same primitive the closed
    // notch pill uses, giving the two surfaces a shared "audio is
    // alive" tell.

    private var infoRow: some View {
        HStack(alignment: .center, spacing: 12) {
            artwork
            VStack(alignment: .leading, spacing: 2) {
                Text(presenter.nowPlaying?.title ?? "Nothing playing")
                    .font(.nkBody.weight(.semibold))
                    .foregroundStyle(DS.Color.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(artistLine)
                    .font(.nkLabel)
                    .foregroundStyle(DS.Color.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            WaveformView(
                isPlaying: presenter.nowPlaying?.isPlaying ?? false,
                width: 22,
                height: 12,
                lineWidth: 1.4,
                tint: DS.Color.textPrimary,
                opacity: 0.85
            )
        }
    }

    // MARK: - Artwork

    /// Square album art at a fixed 72pt — small enough to leave room
    /// for the title/artist strip, large enough to read as the visual
    /// anchor of the row. Decoded inline because the data is already
    /// in memory (came across the MediaRemote payload). Falls back to
    /// a styled placeholder so the view still mounts cleanly when
    /// artwork hasn't arrived yet (some apps send title burst first,
    /// artwork on a follow-up notification).
    private var artwork: some View {
        Group {
            if let data = presenter.nowPlaying?.artworkData,
               let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fill)
            } else {
                placeholderArt
            }
        }
        .frame(width: 72, height: 72)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(0.45), radius: 10, x: 0, y: 6)
    }

    private var placeholderArt: some View {
        ZStack {
            LinearGradient(
                colors: [
                    DS.Color.bgSubtle,
                    DS.Color.bgHover
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: "music.note")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(DS.Color.textTertiary)
        }
    }

    /// Combines artist + album when both are present, falls back to
    /// just the artist (or empty). Apple Music tends to publish both;
    /// Spotify and YouTube often only publish artist.
    private var artistLine: String {
        let info = presenter.nowPlaying
        let artist = info?.artist ?? ""
        let album = info?.album ?? ""
        if !artist.isEmpty && !album.isEmpty {
            return "\(artist) — \(album)"
        }
        return artist
    }

    // MARK: - Progress bar
    //
    // Alcove-style horizontal scrubber. We render it whenever the
    // MediaRemote payload includes both a duration and a positional
    // snapshot (Spotify and Apple Music always do; YouTube tabs in
    // Safari typically don't, and the bar collapses gracefully when
    // timing isn't available — controls and metadata still stand alone).
    //
    // Smoothness: MediaRemote only refreshes its snapshot every ~1s
    // during playback, so naïvely binding to `elapsedTime` would step
    // the bar in 1s jumps. Instead we drive a `TimelineView` that
    // re-evaluates `info.currentPosition(at:)` four times a second —
    // cheap, since the helper is just `elapsedTime + drift` arithmetic.
    // When the user pauses, `currentPosition` returns the snapshot's
    // elapsedTime as a constant, so the bar freezes in place without
    // us doing anything special.

    @ViewBuilder
    private var progressBar: some View {
        if let info = presenter.nowPlaying,
           let total = info.duration,
           total > 0,
           info.elapsedTime != nil {
            TimelineView(.periodic(from: .now, by: 0.25)) { context in
                let position = info.currentPosition(at: context.date) ?? 0
                let clamped = min(max(position, 0), total)
                let progress = clamped / total
                VStack(spacing: 6) {
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.white.opacity(0.10))
                            .frame(height: 3)
                        GeometryReader { geo in
                            Capsule()
                                .fill(Color.white.opacity(0.85))
                                .frame(
                                    width: max(0, geo.size.width * progress),
                                    height: 3
                                )
                        }
                        .frame(height: 3)
                    }
                    .frame(height: 3)
                    HStack {
                        // Elapsed time on the left — what the user has
                        // already heard. Monospaced so the digits don't
                        // jiggle as the seconds tick over.
                        Text(Self.timeString(clamped))
                            .font(.nkLabel)
                            .monospacedDigit()
                            .foregroundStyle(DS.Color.textTertiary)
                        Spacer()
                        // Remaining time on the right — preferred over
                        // total duration here to match the Alcove pattern
                        // the user referenced. Negative-prefix makes the
                        // semantics unambiguous (it's a countdown, not a
                        // bizarrely-rendered total).
                        Text("-\(Self.timeString(max(total - clamped, 0)))")
                            .font(.nkLabel)
                            .monospacedDigit()
                            .foregroundStyle(DS.Color.textTertiary)
                    }
                }
            }
        }
    }

    /// MM:SS formatter scoped to the panel — kept small/inline rather
    /// than promoted to a global helper, since this is the only place
    /// in the app that needs to format track time. If a second consumer
    /// shows up we'll refactor; until then, the locality keeps the
    /// reading flow tight.
    private static func timeString(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let mins = total / 60
        let secs = total % 60
        return String(format: "%d:%02d", mins, secs)
    }

    // MARK: - Transport controls

    /// Three buttons — prev / play-pause / next — sized identically to
    /// the previous vertical layout (44pt hit area, 18 / 26 / 18pt
    /// glyphs). Spacing is wider here than the old design because the
    /// row sits in a much shorter content area and needs to read as
    /// the focal point; clustering the three buttons closer would make
    /// the row feel cramped against the progress bar above it.
    private var transportControls: some View {
        HStack(spacing: 28) {
            controlButton(
                systemImage: "backward.fill",
                size: 18,
                accessibility: "Previous track"
            ) {
                presenter.onMediaCommand?(.previous)
            }

            controlButton(
                systemImage: (presenter.nowPlaying?.isPlaying ?? false)
                    ? "pause.fill"
                    : "play.fill",
                size: 26,
                accessibility: "Play / Pause"
            ) {
                presenter.onMediaCommand?(.togglePlayPause)
            }

            controlButton(
                systemImage: "forward.fill",
                size: 18,
                accessibility: "Next track"
            ) {
                presenter.onMediaCommand?(.next)
            }
        }
    }

    @ViewBuilder
    private func controlButton(
        systemImage: String,
        size: CGFloat,
        accessibility: String,
        action: @escaping () -> Void
    ) -> some View {
        MusicControlButton(
            systemImage: systemImage,
            size: size,
            accessibility: accessibility,
            action: action
        )
    }

    // MARK: - Source badge
    //
    // Tiny "playing in <App>" credit underneath the controls — helps
    // the user orient when multiple media apps are open simultaneously
    // (Spotify in the background, Safari with a YouTube tab in front,
    // etc.); the source bundle is the only reliable signal for which
    // app a play/pause command will land on. Smaller and more recessed
    // here than in the previous layout because the compact HUD doesn't
    // have the room — kept anyway because removing it makes the multi-
    // source case opaque.

    @ViewBuilder
    private var sourceBadge: some View {
        if let info = presenter.nowPlaying,
           let bundleID = info.sourceBundleID,
           let appName = Self.localizedAppName(forBundleID: bundleID) {
            Text("Playing in \(appName)")
                .font(.nkLabel)
                .foregroundStyle(DS.Color.textTertiary)
        }
    }

    private static func localizedAppName(forBundleID bundleID: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return shortName(forBundleID: bundleID)
        }
        let bundle = Bundle(url: url)
        let display = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
        let name = bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
        return display ?? name ?? shortName(forBundleID: bundleID)
    }

    /// Best-effort fallback when we can't resolve a real Bundle —
    /// e.g. Music.app reports `com.apple.Music` and we don't need
    /// to walk the filesystem just to write "Music" on the badge.
    private static func shortName(forBundleID bundleID: String) -> String? {
        switch bundleID {
        case "com.apple.Music": return "Music"
        case "com.spotify.client": return "Spotify"
        case "com.apple.Safari": return "Safari"
        case "com.google.Chrome": return "Chrome"
        case "company.thebrowser.Browser": return "Arc"
        default:
            // Strip the reverse-DNS prefix, capitalize the last
            // segment so "com.example.MyPlayer" → "MyPlayer".
            let last = bundleID.split(separator: ".").last.map(String.init) ?? bundleID
            return last
        }
    }
}

/// Extracted into its own struct so the per-button @State (hover) is
/// scoped correctly — a single shared @State on MusicPanelView would
/// flicker every button at once on cursor entry.
private struct MusicControlButton: View {
    let systemImage: String
    let size: CGFloat
    let accessibility: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(DS.Color.textPrimary)
                .frame(width: 44, height: 44)
                .background(
                    Circle()
                        .fill(DS.Color.bgHover)
                        .opacity(isHovered ? 1 : 0)
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibility)
        .onHover { hovering in
            withAnimation(.rowHover) { isHovered = hovering }
        }
    }
}

#Preview {
    let presenter = PanelPresenter()
    presenter.nowPlaying = NowPlayingInfo(
        title: "SMILEY (Feat. BIBI)",
        artist: "YENA",
        album: "˙ᵕ˙ (SMiLEY)",
        artworkData: nil,
        isPlaying: true,
        sourceBundleID: "com.spotify.client",
        duration: 215,
        elapsedTime: 78,
        infoTimestamp: Date()
    )
    return MusicPanelView()
        .environmentObject(presenter)
        .preferredColorScheme(.dark)
        .frame(width: 380, height: 230)
        .background(Color.black)
}
