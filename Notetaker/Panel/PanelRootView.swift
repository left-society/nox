import SwiftUI
import AppKit

// MORPH ARCHITECTURE
//
// The pill-to-slab morph used to live in this file: SwiftUI animated
// `currentWidth` / `currentHeight` / `currentRadius` against the
// `presenter.isShown` flip via `.animation(.spring(...), value:)`, with
// a `contentReady` gate that delayed heavy children behind a 160ms
// `Task.sleep`. That morph was fundamentally CPU-bound — every spring
// tick triggered a full SwiftUI body re-evaluation + recursive layout
// pass through the whole view tree. The user reported it as "still
// super laggy" and "not even close to smooth" through multiple rounds
// of parameter tuning, which couldn't paper over the architectural
// cost.
//
// The morph now lives in `PanelWindowController.animateOpen` /
// `animateClose`: pure Core Animation, GPU-driven, via
// `panel.animator().setFrame(...)` inside `NSAnimationContext.runAnimationGroup`.
// SwiftUI inside the panel is STATIC during the morph — no internal
// frame morph, no internal cornerRadius morph, no spring on a state
// flag that's flipping mid-animation. Body re-evaluates only on
// discrete `presenter.isShown` flips (twice per show / hide pair),
// not per frame. The visible silhouette change (wide-pill bottom curve
// → tall slab with subtle rounding) comes for free: SwiftUI re-clips
// `Color.black` with a fixed-radius `UnevenRoundedRectangle` against
// the morphing NSHostingView bounds — no Path data being interpolated,
// no shape rebuild per frame. This pattern is from ComfyNotch's
// open-source notch HUD, which we benchmarked against.

enum PanelTab: String, CaseIterable, Identifiable {
    /// `.music` is special: it only appears in the segmented bar when
    /// `PanelPresenter.nowPlaying` is non-nil. It exists to give the
    /// panel a *very light* first-paint surface when the user opens
    /// while music is playing — the alternative (defaulting to .notes
    /// every open) pays the heavy NotesListView mount cost during the
    /// open animation, which the user reported as residual lag even
    /// after the always-mount + opacity-gate refactor. With Music as
    /// the auto-routed default during playback, the first frame the
    /// user sees is just album art + title + 3 buttons. The heavier
    /// tabs (Notes, Images, Videos, Files) lazy-mount only when the
    /// user explicitly switches to them — by which point the panel
    /// is already at rest and the mount hitch is far less perceptible.
    case music, notes, images, videos, files

    var id: String { rawValue }

    var title: String {
        switch self {
        case .music: return "Music"
        case .notes: return "Notes"
        case .images: return "Images"
        case .videos: return "Videos"
        case .files: return "Files"
        }
    }

    /// SF Symbol used in the segmented bar for icon-only tabs (Music
    /// is icon-only because the segmented bar is already tight at 4
    /// labels — adding a 5th text label compresses every segment to
    /// the point of unreadability).
    var icon: String? {
        switch self {
        case .music: return "music.note"
        default: return nil
        }
    }
}

struct PanelRootView: View {
    @EnvironmentObject var presenter: PanelPresenter
    @Namespace private var segmentedPill

    /// Cached on first appear so body re-evals don't poke
    /// NSScreen.main / safeAreaInsets every time. The morph itself
    /// no longer triggers per-frame body evals (see file-level note),
    /// so this is purely a defense-in-depth optimization for the
    /// content-fade transition.
    @State private var notchOverlap: CGFloat = PanelWindowController.notchOverlap(for: NSScreen.main)

    /// Horizontal scale of the waveform inside `pillContentOverlay`.
    /// Held at 1.0 in steady state; pulses to 0.85 then springs back
    /// to 1.0 on every track change (see the `.onChange(of: trackKey)`
    /// in `pillContentOverlay`). Pairs with the artwork's vertical
    /// lift to give the pill a layered "the music moved forward"
    /// gesture that's distinct from Alcove's spin/flip on track change.
    @State private var waveformPulse: Double = 1.0

    /// Phase of the song-change vertical-lift animation on the
    /// pill artwork. 0 = at rest (anchor position, full alpha),
    /// negative = exiting upward (offset = phase * 4 → up to -4pt
    /// when phase = -1), positive = entering from below (offset =
    /// phase * 4 → down to +4pt when phase = +1). The artwork's
    /// blur and opacity follow `|phase|` (full blur + invisible at
    /// the extremes, sharp + opaque at 0). Driven by an explicit
    /// two-phase animation in `triggerSongChange` rather than
    /// SwiftUI's `.transition` because NSHostingView's animation
    /// context propagation through `.id()` boundaries is unreliable
    /// in this codebase — state-based phase control fires every time.
    @State private var trackSwapPhase: Double = 0

    /// Snapshot of the now-playing info that the pill artwork is
    /// currently DISPLAYING. Diverges briefly from `presenter.nowPlaying`
    /// during the song-change animation: while the old artwork is
    /// fading out, this still holds the OLD info so the fade-out
    /// shows the OLD image. After the fade-out completes, this is
    /// updated to the new info, and the fade-in shows the new image.
    /// Without this snapshot the fade-out would render the new image
    /// (since `presenter.nowPlaying` updates synchronously when the
    /// orchestrator forwards a new snapshot), defeating the
    /// "old → new" cross-fade entirely.
    @State private var displayedNowPlaying: NowPlayingInfo? = nil

    /// Mirrors `trackKey` but updated only after the song-change
    /// animation's fade-out completes — used as a sentinel so the
    /// `.onChange(of: trackKey)` handler can distinguish "first load"
    /// (no prior track) from "actual track change" (animate the swap).
    @State private var displayedTrackKey: String = ""

    /// Monotonically-increasing generation token for the song-change
    /// animation. Each call to `triggerSongChange` (or the music-ended
    /// branch) increments this and captures the new value into its
    /// asyncAfter closure; when the closure fires it bails out if the
    /// generation has been superseded by a later track change. Without
    /// this, rapid skips (A→B→C→D faster than the 0.58s animation)
    /// would let stale closures mutate `displayedNowPlaying` /
    /// `displayedTrackKey` / `trackSwapPhase` after the latest one has
    /// already settled, corrupting the visible state.
    @State private var trackSwapGeneration: Int = 0

    /// Sentinel for the "music has ever played in this session" state.
    /// Distinguishes a TRUE first-ever load (no animation — there's
    /// nothing to fade out from) from a music-restart-after-stop
    /// (should animate — conceptually a new track arriving). Without
    /// this, the music-ended branch's nil-out of `displayedNowPlaying`
    /// would route the next play through branch 2 (snap, no animation).
    @State private var hasEverDisplayedTrack: Bool = false

    /// Live horizontal drag distance on the resting music pill,
    /// in points. Zero when no drag is in flight. Drives the
    /// artwork's `.offset(x:)` for visual feedback during a swipe
    /// and powers the "did the user actually intend a skip"
    /// threshold check on drag end. Capped to ±60pt so a drag
    /// far past the threshold doesn't feel like the artwork is
    /// going to slide off the pill — matches Alcove's haptic
    /// "tug" affordance.
    @State private var pillSwipeOffset: CGFloat = 0
    /// True once the in-flight drag has crossed the skip threshold,
    /// so the haptic only fires on the *first* threshold crossing
    /// of a single drag rather than every frame.
    @State private var pillSwipeArmedDirection: Int = 0   // -1 prev, 0 idle, +1 next

    /// Settings → Music → Swipe to skip. Read inline so a flip in
    /// Settings takes effect on the next gesture without any
    /// wiring. Default true — for users who haven't seen the
    /// setting, the gesture is the discoverable feature.
    private var pillSwipeEnabled: Bool {
        if UserDefaults.standard.object(forKey: "pillSwipeToSkip") == nil { return true }
        return UserDefaults.standard.bool(forKey: "pillSwipeToSkip")
    }

    /// Bottom-corner radius for the panel silhouette. 16pt when sitting
    /// at the resting closed-pill geometry (gives quarter-circle corners
    /// reading as a pill), 34pt when expanded into the slab (subtle
    /// squircle reading as a HUD card). SwiftUI animates this via the
    /// chained `.animation(.easeOut(duration: 0.18), value: presenter.isShown)`
    /// modifier on the parent — `UnevenRoundedRectangle` interpolates
    /// `RectangleCornerRadii` continuously, so the corners morph in
    /// lockstep with the panel-frame morph driven by Core Animation.
    /// During the ~450ms expand animation the SwiftUI radius animation
    /// (0.18s) lands first, but the corners are barely visible during
    /// the early part of the morph (panel still close to pill size, so
    /// the bottom edge fills the visible silhouette regardless of
    /// radius) — the visual handoff reads as one continuous shape change.
    private var panelBottomRadius: CGFloat {
        presenter.isShown
            ? PanelWindowController.innerCornerRadius
            : PanelWindowController.pillCornerRadius
    }

    // MARK: - Body

    var body: some View {
        // Outer transparent halo + inner silhouette structure. The
        // NSPanel's frame is `(inner + 2×halo) × (inner + halo)` — the
        // SwiftUI tree here insets by `haloPadding` on left/right/bottom,
        // so the visible silhouette occupies the inner area and the
        // outer halo is transparent space for the shadow to bleed into.
        // Without that bleed area the SwiftUI `.shadow` modifier just
        // gets clipped by the rectangular NSPanel boundary and the panel
        // reads as a pasted-on rectangle — the user described this
        // exactly: "no dropshadow (liquid blur)".
        //
        // The earlier multi-stop gradient + plusLighter-blended notch
        // sheen looked too "lifted" — the user said the new design
        // looked worse and that "black was definitely the choice." The
        // fix is the Alcove vocabulary: solid pure black for the slab
        // (the premium-feeling surface they want), and the depth comes
        // from a quiet rim around the silhouette + a generous luminous
        // drop shadow that escapes into the haloPadding margin.
        //
        // Layer stack (bottom → top):
        //   1. `panelBackground`: solid `Color.black`
        //   2. `contentOverlay`: the actual UI (header/tabs/content)
        //   3. `borderStroke`: subtle 0.5pt rim around the silhouette
        //   4. `dropRingOverlay`: drag-and-drop accent ring (existing)
        // The two `.shadow` calls below stack: a TIGHT dark ground-shadow
        // (close, slightly offset down) for the contact tell, plus a
        // WIDE soft halo (large radius, lower opacity) for the floating
        // glow — same recipe Alcove uses to feel "set into the desktop"
        // rather than "stamped onto" it.
        panelBackground
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(panelSilhouette)
            .overlay(alignment: .top) { artworkTopGradient }
            .overlay(alignment: .top) {
                // Pill artwork+waveform overlay — ONLY rendered when
                // the slab is closed. With opacity-only hiding the
                // SwiftUI render still includes the (invisible)
                // overlay in the layout pass, and at certain
                // intermediate animation states the blur kernel
                // could leak a faint silhouette at the top of the
                // slab — what the user described as "see a little
                // blurred bump there?". Removing the view from the
                // tree entirely when the slab is open guarantees
                // zero leakage.
                if !presenter.isShown {
                    pillContentOverlay
                        .transition(.opacity)
                }
            }
            .overlay(alignment: .top) { contentOverlay }
            .overlay { borderStroke }
            .overlay { dropRingOverlay }
            // Re-clip the entire stack (background + every overlay)
            // to the panel silhouette. Without this, scrollable
            // content like the Images grid paints over the rounded
            // bottom-corner regions, making the panel look like it
            // has a square bottom against the desktop. The background
            // alone is already clipped above; the second clip here
            // catches the overlays that ride on top of it.
            .clipShape(panelSilhouette)
            // Whole-pill reaction. When a transient pill event
            // fires (screenshot, note saved, charging, download),
            // the silhouette itself briefly puffs ~3.5% larger
            // and gets a soft event-tinted glow. Reads as the
            // pill "responding" to the event, not just the inner
            // content rearranging. Only fires on event-CASE
            // changes (not associated-value changes) so a burst
            // screenshot count tick doesn't re-puff per shot.
            .modifier(PillSilhouetteReact(
                caseKey: pillEventCaseKey,
                glowColor: pillReactColor
            ))
            .padding(.horizontal, PanelWindowController.haloPadding)
            .padding(.bottom, PanelWindowController.haloPadding)
            .ignoresSafeArea(.all, edges: .top)
            // Single-axis state animation: content opacity, shadow
            // params, AND the bottom-corner radius interpolation
            // (UnevenRoundedRectangle's `RectangleCornerRadii` is
            // animatable) all run on this one timeline. Frame morph
            // is driven separately at the NSPanel level via Core
            // Animation (see PanelWindowController.animateOpen).
            //
            // `.smooth` is SwiftUI's interpolating-spring preset —
            // settled landing, no overshoot. Same Animation value
            // Alcove uses (the literal `smooth` is in their binary
            // alongside damping/stiffness symbols), and it gives the
            // radius morph a calmer, more "premium hardware" feel
            // than a linear ease-out on the corner shape.
            // `.bouncy` gives the corner-radius interpolation a
            // slight overshoot — the bottom corners briefly round
            // Direction-aware animation. Numbers must mirror the
            // PanelWindowController NSPanel-frame springs so the
            // SwiftUI-side properties (corner radius, content opacity,
            // shadow params) finish on the same beat as the window
            // geometry. Numbers were re-tuned from a frame-by-frame
            // teardown of Alcove's actual morph (~165ms total, no
            // visible overshoot, content fades in concurrent with
            // silhouette growth):
            //   • OPEN  (isShown→true):  k=450 d=40 ratio≈0.94,
            //     full settle in ~150ms. Earlier 200/22 spring
            //     stretched the morph over ~360ms — long enough for
            //     Timer pacing variance to read as jitter.
            //   • CLOSE (isShown→false): k=600 d=50 ratio≈1.02,
            //     just-overdamped, settles in ~120ms.
            .animation(presenter.isShown
                       ? .interpolatingSpring(mass: 1.0, stiffness: 450, damping: 40, initialVelocity: 0)
                       : .interpolatingSpring(mass: 1.0, stiffness: 600, damping: 50, initialVelocity: 0),
                       value: presenter.isShown)
            .animation(.easeInOut(duration: 0.12), value: presenter.isDropTargeted)
            // PERF GATE: both shadows render only when isShown=true.
            // During the morph itself both radii are 0 — SwiftUI's
            // `.shadow` is a CPU-side gaussian convolution whose cost
            // grows with radius² × surface area, so radius 0 is
            // essentially free. The fade-in / fade-out is driven by
            // the `.animation` modifier above.
            //
            // Two-shadow stack: contact + halo. The contact shadow
            // (tight, dark, slightly offset) reads as the panel
            // pressing down toward the desktop. The halo (wide, dim)
            // is the "liquid blur" the user described — a soft
            // luminance bleed all around the silhouette, not just at
            // the bottom.
            // SUBTLE shadow stack — radii drop during morph to
            // shed CPU gaussian cost. SwiftUI `.shadow()` is a
            // CPU-side gaussian convolution whose cost scales
            // with surface area × radius²; on every spring tick
            // during the open morph, two big-radius shadows were
            // re-running and dropping frames. Shrinking them to
            // ~50% during the morph and snapping back when the
            // spring settles keeps the visual "lift" in steady
            // state without paying for it per frame.
            .shadow(
                color: Color.black.opacity(presenter.isShown ? 0.42 : 0),
                radius: presenter.isShown ? (presenter.isMorphing ? 10 : 18) : 0,
                x: 0,
                y: presenter.isShown ? 14 : 0
            )
            .shadow(
                color: Color.black.opacity(presenter.isShown ? 0.22 : 0),
                radius: presenter.isShown ? (presenter.isMorphing ? 18 : 36) : 0,
                x: 0,
                y: presenter.isShown ? 28 : 0
            )
    }

    // MARK: - Content overlay (header / segmented / grid)

    @ViewBuilder
    private var contentOverlay: some View {
        // ALWAYS-MOUNTED. The previous gated form (`if presenter.isShown
        // { ... }`) made the heavy content tree (NotesListView + image/
        // video/file grids + composer + LazyVStack + ScrollView + drag-
        // and-drop wiring + @FocusState scaffolding) un-mount and re-
        // mount on every show / hide cycle. Even after we deferred the
        // mount until AFTER the panel morph finished (so the morph
        // itself ran cleanly over an empty Color.black slab), the
        // 30-50ms SwiftUI mount + initial layout still landed AS A
        // VISIBLE HITCH right after the recoil settled — the user
        // perceived the gap between "panel arrived" and "content
        // visible" as lag. Reported across multiple iterations as
        // "much better than before but still lagging."
        //
        // Always-mount amortizes the mount cost to app launch, where
        // there's no animation competing for main-thread time and the
        // user can't see it. show() / hide() then just toggles the
        // opacity, which Core Animation can render on a single
        // CALayer alpha update — essentially free.
        //
        // Trade-off: the content tree IS evaluated when the panel is
        // hidden (e.g. @Published changes still trigger body re-evals
        // in mounted children). That's why we use `.opacity(0)` rather
        // than `.hidden()`: opacity-0 keeps layout stable but the
        // SwiftUI render path skips painting transparent fragments
        // entirely. LazyVStack inside ScrollView is lazy by definition
        // and only materializes visible cells, so the hidden cost is
        // dominated by the wrapper views (header, segmented, divider,
        // active-tab content frame), all of which are cheap to keep
        // around. ImagesGridView's thumbnail loader gates work on
        // `presenter.isShown` upstream so it doesn't decode JPEGs in
        // the background.
        //
        // `.allowsHitTesting(presenter.isShown)` ensures the invisible
        // content can't intercept clicks. Without this, a click that
        // landed in the closed-pill region while the panel is hidden
        // could be eaten by an invisible search-bar TextField or
        // segmented-control button.
        VStack(spacing: 0) {
            header
            segmented
                .padding(.horizontal, DS.Spacing.md)
            divider
                .padding(.top, DS.Spacing.sm)
            content
        }
        // Push UI below the menu-bar zone. The top `notchOverlap`
        // points of the panel are hidden behind the notch /
        // menu-bar strip; we offset visible widgets down by exactly
        // that amount so the header lands flush below the bar.
        .padding(.top, notchOverlap)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .opacity(presenter.isShown ? 1 : 0)
        // Progressive-blur materialization. When the panel is closed
        // (or morphing toward closed), the content tree is rendered
        // with a 10pt gaussian blur; as `presenter.isShown` flips true
        // the blur animates to 0 alongside the parent's `.smooth`
        // animation. The user sees the header / segmented bar / list
        // dissolve INTO focus rather than fade in flat — same
        // "progressive blur" effect Alcove ships (its binary contains
        // a `progressiveBlurTransitionTask` symbol). The 10pt radius
        // is heavy enough to feel like the content is materializing
        // (not just appearing), but light enough that mid-morph reads
        // are still legible — typography stays decipherable through
        // the blur, so the transition feels like a focus pull rather
        // than a fog-of-war reveal.
        //
        // SwiftUI's `.blur` runs as a Metal filter on the off-screen
        // The content fade is opacity-only now. The previous
        // `.blur(radius: 10 → 0)` ran a GPU gaussian blur over the
        // entire content overlay (notes/images/grids) for every
        // frame of the open morph — measured to be the dominant
        // cost in the per-frame budget once shadows + halo were
        // already deferred. Dropping it eliminates the per-frame
        // blur kernel entirely; we still get a soft focus-in
        // visually because the opacity 0→1 transition with
        // `compositingGroup` lets Core Animation handle the fade
        // as a single layer alpha, no SwiftUI re-rasterization.
        .compositingGroup()
        .allowsHitTesting(presenter.isShown)
    }

    // MARK: - Artwork top gradient (panel-wide tint from album art)

    /// Artwork-color tint that fills the TOP of the panel and
    /// dissolves downward into clean black before reaching the
    /// transport row. Lives at the PanelRootView level (not inside
    /// MusicPanelView) so the gradient starts at the actual top of
    /// the panel — behind the Notetaker header text and the tab
    /// bar — instead of starting halfway down. Per the user:
    /// "tell me where is the top and where is the bottom"; the top
    /// of the panel is the header at y=0, not the music slab content.
    ///
    /// Only renders when the slab is open (`presenter.isShown`) and
    /// there's a track playing — pill state is too small for a
    /// useful gradient, and other tabs (Notes/Images/Videos/Files)
    /// shouldn't be tinted by music artwork they're not showing.
    @ViewBuilder
    private var artworkTopGradient: some View {
        // "Color emerging from the notch" approach. Hardware
        // notch is BLACK on every Mac; we don't paint over it.
        // Instead a soft radial color halo blooms from the panel's
        // top-center (just below the notch silhouette) and fades
        // outward. Effect: the notch hardware looks like it's
        // gently glowing in the album-art's dominant color
        // without us actually drawing on the notch.
        //
        // Replaces the previous `Image(nsImage:)` blurred-art
        // texture, which gave the panel a generic-album-art tint
        // that the user described as flat. A single dominant
        // color in a focused radial keeps the notch reading as
        // "alive but quiet" instead of "lots of color."
        // Render only when the panel is fully open AND not
        // currently morphing. The previous version applied a
        // .blur(radius: 40) on top of a RadialGradient, which
        // re-rasterized every frame as the panel resized
        // through the spring — heavy GPU cost during the open
        // morph that read as jitter. Now the halo paints only
        // at steady state (after morph settles) and we skip
        // the blur entirely — the RadialGradient's stops
        // already give plenty of natural softness.
        if presenter.isShown && !presenter.isMorphing,
           let data = presenter.nowPlaying?.artworkData,
           let color = ArtworkColor.dominant(from: data) {
            RadialGradient(
                gradient: Gradient(stops: [
                    .init(color: color.opacity(0.42), location: 0.0),
                    .init(color: color.opacity(0.20), location: 0.35),
                    .init(color: color.opacity(0.06), location: 0.7),
                    .init(color: Color.clear, location: 1.0),
                ]),
                center: UnitPoint(x: 0.5, y: 0),
                startRadius: 0,
                endRadius: 280
            )
            // Mask the lower half so the color doesn't bleed
            // into the transport row / bottom of the slab. The
            // halo's job is to make the NOTCH zone feel alive;
            // the rest of the panel stays clean black.
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: Color.black, location: 0.0),
                        .init(color: Color.black.opacity(0.7), location: 0.4),
                        .init(color: Color.clear, location: 0.85),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .allowsHitTesting(false)
            // Cross-fade smoothly when the dominant color
            // changes (track swap) and on morph entry/exit
            // (since presenter.isMorphing gates rendering).
            .animation(.easeInOut(duration: 0.4),
                       value: presenter.nowPlaying?.artworkData)
            .transition(.opacity.animation(.easeInOut(duration: 0.35)))
        }
    }

    // MARK: - Pill content overlay (resting now-playing indicator)

    /// Artwork + waveform pill body — rendered inside the SAME NSPanel
    /// that hosts the full slab content, so the resting pill and the
    /// expanded slab are literally one window morphing. This is the
    /// architectural shift the user asked for: "the pill should be
    /// always there... when you press the cursor to that, it just
    /// expands the music thing." Confirmed against Alcove's binary
    /// (NotchController + NotchPanel + _isExpanded/_isHovering flags
    /// in `/Applications/Alcove.app/Contents/MacOS/Alcove`).
    ///
    /// Visibility gate: `isResting && !isShown`. Mutually exclusive with
    /// `contentOverlay` (which is gated on `isShown`). When the panel
    /// expands, isShown flips true → pill fades out as the full content
    /// fades in. The 0.18s easeOut on the parent runs both crossfades
    /// in lockstep alongside the Core Animation frame morph.
    ///
    /// Layout: the pill content (artwork + waveform) sits ENTIRELY
    /// within the notch+menu-bar zone (the upper `notchOverlap` of the
    /// panel, ~32pt on a 16"/14" notched Mac). With closedPillBump=0pt
    /// there is no visible-below-menu-bar strip — the content reads as
    /// if it's PART OF the notch hardware itself, the same trick Alcove
    /// uses. Pixel measurement of `/Applications/Alcove.app` showed
    /// their resting pill silhouette ends at y=31.5pt — half a point
    /// shy of the menu-bar bottom — and content is rendered in the
    /// lower portion of the notch zone (below the camera lens). HStack
    /// with 14pt artwork + 16×8 waveform, centered vertically within
    /// the 32pt notch zone with horizontal padding tuned so the pair
    /// reads as integrated rather than crammed.
    @ViewBuilder
    private var pillContentOverlay: some View {
        // Priority order: system events (charging) > video
        // candidate > music. Each transient state takes over the
        // pill briefly then reverts to whatever was underneath.
        // The bouncy animation + scale transitions make the
        // morph feel tactile rather than a hard cut.
        Group {
            if case .charging(let pct, let plugged) = presenter.pendingSystemEvent {
                chargingPillContent(percent: pct, plugged: plugged)
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.6, anchor: .center)
                            .combined(with: .opacity),
                        removal: .scale(scale: 0.85, anchor: .center)
                            .combined(with: .opacity)
                    ))
                    .id("charging")
            } else if case .screenshotSaved(let count) = presenter.pendingSystemEvent {
                screenshotPillContent(count: count)
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.6, anchor: .center)
                            .combined(with: .opacity),
                        removal: .scale(scale: 0.85, anchor: .center)
                            .combined(with: .opacity)
                    ))
                    // Stable id across count updates — a burst
                    // updates `count` only, the view stays mounted
                    // and the count Text re-renders in place
                    // instead of re-running the entrance bounce
                    // for every shot.
                    .id("screenshot")
            } else if case .downloadStarted(let host) = presenter.pendingSystemEvent {
                downloadPillContent(host: host, completed: false)
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.6, anchor: .center)
                            .combined(with: .opacity),
                        removal: .scale(scale: 0.85, anchor: .center)
                            .combined(with: .opacity)
                    ))
                    .id("download-start-\(host)")
            } else if case .downloadCompleted(let host) = presenter.pendingSystemEvent {
                downloadPillContent(host: host, completed: true)
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.6, anchor: .center)
                            .combined(with: .opacity),
                        removal: .scale(scale: 0.85, anchor: .center)
                            .combined(with: .opacity)
                    ))
                    .id("download-done-\(host)")
            } else if case .noteSaved = presenter.pendingSystemEvent {
                noteSavedPillContent
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.6, anchor: .center)
                            .combined(with: .opacity),
                        removal: .scale(scale: 0.85, anchor: .center)
                            .combined(with: .opacity)
                    ))
                    .id("noteSaved")
            } else if case .bluetoothConnected(let name, let isAirPods) = presenter.pendingSystemEvent {
                bluetoothPillContent(name: name, isAirPods: isAirPods, isConnected: true)
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.6, anchor: .center)
                            .combined(with: .opacity),
                        removal: .scale(scale: 0.85, anchor: .center)
                            .combined(with: .opacity)
                    ))
                    .id("btConnected-\(name)")
            } else if case .bluetoothDisconnected(let name, let isAirPods) = presenter.pendingSystemEvent {
                bluetoothPillContent(name: name, isAirPods: isAirPods, isConnected: false)
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.6, anchor: .center)
                            .combined(with: .opacity),
                        removal: .scale(scale: 0.85, anchor: .center)
                            .combined(with: .opacity)
                    ))
                    .id("btDisconnected-\(name)")
            } else if case .timerRunning(let remaining) = presenter.pendingSystemEvent {
                timerRunningPillContent(remainingSeconds: remaining)
                    .transition(.opacity)
                    // Stable id across tick updates so the entrance
                    // bounce only fires once on start.
                    .id("timerRunning")
            } else if case .timerFinished = presenter.pendingSystemEvent {
                timerFinishedPillContent
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.6, anchor: .center)
                            .combined(with: .opacity),
                        removal: .scale(scale: 0.85, anchor: .center)
                            .combined(with: .opacity)
                    ))
                    .id("timerFinished")
            } else if case .calendarUpcoming(let title, let minutes) = presenter.pendingSystemEvent {
                calendarUpcomingPillContent(title: title, minutesUntilStart: minutes)
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.6, anchor: .center)
                            .combined(with: .opacity),
                        removal: .scale(scale: 0.85, anchor: .center)
                            .combined(with: .opacity)
                    ))
                    // Stable id while the same meeting is counting
                    // down — minute updates re-render in place.
                    .id("calendar-\(title)")
            } else if case .airDropReceived(let filename) = presenter.pendingSystemEvent {
                airDropPillContent(filename: filename)
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.6, anchor: .center)
                            .combined(with: .opacity),
                        removal: .scale(scale: 0.85, anchor: .center)
                            .combined(with: .opacity)
                    ))
                    .id("airdrop-\(filename)")
            } else if let videoURL = presenter.pendingVideoCandidate {
                videoPreviewPillContent(for: videoURL)
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.6, anchor: .center)
                            .combined(with: .opacity),
                        removal: .scale(scale: 0.85, anchor: .center)
                            .combined(with: .opacity)
                    ))
                    .id("video")
            } else {
                musicPillContent
                    .transition(.opacity)
                    .id("music")
            }
        }
        // Bouncy spring on the content swap — gives the system
        // event entrance a tactile "pop in" feel rather than a
        // straight fade. extraBounce 0.3 is more pronounced than
        // the slab-radius bounce because the content is small
        // and the swap is short — needs more energy to read.
        // Stronger bounce + slightly longer duration so the
        // pill ENTRANCE itself reads as a "pop" before the
        // shutter punch / flash plays out on the icon. The
        // user explicitly wanted "more alive" for screenshot
        // events; this curve drives all transient pill morphs
        // (charging, screenshot, download) for consistency.
        .animation(.bouncy(duration: 0.50, extraBounce: 0.45),
                   value: presenter.pendingSystemEvent)
        .animation(.bouncy(duration: 0.42, extraBounce: 0.25),
                   value: presenter.pendingVideoCandidate)
        // Progressive-blur swap mask. When the pill morphs from
        // one event type to another (music → charging, music →
        // screenshot, etc.), apply a brief gaussian blur over the
        // entire pill content for ~0.45s, peaking at the swap
        // moment. The user reported the swap "still not seamless"
        // and pointed at Alcove's charging morph; Alcove's binary
        // contains `ProgressiveBlurEffect` + `gaussianBlurFilter`
        // symbols and a `progressiveBlurTransitionTask` — same
        // technique. The blur masks the visual seam where the old
        // and new content overlap during a SwiftUI transition,
        // making the swap read as one soft morph instead of two
        // crossfading rectangles. Triggered only on case CHANGE
        // (count updates within `.screenshotSaved` don't blur).
        .modifier(PillSwapBlur(caseKey: pillEventCaseKey))
    }

    /// Identity string for the current pendingSystemEvent / video
    /// candidate. Used by `PillSwapBlur` to detect actual case
    /// transitions vs. associated-value updates within the same
    /// case (e.g., screenshot count incrementing).
    private var pillEventCaseKey: String {
        if let event = presenter.pendingSystemEvent {
            switch event {
            case .charging: return "charging"
            case .screenshotSaved: return "screenshot"
            case .downloadStarted: return "downloadStarted"
            case .downloadCompleted: return "downloadCompleted"
            case .noteSaved: return "noteSaved"
            case .bluetoothConnected(let name, _): return "btConnected-\(name)"
            case .bluetoothDisconnected(let name, _): return "btDisconnected-\(name)"
            case .timerRunning: return "timerRunning"
            case .timerFinished: return "timerFinished"
            case .calendarUpcoming(let title, _): return "calendar-\(title)"
            case .airDropReceived(let filename): return "airdrop-\(filename)"
            }
        }
        if presenter.pendingVideoCandidate != nil { return "video" }
        return "music"
    }

    /// Glow color for the pill's silhouette reaction — matches
    /// the event tile's accent so the puff feels color-coded.
    /// Used by `PillSilhouetteReact` for the brief shadow during
    /// the puff.
    private var pillReactColor: Color {
        if let event = presenter.pendingSystemEvent {
            switch event {
            case .charging: return Color(red: 0.30, green: 0.85, blue: 0.45)
            case .screenshotSaved: return Color(red: 0.30, green: 0.78, blue: 0.99)
            case .noteSaved: return Color(red: 0.99, green: 0.80, blue: 0.20)
            case .downloadStarted, .downloadCompleted: return Color(red: 0.93, green: 0.13, blue: 0.13)
            case .bluetoothConnected: return Color(red: 0.45, green: 0.65, blue: 1.0)
            case .bluetoothDisconnected: return Color(red: 0.65, green: 0.65, blue: 0.70)
            case .timerRunning: return Color(red: 1.00, green: 0.55, blue: 0.20)
            case .timerFinished: return Color(red: 0.30, green: 0.85, blue: 0.45)
            case .calendarUpcoming: return Color(red: 0.99, green: 0.45, blue: 0.30)
            case .airDropReceived: return Color(red: 0.30, green: 0.78, blue: 0.99)
            }
        }
        return Color.white
    }

    /// Charging plug-in / unplug indicator. Same horizontal layout
    /// as music: battery glyph on the left, percentage text on the
    /// right. The bolt subtly pulses while plugged to convey
    /// "energy flowing in"; the percentage text slides in from the
    /// right for additional motion polish.
    /// Compact "screenshot saved" pill content. Camera glyph on
    /// the left, "Saved" badge on the right. Auto-dismisses after
    /// the 1.4s timeout. Reads as the iOS Dynamic Island's
    /// screenshot toast — quick acknowledgement without stealing
    /// focus.
    @ViewBuilder
    private func screenshotPillContent(count: Int) -> some View {
        ScreenshotPillBody(count: count, notchOverlap: notchOverlap)
            .opacity(presenter.isResting && !presenter.isShown ? 1 : 0)
    }

    /// "Download started" / "Download complete" pill content.
    /// Platform-tinted tile (same logic as the video preview pill)
    /// + state badge. The completed variant flashes a checkmark
    /// glyph and "Done" text.
    @ViewBuilder
    private func downloadPillContent(host: String, completed: Bool) -> some View {
        let accent = videoPlatformAccent(host: host)
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(accent.opacity(0.9))
                Image(systemName: completed ? "checkmark" : "arrow.down")
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundStyle(.white)
            }
            .frame(width: 22, height: 22)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))

            Spacer(minLength: 0)

            Text(completed ? "Done" : "Downloading")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
                .padding(.trailing, 4)
        }
        .padding(.horizontal, 8)
        .frame(height: notchOverlap)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .opacity(presenter.isResting && !presenter.isShown ? 1 : 0)
    }

    /// Pill content for clipboard text auto-saved as a note.
    /// Yellow note glyph + "Note saved" badge — matches the
    /// Notes tab's chromatic identity. Same dismissal window as
    /// screenshots so the user gets a quick acknowledgement
    /// without the panel ever opening.
    @ViewBuilder
    private var noteSavedPillContent: some View {
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color(red: 0.99, green: 0.80, blue: 0.20).opacity(0.9))
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundStyle(.white)
            }
            .frame(width: 22, height: 22)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))

            Spacer(minLength: 0)

            Text("Note saved")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
                .padding(.trailing, 4)
        }
        .padding(.horizontal, 8)
        .frame(height: notchOverlap)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .opacity(presenter.isResting && !presenter.isShown ? 1 : 0)
    }

    /// Bluetooth connect/disconnect HUD content. Mirrors the
    /// DynamicLake Pro "DynaConnect" pill the user pointed at —
    /// small device icon on the left, name + status on the right.
    /// `isConnected` flips the status text and dims the icon for
    /// disconnect. `isAirPods` swaps to the dedicated AirPods
    /// SF Symbol; everything else gets the generic headphones
    /// glyph.
    /// Read Settings → Bluetooth → Distinguish AirPods icon. When
    /// off, the AirPods glyph is collapsed back to the generic
    /// "headphones" symbol so the user gets the simpler pill (some
    /// users find the silhouette-specific icon visually noisy when
    /// they pair multiple AirPods sets across the day).
    private func bluetoothIconName(isAirPods: Bool) -> String {
        if !isAirPods { return "headphones" }
        let key = "bluetoothShowAirPodsIcon"
        let distinguish: Bool = {
            if UserDefaults.standard.object(forKey: key) == nil { return true }
            return UserDefaults.standard.bool(forKey: key)
        }()
        return distinguish ? "airpods.gen3" : "headphones"
    }

    private func bluetoothPillContent(name: String, isAirPods: Bool, isConnected: Bool) -> some View {
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(
                        (isConnected
                         ? Color(red: 0.45, green: 0.65, blue: 1.0)
                         : Color(white: 0.55))
                            .opacity(0.9)
                    )
                // Settings → Bluetooth → Distinguish AirPods icon
                // controls whether AirPods get a dedicated glyph or
                // ride on the generic headphones one. Default true.
                // Read inline so a flip in Settings takes effect on
                // the next pill without any wiring.
                Image(systemName: bluetoothIconName(isAirPods: isAirPods))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 22, height: 22)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))

            VStack(alignment: .leading, spacing: 0) {
                Text(name)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.95))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(isConnected ? "Connected" : "Disconnected")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(0.62))
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: notchOverlap)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .opacity(presenter.isResting && !presenter.isShown ? 1 : 0)
    }

    /// Live countdown pill — orange timer glyph + monospaced
    /// "MM:SS" remaining. Stays pinned the entire time the timer
    /// is counting (the service pushes a fresh `.timerRunning(...)`
    /// every second; the same `.id("timerRunning")` keeps the view
    /// stable so the time text updates in place without retriggering
    /// the entrance bounce on each tick).
    private func timerRunningPillContent(remainingSeconds: Int) -> some View {
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color(red: 1.00, green: 0.55, blue: 0.20).opacity(0.92))
                Image(systemName: "timer")
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundStyle(.white)
            }
            .frame(width: 22, height: 22)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))

            Spacer(minLength: 0)

            Text(formatTimerDuration(remainingSeconds))
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.95))
                .padding(.trailing, 4)
                .contentTransition(.numericText(countsDown: true))
        }
        .padding(.horizontal, 8)
        .frame(height: notchOverlap)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .opacity(presenter.isResting && !presenter.isShown ? 1 : 0)
    }

    /// "Timer done" celebratory pill. Green checkmark + "Time's
    /// up" badge. 3-second window so the user sees it even if
    /// they were heads-down on something else.
    private var timerFinishedPillContent: some View {
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color(red: 0.30, green: 0.85, blue: 0.45).opacity(0.92))
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundStyle(.white)
            }
            .frame(width: 22, height: 22)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))

            Spacer(minLength: 0)

            Text("Time's up")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.95))
                .padding(.trailing, 4)
        }
        .padding(.horizontal, 8)
        .frame(height: notchOverlap)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .opacity(presenter.isResting && !presenter.isShown ? 1 : 0)
    }

    private func formatTimerDuration(_ totalSeconds: Int) -> String {
        let s = max(totalSeconds, 0)
        let m = s / 60
        let sec = s % 60
        if m >= 60 {
            let h = m / 60
            let remM = m % 60
            return String(format: "%d:%02d:%02d", h, remM, sec)
        }
        return String(format: "%d:%02d", m, sec)
    }

    /// Upcoming-meeting pill — orange calendar tile + truncated
    /// title + minutes remaining. Tappable: tap routes through
    /// `presenter.onJoinUpcomingMeeting` (installed by AppDelegate)
    /// which opens the join URL in the user's default browser.
    /// We render this with a `.contentShape` rectangle so the
    /// whole pill area is tappable, not just the text label.
    @ViewBuilder
    private func calendarUpcomingPillContent(title: String, minutesUntilStart: Int) -> some View {
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color(red: 0.99, green: 0.45, blue: 0.30).opacity(0.92))
                Image(systemName: "calendar")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 22, height: 22)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))

            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.95))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(calendarTimeLabel(minutes: minutesUntilStart))
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(0.62))
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: notchOverlap)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .opacity(presenter.isResting && !presenter.isShown ? 1 : 0)
        .contentShape(Rectangle())
        .onTapGesture {
            presenter.onJoinUpcomingMeeting?()
        }
    }

    /// Format the lead-time label inside the calendar pill. Negative
    /// minutes (event already started) read as "now" so the user
    /// doesn't see "-2 min" — confusing during the in-progress
    /// grace window.
    private func calendarTimeLabel(minutes: Int) -> String {
        if minutes <= 0 { return "now" }
        if minutes == 1 { return "in 1 min" }
        return "in \(minutes) min"
    }

    /// AirDrop arrival pill — blue AirDrop glyph + filename. Tap
    /// reveals the file in Finder via `presenter.onRevealAirDrop`.
    /// Filename gets a left-truncation so long names show their
    /// extension (the part the user actually cares about for
    /// "is this the file I expected").
    @ViewBuilder
    private func airDropPillContent(filename: String) -> some View {
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color(red: 0.30, green: 0.78, blue: 0.99).opacity(0.92))
                Image(systemName: "shareplay")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 22, height: 22)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))

            VStack(alignment: .leading, spacing: 0) {
                Text("AirDrop")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.62))
                    .lineLimit(1)
                Text(filename)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.95))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: notchOverlap)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .opacity(presenter.isResting && !presenter.isShown ? 1 : 0)
        .contentShape(Rectangle())
        .onTapGesture {
            presenter.onRevealAirDrop?()
        }
    }

    @ViewBuilder
    private func chargingPillContent(percent: Int, plugged: Bool) -> some View {
        HStack(spacing: 6) {
            ChargingTile(percent: percent, plugged: plugged)
            Spacer(minLength: 0)
            Text("\(percent)%")
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .transition(.move(edge: .trailing).combined(with: .opacity))
        }
        .padding(.horizontal, 8)
        .frame(height: notchOverlap)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .opacity(presenter.isResting && !presenter.isShown ? 1 : 0)
        .animation(.easeOut(duration: 0.18), value: presenter.isShown)
    }

    /// Color the battery tile by state — green when plugged and
    /// charging, amber when low and unplugged, neutral elsewhere.
    /// Picks up the same kind of "at-a-glance" color cue Apple
    /// uses on the menu-bar battery icon.
    private func chargingTileColor(percent: Int, plugged: Bool) -> Color {
        if plugged {
            return Color(red: 0.30, green: 0.78, blue: 0.39)
        }
        if percent < 20 {
            return Color(red: 0.95, green: 0.40, blue: 0.20)
        }
        return Color(red: 0.45, green: 0.45, blue: 0.50)
    }

    /// Compact "video URL detected" pill content. Left: video glyph
    /// tinted by source platform. Right: download button. Tap the
    /// download button → routes to `presenter.onDownloadVideo`
    /// (AppDelegate hooks this to videoStore.startDownload). If the
    /// user ignores it for 15s, the pill auto-reverts to music mode.
    @ViewBuilder
    private func videoPreviewPillContent(for url: URL) -> some View {
        let host = url.host?.lowercased() ?? ""
        let accent = videoPlatformAccent(host: host)
        let glyph = videoPlatformGlyph(host: host)
        HStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(accent.opacity(0.85))
                Image(systemName: glyph)
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(.white)
            }
            .frame(width: 22, height: 22)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))

            Spacer(minLength: 0)

            Button {
                presenter.onDownloadVideo?(url)
            } label: {
                ZStack {
                    Circle().fill(Color.white.opacity(0.18))
                    Image(systemName: "arrow.down")
                        .font(.system(size: 10, weight: .heavy))
                        .foregroundStyle(.white)
                }
                .frame(width: 20, height: 20)
                // Visual stays at 20×20; hit target extends to the
                // full pill height + 12pt of horizontal slack so the
                // button is reachable without precision aim. With
                // hover-expand suppressed in video-preview mode,
                // this is the only interaction on the pill — make
                // sure it lands first try.
                .padding(.vertical, 4)
                .padding(.leading, 12)
                .padding(.trailing, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Download \(host)")
        }
        .padding(.horizontal, 8)
        .frame(height: notchOverlap)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .opacity(presenter.isResting && !presenter.isShown ? 1 : 0)
        .animation(.easeOut(duration: 0.18), value: presenter.isShown)
    }

    /// Brand-accurate-ish accent color for the hosts we can
    /// silently download from — video sites via yt-dlp, plus the
    /// two file-share hosts yt-dlp's extractors handle (Drive,
    /// Dropbox). Falls back to neutral blue.
    private func videoPlatformAccent(host: String) -> Color {
        if host.contains("youtube") || host.contains("youtu.be") {
            return Color(red: 0.93, green: 0.13, blue: 0.13)
        }
        if host.contains("tiktok") {
            return Color(red: 0.0, green: 0.84, blue: 0.85)
        }
        if host.contains("twitter") || host.contains("x.com") {
            return Color(red: 0.10, green: 0.10, blue: 0.10)
        }
        if host.contains("vimeo") {
            return Color(red: 0.10, green: 0.55, blue: 0.83)
        }
        if host.contains("twitch") {
            return Color(red: 0.57, green: 0.30, blue: 0.85)
        }
        if host.contains("instagram") {
            return Color(red: 0.91, green: 0.31, blue: 0.55)
        }
        if host.contains("drive.google.com") {
            return Color(red: 0.96, green: 0.76, blue: 0.20) // Drive yellow
        }
        if host.contains("dropbox.com") {
            return Color(red: 0.0, green: 0.40, blue: 0.93) // Dropbox blue
        }
        return Color.accentColor
    }

    /// SF Symbol matching the link's category. Video sites get the
    /// play glyph; Drive/Dropbox get a folder glyph since the
    /// downloaded thing might be any file type.
    private func videoPlatformGlyph(host: String) -> String {
        if host.contains("drive.google.com") || host.contains("dropbox.com") {
            return "folder.fill"
        }
        return "play.fill"
    }

    @ViewBuilder
    private var musicPillContent: some View {
        HStack(spacing: 6) {
            pillArtwork
            Spacer(minLength: 0)
            WaveformView(
                isPlaying: presenter.nowPlaying?.isPlaying ?? false,
                width: 20,
                height: 12,
                lineWidth: 1.4,
                tint: ArtworkColor.dominant(from: presenter.nowPlaying?.artworkData) ?? .white,
                opacity: 0.95,
                // Same per-track rhythmic pattern as the slab
                // waveform — pill and slab pulse in lockstep,
                // sharing one visual identity per song.
                pattern: WaveformPattern.deterministic(for: trackKey)
            )
            // Subtle horizontal pulse on track change — the waveform
            // squeezes to 0.85x then settles back to 1.0x in lockstep
            // with the artwork's vertical lift. Anchored .trailing so
            // the right edge stays pinned. Driven by `waveformPulse`
            // state which is reset & sprung in `.onChange(of: trackKey)`
            // below — gives the pill two layered gestures with
            // slightly different personalities (artwork lifts
            // vertically, waveform compresses horizontally).
            .scaleEffect(x: waveformPulse, y: 1, anchor: .trailing)
        }
        // Swipe-to-skip. Horizontal drag on the resting pill triggers
        // previous (left swipe) or next (right swipe). Driven by a
        // SwiftUI DragGesture with a 10pt minimum distance so
        // straight clicks (used for tap-to-expand the slab) still
        // pass through. Visual feedback: the whole pill shifts
        // ±20pt during the drag, giving the user a "tug" affordance
        // before the threshold commits. Capped via the `min(max(…))`
        // clamp so a long drag doesn't drag the pill off-screen.
        .offset(x: max(-20, min(20, pillSwipeOffset)))
        .simultaneousGesture(
            DragGesture(minimumDistance: 10)
                .onChanged { value in
                    guard pillSwipeEnabled,
                          presenter.nowPlaying != nil,
                          presenter.isResting,
                          !presenter.isShown
                    else { return }
                    // Only consider near-horizontal drags so that
                    // accidental vertical motions don't register
                    // as skips. tan(20°) ≈ 0.36 — pretty forgiving.
                    let dx = value.translation.width
                    let dy = abs(value.translation.height)
                    guard dy < abs(dx) * 1.2 else { return }
                    pillSwipeOffset = dx
                    let threshold: CGFloat = 35
                    let direction: Int = dx > threshold ? 1
                                       : dx < -threshold ? -1 : 0
                    if direction != pillSwipeArmedDirection && direction != 0 {
                        // Crossed the threshold — give a one-time
                        // haptic so the user knows the next release
                        // will commit. Direction-armed flag prevents
                        // re-firing on every drag delta.
                        HapticFeedback.generic()
                        pillSwipeArmedDirection = direction
                    } else if direction == 0 && pillSwipeArmedDirection != 0 {
                        // Drift back below threshold — disarm so the
                        // next crossing in either direction can fire
                        // its haptic again.
                        pillSwipeArmedDirection = 0
                    }
                }
                .onEnded { value in
                    guard pillSwipeEnabled,
                          presenter.nowPlaying != nil,
                          presenter.isResting,
                          !presenter.isShown
                    else {
                        pillSwipeOffset = 0
                        pillSwipeArmedDirection = 0
                        return
                    }
                    let dx = value.translation.width
                    let dy = abs(value.translation.height)
                    let threshold: CGFloat = 35
                    let isHorizontal = dy < abs(dx) * 1.2
                    if isHorizontal && dx > threshold {
                        presenter.onMediaCommand?(.next)
                        HapticFeedback.alignment()
                    } else if isHorizontal && dx < -threshold {
                        presenter.onMediaCommand?(.previous)
                        HapticFeedback.alignment()
                    }
                    // Snap back to centered with a soft spring so
                    // a not-quite-far-enough drag releases naturally.
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                        pillSwipeOffset = 0
                    }
                    pillSwipeArmedDirection = 0
                }
        )
        // Track-change side effects:
        //  1. Update `pendingTrackSwap` to drive the artwork-swap
        //     animation. We use an explicit state-based fade
        //     orchestrated below (rather than a SwiftUI `.transition`
        //     attached to `.id(trackKey)`) because NSHostingView's
        //     animation context propagation through `.id()` boundaries
        //     is unreliable in this codebase — `.transition` sometimes
        //     fires, sometimes doesn't, depending on how the
        //     `@Published` update is delivered. State-based phase
        //     control always works.
        //  2. Pulse the waveform horizontally — purely visual, runs
        //     parallel to the artwork lift.
        // Filter on `trackKey` change only; pause/play toggles, elapsed-
        // time ticks, and pure artwork-data updates leave the pill alone.
        .onAppear {
            // Seed displayed state so the first track that ever plays
            // doesn't trigger a phantom "fade out → fade in" animation
            // (there's nothing to fade out from). Subsequent track
            // changes go through `triggerSongChange`.
            //
            // Idempotent across multiple onAppear calls (panel can be
            // unmounted and remounted): we only seed when nothing has
            // ever been displayed AND nothing is currently displayed,
            // so a second mount with a non-nil `presenter.nowPlaying`
            // doesn't double-snap and clobber state from a swap that's
            // mid-flight.
            if !hasEverDisplayedTrack && displayedNowPlaying == nil {
                displayedNowPlaying = presenter.nowPlaying
                displayedTrackKey = trackKey
                if presenter.nowPlaying != nil {
                    hasEverDisplayedTrack = true
                }
            }
        }
        // When the slab opens or closes, hard-reset any in-flight
        // pill artwork animation so the pill never shows a stale
        // intermediate phase. Without this, a track change that
        // happened during the open animation would leave
        // `trackSwapPhase` non-zero, and on close the pill would
        // briefly flash the artwork at an offset/blur position
        // before snapping to settled.
        .onChange(of: presenter.isShown) { _ in
            var snap = Transaction()
            snap.disablesAnimations = true
            withTransaction(snap) {
                trackSwapPhase = 0
                waveformPulse = 1.0
                // Sync displayed state to current — if a track
                // changed while we suppressed the animation, the
                // pill needs to know about the new track BEFORE it
                // becomes visible again.
                if let cur = presenter.nowPlaying {
                    displayedNowPlaying = cur
                    displayedTrackKey = "\(cur.title)|\(cur.artist)"
                }
            }
        }
        .onChange(of: presenter.nowPlaying) { newInfo in
            NSLog("Notetaker: 📻 nowPlaying changed title=\(newInfo?.title ?? "nil") artwork=\(newInfo?.artworkData?.count ?? 0)b oldKey=\(displayedTrackKey)")
            // Single dispatcher for every now-playing update.
            // Branches:
            //  1. Same track, content fields refreshed (artwork
            //     loaded asynchronously, isPlaying toggled, elapsed
            //     time updated) → silent update of `displayedNowPlaying`
            //     so the new artwork appears without animation.
            //  2. True first-ever track (nothing has ever played in
            //     this session) → snap to it, no animation (there
            //     was no prior artwork to fade out from).
            //  3. Music ended (newInfo == nil) → fade out only,
            //     don't run the entry phase (would flash the
            //     placeholder glyph briefly as the pill collapses).
            //  4. Genuine track change OR music restart after a stop
            //     → run the two-phase vertical-lift animation. The
            //     entry phase reads from `presenter.nowPlaying` at
            //     swap time, so a restart-from-nil correctly enters
            //     the new artwork from below.
            let newKey = "\(newInfo?.title ?? "")|\(newInfo?.artist ?? "")"

            // Branch 1: same track, just a content refresh
            if newKey == displayedTrackKey && displayedNowPlaying != nil && newInfo != nil {
                displayedNowPlaying = newInfo
                return
            }
            // Branch 2: true first-ever track this session
            if !hasEverDisplayedTrack && displayedNowPlaying == nil {
                displayedNowPlaying = newInfo
                displayedTrackKey = newKey
                if newInfo != nil {
                    hasEverDisplayedTrack = true
                }
                return
            }
            // Branch 3: music ended
            if newInfo == nil {
                trackSwapGeneration &+= 1
                let gen = trackSwapGeneration
                withAnimation(.easeIn(duration: 0.18)) {
                    trackSwapPhase = -1
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                    // Bail if a later track-start (or another stop)
                    // has already superseded this fade. The newer
                    // call owns the displayed state from this point.
                    guard gen == trackSwapGeneration else { return }
                    displayedNowPlaying = nil
                    displayedTrackKey = newKey
                    trackSwapPhase = 0
                }
                return
            }
            // Branch 4: real track change OR music restart → animate.
            // BUT: if the slab is currently OPEN, the pill is hidden
            // (opacity 0) and any animation we run on the pill
            // artwork can leave it stuck mid-phase. When the user
            // closes the slab, the pill suddenly reappears at the
            // stale phase position and looks like a glitch. Skip
            // the animation when hidden — silent state update
            // instead. User: "the small pills thumbnails sometime
            // gliching in background while opening the main pill."
            if presenter.isShown {
                displayedNowPlaying = newInfo
                displayedTrackKey = newKey
                trackSwapPhase = 0
                return
            }
            if displayedNowPlaying == nil {
                trackSwapPhase = -1
            }
            triggerSongChange(newKey: newKey)
            // Snap waveform to compressed state, then spring back. The
            // explicit transaction with disablesAnimations prevents the
            // ambient onChange animation context from interpolating the
            // 1.0 → 0.85 step (which would cancel the squeeze visually).
            var snap = Transaction()
            snap.disablesAnimations = true
            withTransaction(snap) {
                waveformPulse = 0.85
            }
            // Spring-back to 1.0 with overshoot. Lower damping (0.55)
            // gives the waveform a visible bounce as it settles —
            // the "snap" the user reads as energy. Smooth interp
            // was correct but flat; this adds a tiny rebound that
            // makes the pulse feel alive.
            withAnimation(.spring(response: 0.32, dampingFraction: 0.55)) {
                waveformPulse = 1.0
            }
        }
        // Horizontal padding 8pt — anchors the artwork at the LEFT
        // EDGE of the pill (left of the camera notch) and the
        // waveform at the RIGHT EDGE (right of the notch). The
        // physical notch is centered on the display; the pill
        // extends about 35pt past the notch on each side, and the
        // artwork/waveform sit in those side strips with just enough
        // padding (8pt) to clear the bottom-corner curves. This is
        // the canonical Alcove layout — content hugging the pill's
        // outer edges with the camera as the natural visual anchor
        // in the middle. Earlier rounds tried 32pt (pulled content
        // toward the center, which the user explicitly rejected:
        // "it should in the left edge ... macbook have a notch at
        // center"), 18pt (still felt off), and now 8pt (settles).
        .padding(.horizontal, 8)
        // Content lives in the menu-bar zone ONLY (`notchOverlap`
        // = 32pt), NOT in the bump area below. This matches
        // Alcove's pattern where the artwork sits in the upper
        // portion of the pill (level with the menu bar) and the
        // bump is a clean rounded curl below — no content. If we
        // extended the content frame into the bump, the artwork
        // would shift downward into the curl area and look like
        // it's spilling out of the menu-bar zone.
        .frame(height: notchOverlap)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .opacity(presenter.isResting && !presenter.isShown ? 1 : 0)
        .blur(radius: presenter.isResting && !presenter.isShown ? 0 : 6)
        // **Override** the panel-wide `.bouncy` animation (set on
        // panelBackground) for THIS subtree. Bouncy springs overshoot
        // their target, which is fine for shape/position but causes
        // visible artifacts on opacity (clamping at 0/1 produces a
        // brief "stuck" frame) and on blur (negative radius is
        // invalid, the renderer can flicker). Use a tight smooth
        // animation here so the pill content fades cleanly without
        // the bounce. Fixes the user's report that "the small pills
        // thumbnails sometime gliching in background while opening
        // the main pill."
        .animation(.easeOut(duration: 0.18), value: presenter.isShown)
        .allowsHitTesting(false)
    }

    /// Stable identity for the current track. Changes when title or
    /// artist changes (i.e. user skipped, queue advanced, or source
    /// app picked a new track). Drives the artwork's `.id()` modifier
    /// so SwiftUI treats a new track as a fresh view → fires the
    /// `.verticalLift` transition for the swap. Includes both fields
    /// because some sources publish the same title across artists
    /// (covers, multi-artist compilations) and we want those treated
    /// as distinct tracks.
    private var trackKey: String {
        let info = presenter.nowPlaying
        return "\(info?.title ?? "")|\(info?.artist ?? "")"
    }

    /// Run the two-phase vertical-lift song-change animation. Phase 1:
    /// the OLD artwork (still in `displayedNowPlaying`) animates from
    /// rest to "exited up" — `trackSwapPhase` 0 → -1 over 0.18s, which
    /// drives offset 0 → -4pt, blur 0 → 7pt, opacity 1 → 0. Phase 2:
    /// after the first phase completes, snap `displayedNowPlaying` to
    /// the new track and `trackSwapPhase` to +1 (positioned 4pt below
    /// resting, fully blurred and invisible — no flash because all
    /// three modifiers leave the artwork at zero alpha at this point),
    /// then animate `trackSwapPhase` +1 → 0 over 0.22s for the
    /// rise-into-place. Total animation is 0.40s of perceived motion,
    /// well within Apple HIG's "deliberate" range.
    ///
    /// Note: we don't use SwiftUI's `.transition()` modifier because
    /// the animation context propagation through NSHostingView's
    /// `.id()` boundaries is unreliable in this codebase — the
    /// transition would sometimes fire and sometimes not, depending
    /// on the path the @Published update came through. Explicit
    /// state-based phase control fires deterministically every time.
    private func triggerSongChange(newKey: String) {
        NSLog("Notetaker: 🎵 triggerSongChange firing newKey=\(newKey) oldKey=\(displayedTrackKey)")
        // Smoother two-phase animation. User reported the previous
        // version had the thumbnail "getting delated suddenly" mid-
        // transition — that was caused by `easeIn` (which spends
        // most of its time at low opacity then snaps to invisible
        // at the very end) combined with imperfect timing between
        // the asyncAfter and the animation completion.
        //
        // Fix: use `.smooth` for BOTH phases (gentle ease in/out
        // throughout, no sudden snap), and overlap the swap by
        // ~30ms so the new artwork starts entering BEFORE the old
        // one is fully cleared — the eye perceives one continuous
        // gesture instead of two sequential events.
        let fadeOut: TimeInterval = 0.26
        let fadeIn: TimeInterval = 0.32
        let swapPoint: TimeInterval = fadeOut - 0.03  // 30ms overlap

        // Generation token: each invocation captures `gen` into its
        // dispatched closures, then bails on entry if the field has
        // moved on (a newer skip arrived). Prevents stale closures
        // from a prior A→B swap from clobbering the displayed state
        // mid-flight in a rapid A→B→C→D scrub. `&+=` so we don't
        // crash on Int overflow over a multi-decade session.
        trackSwapGeneration &+= 1
        let gen = trackSwapGeneration
        hasEverDisplayedTrack = true

        // Phase 1: smooth fade OLD artwork out + up
        withAnimation(.smooth(duration: fadeOut)) {
            trackSwapPhase = -1
        }
        // Phase 2 (slightly before phase 1 ends): swap data + rise.
        DispatchQueue.main.asyncAfter(deadline: .now() + swapPoint) {
            // Bail if a newer change has superseded this swap. The
            // latest invocation's phase-1 is in flight and owns the
            // displayed state and trackSwapPhase from here on.
            guard gen == trackSwapGeneration else { return }
            displayedNowPlaying = presenter.nowPlaying
            displayedTrackKey = newKey
            // Snap to entry position (8pt below, invisible). Phase 1
            // hasn't quite reached -1 yet but is close enough to 0
            // alpha that the teleport is imperceptible.
            trackSwapPhase = 1
            // Bouncy rise-from-below — the new artwork doesn't just
            // settle into place, it overshoots slightly and bounces
            // back. Gives the song change a tactile "landed" feel
            // (vs. the previous smooth slide which was correct but
            // forgettable). Fade-out stays smooth — overshoot on
            // exit would look bizarre. Only the entry gets bounce.
            withAnimation(.bouncy(duration: fadeIn, extraBounce: 0.22)) {
                trackSwapPhase = 0
            }
        }
        // Safety reset: if the dispatched closures above never run
        // (main-thread stall, app suspended mid-swap and resumed past
        // the dispatch deadline, generation-guard bailed because a
        // newer swap took over but THAT one also stalled), the
        // artwork would be stuck at trackSwapPhase = -1 (offset -8pt,
        // 12pt blur, alpha 0 — invisible). After the full animation
        // budget plus generous slack we force trackSwapPhase back to
        // 0 IF this generation is still the latest, so the pill never
        // gets visually wedged. Wrapped in withAnimation so it doesn't
        // pop in if it actually runs.
        let safetyDeadline = swapPoint + fadeIn + 0.20
        DispatchQueue.main.asyncAfter(deadline: .now() + safetyDeadline) {
            guard gen == trackSwapGeneration else { return }
            if trackSwapPhase != 0 {
                NSLog("Notetaker: ⚠️ song-change safety reset firing (phase=\(trackSwapPhase))")
                withAnimation(.smooth(duration: 0.18)) {
                    trackSwapPhase = 0
                }
            }
        }
    }

    /// 22×22 album-art tile sized to fill the 32pt notch zone
    /// substantially — leaves ~5pt of breathing room above (clears
    /// the camera lens) and below (clears the menu-bar bottom edge).
    /// Earlier rounds tried 14pt (looked dwarfed inside the notch),
    /// 16pt (still felt small once the notch zone was the full 32pt
    /// host instead of a 20pt bump), and 22pt (current) — at which
    /// point the user said "looking right" alongside Alcove. Reads
    /// as the dominant content element of the pill, the way Apple
    /// Music / Spotify mini-players treat their artwork.
    ///
    /// Reads from `displayedNowPlaying` (not `presenter.nowPlaying`)
    /// so the song-change animation can keep showing the OLD image
    /// during the fade-out phase. The `.offset` / `.blur` / `.opacity`
    /// modifiers follow `trackSwapPhase`: 0 at rest, animates to -1
    /// on track change (fade out upward), snaps to +1 (positioned
    /// below for entry), animates back to 0 (fade in from below).
    /// 4pt of vertical travel is ~18% of the artwork height — visible
    /// but contained; 7pt of blur is enough to read as "softening"
    /// without dissolving into a smear.
    @ViewBuilder
    private var pillArtwork: some View {
        Group {
            if let data = displayedNowPlaying?.artworkData,
               let img = NSImage(data: data) {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
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
        // 8pt offset (~36% of artwork height) + 12pt blur make the
        // song-change animation legibly visible — earlier 4pt + 7pt
        // values were too subtle for the user to perceive against
        // the small 22pt artwork. Premium song-change animations
        // typically use 30-50% of the element's dimension for
        // travel; 36% lands cleanly inside that range.
        .offset(y: trackSwapPhase * 8)
        .blur(radius: abs(trackSwapPhase) * 12)
        .opacity(1 - abs(trackSwapPhase))
    }

    // MARK: - Background layers

    /// Solid pure black. The user explicitly asked for black after the
    /// gradient version landed: "black was definitely the choice but
    /// we need to something around it / Like alcove." Depth now comes
    /// from the drop shadow on the parent and the quiet rim below —
    /// not from any internal lift. Keeps the slab reading as a piece
    /// of premium dark hardware, not a tinted glass panel.
    private var panelBackground: some View {
        Group {
            if presenter.isShown {
                // Slab (expanded) state: vibrancy + dark tint for
                // depth. The blur samples the desktop / windows
                // behind the panel via NSVisualEffectView's
                // .behindWindow blending; the dark tint keeps the
                // slab reading as a premium dark surface.
                ZStack {
                    VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow)
                    Color.black.opacity(0.65)
                }
            } else {
                // Resting pill state: SOLID BLACK to match the
                // physical camera-notch hardware. The pill is
                // ambient and tiny — vibrancy on this surface
                // looked off, like the notch itself was glowing
                // with the wallpaper. User: "This pill thing
                // should always look dark (black) cause it's
                // matching the hardware you got me?"
                Color.black
            }
        }
    }

    /// Quiet 0.5pt rim around the silhouette — Alcove's signature
    /// treatment. Just enough edge definition to keep the slab from
    /// dissolving into very-dark wallpapers, but not so bright it
    /// reads as a sheen on glass. White at 6% opacity is below the
    /// noise floor of most desktops; the user reads it as "the slab
    /// has an edge" without being able to point to a specific stroke.
    @ViewBuilder
    private var borderStroke: some View {
        panelSilhouette
            .stroke(Color.white.opacity(0.06), lineWidth: 0.5)
            .allowsHitTesting(false)
            .opacity(presenter.isShown ? 1 : 0)
    }

    // MARK: - Drop-target accent ring

    @ViewBuilder
    private var dropRingOverlay: some View {
        if presenter.isDropTargeted {
            panelSilhouette
                .stroke(DS.Color.accent.opacity(0.85), lineWidth: 1.5)
                .transition(.opacity)
                .allowsHitTesting(false)
        }
    }

    // MARK: - Silhouette

    /// Panel silhouette — flat top edge fused with the menu-bar zone
    /// (top corners square), and a state-dependent bottom-corner radius.
    /// 16pt when resting (closed-pill quarter-circle corners), 34pt
    /// when expanded (slab squircle). SwiftUI re-clips against the
    /// morphing NSHostingView bounds each frame of the NSPanel.frame
    /// Core Animation morph, and the `RectangleCornerRadii`
    /// interpolation handles the radius transition so the silhouette
    /// shape changes smoothly alongside the size morph.
    private var panelSilhouette: AnyShape {
        // Notch-hardware silhouette for BOTH resting pill AND the
        // expanded slab. Subtle 2pt outward flare at the top
        // corners (blends into the screen-bezel area, not bumpy)
        // + larger inward rounded curve at the bottom that
        // interpolates between `pillCornerRadius` (resting) and
        // `innerCornerRadius` (slab) via `panelBottomRadius`. Same
        // shape language across both states — pill→slab morph
        // becomes a continuous radius interpolation, no shape-
        // type switch mid-animation.
        return AnyShape(
            OutwardFlaredShape(
                topFlareRadius: 2,
                bottomCornerRadius: panelBottomRadius
            )
        )
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: DS.Spacing.sm) {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(DS.Color.textSecondary)

            Text("Notetaker")
                .font(.nkTitle)
                .foregroundStyle(DS.Color.textPrimary)

            Spacer(minLength: DS.Spacing.sm)

            KeycapLabel("⌥", "Space")

            SettingsButton()
        }
        .padding(.horizontal, DS.Spacing.md)
        .padding(.top, DS.Spacing.sm)
        .padding(.bottom, DS.Spacing.xs)
    }

    // MARK: - Segmented

    private var segmented: some View {
        // `presenter.visibleTabs` injects the .music tab at the head
        // when something is playing, otherwise returns the original
        // 4-tab strip. Animating on the visible-tab list ID gives a
        // tidy slide-in / slide-out when music starts or stops mid-
        // session — without it, the row would just pop new segments
        // into existence and feel jittery.
        HStack(spacing: 2) {
            ForEach(presenter.visibleTabs) { tab in
                segmentButton(for: tab)
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous)
                .fill(DS.Color.bgSubtle)
        )
        .animation(.selection, value: presenter.visibleTabs)
    }

    private func segmentButton(for tab: PanelTab) -> some View {
        let isSelected = presenter.activeTab == tab
        return Button {
            // Skip the haptic when re-tapping the already-selected
            // tab — that's a no-op visually, so a click would feel
            // gratuitous. `.generic` is the lightest pattern, fits
            // a tab switch's "navigation" semantic.
            if !isSelected {
                HapticFeedback.generic()
            }
            withAnimation(.selection) { presenter.activeTab = tab }
        } label: {
            // Icon-only when the tab provides one (currently Music) —
            // the segmented bar gets cramped at 5 text labels, so
            // collapsing Music to a 12pt music.note keeps every text
            // label readable. The icon's intrinsic width is also
            // narrower than a label like "Files," which lets the
            // remaining tabs spread evenly.
            Group {
                if let icon = tab.icon {
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                } else {
                    Text(tab.title)
                        .font(.nkMeta.weight(isSelected ? .semibold : .regular))
                }
            }
            .foregroundStyle(isSelected ? DS.Color.textPrimary : DS.Color.textSecondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .background(
                ZStack {
                    if isSelected {
                        RoundedRectangle(cornerRadius: DS.Radius.pill, style: .continuous)
                            .fill(DS.Color.bgSelected)
                            .matchedGeometryEffect(id: "pill", in: segmentedPill)
                    }
                }
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Divider & content

    private var divider: some View {
        Rectangle()
            .fill(DS.Color.divider)
            .frame(height: 1)
    }

    @ViewBuilder
    private var content: some View {
        // SwiftUI's switch-based ViewBuilder is already lazy: only the
        // active case is in the view tree, the others aren't mounted
        // at all. That's the foundation of the open-lag fix — when
        // `activeTab` is .music on open, NotesListView / ImagesGridView
        // / VideosGridView / FilesGridView are NOT instantiated, so
        // their first-paint cost (composer + LazyVStack + image decode
        // + ScrollView content-size calc + onAppear hooks for link
        // previews) is paid lazily on the first deliberate tab tap,
        // not during the panel-open animation.
        switch presenter.activeTab {
        case .music:
            MusicPanelView()
        case .notes:
            NotesListView()
        case .images:
            ImagesGridView()
        case .videos:
            VideosGridView()
        case .files:
            FilesGridView()
        }
    }
}

// MARK: - Pill swap blur (Alcove-style progressive blur)
//
// Adapted from Alcove's `ProgressiveBlurEffect` + `gaussianBlurFilter`
// approach (decoded from their binary's symbol table). When the
// pill morphs between event types, a brief gaussian blur is applied
// over the entire pill content. The blur peaks right at the swap
// moment and decays as the new content settles, masking the visual
// seam where SwiftUI's transition would otherwise show two
// rectangles crossfading. Net effect: the swap reads as one soft
// shape morph instead of two competing views.
//
// Triggers ONLY on `caseKey` change (e.g., music → screenshot),
// not on associated-value updates within the same case (e.g.,
// screenshot count ticking from 1 to 2). This way burst-screenshot
// counts don't re-blur on every shot — the blur fires once at the
// initial swap and then the count animates in place.
private struct PillSwapBlur: ViewModifier {
    let caseKey: String
    @State private var previousKey: String = ""
    @State private var blur: Double = 0

    func body(content: Content) -> some View {
        content
            .blur(radius: blur)
            .onChange(of: caseKey) { newKey in
                if newKey != previousKey && !previousKey.isEmpty {
                    triggerBlur()
                }
                previousKey = newKey
            }
            .onAppear { previousKey = caseKey }
    }

    /// Two-stage spring: quick ramp UP to peak blur synced with
    /// the SwiftUI transition's visible-overlap moment, then a
    /// slower decay back to zero as the new content settles.
    /// 6pt is heavy enough to obscure the seam but light enough
    /// that the new content reads through it almost immediately.
    private func triggerBlur() {
        withAnimation(.easeOut(duration: 0.14)) {
            blur = 6
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) {
            withAnimation(.easeOut(duration: 0.32)) {
                blur = 0
            }
        }
    }
}

// MARK: - Pill silhouette reaction (whole-pill puff + glow)
//
// The user reported "only text and svg is showing the pill is
// not reacting." Without this, transient events animate inside
// the pill but the silhouette itself is static. This modifier
// adds a brief whole-pill scale puff (~3.5%) plus an event-tinted
// soft glow on every event-case change. Subtle enough that it
// doesn't feel disruptive, present enough that the pill clearly
// "responds" to the event.
//
// Triggers ONLY on caseKey change (not on count updates within
// `.screenshotSaved`) so a screenshot burst doesn't re-puff per
// shot — the pill puffs once on entry, the count animates in
// place, and it puffs again only when transitioning to a
// different event type.
private struct PillSilhouetteReact: ViewModifier {
    let caseKey: String
    let glowColor: Color
    @State private var previousKey: String = ""
    @State private var react: Double = 0

    func body(content: Content) -> some View {
        content
            .scaleEffect(1.0 + react * 0.035)
            // Tinted glow that ramps with the puff. Radius scales
            // with `react` so the glow only paints during the puff
            // — zero cost when settled.
            .shadow(color: glowColor.opacity(react * 0.45),
                    radius: react * 22)
            .onChange(of: caseKey) { newKey in
                if newKey != previousKey && !previousKey.isEmpty {
                    triggerPuff()
                }
                previousKey = newKey
            }
            .onAppear { previousKey = caseKey }
    }

    /// Quick spring up + slower spring back. Same two-stage
    /// pattern as the screenshot icon punch so all the reactions
    /// feel of a piece.
    private func triggerPuff() {
        withAnimation(.spring(response: 0.22, dampingFraction: 0.55)) {
            react = 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
            withAnimation(.spring(response: 0.55, dampingFraction: 0.65)) {
                react = 0
            }
        }
    }
}

// MARK: - Screenshot pill body
//
// Standalone view so it owns its own @State for the per-shot
// punch + flash animations. Lives outside PanelRootView so the
// animation state survives re-evals of the parent body when other
// presenter state changes (e.g., a track update).
private struct ScreenshotPillBody: View {
    let count: Int
    let notchOverlap: CGFloat
    @EnvironmentObject var presenter: PanelPresenter

    /// 0 = neutral, 1 = punched. Spring-driven by `triggerPunch`
    /// on every screenshot capture. Drives icon scale + rotation
    /// for the "shutter snap" feel.
    @State private var iconPunch: Double = 0
    /// 0 = invisible, 1 = peak white. Decays to 0 over ~280ms
    /// after each capture — the camera-flash glint.
    @State private var flashOpacity: Double = 0

    /// Tile shape responds to whether we have a real thumbnail —
    /// 32×20 (16:10ish, matches typical screenshot proportions)
    /// when there's a thumbnail to show, 22×22 square when
    /// falling back to the camera glyph. The shape change reads
    /// as "this thing is your screenshot," not just a generic
    /// icon. Animates smoothly because both width and height
    /// are bound to the same conditional.
    private var hasThumbnail: Bool { presenter.lastScreenshotThumbnail != nil }
    private var tileWidth: CGFloat { hasThumbnail ? 32 : 22 }
    private var tileHeight: CGFloat { hasThumbnail ? 20 : 22 }

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color(red: 0.30, green: 0.78, blue: 0.99).opacity(0.9))
                if let thumb = presenter.lastScreenshotThumbnail {
                    // Real screenshot. Filling the tile via
                    // .fill content mode + clip means small text
                    // / busy areas just become an abstract
                    // "this is your screen" tile — readable as
                    // identity even at 32×20.
                    Image(nsImage: thumb)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: tileWidth, height: tileHeight)
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .scaleEffect(1.0 + iconPunch * 0.18)
                        .rotationEffect(.degrees(iconPunch * 4))
                } else {
                    Image(systemName: "camera.viewfinder")
                        .font(.system(size: 10, weight: .heavy))
                        .foregroundStyle(.white)
                        .scaleEffect(1.0 + iconPunch * 0.35)
                        .rotationEffect(.degrees(iconPunch * 8))
                }
            }
            .frame(width: tileWidth, height: tileHeight)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay(
                // White flash overlay clipped to the tile.
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.white)
                    .opacity(flashOpacity)
                    .allowsHitTesting(false)
            )
            // The tile size itself animates when the
            // thumbnail-vs-icon state changes — that's the
            // "shape responds" cue. Same bouncy curve as the
            // entrance so it feels of a piece.
            .animation(.bouncy(duration: 0.35, extraBounce: 0.3),
                       value: hasThumbnail)

            Spacer(minLength: 0)

            Text(count > 1 ? "Saved · \(count)" : "Saved")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
                .padding(.trailing, 4)
                .contentTransition(.numericText())
                .animation(.easeOut(duration: 0.18), value: count)
                // Subtle scale bump on count change so the burst
                // count "lands" with a tiny pop in addition to
                // the numeric ticker.
                .scaleEffect(1.0 + iconPunch * 0.08)
        }
        .padding(.horizontal, 8)
        .frame(height: notchOverlap)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Whole-pill micro-bump — the entire camera tile + count
        // breathes outward on a punch and settles. ~3% scale; the
        // larger 35% on the icon is what reads as the "shutter
        // pop", this is the subtle envelope around it.
        .scaleEffect(1.0 + iconPunch * 0.03)
        .onAppear { triggerPunch() }
        .onChange(of: count) { _ in triggerPunch() }
    }

    /// Two-stage spring: aggressive snap up to 1, slower
    /// underdamped settle back to 0. The flash overlay runs
    /// in parallel, peaking with the snap and fading on the way
    /// down. Gives one capture event a satisfying pop without
    /// requiring `keyframeAnimator` (macOS 14+).
    private func triggerPunch() {
        withAnimation(.spring(response: 0.18, dampingFraction: 0.55)) {
            iconPunch = 1
            flashOpacity = 0.55
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.62)) {
                iconPunch = 0
            }
            withAnimation(.easeOut(duration: 0.28)) {
                flashOpacity = 0
            }
        }
    }
}

// MARK: - Keycap label

private struct KeycapLabel: View {
    let keys: [String]

    init(_ keys: String...) {
        self.keys = keys
    }

    var body: some View {
        HStack(spacing: 3) {
            ForEach(keys, id: \.self) { key in
                Text(key)
                    .font(.system(size: DS.FontSize.xs, weight: .medium, design: .rounded))
                    .foregroundStyle(DS.Color.textTertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(DS.Color.bgSubtle)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.06), lineWidth: 0.5)
                    )
            }
        }
    }
}

// MARK: - Settings button

private struct SettingsButton: View {
    @State private var isHovered = false

    var body: some View {
        // We deliberately do NOT use `SettingsLink` or the SwiftUI
        // `Settings { }` scene. The panel's SwiftUI tree is mounted via
        // `NSHostingController` inside an `NSPanel`, which creates a
        // separate SwiftUI root that does not inherit the App scene's
        // environment. `SettingsLink` resolves an unbound `\.openSettings`
        // there and silently no-ops; the legacy `showSettingsWindow:`
        // action selector also fails because `LSUIElement = true` means
        // there's no main window in the responder chain.
        //
        // `SettingsWindow.open()` instead routes to AppDelegate, which
        // owns an `NSWindow` directly and pushes a SwiftUI `SettingsView`
        // into it via `NSHostingController` — bypassing the scene
        // plumbing entirely.
        Button {
            NSLog("Notetaker: gear button tapped")
            SettingsWindow.open()
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isHovered ? DS.Color.textSecondary : DS.Color.textTertiary)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.rowHover) { isHovered = hovering }
        }
    }
}

#Preview {
    PanelRootView()
        .preferredColorScheme(.dark)
        .frame(width: 340, height: 700)
        .background(Color.black)
}

// MARK: - Vertical-Lift song-change transition
//
// Premium song-change animation for the resting-pill artwork. Designed
// to be visually DIFFERENT from Alcove's spin/flip — Alcove rotates the
// artwork tile around its Y axis with a small bumpy bounce; we slide
// vertically with a soft blur. Same intent ("a track changed, here's
// the new one") expressed through orthogonal motion (vertical vs
// rotational), so the two HUDs stay distinguishable side-by-side on the
// same Mac.
//
// Outgoing artwork: drifts ↑3pt with a 6pt blur and fades to 0 alpha.
// Incoming artwork: starts 3pt below resting, 6pt blurred, 0 alpha;
// rises ↑ to its anchor, blur clearing and alpha rising as it settles.
//
// 3pt is small but legible inside a 14pt artwork tile (≈21% of the
// tile's height). Larger values would feel like the artwork is jumping
// out of the pill bounds; smaller values would be imperceptible.
//
// 6pt of blur is enough to read as "the artwork softened" but not
// enough to dissolve into a featureless smear. SwiftUI's `.blur` runs
// as a Metal filter scoped to this 14×14 surface, so cost is trivially
// small (~196 input pixels, four-tap kernel).

private struct VerticalLiftEnter: ViewModifier {
    /// 0 = entering (4pt below, 7pt blur, alpha 0)
    /// 1 = settled (anchor position, no blur, full alpha)
    let progress: Double

    func body(content: Content) -> some View {
        content
            .offset(y: (1 - progress) * 4)
            .blur(radius: (1 - progress) * 7)
            .opacity(progress)
    }
}

private struct VerticalLiftExit: ViewModifier {
    /// 1 = anchored (full presence)
    /// 0 = exited (4pt above, 7pt blur, alpha 0)
    let progress: Double

    func body(content: Content) -> some View {
        content
            .offset(y: -(1 - progress) * 4)
            .blur(radius: (1 - progress) * 7)
            .opacity(progress)
    }
}

extension AnyTransition {
    /// Asymmetric vertical-lift transition. Use for views that get a
    /// fresh `.id()` on each "new content" event — the outgoing copy
    /// drifts up and out, the incoming copy rises into place from
    /// below. Pair with an `.animation(_, value:)` on the parent so
    /// the SwiftUI run-loop has an animation context to drive the
    /// modifier interpolation.
    static var verticalLift: AnyTransition {
        .asymmetric(
            insertion: .modifier(
                active: VerticalLiftEnter(progress: 0),
                identity: VerticalLiftEnter(progress: 1)
            ),
            removal: .modifier(
                active: VerticalLiftExit(progress: 0),
                identity: VerticalLiftExit(progress: 1)
            )
        )
    }
}

// MARK: - Top-flared pill shape
//
// Top-flared silhouette per user spec: TOP-LEFT and TOP-RIGHT
// corners FLARE OUTWARD (silhouette is wider at the top than at
// the body), body stays narrower below, bottom corners are square.
// The flare is a smooth quarter-arc in each top corner, centered
// at where the body edge meets the panel top — so the arc bulges
// OUT toward the panel top corners, then curves back INWARD to
// the narrower body.
//
// Geometry (with flareR = 16):
//   Top edge:    width = rect.width  (full width)
//   Flare arcs:  90° quarter arcs, top `flareR` of height
//   Body sides:  vertical, from y=flareR to y=h
//   Body width:  rect.width - 2*flareR  (narrower)
//   Bottom edge: width = rect.width - 2*flareR  (square corners)
//
// Lives entirely within the rect — for the resting pill, that's
// the 32pt menu-bar zone, so no part of the silhouette crosses
// the menu bar bottom.

private struct OutwardFlaredShape: Shape {
    var topFlareRadius: CGFloat
    var bottomCornerRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topFlareRadius, bottomCornerRadius) }
        set {
            topFlareRadius = newValue.first
            bottomCornerRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let topR = max(0, min(topFlareRadius, rect.height / 3, rect.width / 4))
        let bottomR = max(0, min(bottomCornerRadius, rect.height / 3, max(0, rect.width / 2 - topR)))
        // Body sides are inset from the panel edges by topR — gives
        // the body a narrower waist than the top edge so the top
        // flares can extend OUTWARD to the panel edges.
        let leftBodyX = rect.minX + topR
        let rightBodyX = rect.maxX - topR
        // Bottom edge is further inset by bottomR — bottom corners
        // round INWARD from the body to a narrower bottom edge.
        let leftBottomEdgeX = leftBodyX + bottomR
        let rightBottomEdgeX = rightBodyX - bottomR
        let topY = rect.minY
        let bottomY = rect.maxY
        let bodyStartY = topY + topR
        let bodyEndY = bottomY - bottomR

        // Top-left of silhouette (at full panel width)
        path.move(to: CGPoint(x: rect.minX, y: topY))
        // Top edge to top-right
        path.addLine(to: CGPoint(x: rect.maxX, y: topY))

        // Top-right OUTWARD flare: bulges into the upper-right
        // shoulder, body comes inside below.
        path.addArc(
            center: CGPoint(x: rightBodyX, y: topY),
            radius: topR,
            startAngle: .degrees(0),
            endAngle: .degrees(90),
            clockwise: false
        )

        // Body right side down to bottom rounding start
        path.addLine(to: CGPoint(x: rightBodyX, y: bodyEndY))

        // Bottom-right INWARD rounded corner: arc center at the
        // inset corner (rightBottomEdgeX, bodyEndY). The arc passes
        // through the upper-right of this center — the bottom-right
        // corner of the silhouette is "cut off" smoothly.
        path.addArc(
            center: CGPoint(x: rightBottomEdgeX, y: bodyEndY),
            radius: bottomR,
            startAngle: .degrees(0),
            endAngle: .degrees(90),
            clockwise: false
        )

        // Bottom edge — narrower than body
        path.addLine(to: CGPoint(x: leftBottomEdgeX, y: bottomY))

        // Bottom-left INWARD rounded corner
        path.addArc(
            center: CGPoint(x: leftBottomEdgeX, y: bodyEndY),
            radius: bottomR,
            startAngle: .degrees(90),
            endAngle: .degrees(180),
            clockwise: false
        )

        // Body left side up to top flare start
        path.addLine(to: CGPoint(x: leftBodyX, y: bodyStartY))

        // Top-left OUTWARD flare
        path.addArc(
            center: CGPoint(x: leftBodyX, y: topY),
            radius: topR,
            startAngle: .degrees(90),
            endAngle: .degrees(180),
            clockwise: false
        )

        path.closeSubpath()
        return path
    }
}

// MARK: - Charging tile (pill content for charging events)

/// 22pt rounded square that shows a battery/bolt glyph and animates
/// while the pill is in "charging" mode. The bolt does a continuous
/// 1.0 → 1.18 scale + opacity pulse (~1s cycle) to convey "energy
/// flowing in"; the unplugged battery glyph stays static. On first
/// appearance the entire tile springs from 0.6 → 1.0 scale to give
/// the pill morph a satisfying tactile pop.
private struct ChargingTile: View {
    let percent: Int
    let plugged: Bool

    @State private var pulse: Bool = false
    @State private var appeared: Bool = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(tileColor)
            Image(systemName: plugged ? "bolt.fill" : "battery.50")
                .font(.system(size: 11, weight: .heavy))
                .foregroundStyle(.white)
                .scaleEffect(plugged && pulse ? 1.18 : 1.0)
                .opacity(plugged && pulse ? 0.85 : 1.0)
                .animation(
                    plugged
                        ? .easeInOut(duration: 0.7).repeatForever(autoreverses: true)
                        : .default,
                    value: pulse
                )
        }
        .frame(width: 22, height: 22)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .scaleEffect(appeared ? 1.0 : 0.6)
        .onAppear {
            withAnimation(.bouncy(duration: 0.45, extraBounce: 0.3)) {
                appeared = true
            }
            if plugged {
                // Slight delay so the appear-bounce settles before
                // the pulse loop starts — otherwise the two
                // animations overlap and read as jitter.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                    pulse = true
                }
            }
        }
    }

    private var tileColor: Color {
        if plugged {
            return Color(red: 0.30, green: 0.78, blue: 0.39)
        }
        if percent < 20 {
            return Color(red: 0.95, green: 0.40, blue: 0.20)
        }
        return Color(red: 0.45, green: 0.45, blue: 0.50)
    }
}
