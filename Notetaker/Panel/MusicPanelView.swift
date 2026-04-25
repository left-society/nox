import SwiftUI
import AppKit

/// The "music page" surface — a deliberately lightweight view that
/// mounts in well under one frame so it can serve as the first content
/// the user sees when opening the panel during playback.
///
/// Why this exists at all: the previous open path defaulted the user
/// onto NotesListView (or whichever auto-route fired), and that view's
/// first paint is heavy — composer with @FocusState, ScrollView with
/// LazyVStack of NoteRows, each NoteRow firing `onAppear` to ensure
/// link previews, FaviconView decoding NSImages async. Even with the
/// always-mount + opacity-gate refactor, that first-visibility burst
/// of work landed inside the panel-morph window and read as residual
/// lag. The user described the desired behavior plainly: "when music
/// is playing, it should only open the music player… in the background
/// it will load everything else."
///
/// MusicPanelView is the answer: when music is playing, the panel
/// auto-routes to this surface on open. Mount cost is dominated by
/// one optional `NSImage(data:)` for the artwork — no scroll content,
/// no list, no async fetches, no focus state. The user sees the
/// panel arrive and the player is already painted; switching to
/// Notes / Images / Videos / Files is then a deliberate click
/// further along, by which point the morph is long settled and any
/// per-tab mount cost is invisible.
///
/// Bindings:
/// - `presenter.nowPlaying`: source of truth, forwarded here from
///   `MediaRemoteService` via `NotchOrchestrator` (see AppDelegate
///   wiring). Re-renders happen exactly when the snapshot changes —
///   title flip, play↔pause, artwork swap.
/// - `presenter.onMediaCommand`: closure to dispatch play/pause/skip.
///   Owned by NotchOrchestrator's MediaRemoteService; wired in once
///   at launch.
struct MusicPanelView: View {
    @EnvironmentObject var presenter: PanelPresenter

    var body: some View {
        ZStack {
            gradientBackdrop
            VStack(spacing: 16) {
                artwork
                metadata
                progressBar
                controls
                sourceBadge
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DS.Spacing.md)
            .padding(.top, DS.Spacing.md)
            .padding(.bottom, DS.Spacing.md)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    // MARK: - Gradient artwork backdrop
    //
    // Same vocabulary as the closed notch pill — when album artwork is
    // available, paint a heavily-blurred copy of it behind the music
    // page content so the dominant colors of the song bleed into the
    // surface itself. Alcove parity. Bigger blur radius (70pt vs the
    // pill's 40pt) because the canvas is much larger here and a tighter
    // blur would let recognizable shapes from the artwork peek through;
    // we want a smooth wash of color, not a visible smeared thumbnail.
    //
    // The vertical gradient over the top is darker on the BOTTOM half
    // because that's where the metadata text, scrubber digits, and
    // transport-button glyphs live — those need contrast against the
    // potentially-bright artwork wash. The top half stays lighter so
    // the user sees the artwork's colors at full saturation directly
    // behind the crisp album-art tile (the artwork view above sits
    // ON TOP of this backdrop, doubling up the visual association
    // between the song and its color palette).
    //
    // The whole layer is gated on artwork being present — when there's
    // no artwork (Safari without og:image, podcasts with missing art)
    // the backdrop collapses to nothing and the panel's regular black
    // background shows through, so the music page degrades gracefully
    // to look identical to the other panel pages.
    @ViewBuilder
    private var gradientBackdrop: some View {
        if let data = presenter.nowPlaying?.artworkData,
           let img = NSImage(data: data) {
            ZStack {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .blur(radius: 70, opaque: true)
                    .opacity(0.55)
                    .allowsHitTesting(false)
                LinearGradient(
                    colors: [
                        Color.black.opacity(0.30),
                        Color.black.opacity(0.55),
                        Color.black.opacity(0.65)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .allowsHitTesting(false)
        }
    }

    // MARK: - Subviews

    /// Square album art with a soft drop shadow. Decoded inline because
    /// the data is already in memory (came across the MediaRemote
    /// notification payload) — no disk I/O, no network fetch, no
    /// expensive transforms. Falls back to a styled placeholder so the
    /// view still mounts cleanly when artwork hasn't arrived yet (some
    /// apps send the title burst first, then artwork on a follow-up).
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
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: 180)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(0.45), radius: 14, x: 0, y: 8)
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
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(DS.Color.textTertiary)
        }
    }

    private var metadata: some View {
        VStack(spacing: 2) {
            Text(presenter.nowPlaying?.title ?? "Nothing playing")
                .font(.nkBody.weight(.semibold))
                .foregroundStyle(DS.Color.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
                .multilineTextAlignment(.center)
            Text(artistLine)
                .font(.nkLabel)
                .foregroundStyle(DS.Color.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
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

    /// Alcove-style horizontal scrubber. We render it whenever the
    /// MediaRemote payload includes both a duration and a positional
    /// snapshot (Spotify and Apple Music always do; YouTube tabs in
    /// Safari typically don't, and the bar collapses gracefully when
    /// timing isn't available — controls and metadata still stand
    /// alone).
    ///
    /// Smoothness: MediaRemote only refreshes its snapshot every ~1s
    /// during playback, so naïvely binding to `elapsedTime` would step
    /// the bar in 1s jumps. Instead we drive a `TimelineView` that
    /// re-evaluates `info.currentPosition(at:)` four times a second —
    /// cheap, since the helper is just `elapsedTime + drift` arithmetic.
    /// When the user pauses, `currentPosition` returns the snapshot's
    /// elapsedTime as a constant, so the bar freezes in place without
    /// us doing anything special.
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

    private var controls: some View {
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
        .padding(.top, 4)
    }

    /// Hover-aware circular button. The buttons are visually quiet
    /// (no chip background by default) so the metadata reads as the
    /// primary content; hovering brings up a subtle disc to confirm
    /// the hit target.
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

    /// Tiny "playing in <App>" credit at the bottom plus a small
    /// audio-bar visualizer. Helps the user orient when multiple media
    /// apps are open simultaneously (Spotify in the background, Safari
    /// with a YouTube tab in front, etc.) — the source bundle is the
    /// only reliable signal for which app a play/pause command will
    /// land on. The visualizer is the same primitive as the notch HUD
    /// pill (WaveformView) so the two surfaces share the same "audio
    /// is alive" tell.
    @ViewBuilder
    private var sourceBadge: some View {
        if let info = presenter.nowPlaying,
           let bundleID = info.sourceBundleID,
           let appName = Self.localizedAppName(forBundleID: bundleID) {
            HStack(spacing: 8) {
                WaveformView(
                    isPlaying: info.isPlaying,
                    width: 18,
                    height: 10,
                    lineWidth: 1.2,
                    tint: DS.Color.textSecondary,
                    opacity: 0.9
                )
                Text("Playing in \(appName)")
                    .font(.nkLabel)
            }
            .foregroundStyle(DS.Color.textTertiary)
            .padding(.top, 2)
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
        title: "Sapphire",
        artist: "Mac DeMarco",
        album: "This Old Dog",
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
        .frame(width: 340, height: 480)
        .background(Color.black)
}
