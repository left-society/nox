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

    /// Drag-to-scrub state for the progress bar. While `isScrubbing`
    /// is true, the bar renders `scrubProgress` instead of the live
    /// playback fraction — gives the user immediate feedback as they
    /// drag, even though the seek doesn't land until they release.
    /// Apple Music / Spotify desktop both use this pattern.
    @State private var isScrubbing = false
    @State private var scrubProgress: Double = 0
    /// Hover state for the progress bar — when true, the scrubber
    /// thumb appears (so the user can SEE the bar is interactive
    /// before they grab it). Also slightly thickens the track.
    @State private var isProgressHovering = false
    /// Timestamp of the last transport command we dispatched. Used to
    /// debounce rapid-fire button taps — Spotify and Music both react
    /// to MediaRemote commands within ~80-150ms, but the *AppleScript*
    /// helpers we route seek through can stall a few hundred ms. If
    /// the user mashes Next, we'd otherwise queue up a stack of
    /// commands the source app processes serially, manifesting as
    /// "skipped 4 tracks at once." Hard-floor the inter-command
    /// interval at 150ms.
    @State private var lastCommandAt: Date = .distantPast
    /// Settings-driven gate. Default true for first-launch users
    /// so the visualizer is on out-of-the-box.
    @AppStorage("sphereVisualizerEnabled") private var sphereEnabled: Bool = true

    var body: some View {
        // Gradient lives at PanelRootView level now (so it covers
        // the actual TOP of the panel, behind the header / tabs)
        // — see `artworkTopGradient` there. This view just lays
        // out the music HUD content on top of the panel-level tint.
        VStack(spacing: 10) {
            infoRow
            progressBar
            transportControls
            sourceBadge
            // Bluetooth battery strip — only renders when an
            // AirPods/headphones with battery info is connected.
            // Hidden otherwise so the layout doesn't reserve empty
            // space.
            BluetoothBatteryRow()
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.Spacing.md)
        .padding(.top, DS.Spacing.md)
        .padding(.bottom, DS.Spacing.sm)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// Artwork-color tint that flows FROM THE TOP and dissolves
    /// INTO THE BOTTOM. Uses the artwork itself (heavily blurred +
    /// scaled) as the color source — no need to extract a dominant
    /// color explicitly, the blur averages the artwork down to its
    /// tonal field. The vertical mask gradient (full at top → clear
    /// at bottom) is what makes it dissolve cleanly into the slab's
    /// black background by the time the eye reaches the transport
    /// row. Per the user's note: "Gradiant should come from the top
    /// and desolve into the bottom So it looks cleaner."
    ///
    /// 0.7 opacity (up from 0.45) makes the tint actually visible —
    /// the previous value was so subtle that the user reported it
    /// as not present. The mask hits zero opacity by 60% of the
    /// 240pt header height, leaving the lower 40% of the panel
    /// completely on the slab's black background for transport-
    /// button contrast.
    @ViewBuilder
    private var artworkGradientHeader: some View {
        if let data = presenter.nowPlaying?.artworkData,
           let image = NSImage(data: data) {
            // Top-only gradient header. Per the user's clarification:
            // "I said gradient comes from top (top means the top not
            // the bottom half)." Previous version masked through 85%
            // of a 240pt header, which painted the gradient through
            // the middle of the panel. New version: 140pt total
            // height, mask fully clear by 50%, so the gradient lives
            // strictly in the upper ~70pt of the panel (the area
            // around the artwork tile) and the panel below is clean
            // black.
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(height: 140)
                .blur(radius: 50, opaque: true)
                .opacity(0.7)
                .scaleEffect(1.6)
                .frame(maxWidth: .infinity, alignment: .top)
                .clipped()
                .mask(
                    LinearGradient(
                        stops: [
                            .init(color: Color.black, location: 0.0),
                            .init(color: Color.black.opacity(0.6), location: 0.3),
                            .init(color: Color.clear, location: 0.55)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        }
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
        // Resolve nowPlaying once so we don't re-traverse the
        // optional chain four times in this row's body. Cheap, but
        // also gives us a single place to read the artwork data and
        // hand it to ArtworkColor — the cache will short-circuit the
        // duplicate calls regardless, but this is clearer.
        let info = presenter.nowPlaying
        let title = info?.title ?? "Nothing playing"
        let artist = info?.artist ?? ""
        let album = info?.album ?? ""
        let tint = ArtworkColor.dominant(from: info?.artworkData) ?? .white
        // Stable per-track key for waveform pattern. Avoid empty
        // string when nothing is playing — falls through to the
        // default pattern in that case via WaveformPattern's guard.
        let trackKey = info.map { "\($0.title)|\($0.artist)" } ?? ""

        return HStack(alignment: .center, spacing: 14) {
            artwork
            // Tappable metadata stack — clicking any of the title/
            // artist/album labels brings the source app forward.
            // Same gesture as tapping the artwork. Reads as "click
            // anywhere on the now-playing card to jump to the
            // source." User: "When I click on it ... it should open
            // Spotify or whatever I'm using."
            Button {
                openSourceApp()
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(title)
                    if !artist.isEmpty {
                        Text(artist)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white.opacity(0.85))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .help(artist)
                    }
                    if !album.isEmpty {
                        Text(album)
                            .font(.system(size: 11, weight: .regular))
                            .foregroundStyle(.white.opacity(0.55))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .help(album)
                    }
                }
                // Cap title block at 280pt so the sphere
                // visualizer sits visually adjacent to the title
                // text. With the wider 530pt slab, the previous
                // `maxWidth: .infinity` stretched the title block
                // full-width and pushed the sphere alone to the far
                // right corner — felt disconnected from the music
                // card. 280pt is comfortable for typical track
                // titles; longer ones still truncate via
                // .lineLimit(1).
                .frame(maxWidth: 280, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(sourceAppHelpText())
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Self.metadataAccessibilityLabel(
                title: title, artist: artist, album: album
            ))

            // Spacer between title and sphere — modest gap, not the
            // entire remaining width like before.
            Spacer(minLength: 12)

            // Rotating particle sphere. Paused when:
            //   • slab is closed (resting pill — invisible)
            //   • a panel-frame morph is in flight
            //
            // Visibility: hidden (opacity 0) the instant a morph
            // starts, fades back in over 280ms once the spring has
            // settled. Without the fade you see a frozen sphere
            // riding the morph's spring oscillation, which reads as
            // a competing visual element fighting the panel's
            // motion. Hiding cleanly during the morph + reappearing
            // post-settle gives the morph the user's full attention.
            // Settings → Music → Sphere visualizer toggle. When
            // disabled, the .frame collapses the view to 0×0 so
            // the surrounding HStack reclaims the space and the
            // title/artist row reads as a normal music-card layout
            // without the sphere reservation. The `isPaused` flag
            // also stops the 60Hz timer for zero CPU cost.
            SphereVisualizer(
                isPlaying: info?.isPlaying ?? false,
                isPaused: !presenter.isShown || presenter.isMorphing
                          || !sphereEnabled,
                size: sphereEnabled ? 40 : 0,
                tint: tint
            )
            // Explicit frame because NSViewRepresentable doesn't
            // propagate the inner size param as a SwiftUI layout
            // constraint — without this, the sphere fills whatever
            // space the HStack proposes, and the disabled-toggle
            // path wouldn't actually reclaim its row space.
            .frame(width: sphereEnabled ? 40 : 0,
                   height: sphereEnabled ? 40 : 0)
            .opacity(presenter.isMorphing ? 0 : 1)
            .animation(.easeOut(duration: 0.28), value: presenter.isMorphing)
        }
    }

    /// Build a single VoiceOver phrase from the three metadata
    /// fields — empties are skipped so the user doesn't hear
    /// awkward leading commas when artist or album is missing.
    private static func metadataAccessibilityLabel(
        title: String, artist: String, album: String
    ) -> String {
        [title, artist, album]
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
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
        Button {
            openSourceApp()
        } label: {
            Group {
                if let data = presenter.nowPlaying?.artworkData,
                   let image = NSImage(data: data) {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fill)
                } else if let icon = sourceAppIcon() {
                    // No track artwork (WhatsApp audio, some YouTube
                    // tabs, podcasts, etc.) → fall back to the source
                    // app's icon so the panel still has a visual
                    // anchor identifying WHERE the audio is coming
                    // from. User: "in any other software or window
                    // where we use any kind of sounds ... it should
                    // register as that."
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .padding(8)
                        .background(
                            LinearGradient(
                                colors: [DS.Color.bgSubtle, DS.Color.bgHover],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                } else {
                    placeholderArt
                }
            }
            .frame(width: 76, height: 76)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
            )
            .shadow(color: Color.black.opacity(0.4), radius: 8, x: 0, y: 4)
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .help(sourceAppHelpText())
    }

    /// Pull the source app's NSImage icon by bundleID. Used as a
    /// fallback artwork when the source doesn't publish track
    /// artwork (WhatsApp audio, some browser tabs, podcasts).
    private func sourceAppIcon() -> NSImage? {
        guard let bundleID = presenter.nowPlaying?.sourceBundleID,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    /// Hover help text for the artwork tile — tells the user
    /// clicking it will open the source app. Falls back to a
    /// generic label when source isn't known.
    private func sourceAppHelpText() -> String {
        if let bundleID = presenter.nowPlaying?.sourceBundleID,
           let name = Self.localizedAppName(forBundleID: bundleID) {
            return "Open \(name)"
        }
        return "Open the source app"
    }

    /// Bring the source app to the foreground. Called when the user
    /// clicks the artwork or the title/artist row — the panel acts
    /// as a remote, but click-on-info is the universal "take me
    /// where this is coming from" gesture. User: "When I click on
    /// it ... it's not opening Spotify. What I need is that when I
    /// click on that thing, it should open Spotify or whatever I'm
    /// using."
    private func openSourceApp() {
        // Route through the presenter callback (wired to
        // NotchOrchestrator.openSourceApp) so the dispatcher can
        // jump to the actual playing browser tab — not just bring
        // Chrome to whatever tab is currently active. Falls back to
        // a plain NSWorkspace open when the callback isn't wired
        // (shouldn't happen in production but useful for previews).
        if let handler = presenter.onOpenSourceApp {
            handler()
            return
        }
        guard let bundleID = presenter.nowPlaying?.sourceBundleID else { return }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in
            if let error {
                NSLog("Notetaker: failed to open \(bundleID): \(error)")
            }
        }
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

    /// Gradient colors for the progress-bar fill. Leading edge is
    /// white (full energy at the play head), trailing edge picks up
    /// the dominant color from the album artwork. Falls back to
    /// pure-white gradient when no artwork is loaded.
    private var progressBarColors: [Color] {
        if let tint = ArtworkColor.dominant(from: presenter.nowPlaying?.artworkData) {
            return [Color.white, tint]
        }
        return [Color.white, Color.white.opacity(0.75)]
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
        // We render the bar whenever there's a current track (info
        // present), even if duration / elapsed time aren't published
        // yet. Without timing data, the bar appears as an empty
        // track — visual continuity is more important than
        // conditional hiding (the user reported earlier that the
        // bar "is not visible at all" because some tracks took a
        // moment to publish duration, leaving an awkward gap in the
        // layout). With timing data, the bar fills in.
        if let info = presenter.nowPlaying {
            // Treat any non-finite or non-positive duration as "no
            // timing." This guards against AppleScript / MediaRemote
            // sources that occasionally publish duration: 0 or NaN
            // (e.g. live radio streams, podcast preroll) — without
            // this, `clamped / total` divides by zero and the bar
            // jumps to NaN width.
            let rawTotal = info.duration ?? 0
            let total = (rawTotal.isFinite && rawTotal > 0) ? rawTotal : 0
            let hasTiming = total > 0 && info.elapsedTime != nil
            TimelineView(.periodic(from: .now, by: 0.25)) { context in
                let position = hasTiming ? (info.currentPosition(at: context.date) ?? 0) : 0
                let clamped = hasTiming ? min(max(position, 0), total) : 0
                // While the user is actively scrubbing, render the
                // bar at their drag position so the UI feels locked
                // to the cursor. As soon as they release, we snap
                // back to the live `clamped` from the timeline (and
                // dispatch a real seek to the source app — see
                // `seek(toFraction:)`).
                // `total > 0` is guaranteed when hasTiming is true
                // (see the validity check above), so the division is
                // safe — but compute defensively anyway in case a
                // future refactor flips the invariant.
                let progress: Double = {
                    guard hasTiming, total > 0 else { return 0 }
                    return isScrubbing ? scrubProgress : clamped / total
                }()
                let displayed = isScrubbing ? scrubProgress * total : clamped
                VStack(spacing: 6) {
                    GeometryReader { geo in
                        let trackHeight: CGFloat = (isProgressHovering || isScrubbing) ? 6 : 4
                        ZStack(alignment: .leading) {
                            // Track: recessed pill the bar slides over.
                            // Thickens slightly on hover/scrub for
                            // tactile "I'm interactive" feedback.
                            Capsule()
                                .fill(Color.white.opacity(0.12))
                                .frame(height: trackHeight)
                            // Fill with artwork-color gradient.
                            Capsule()
                                .fill(
                                    LinearGradient(
                                        colors: progressBarColors,
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .frame(
                                    width: max(2, geo.size.width * progress),
                                    height: trackHeight
                                )
                            // Scrubber thumb — visible on HOVER as
                            // well as during scrubbing. The hover
                            // visibility is the affordance: when the
                            // user mouses over the bar, the dot
                            // appears, signaling "this is grabbable."
                            // Smooth size/offset animations make the
                            // hover transition feel polished rather
                            // than popping in instantly.
                            Circle()
                                .fill(Color.white)
                                .frame(width: 10, height: 10)
                                .shadow(color: Color.black.opacity(0.3), radius: 2, x: 0, y: 1)
                                .offset(x: max(0, geo.size.width * progress - 5))
                                .opacity((isScrubbing || isProgressHovering) ? 1 : 0)
                                .animation(.easeOut(duration: 0.15),
                                           value: isProgressHovering)
                        }
                        .frame(height: 14, alignment: .center)
                        .onHover { hovering in
                            withAnimation(.easeOut(duration: 0.15)) {
                                isProgressHovering = hovering
                            }
                            // Only push the cursor when there's
                            // actually something to scrub (timing
                            // available). Pushing pointingHand on a
                            // dead bar is a lie — the click won't do
                            // anything. Pop on exit either way to
                            // avoid leaking pushed cursors if the
                            // view disappears mid-hover.
                            if hovering, hasTiming {
                                NSCursor.pointingHand.push()
                            } else {
                                NSCursor.pop()
                            }
                        }
                        // Hit area is taller than the visible track
                        // (14pt vs 4pt) so the bar is easy to grab —
                        // SwiftUI's gesture system requires a real
                        // surface to hit-test against, and a 4pt
                        // capsule is essentially impossible to land
                        // on with a trackpad. `contentShape(Rectangle)`
                        // makes the entire 14pt-tall band draggable.
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    // Don't allow scrubbing on a bar
                                    // with no timing — visual movement
                                    // would imply seekability we don't
                                    // have. Better to feel inert than
                                    // to feel broken.
                                    guard hasTiming, geo.size.width > 0 else { return }
                                    let frac = max(0, min(1, value.location.x / geo.size.width))
                                    isScrubbing = true
                                    scrubProgress = frac
                                }
                                .onEnded { value in
                                    guard hasTiming, geo.size.width > 0 else {
                                        isScrubbing = false
                                        return
                                    }
                                    let frac = max(0, min(1, value.location.x / geo.size.width))
                                    isScrubbing = false
                                    // `.alignment` haptic on release —
                                    // matches Alcove's "snap to value"
                                    // feel. Reads as the bar locking
                                    // into the new position.
                                    HapticFeedback.alignment()
                                    seek(toFraction: frac, total: total)
                                }
                        )
                        .accessibilityLabel("Playback position")
                        .accessibilityValue(hasTiming
                            ? "\(Self.timeString(displayed)) of \(Self.timeString(total))"
                            : "Position not available")
                    }
                    .frame(height: 14)
                    if hasTiming {
                        HStack {
                            Text(Self.timeString(displayed))
                                .font(.system(size: 11, weight: .medium))
                                .monospacedDigit()
                                .foregroundStyle(.white.opacity(0.6))
                            Spacer()
                            Text("-\(Self.timeString(max(total - displayed, 0)))")
                                .font(.system(size: 11, weight: .medium))
                                .monospacedDigit()
                                .foregroundStyle(.white.opacity(0.6))
                        }
                        // Hide the time labels from VoiceOver — the
                        // bar's own accessibilityValue already
                        // announces position/total, so reading these
                        // separately is redundant chatter.
                        .accessibilityHidden(true)
                    }
                }
            }
        }
    }

    /// Send a seek command to the source app. macOS's MediaRemote
    /// `MRMediaRemoteSendCommand` doesn't expose a public seek, so
    /// we route through AppleScript for the two main supported apps
    /// (Spotify and Apple Music — both implement
    /// `set player position to <seconds>`). Other sources (YouTube
    /// in a browser tab, Podcasts, third-party players) silently
    /// no-op; the bar still updates visually while the user is
    /// dragging, which is the more important feedback. Run on a
    /// background queue because `NSAppleScript.executeAndReturnError`
    /// can take 100-300ms — blocking the main thread would cause a
    /// visible UI hitch on release.
    private func seek(toFraction fraction: Double, total: TimeInterval) {
        guard let bundleID = presenter.nowPlaying?.sourceBundleID else { return }
        // Defend against `total` going non-finite at the call site
        // (the progress bar already filters but seek is callable
        // from anywhere a future caller might add).
        guard total.isFinite, total > 0, fraction.isFinite else { return }
        let appName: String
        switch bundleID {
        case "com.spotify.client": appName = "Spotify"
        case "com.apple.Music": appName = "Music"
        default: return
        }
        let target = max(0, min(total, fraction * total))

        // OPTIMISTIC LOCAL UPDATE — fire BEFORE dispatching the
        // AppleScript so the bar lands at the new position on the
        // very next render. Without this, `lastInfo.elapsedTime`
        // stays at the pre-seek value, the TimelineView keeps
        // extrapolating from there, and the bar visibly snaps
        // back to the old position until the 2.5s AppleScript
        // refresher catches up. User: "I'm clicking it and it's
        // reacting to the click, but it's not moving the bar
        // where it should move." The next authoritative refresh
        // (within 2.5s) will land within a fraction of a second
        // of `target` and there's no perceptible jump because the
        // optimistic value is already correct.
        if let last = presenter.nowPlaying {
            presenter.nowPlaying = NowPlayingInfo(
                title: last.title,
                artist: last.artist,
                album: last.album,
                artworkData: last.artworkData,
                isPlaying: last.isPlaying,
                sourceBundleID: last.sourceBundleID,
                duration: last.duration,
                elapsedTime: target,
                infoTimestamp: Date()
            )
        }

        let script = "tell application \"\(appName)\" to set player position to \(target)"
        DispatchQueue.global(qos: .userInitiated).async {
            var error: NSDictionary?
            if let scriptObj = NSAppleScript(source: script) {
                _ = scriptObj.executeAndReturnError(&error)
                // Log permission/app-not-running failures to the
                // console so we can diagnose silent seek issues
                // without crashing or showing a UI alert. The user
                // already gets the "scrubber didn't move" visual
                // feedback when the source ignores the seek; the
                // log gives us something actionable in postmortems.
                if let error = error {
                    NSLog("[MusicPanel] seek to \(target)s in \(appName) failed: \(error)")
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
        let isPlaying = presenter.nowPlaying?.isPlaying ?? false
        // Pull the artwork's dominant color and use it as the accent
        // tint on the transport-button backgrounds. Same color as
        // the timeline gradient, so the whole bottom half of the
        // panel reads as a unified chromatic accent. Falls back to
        // white so the previous monochrome look returns when no
        // artwork is available.
        let accent = ArtworkColor.dominant(from: presenter.nowPlaying?.artworkData) ?? .white
        return HStack(spacing: 24) {
            MusicControlButton(
                systemImage: "backward.fill",
                glyphSize: 16,
                buttonSize: 38,
                isPrimary: false,
                accent: accent,
                accessibility: "Previous track"
            ) {
                dispatch(.previous)
            }

            // Primary play/pause button — slightly larger, with the
            // artwork-color accent fill that gives it visual weight
            // as the focal action. Same color language as the
            // timeline so the surface reads as one unified accent.
            MusicControlButton(
                systemImage: isPlaying ? "pause.fill" : "play.fill",
                glyphSize: 22,
                buttonSize: 50,
                isPrimary: true,
                accent: accent,
                accessibility: isPlaying ? "Pause" : "Play"
            ) {
                dispatch(.togglePlayPause)
            }

            MusicControlButton(
                systemImage: "forward.fill",
                glyphSize: 16,
                buttonSize: 38,
                isPrimary: false,
                accent: accent,
                accessibility: "Next track"
            ) {
                dispatch(.next)
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// Debounced wrapper around `presenter.onMediaCommand` — drops
    /// any command that lands within 150ms of the previous one. This
    /// prevents a stack of queued commands from rapid taps overshooting
    /// the user's intent (e.g. mashing Next four times when they meant
    /// "skip forward one track but the source app was slow"). Toggle
    /// play/pause is the most visible failure mode of un-debounced
    /// dispatch — without this, a double-tap can land as
    /// pause-then-play on Spotify while Apple Music swallows the
    /// second command, leaving the two sources out of sync visually.
    private func dispatch(_ command: MediaRemoteService.Command) {
        let now = Date()
        if now.timeIntervalSince(lastCommandAt) < 0.15 { return }
        lastCommandAt = now
        // `.generic` is the lightest of the three NSHapticFeedback
        // patterns — a quiet "tick" that confirms the button
        // registered. Stronger patterns on a transport button get
        // tiring across a session. The 150ms debounce above also
        // serves as a haptic anti-spam guard, mirroring Alcove's
        // `hasRecentlyTriggeredHaptic` flag pattern.
        HapticFeedback.generic()
        presenter.onMediaCommand?(command)
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
            HStack(spacing: 6) {
                // Speaker glyph — gives the badge a visual hook so
                // it reads as "audio source" at a glance, rather
                // than a generic line of text floating below the
                // controls. Sized to match the label cap-height.
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
                Text("Playing in \(appName)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            // Pill background — subtle white overlay that lifts the
            // badge off the slab surface and reads as a discrete
            // chip. Without this the text floated formless below the
            // transport row.
            .background(
                Capsule()
                    .fill(Color.white.opacity(0.06))
                    .overlay(
                        Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
                    )
            )
        }
    }

    private static func localizedAppName(forBundleID bundleID: String) -> String? {
        // Hard-coded canonical names for the apps we know about take
        // precedence over the bundle's `CFBundleDisplayName`. Some
        // apps publish Display values like "Spotify Free" or
        // "Apple Music" that read awkwardly in the badge ("Playing
        // in Apple Music" reads weirdly when the app is just the
        // built-in Music). The canonical map keeps the badge tight.
        if let canonical = canonicalShortName(forBundleID: bundleID) {
            return canonical
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return shortName(forBundleID: bundleID)
        }
        let bundle = Bundle(url: url)
        let display = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
        let name = bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
        return display ?? name ?? shortName(forBundleID: bundleID)
    }

    /// Curated short names for the apps we care about. Returning
    /// nil means "fall through to `urlForApplication` / `shortName`."
    private static func canonicalShortName(forBundleID bundleID: String) -> String? {
        switch bundleID {
        case "com.apple.Music":            return "Music"
        case "com.spotify.client":         return "Spotify"
        case "com.apple.podcasts":         return "Podcasts"
        case "com.apple.TV":               return "TV"
        case "com.apple.Safari":           return "Safari"
        case "com.google.Chrome":          return "Chrome"
        case "com.google.Chrome.canary":   return "Chrome Canary"
        case "company.thebrowser.Browser": return "Arc"
        case "com.brave.Browser":          return "Brave"
        case "org.mozilla.firefox":        return "Firefox"
        case "com.microsoft.edgemac":      return "Edge"
        default: return nil
        }
    }

    /// Best-effort fallback when we can't resolve a real Bundle —
    /// e.g. unknown bundles or running in a sandbox where
    /// `urlForApplication` returns nil.
    private static func shortName(forBundleID bundleID: String) -> String? {
        if let canonical = canonicalShortName(forBundleID: bundleID) {
            return canonical
        }
        // Strip the reverse-DNS prefix, capitalize the last segment
        // so "com.example.MyPlayer" → "MyPlayer".
        let last = bundleID.split(separator: ".").last.map(String.init) ?? bundleID
        return last
    }
}

/// Extracted into its own struct so the per-button @State (hover) is
/// scoped correctly — a single shared @State on MusicPanelView would
/// flicker every button at once on cursor entry.
private struct MusicControlButton: View {
    let systemImage: String
    let glyphSize: CGFloat
    let buttonSize: CGFloat
    let isPrimary: Bool
    /// Artwork-extracted accent color. Used to tint the button's
    /// background fill so the transport row picks up the same
    /// chromatic identity as the timeline gradient and waveform.
    let accent: Color
    let accessibility: String
    let action: () -> Void

    @State private var isHovered = false
    @State private var isPressed = false

    var body: some View {
        Button(action: action) {
            ZStack {
                // Background fill: primary buttons get an artwork-
                // tinted gradient (white → accent) — same color
                // language as the timeline, so the whole transport
                // row feels chromatically connected to the playing
                // track. Secondary buttons (prev/next) fade in a
                // subtle accent-tinted hover background only on
                // cursor entry.
                if isPrimary {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [Color.white.opacity(isPressed ? 0.22 : isHovered ? 0.18 : 0.14), accent.opacity(isPressed ? 0.45 : isHovered ? 0.38 : 0.30)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .overlay(
                            Circle()
                                .strokeBorder(accent.opacity(0.35), lineWidth: 0.5)
                        )
                } else {
                    Circle()
                        .fill(accent.opacity(isPressed ? 0.22 : 0.14))
                        .opacity(isHovered || isPressed ? 1 : 0)
                }

                Image(systemName: systemImage)
                    .font(.system(size: glyphSize, weight: isPrimary ? .semibold : .medium))
                    .foregroundStyle(.white.opacity(isPrimary ? 1.0 : 0.85))
                    // Tiny scale spring on press for tactile feedback —
                    // 8% squeeze on press, bouncy snap back on release.
                    .scaleEffect(isPressed ? 0.92 : 1.0)
            }
            .frame(width: buttonSize, height: buttonSize)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibility)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) { isHovered = hovering }
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !isPressed {
                        withAnimation(.easeOut(duration: 0.08)) { isPressed = true }
                    }
                }
                .onEnded { _ in
                    // Bouncy release — the button "pops" back from
                    // the pressed state with a slight overshoot,
                    // giving the press a tactile rebound. Lower
                    // damping than the default spring so the bounce
                    // is visible. Keeps the press DOWN sharp
                    // (easeOut) and only adds spring on release.
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.5)) {
                        isPressed = false
                    }
                }
        )
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
