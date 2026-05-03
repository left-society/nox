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

    /// 3D-tilt swap phase for the artwork. -1 = exiting (tilted away
    /// from viewer + faded), 0 = at rest, +1 = entering (tilted
    /// from below toward viewer). Animated by `triggerArtworkSwap`
    /// on track changes AND immediately on `dispatch(.next/.previous)`
    /// — the eager trigger means the artwork starts moving the moment
    /// the user clicks the button, not after the source app finally
    /// reports the new track. That's what makes Alcove's transitions
    /// feel zero-latency: the animation runs in PARALLEL with the
    /// underlying track change, so the new artwork lands at the end
    /// of the in-flight tilt rather than after a lag.
    @State private var artworkSwapPhase: Double = 0
    /// Cumulative Y-axis flip angle for the new (DynamicNotch-style)
    /// swap animation. Each track change does `+= 180`; the cosineSign
    /// modifier mirrors the X scale on the back face so the artwork
    /// is never visually mirrored. Reference: jackson-storm/DynamicNotch
    /// `Features/NowPlaying/Components/ArtworkView.swift` —
    /// `AlbumArtFlipModifier`. Single rotation + sign-flip is the
    /// cleanest possible "vinyl card flip" — replaces the previous
    /// 5-axis stack (offset + blur + scale + 3D rotate + opacity)
    /// the user described as "weird tilted."
    @State private var artworkFlipAngle: Double = 0
    /// Direction of the swap: -1 = previous (tilt toward right edge),
    /// +1 = next (tilt toward left edge). Determines the rotation
    /// axis sign so the artwork visually moves in the direction
    /// matching the user's intent.
    @State private var artworkSwapDirection: Double = 1
    /// Stable identity for the currently-displayed track, used to
    /// detect actual track changes vs. content-only refreshes.
    @State private var displayedTrackKey: String = ""
    /// The artwork data we're CURRENTLY displaying. Decoupled from
    /// `presenter.nowPlaying.artworkData` so that during a swap-out,
    /// we can keep showing the OLD artwork until the swap-in phase
    /// — preventing a frame where the new artwork appears at full
    /// alpha before the entrance animation runs.
    @State private var displayedArtworkData: Data? = nil
    /// Title/artist/album we're currently displaying. Decoupled from
    /// `presenter.nowPlaying` (just like `displayedArtworkData`) so
    /// title/artist text fades through the swap animation in lockstep
    /// with the artwork — without this, the text would SNAP to the
    /// new values the moment Spotify's MediaRemote pushed them, while
    /// the artwork was still tilting out. User saw the artwork
    /// animate but the text snap, and reported "still laggy inside."
    /// elapsedTime / isPlaying are NOT decoupled — those need to be
    /// live (progress bar, waveform).
    @State private var displayedTitle: String = ""
    @State private var displayedArtist: String = ""
    @State private var displayedAlbum: String = ""
    /// Cached decoded NSImage for the slab artwork. Populated from
    /// `ArtworkCache` synchronously on cache hit, asynchronously
    /// on miss. Keeps the main thread off the NSImage(data:) decode
    /// hot path and gives instant return-to-recent.
    @State private var displayedArtworkImage: NSImage? = nil
    /// Source-app sound volume on a 0-1 scale. Polled on track
    /// change and dispatched on slider drag. Spotify and Apple Music
    /// both expose `sound volume` (0-100) in AppleScript.
    @State private var sourceVolume: Double = 0.7
    /// While the user is actively dragging the volume slider, we
    /// suppress polled-value updates so the slider doesn't jitter
    /// between the user's intended value and the value we just
    /// dispatched (round-trip latency is ~100ms). Released when the
    /// slider's onEditingChanged ends.
    @State private var isAdjustingVolume: Bool = false

    var body: some View {
        // Gradient lives at PanelRootView level now (so it covers
        // the actual TOP of the panel, behind the header / tabs)
        // — see `artworkTopGradient` there. This view just lays
        // out the music HUD content on top of the panel-level tint.
        //
        // Composition: the now-playing block (artwork + title/
        // artist/album + waveform visualizer) is wrapped in an
        // inset rounded card to give the "what's playing"
        // identity a defined surface — pattern Apple uses on the
        // Sonoma+ Music app's mini player and Settings detail
        // cards. Progress / transport / volume stay flat on the
        // slab below for the airy Apple Music transport-row look.
        // 2026-04-29 layout: transport (prev/play/next) + volume
        // moved INTO the now-playing card's right wing — see
        // `inlineControlsCluster`. The bottom transport row is
        // gone, removing ~58pt of vertical space and any chance
        // of the play button clipping. `transportControls` is
        // kept as a private helper for now (referenced internally
        // by the dispatch chain) but isn't rendered.
        VStack(spacing: 12) {
            nowPlayingCard
            progressBar
            // 2026-05-02 transport + inline mini-volume row.
            // Volume is a small trim control on the right of the
            // transport buttons (per user spec — "should be at
            // the right side of the play button much smaller").
            iosStyleTransportRow
            // BluetoothBatteryRow removed at user request — the
            // component file is still present (BluetoothBatteryRow.swift)
            // but isn't rendered.
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.Spacing.md)
        .padding(.top, DS.Spacing.md)
        // 2026-04-29: bumped bottom 6pt → 14pt so the progress
        // bar's time labels clear the panel's bottom rounded
        // corner. With 6pt the label descenders were getting
        // sliced off by the silhouette's curved bottom edge —
        // user reported "numbers are unvisible here." 14pt gives
        // the 11pt-tall labels a comfortable 3pt safe area below.
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// Inset card wrapping the artwork + metadata + waveform row.
    /// Gives the now-playing block a defined surface so it reads
    /// as ONE cohesive "this is what's playing" element rather
    /// than three orphans floating on the slab.
    ///
    /// Surface spec mirrors macOS Sonoma+ inset cards:
    ///   • 14pt corner radius (`DS.Radius.card`)
    ///   • 5% white fill — visible-but-quiet lift off the black
    ///     slab; never competes with the artwork's saturation
    ///   • 0.5pt hairline stroke at 7% white — defines the edge
    ///     without screaming
    ///   • 12pt internal padding so artwork + text breathe
    ///     against the card walls
    private var nowPlayingCard: some View {
        infoRow
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                    .fill(DS.Color.bgCard)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                    .strokeBorder(DS.Color.strokeCard, lineWidth: 0.5)
            )
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
        // Text snaps to new values directly from `presenter.nowPlaying`.
        // We tried decoupled `displayedTitle/Artist/Album` state with
        // a fade-and-slide modifier on the text block, but the user
        // reported the transport row visibly JUMPING during a Next
        // click — the modifier was the regression ("previous titling
        // wasn't causing this"). Snapping the text removes any
        // dependency between the text block's transform/opacity and
        // the layout below it, which is what the user wants.
        //
        // EMPTY → PLAYING SMOOTHING (2026-04-29): bound the labels
        // to the `displayed*` state vars (which update inside
        // `applyDisplayed`, called from `runFullArtworkSwap` at
        // the BOTTOM of the artwork tilt-out — the exact moment
        // the artwork is invisible at phase=-1). With direct
        // `info?.title` binding, the text snapped to the new value
        // at t=0 while the artwork was still at the start of its
        // 800ms tilt — a visible "text jumped, art is still
        // animating" desync the user reported as "kind of jumps to
        // the music part." Now text changes happen IN LOCKSTEP
        // with the artwork swap: both update at the swap moment,
        // both fade back in together. Critical: NO offset/transform
        // on the text block — that was the layout-reflow bug from
        // the previous decoupled attempt. Just synchronized content
        // changes, layout stays nailed.
        //
        // Empty-state fallback: when `displayedTitle` is empty
        // (nothing playing yet), show "Nothing playing" placeholder.
        // Once a track lands, this flips to the real title at the
        // synchronized swap moment.
        let displayedTitleResolved = displayedTitle.isEmpty ? "Nothing playing" : displayedTitle
        let title = displayedTitleResolved
        let artist = displayedArtist
        let album = displayedAlbum
        let tint = ArtworkColor.dominant(from: displayedArtworkData ?? info?.artworkData) ?? .white
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
                    // Title — always rendered.
                    titleText(title)
                    // Artist — ALWAYS rendered (non-conditional). Empty
                    // value falls back to a single space char so the
                    // Text view still reserves its line height. This is
                    // what fixes the "transport row jumps" bug:
                    // previously this line was wrapped in
                    // `if !artist.isEmpty { ... }`, so a track with
                    // missing artist had ZERO height for this row,
                    // and any track change that flipped artist between
                    // empty and non-empty (very common with Spotify's
                    // two-stage emission — title arrives first, artist
                    // ~100-200ms later) reflowed the whole VStack.
                    // Reflow propagated through the parent VStack,
                    // bumping the progress bar / transport row down
                    // by ~22pt mid-animation. Locking the height to
                    // 3 stable lines kills the reflow.
                    // Artist line doubles as the empty-state subtitle.
                    // When nothing is playing, this slot fills with a
                    // helpful hint ("Open Spotify, Apple Music, or any
                    // audio source") instead of sitting blank — the
                    // user reported the empty state felt "empty" /
                    // unintentional. The slot retains the same line
                    // height in both states (13pt medium), so the
                    // layout is locked and the empty→playing
                    // transition is just a content swap (which fires
                    // synchronously with the artwork tilt — see the
                    // displayed* binding above).
                    artistText(
                        text: displayedTitle.isEmpty
                            ? "Open Spotify, Apple Music, or any audio source"
                            : (artist.isEmpty ? " " : artist),
                        isHint: displayedTitle.isEmpty,
                        artist: artist
                    )
                    // Album — same fix as artist. Hidden in empty
                    // state (the subtitle above already conveys the
                    // hint; a third dimmed line of placeholder text
                    // would over-load the empty card).
                    albumText(album)
                }
                // No fade or offset on the text block. Earlier this
                // had `.opacity(1.0 - abs(artworkSwapPhase))` and
                // `.offset(x: artworkSwapPhase * 4 * artworkSwapDirection)`
                // to keep text in lockstep with the artwork tilt.
                // The user reported visible JUMPS in the transport
                // row beneath the text block when these modifiers
                // were present ("previous titling wasn't causing
                // this"). Removing them lets the text snap as before
                // and isolates the swap animation to the artwork
                // tile alone — which is what the user wants.
                //
                // What we DO animate: the opacity and color of the
                // artist/album lines tied to `displayedTitle`
                // emptiness. Going empty → playing or vice versa
                // changes the hint/value, the hint dim 0.55, and the
                // artist value brightness 0.85 — easing those
                // crossfades in over ~0.35s removes the harsh snap
                // without re-introducing the layout-reflow bug
                // (no offset, no transform — just opacity/color).
                // Cap title block at 280pt so the sphere
                // visualizer sits visually adjacent to the title
                // text. With the wider 530pt slab, the previous
                // `maxWidth: .infinity` stretched the title block
                // full-width and pushed the sphere alone to the far
                // right corner — felt disconnected from the music
                // card. 280pt is comfortable for typical track
                // titles; longer ones still truncate via
                // .lineLimit(1).
                // Shrunk 280 → 200 so the inline controls cluster
                // (transport + volume) sits visually near the
                // CENTER of the card instead of pinned to the
                // right edge. With balanced Spacers around the
                // cluster, less title width = more room for the
                // Spacers to flex, which moves the cluster
                // leftward toward the geometric middle of the
                // card. Long titles still truncate via lineLimit(1).
                // 2026-05-02: was capped at 200pt to leave room for
                // the inline-controls cluster on the right. With
                // controls moved to a row below, the title block
                // can grow to fill the remaining width — same way
                // iOS lock-screen Now Playing widget does. Long
                // titles still truncate via .lineLimit(1).
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                // Smooth crossfade for the opacity/color changes
                // tied to empty↔playing. Doesn't animate text
                // content (atomic on macOS 13), but the surrounding
                // chrome eases — combined with the artwork tilt
                // that's running in parallel, the empty→playing
                // transition reads as one coordinated motion
                // instead of a hard snap.
                .animation(.smooth(duration: 0.35), value: displayedTitle.isEmpty)
                .animation(.smooth(duration: 0.35), value: artist.isEmpty)
                .animation(.smooth(duration: 0.35), value: album.isEmpty)
            }
            .buttonStyle(.plain)
            .help(sourceAppHelpText())
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Self.metadataAccessibilityLabel(
                title: title, artist: artist, album: album
            ))

            // 2026-05-02 iOS-style restructure. Per the user's
            // reference screenshot (iOS lock-screen Now Playing
            // widget), transport controls move OUT of the title
            // row and BELOW the progress bar — see `transportRow`.
            // The title row is now just artwork + title VStack,
            // with the title block expanding to fill the remaining
            // width like Apple's lock-screen widget does. Volume
            // slider removed entirely; user can use system volume
            // (matches the iOS reference which has no inline
            // volume slider in the compact widget).
            Spacer(minLength: 0)
        }
    }

    /// Inline prev / play / next / volume cluster that lives in
    /// the right wing of the now-playing card. Replaces the
    /// previous bottom transport row + waveform. Two-row stack:
    ///   • Top: prev (28pt) — play (38pt) — next (28pt)
    ///   • Bottom: speaker icon + compact volume slider (90pt)
    ///
    /// Vertical layout matches the artwork tile's 76pt height so
    /// the card stays visually balanced (artwork left, controls
    /// right, both 76pt tall).
    @ViewBuilder
    private func inlineControlsCluster(accent: Color) -> some View {
        // 2026-05-01 v2 (evidence-based revert). The earlier swap to
        // `presenter.isAudioFlowing` was based on the assumption that
        // CoreAudio would drop the signal promptly when the user
        // paused in the source app. /tmp/notetaker-mra.log proved
        // otherwise — Chrome keeps its audio-helper IO procs alive
        // through pause, so isAudioFlowing stays TRUE indefinitely
        // for browser-sourced audio. The icon was therefore stuck
        // on pause.fill forever for paused YouTube. Reverting to
        // MediaRemote's isPlaying flag (or nil = paused) gives a
        // ~2s lag (waiting for MR's pause-event emit) which is
        // strictly better than infinite. For Spotify/Music both
        // signals agree.
        let isPlaying = presenter.nowPlaying?.isPlaying ?? false
        VStack(alignment: .trailing, spacing: 8) {
            HStack(spacing: 10) {
                MusicControlButton(
                    systemImage: "backward.fill",
                    glyphSize: 12,
                    buttonSize: 28,
                    isPrimary: false,
                    accent: accent,
                    accessibility: "Previous track"
                ) { dispatch(.previous) }
                MusicControlButton(
                    systemImage: isPlaying ? "pause.fill" : "play.fill",
                    glyphSize: 16,
                    buttonSize: 38,
                    isPrimary: true,
                    accent: accent,
                    accessibility: isPlaying ? "Pause" : "Play"
                ) { dispatch(.togglePlayPause) }
                MusicControlButton(
                    systemImage: "forward.fill",
                    glyphSize: 12,
                    buttonSize: 28,
                    isPrimary: false,
                    accent: accent,
                    accessibility: "Next track"
                ) { dispatch(.next) }
            }
            volumeControl
                .frame(width: 130)
        }
    }

    /// 2026-05-02 compact volume row.
    ///
    /// User feedback: full-width slider was too prominent —
    /// dominated the bottom of the music card. Pulled in to a
    /// fixed 160pt slider beside the speaker icon, centered
    /// horizontally. Reads as a quiet trim control rather than
    /// the focal element. Same underlying state binding as the
    /// original `volumeControl`. Disabled / dimmed when the
    /// source app doesn't support remote-volume AppleScript
    /// (anything other than Spotify or Music).
    private var iosStyleVolumeRow: some View {
        let bundleID = presenter.nowPlaying?.sourceBundleID
        let supported = bundleID == "com.spotify.client" || bundleID == "com.apple.Music"
        return HStack(spacing: 10) {
            Spacer(minLength: 0)
            Image(systemName: volumeIcon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(supported ? 0.55 : 0.25))
                .frame(width: 16, alignment: .center)
            Slider(
                value: Binding(
                    get: { sourceVolume },
                    set: { newValue in
                        sourceVolume = newValue
                        setSourceVolume(newValue)
                    }
                ),
                in: 0...1,
                onEditingChanged: { editing in
                    isAdjustingVolume = editing
                }
            )
            .controlSize(.mini)
            .frame(width: 160)
            .tint(Color.white.opacity(0.75))
            .disabled(!supported)
            Spacer(minLength: 0)
        }
    }

    /// 2026-05-02 transport + inline mini-volume row.
    ///
    /// Layout (left → right):
    ///   [── balance spacer ──]  [⏪ ⏸ ⏩]  [🔊─slider]
    ///
    /// The transport cluster (prev/play/next) is the visual focal
    /// point and stays HORIZONTALLY CENTERED via a balance spacer
    /// on the left equal in width to the volume control on the
    /// right. Volume is a quiet 70pt mini-slider with a small
    /// speaker icon — reads as a trim control, not a primary
    /// element.
    private var iosStyleTransportRow: some View {
        let isPlaying = presenter.nowPlaying?.isPlaying ?? false
        let accent = ArtworkColor.dominant(from: presenter.nowPlaying?.artworkData) ?? .white
        let bundleID = presenter.nowPlaying?.sourceBundleID
        let volumeSupported = bundleID == "com.spotify.client" || bundleID == "com.apple.Music"
        // Both flanks are 100pt wide so the transport buttons
        // stay centered on the panel midline.
        let flankWidth: CGFloat = 100

        return HStack(spacing: 0) {
            // LEFT: balance spacer — same width as the right-flank
            // volume cluster so the play button lands on center.
            Color.clear
                .frame(width: flankWidth, height: 1)

            Spacer(minLength: 0)

            // CENTER: transport cluster
            HStack(spacing: 28) {
                MusicControlButton(
                    systemImage: "backward.fill",
                    glyphSize: 16,
                    buttonSize: 36,
                    isPrimary: false,
                    accent: accent,
                    accessibility: "Previous track"
                ) { dispatch(.previous) }
                MusicControlButton(
                    systemImage: isPlaying ? "pause.fill" : "play.fill",
                    glyphSize: 22,
                    buttonSize: 50,
                    isPrimary: true,
                    accent: accent,
                    accessibility: isPlaying ? "Pause" : "Play"
                ) { dispatch(.togglePlayPause) }
                MusicControlButton(
                    systemImage: "forward.fill",
                    glyphSize: 16,
                    buttonSize: 36,
                    isPrimary: false,
                    accent: accent,
                    accessibility: "Next track"
                ) { dispatch(.next) }
            }

            Spacer(minLength: 0)

            // RIGHT: mini-volume — speaker icon + 70pt slider.
            // Quiet trim control, not the focal element.
            HStack(spacing: 5) {
                Image(systemName: volumeIcon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(volumeSupported ? 0.55 : 0.25))
                    .frame(width: 12, alignment: .center)
                Slider(
                    value: Binding(
                        get: { sourceVolume },
                        set: { newValue in
                            sourceVolume = newValue
                            setSourceVolume(newValue)
                        }
                    ),
                    in: 0...1,
                    onEditingChanged: { editing in
                        isAdjustingVolume = editing
                    }
                )
                .controlSize(.mini)
                .frame(width: 70)
                .tint(Color.white.opacity(0.65))
                .disabled(!volumeSupported)
            }
            .frame(width: flankWidth, alignment: .trailing)
        }
    }

    // MARK: - Text helpers (with macOS 14+ content crossfade)
    //
    // Wraps Text views for the title/artist/album so the actual
    // string content crossfades on changes (macOS 14's
    // `.contentTransition(.opacity)`). On macOS 13 the call is a
    // no-op and the text snaps as before — but the surrounding
    // chrome (color, opacity) still eases via the `.animation`
    // modifier on the parent VStack, so the empty→playing
    // transition is much softer than the old hard snap.

    @ViewBuilder
    private func titleText(_ value: String) -> some View {
        let base = Text(value)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .truncationMode(.tail)
            .help(value)
        if #available(macOS 14.0, *) {
            base.contentTransition(.opacity)
        } else {
            base
        }
    }

    @ViewBuilder
    private func artistText(text: String, isHint: Bool, artist: String) -> some View {
        let base = Text(text)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white.opacity(isHint ? 0.55 : 0.85))
            .lineLimit(1)
            .truncationMode(.tail)
            .help(artist)
            .opacity(isHint || !artist.isEmpty ? 1 : 0)
        if #available(macOS 14.0, *) {
            base.contentTransition(.opacity)
        } else {
            base
        }
    }

    @ViewBuilder
    private func albumText(_ value: String) -> some View {
        let base = Text(value.isEmpty ? " " : value)
            .font(.system(size: 11, weight: .regular))
            .foregroundStyle(.white.opacity(0.55))
            .lineLimit(1)
            .truncationMode(.tail)
            .help(value)
            .opacity(value.isEmpty ? 0 : 1)
        if #available(macOS 14.0, *) {
            base.contentTransition(.opacity)
        } else {
            base
        }
    }

    // MARK: - Volume control

    /// Compact horizontal slider with a state-aware speaker glyph
    /// on the leading edge. Drag dispatches the new volume to the
    /// source app via `set sound volume to N` AppleScript. While
    /// the user is dragging, the polled value (refreshed on every
    /// track change + 2s) is suppressed so the slider doesn't
    /// fight the user's input.
    @ViewBuilder
    private var volumeControl: some View {
        let bundleID = presenter.nowPlaying?.sourceBundleID
        let supported = bundleID == "com.spotify.client" || bundleID == "com.apple.Music"
        HStack(spacing: 6) {
            Image(systemName: volumeIcon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(supported ? 0.65 : 0.30))
                .frame(width: 16, alignment: .center)
                // Symbol-effect replace transitions are macOS 14+.
                // We target 13.0, so the icon swap is just a hard
                // re-render on state change. Visually fine — the
                // surrounding scale + opacity already give the
                // toggle plenty of feedback.
            Slider(
                value: Binding(
                    get: { sourceVolume },
                    set: { newValue in
                        sourceVolume = newValue
                        setSourceVolume(newValue)
                    }
                ),
                in: 0...1,
                onEditingChanged: { editing in
                    isAdjustingVolume = editing
                }
            )
            .controlSize(.mini)
            .frame(width: 78)
            .tint(Color.white.opacity(0.88))
            .disabled(!supported)
        }
        .help(supported
              ? "Adjust \(bundleID == "com.spotify.client" ? "Spotify" : "Apple Music") volume"
              : "Volume control supported for Spotify and Apple Music")
    }

    /// State-driven SF Symbol — slash when muted, ramps up through
    /// "wave.1" / "wave.2" as volume increases. Reads at a glance
    /// without needing to look at the slider knob.
    private var volumeIcon: String {
        if sourceVolume <= 0.001 { return "speaker.slash.fill" }
        if sourceVolume < 0.34 { return "speaker.fill" }
        if sourceVolume < 0.67 { return "speaker.wave.1.fill" }
        return "speaker.wave.2.fill"
    }

    // toggleLike() and saveToSpotifyLikedSongs() removed — the
    // heart button was removed per user request because Spotify's
    // AppleScript dictionary doesn't expose a saved-tracks flag,
    // so the only Spotify path was a Cmd+S keystroke through
    // System Events that needs Accessibility permission. Without
    // that grant the heart filled but the song never actually
    // got saved ("UI lies"). With the button gone, this whole
    // branch is dead code.

    /// Push a new volume to the source app. 0-1 range gets scaled
    /// to AppleScript's 0-100 integer range.
    private func setSourceVolume(_ value: Double) {
        guard let bundleID = presenter.nowPlaying?.sourceBundleID else { return }
        let v = max(0, min(100, Int((value * 100).rounded())))
        let appName: String
        switch bundleID {
        case "com.apple.Music": appName = "Music"
        case "com.spotify.client": appName = "Spotify"
        default: return
        }
        let script = "tell application \"\(appName)\" to set sound volume to \(v)"
        runAppleScriptAsync(script)
    }

    /// Read the source app's current volume and reflect it into
    /// our @State. Called on track change so the volume slider
    /// stays accurate when the user changed Spotify / Music's
    /// volume from elsewhere while the slab was closed.
    ///
    /// Was `refreshLikedAndVolume` — the liked-state poll was
    /// removed when the heart button was removed (Spotify's
    /// AppleScript dictionary doesn't expose a saved-tracks flag,
    /// and without the heart there's no UI to drive).
    private func refreshVolume() {
        guard let bundleID = presenter.nowPlaying?.sourceBundleID else { return }
        let appName: String
        switch bundleID {
        case "com.apple.Music": appName = "Music"
        case "com.spotify.client": appName = "Spotify"
        default: return
        }

        let volScript = "tell application \"\(appName)\" to get sound volume"
        DispatchQueue.global(qos: .userInitiated).async {
            var error: NSDictionary?
            guard let scriptObj = NSAppleScript(source: volScript) else { return }
            let descriptor = scriptObj.executeAndReturnError(&error)
            if error != nil { return }
            let raw = descriptor.int32Value
            let normalized = Double(raw) / 100.0
            DispatchQueue.main.async {
                guard !isAdjustingVolume else { return }
                sourceVolume = max(0, min(1, normalized))
            }
        }
    }

    /// Background-queue dispatch wrapper for fire-and-forget
    /// AppleScript. Errors logged to the console so silent
    /// permission-denied / app-not-running cases are still
    /// diagnosable from a Console.app filter.
    private func runAppleScriptAsync(_ script: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            var error: NSDictionary?
            if let scriptObj = NSAppleScript(source: script) {
                _ = scriptObj.executeAndReturnError(&error)
                if let error = error {
                    NSLog("[MusicPanel] AppleScript failed: \(error)")
                }
            }
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
                // Use the cached/decoded NSImage directly. The
                // cache lookup happens off the render hot path
                // (in onAppear and onChange handlers), so this
                // branch just reads the cached image without
                // re-decoding.
                if let image = displayedArtworkImage {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fill)
                } else if let icon = sourceAppIcon(),
                          !isMusicAppSource(presenter.nowPlaying?.sourceBundleID) {
                    // Source-app-icon fallback ONLY for non-music
                    // sources — WhatsApp audio, some YouTube tabs,
                    // podcasts, browser-tab audio, etc. — where
                    // there's never going to be track art and the
                    // user benefits from the visual anchor: "in any
                    // other software or window where we use any
                    // kind of sounds ... it should register as that."
                    //
                    // For Spotify and Apple Music we deliberately
                    // skip this branch and fall through to
                    // `placeholderArt` instead. Reason: those
                    // sources DO have artwork, but the bytes can
                    // briefly be nil during the window between a
                    // notification firing (with title/artist only)
                    // and the iTunes Search / cache fetch
                    // completing. With this fallback enabled, that
                    // ~500ms window read as the album art
                    // "disappearing into a Spotify logo" — exactly
                    // what the user reported. Showing the neutral
                    // music-note placeholder instead means the
                    // brief artwork gap is invisible: the eye reads
                    // "art still loading" rather than "art gone."
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
            // Flatten artwork+border+shadow into a single rasterized
            // layer BEFORE the 3D rotation transform below. Without
            // compositingGroup, SwiftUI re-rasterizes the bordered
            // image + shadow on EVERY frame of the rotation as a
            // separate layer per child — that's the visible jitter
            // during track-change flips. With it, Core Animation
            // applies the 3D transform to a single flat texture.
            .compositingGroup()
            .shadow(color: Color.black.opacity(0.4), radius: 8, x: 0, y: 4)
            .contentShape(RoundedRectangle(cornerRadius: 12))
            // Full layered 3D-tumble swap. The user reported the
            // previous version's tilt was "not taking effect" —
            // two things were strangling it:
            //   1. ±32° at perspective 0.6 is subtle on a 76pt
            //      tile. Apple's docs: perspective < 1.0 = LESS
            //      foreshortening; default is 1.0; we need MORE.
            //   2. The opacity fade was linear in phase, so by
            //      the time rotation reached its peak (phase=±1),
            //      opacity was already 0 — the dramatic tilt was
            //      INVISIBLE.
            //
            // Fixed both:
            //   • Bumped angle to ±72° at perspective 1.0 → real
            //     foreshortening, the right edge clearly recedes
            //     on a Next press, left edge on a Previous.
            //   • Quadratic opacity (`1 - phase²`) keeps opacity
            //     near 1.0 through the early/middle of the tilt,
            //     dropping to 0 only in the final ~25% of the
            //     swap. The full rotation is now visible.
            //   • Slight x-axis component (0.15) adds a top-edge
            //     tip during the tumble — reads as a real 3D
            //     tumbling card, not just a y-axis flip.
            //
            // Direction-sensitive: `artworkSwapDirection` is +1
            // for next, -1 for previous. Set in `dispatch(_:)`,
            // NOT overwritten in `runFullArtworkSwap`, so back
            // button reverses the rotation axis as the user asked.
            //
            // All transform-only — no layout impact, transport
            // row stays nailed in place.
            // Clean Y-axis flip — single rotation + cosineSign-based
            // X-scale mirror so the back face of the rotation never
            // appears as a mirrored image. Replaces the previous
            // 5-axis transform stack (user feedback 2026-04-29:
            // "weird tilted"). Pattern lifted verbatim from
            // jackson-storm/DynamicNotch's AlbumArtFlipModifier.
            //
            // The image data swap (in `runFullArtworkSwap`) lands at
            // the mid-flip moment when the card is exactly edge-on
            // (angle ≡ 90° mod 180°), so the user never sees the
            // crossfade — same visual signature as Alcove and Sleeve.
            .rotation3DEffect(
                .degrees(artworkFlipAngle),
                axis: (x: 0, y: 1, z: 0),
                anchor: .center,
                anchorZ: 0,
                perspective: 0.5
            )
            .scaleEffect(x: artworkFlipCosineSign, y: 1)
        }
        .buttonStyle(.plain)
        .help(sourceAppHelpText())
        .onAppear {
            // Seed displayed state from current snapshot so the
            // first track that mounts doesn't trigger a phantom
            // swap animation.
            applyDisplayed(from: presenter.nowPlaying)
            // Pull the source app's current liked + volume so the
            // heart and slider reflect reality on first paint.
            refreshVolume()
        }
        .onChange(of: presenter.nowPlaying) { newInfo in
            let newKey = newInfo.map { "\($0.title)|\($0.artist)" } ?? ""
            // Same-track artwork refresh (async artwork arrived for
            // a track whose title/artist already landed). Critical:
            // ALSO trigger a cache lookup so the decoded NSImage is
            // populated. Without this, we'd update raw data but
            // never the displayed image — exactly the "next song's
            // thumbnail not appearing" bug. Spotify regularly pushes
            // metadata in two-stage emissions: title/artist first,
            // artwork ~100-300ms later as a same-track refresh.
            if newKey == displayedTrackKey {
                displayedArtworkData = newInfo?.artworkData
                if let info = newInfo, let data = info.artworkData {
                    let key = "\(info.title)|\(info.artist)"
                    // Per BUG-012 fix: ArtworkCache.image() no longer
                    // takes an onReady closure (it was documented as
                    // never firing). Just consume the synchronous
                    // return value.
                    if let img = ArtworkCache.shared.image(data: data, key: key) {
                        displayedArtworkImage = img
                    }
                }
                return
            }
            // Real track change → run the flip. The cumulative
            // `artworkFlipAngle += 180` pattern naturally handles
            // mid-flight consecutive clicks — every track change
            // just adds another 180° to the rotation, so a fast
            // double-tap ends at 360° (back at the start) with
            // both intermediate swaps visible. No more "teleport
            // from -1 → +1" bug the old artworkSwapPhase had.
            if false {
                // (placeholder branch kept to preserve history; see
                // git for the previous swap-phase implementation)
            } else {
                // Cold change: full sequence.
                runFullArtworkSwap(newInfo: newInfo, newKey: newKey)
            }
            // New track → re-poll source-app state. Liked status
            // is per-track, so a skip can flip the heart between
            // filled and empty. Volume is global to the source so
            // it doesn't strictly need re-polling per track, but
            // doing it here is the cheapest hook we have and keeps
            // a long-lived slab in sync if the user changed Spotify
            // / Music's volume from somewhere else.
            refreshVolume()
        }
    }

    /// Snapshot the displayed text fields + artwork from a
    /// NowPlayingInfo. Called from onAppear and at the bottom of
    /// each swap so the text fades + tilts in lockstep with the
    /// artwork rather than snapping ahead of the animation.
    ///
    /// Artwork goes through `ArtworkCache` for instant return-to-
    /// recent + off-main-thread decode for fresh tracks.
    private func applyDisplayed(from info: NowPlayingInfo?) {
        displayedArtworkData = info?.artworkData
        displayedTitle = info?.title ?? ""
        displayedArtist = info?.artist ?? ""
        displayedAlbum = info?.album ?? ""
        // Resolve the decoded NSImage via the cache. Hit returns
        // synchronously; miss schedules a background decode and
        // refreshes when ready. Either way, no main-thread block
        // on `NSImage(data:)`.
        guard let info = info else {
            displayedArtworkImage = nil
            return
        }
        let key = "\(info.title)|\(info.artist)"
        // Per BUG-012 fix: ArtworkCache.image() no longer takes
        // a stale-decode-rejection closure (it never fired anyway).
        // The synchronous decode either returns the image now or
        // returns nil (which we propagate below).
        let img = ArtworkCache.shared.image(data: info.artworkData, key: key)
        // ALWAYS update displayedArtworkImage — including when img
        // is nil (cache miss, decode in flight). Setting to nil
        // here clears any stale image from a previous track so the
        // slab shows the placeholder source-app icon during the
        // decode window. Without this clear, the OLD track's
        // artwork would camp on screen while the new track's
        // metadata (title, artist, album) was already displayed —
        // exactly the "thumbnail is not changing" bug the user
        // reported. The decode-completion closure replaces this
        // nil with the decoded image once ready.
        displayedArtworkImage = img
    }

    /// Full out-and-in artwork swap. Now the only swap path —
    /// dispatch no longer kicks an eager tilt because that caused
    /// the new artwork to briefly appear at phase=-1 (tilted +
    /// faded ~9% opacity) before the spring brought it back to
    /// center, which read as a jump.
    ///
    /// Timing chosen so the data swap happens AFTER the tilt-out
    /// completes (phase fully at -1, opacity exactly 0):
    ///   • tilt-out runs 0.24s with .smooth (a hair longer than
    ///     the swap deadline below so phase has actually reached
    ///     -1 by the time we swap)
    ///   • 0.24s later: swap data at phase=-1 (opacity=0,
    ///     completely invisible — swap is imperceptible)
    ///   • spring back to phase=0 with .spring(0.45, 0.85) —
    ///     critically-damped, no overshoot
    /// X-axis scale value that compensates for the back face of the
    /// Y-axis rotation. `cos(angle) > 0` → 1.0 (front face, normal),
    /// `cos(angle) < 0` → -1.0 (back face, mirror). The exact 90°/270°
    /// boundaries pick a side based on the rotation direction sign so
    /// the transition is smooth even at the singularity.
    private var artworkFlipCosineSign: CGFloat {
        let cosine = cos(artworkFlipAngle * .pi / 180)
        if cosine > 0.001 { return 1 }
        if cosine < -0.001 { return -1 }
        // Exactly edge-on. Pick the side based on rotation direction.
        return artworkFlipAngle.truncatingRemainder(dividingBy: 360) >= 0 ? -1 : 1
    }

    private func runFullArtworkSwap(newInfo: NowPlayingInfo?, newKey: String) {
        // CRITICAL: do NOT overwrite `artworkSwapDirection` here.
        // The previous version unconditionally set it to 1 (next-
        // direction), which made the back button animate IDENTICAL
        // to next — the user reported "do reverse animation for
        // when someone do the back button." `dispatch(.previous)`
        // already set direction = -1 BEFORE this function runs;
        // overwriting clobbered that intent. If this is called
        // from natural queue advancement (no user click), direction
        // stays at its last user-set value, which is the right
        // intuition.
        // GATE THE FLIP. Per 2026-04-29 user feedback ("it's
        // rotating too much without actual thumbnail"), the
        // 180° flip is only visually meaningful when there's
        // REAL artwork on BOTH sides of the swap. Placeholder→
        // placeholder rotation looks like motion for motion's
        // sake — Apple's Music.app and the open-source flip
        // implementations (DynamicNotch, Alcove) all guard
        // against this case.
        //
        // Decision matrix:
        //   • old has art + new has art   → flip (the whole point)
        //   • old has art + new has none  → crossfade (track is
        //     loading; flipping reveals an empty placeholder which
        //     looks broken)
        //   • old has none + new has art  → crossfade (artwork
        //     just landed for an existing track)
        //   • neither has art             → snap, no animation
        //     (nothing visible would change anyway)
        let oldHasArt = displayedArtworkImage != nil
        let newHasArt = (newInfo?.artworkData?.isEmpty == false)
        let shouldFlip = oldHasArt && newHasArt

        if shouldFlip {
            // Full vinyl-card flip. Image data swaps at the
            // edge-on moment (89% of the flip) so the new
            // artwork rides the front face into view.
            let flipDuration: TimeInterval = 0.45
            let swapDelay: TimeInterval = 0.40
            withAnimation(.easeInOut(duration: flipDuration)) {
                artworkFlipAngle += 180
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + swapDelay) {
                withAnimation(.smooth(duration: 0.20)) {
                    applyDisplayed(from: newInfo)
                    displayedTrackKey = newKey
                }
            }
        } else {
            // Quiet crossfade — no rotation. Mirrors Apple Music's
            // own mini-player swap behaviour for placeholder
            // states, and stops the "rotating too much" feel.
            withAnimation(.easeInOut(duration: 0.30)) {
                applyDisplayed(from: newInfo)
                displayedTrackKey = newKey
            }
        }
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

    /// True for sources that ALWAYS provide track artwork once the
    /// metadata fully lands — Spotify and Apple Music. Used to gate
    /// the source-app-icon fallback so the user doesn't see a
    /// transient "Spotify logo" flash during the brief window
    /// between a notification firing (title/artist only) and the
    /// artwork bytes arriving via iTunes Search / cache. For these
    /// sources we prefer to show the neutral music-note placeholder
    /// instead, which reads as "art still loading" rather than
    /// "art replaced with app logo."
    private func isMusicAppSource(_ bundleID: String?) -> Bool {
        guard let bundleID = bundleID else { return false }
        return bundleID == "com.spotify.client" || bundleID == "com.apple.Music"
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
            // 2026-04-29 jitter pass: dropped tick rate 0.25s → 0.5s
            // (4 Hz → 2 Hz). The progress bar's pixel position only
            // visibly moves once per second at typical track lengths
            // (a 4-min track / 1000pt-wide bar = 0.27px/sec), so a
            // 2 Hz refresh is still smooth enough to look continuous
            // while halving the re-eval cost during music playback.
            TimelineView(.periodic(from: .now, by: 0.5)) { context in
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
                        // 2026-04-29: 10pt horizontal inset so the
                        // time labels don't crash into the rounded
                        // corners of the panel silhouette. The panel
                        // bottom corners curve inward — without this
                        // padding the labels sat hard against the
                        // edges and read as clipped or invisible
                        // (user: "numbers are unvisible here"). The
                        // progress bar above stays edge-to-edge for
                        // the gradient effect; only the text needs
                        // safe-area inset.
                        .padding(.horizontal, 10)
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
        // See `inlineControlsCluster` for the evidence-based revert
        // away from isAudioFlowing — Chrome doesn't drop CoreAudio's
        // IO-running flag on pause, so that signal is stuck-on for
        // browser audio.
        let isPlaying = presenter.nowPlaying?.isPlaying ?? false
        // Pull the artwork's dominant color and use it as the accent
        // tint on the transport-button backgrounds. Same color as
        // the timeline gradient, so the whole bottom half of the
        // panel reads as a unified chromatic accent. Falls back to
        // white so the previous monochrome look returns when no
        // artwork is available.
        let accent = ArtworkColor.dominant(from: presenter.nowPlaying?.artworkData) ?? .white
        // Symmetric 3-zone layout for the transport row: heart on
        // the LEFT edge, prev/play/next centered, volume on the
        // RIGHT edge. The two outer Spacers + .frame on each zone
        // pin the center cluster to the visual middle of the slab,
        // and the heart's left edge mirrors the slider's right
        // edge — what the user asked for when they said "this design
        // can be more symmetrical."
        return HStack(spacing: 0) {
            // LEFT zone: empty 110pt placeholder, mirrors the
            // right-zone volume slider's width so the center
            // cluster (prev/play/next) stays at the panel's true
            // visual center. Heart/like button used to live here
            // but was removed per user request — Spotify's
            // AppleScript dictionary doesn't expose the saved-
            // tracks flag, so the button required a Cmd+S
            // keystroke route that needs Accessibility permission;
            // without that grant the heart filled but the song
            // never actually got saved ("UI lies"). Removing the
            // control eliminates the broken-state UX entirely.
            Color.clear
                .frame(width: 110, height: 1)
            Spacer(minLength: 0)
            // CENTER zone: the three transport buttons. Same
            // glyph sizes, same spacing, same haptic dispatch
            // as before — only the wrapping HStack moved.
            HStack(spacing: 24) {
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
            Spacer(minLength: 0)
            // RIGHT zone: volume control. Width matches the LEFT
            // zone exactly so the middle cluster lands on the
            // panel's centerline.
            volumeControl
                .frame(width: 110, alignment: .trailing)
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

        // No eager tilt-out. Earlier this kicked off a tilt
        // animation IMMEDIATELY on click so the response felt
        // zero-latency, but the swap point at the bottom of the
        // tilt (where displayed data updates) caused visible
        // glitches — the new artwork would briefly appear at
        // phase=-1 (rotated + faded) before the spring brought
        // it back to center, which read as a jump/flicker on the
        // user's screen. Now: dispatch only sends the command;
        // the full swap animation runs once when nowPlaying
        // actually changes (handled in the `.onChange(of:)` of
        // the artwork view via `runFullArtworkSwap`). Trade-off:
        // ~200-400ms of "nothing happens visually" between click
        // and animation start, but no glitch — which is what the
        // user prioritized.
        switch command {
        case .next:
            artworkSwapDirection = 1
        case .previous:
            artworkSwapDirection = -1
        default:
            break
        }

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
                    // Resting state for prev/next: subtle white
                    // halo at 6% opacity so the buttons read as
                    // buttons even before hover. On hover/press
                    // the halo brightens AND picks up the artwork
                    // accent tint — same chromatic language as
                    // the play button. Per user feedback that the
                    // transport row felt "flat / not Apple-grade":
                    // visible-at-rest backgrounds are how Apple
                    // Music's macOS small player and Sonoma+
                    // Settings rows distinguish controls from
                    // chrome.
                    Circle()
                        .fill(
                            isPressed
                                ? accent.opacity(0.28)
                                : isHovered
                                    ? accent.opacity(0.18)
                                    : Color.white.opacity(0.06)
                        )
                        .overlay(
                            Circle()
                                .strokeBorder(Color.white.opacity(isHovered ? 0.10 : 0.05), lineWidth: 0.5)
                        )
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
