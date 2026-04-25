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
        VStack(spacing: 18) {
            artwork
            metadata
            controls
            sourceBadge
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.Spacing.md)
        .padding(.top, DS.Spacing.md)
        .padding(.bottom, DS.Spacing.md)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
                    barCount: 3,
                    barWidth: 2,
                    spacing: 2,
                    maxHeight: 10,
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
        sourceBundleID: "com.spotify.client"
    )
    return MusicPanelView()
        .environmentObject(presenter)
        .preferredColorScheme(.dark)
        .frame(width: 340, height: 480)
        .background(Color.black)
}
