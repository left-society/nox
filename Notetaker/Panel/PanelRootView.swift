import SwiftUI
import AppKit
import UniformTypeIdentifiers

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

    /// SF Symbol for the dock-style tab bar. Per the user's
    /// 2026-04-29 redesign request ("instead of using text for
    /// image/video stuff just use Apple icons — transparent ones"),
    /// every tab is now icon-only. References: the Liquid-Glass
    /// floating dock pill that ships with macOS Tahoe / iOS 26 +
    /// the user's reference screenshot showing a frosted pill bar
    /// with 6-7 outlined circular icons.
    ///
    /// Picking guidelines (matched to Apple's canonical glyphs for
    /// each domain):
    ///   • Music — `music.note` (Music app's notch glyph)
    ///   • Notes — `note.text` (Notes.app dock + sidebar glyph)
    ///   • Images — `photo` (Photos.app, Markup, screenshot
    ///     stack — outlined variant for "transparent" feel)
    ///   • Videos — `play.rectangle` (QuickTime + Apple Music
    ///     videos tab use the rectangular play glyph)
    ///   • Files — `folder` (Finder's canonical glyph; outlined
    ///     SF Symbol matches the user's "transparent ones" cue
    ///     better than `tray.full`)
    var icon: String {
        switch self {
        case .music: return "music.note"
        case .notes: return "note.text"
        case .images: return "photo"
        case .videos: return "play.rectangle"
        case .files: return "folder"
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

    /// Height of the visible pill content area BELOW the menu bar.
    /// Matches `PanelWindowController.closedPillBump` (20pt — the
    /// locked Alcove-parity dimension). Pill body views render at
    /// this height in the visible drop-down zone, NOT at notchOverlap
    /// height in the menu-bar-overlap zone (which gets covered by
    /// physical notch hardware + menu-bar items).
    ///
    /// This is iPhone Dynamic Island's geometry: silhouette extends
    /// downward past the cutout, content lives in the visible area.
    private let pillContentHeight: CGFloat = PanelWindowController.closedPillBump

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

    /// Decoded NSImage for the currently-displayed artwork, looked
    /// up from `ArtworkCache`. nil when no artwork data is available
    /// yet (placeholder music.note shows in that case) or while a
    /// background decode is in flight. Refreshed whenever
    /// `displayedNowPlaying` changes — re-renders this state when
    /// the cache completes a decode.
    @State private var pillArtworkImage: NSImage? = nil

    // (Motion-blur snapshot now lives on PanelPresenter, cached
    // by PanelWindowController after each settled state. Removed
    // the @State here — the previous attempt to re-render
    // `renderableContent` via ImageRenderer crashed because the
    // SwiftUI tree depends on @EnvironmentObject stack that
    // doesn't propagate into ImageRenderer's render context.)

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

    /// Stable identity for the dictation pill content — used as
    /// `.id(...)` on the SwiftUI view so phase transitions trigger
    /// the bouncy `.pillPop` transition. Three discrete states map
    /// to three IDs; same-phase changes (audio level updates while
    /// `.recording`) keep the same ID and don't re-trigger the
    /// transition.
    private var dictationStateID: String {
        switch presenter.dictationPhase {
        case .idle: return "idle"
        case .recording: return "rec"
        case .transcribing: return "transcribing"
        case .error: return "err"
        }
    }

    /// Rubber-banded swipe offset for the resting pill. Maps the raw
    /// drag distance through a square-root-ish curve so that the
    /// pill follows the finger ~1:1 for the first ~10pt then tapers
    /// — past ~30pt it barely moves further. Caps at ±20pt absolute
    /// so the pill silhouette never visibly clears the notch
    /// rectangle. Earlier the offset was a direct `min(max(-20, dx), 20)`
    /// clamp, which felt rigid (the pill stops dead at the cap
    /// instead of resisting). Reads as Apple's standard rubber-band
    /// over-scroll behavior.
    private var rubberBandedSwipeOffset: CGFloat {
        let raw = pillSwipeOffset
        // Polynomial easing: out = sign(x) * (max * (1 - exp(-|x| / max)))
        // — a soft-clip toward `max` that never reaches it. Looks
        // smooth at all drag distances and bounded by `max`.
        let cap: CGFloat = 20
        let sign: CGFloat = raw >= 0 ? 1 : -1
        let magnitude = abs(raw)
        let eased = cap * (1 - exp(-magnitude / cap))
        return sign * eased
    }

    /// Two sides for the chevron overlay. Left chevron means
    /// "swiping left to commit previous"; right chevron means
    /// "swiping right to commit next."
    private enum SwipeSide { case left, right }

    /// Chevron opacity ramps with how far the user has dragged
    /// past the 10pt minimum. Bright when armed (past threshold).
    /// Hidden completely when there's no drag in flight.
    private func swipeChevronOpacity(side: SwipeSide) -> Double {
        let dx = pillSwipeOffset
        // Right chevron only shows when dragging right (positive dx).
        // Left chevron only when dragging left (negative dx).
        let directional: Double
        switch side {
        case .left:  directional = dx < 0 ? Double(-dx) : 0
        case .right: directional = dx > 0 ? Double(dx) : 0
        }
        guard directional > 4 else { return 0 }   // dead-zone
        // Ramp from 0 → 0.5 over the 4–35pt drag range, then jump
        // to 1.0 once the threshold is crossed (signaled by the
        // armed direction matching this side).
        let armedSign = pillSwipeArmedDirection
        let isArmed = (armedSign == 1 && side == .right) ||
                      (armedSign == -1 && side == .left)
        if isArmed { return 1.0 }
        let ramp = min(0.5, (directional - 4) / 60.0)
        return ramp
    }

    /// Chevron scales up subtly when armed — same affordance as
    /// the macOS swipe-actions in Mail.
    private func swipeChevronScale(side: SwipeSide) -> Double {
        let armedSign = pillSwipeArmedDirection
        let isArmed = (armedSign == 1 && side == .right) ||
                      (armedSign == -1 && side == .left)
        return isArmed ? 1.18 : 1.0
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

    /// Inverse-bow shoulder radius at the top corners — drives the
    /// concave "S-curve" where the slab tucks under the menu bar.
    /// Smaller for the resting pill (subtle chamfer at the corners)
    /// and larger for the open slab (visible shoulder curve).
    /// Both values land in OutwardFlaredShape.path's `topR` clamp.
    /// Interpolated alongside `panelBottomRadius` via the shape's
    /// `animatableData` for a smooth pill→slab morph of both
    /// radii in lockstep.
    private var panelTopRadius: CGFloat {
        presenter.isShown ? 22 : 6
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
            // OPAQUE BLACK NOTCH BAND. ALWAYS-RENDERED (no
            // `if presenter.isShown` gate) so it doesn't fade
            // in during the open morph. Earlier the band was
            // gated and the `withAnimation(.easeInOut(0.45))`
            // wrapping `presenter.isShown = true` applied an
            // implicit insertion fade — for the first ~200ms
            // of the open, the band was at partial opacity and
            // the panel's vibrancy background let the desktop
            // wallpaper bleed the top with hue. User saw it
            // as "light coming from the notch for a few
            // milliseconds during the open."
            //
            // Always-rendered means: when the panel is in pill
            // state (isShown=false), the band is still here at
            // full opacity. The panelBackground is also pure
            // Color.black in that state, so the band is
            // visually a no-op (black on black). When the
            // panel grows to slab and panelBackground becomes
            // translucent (VisualEffectBlur + 65% black), the
            // band is ALREADY at full opacity from frame zero
            // — no crossfade window, no wallpaper leak.
            //
            // LinearGradient with hard black at top, soft fade
            // at the bottom edge so the band-to-content
            // transition reads as continuous gradient, not a
            // visible seam.
            //
            // Height = notchOverlap + 36pt covers the hardware
            // notch (~32-37pt safe-area-inset) plus a fade tail
            // that meets the artwork gradient cleanly.
            .overlay(alignment: .top) {
                LinearGradient(
                    stops: [
                        .init(color: Color.black, location: 0.0),
                        .init(color: Color.black, location: 0.55),
                        .init(color: Color.black.opacity(0.7), location: 0.75),
                        .init(color: Color.black.opacity(0.0), location: 1.0),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: notchOverlap + 36)
                .frame(maxWidth: .infinity)
                .allowsHitTesting(false)
            }
            // artworkTopGradient overlay REMOVED per user request:
            // "remove the gradient from the thing and make it deep
            // black. And gradient will be only in song timeline,
            // play button, next button and the audio visualizer."
            // The slab background is now solid black; the album-
            // color tint lives only on the interactive controls
            // (progress bar fill, transport button accents, and
            // the visualizer bars). Function `artworkTopGradient`
            // is kept defined below in case we want to reintroduce
            // ambient lighting later, but it's no longer wired in.
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
                //
                // Per "still feeling like a little gradient at the
                // top while opening for a millisecond" feedback:
                // when `isShown` flips true (wrapped in
                // `withAnimation(.easeInOut(0.45))`), this
                // conditional removal was being animated as a fade
                // — the small album-art tile + waveform stayed
                // visible at the top of the growing slab for the
                // first 200+ms of the morph, which read as a
                // brief color flash at the top. Use
                // `.transition(.identity)` + an explicit
                // `transaction { animation = nil }` wrapper so the
                // removal is INSTANT regardless of the parent
                // animation context. The pill content vanishes
                // the moment isShown flips true; the slab grows
                // over a clean black panel from frame zero.
                Group {
                    if !presenter.isShown {
                        pillContentOverlay
                            .transition(.identity)
                    }
                }
                .transaction { txn in txn.animation = nil }
            }
            .overlay(alignment: .top) { contentOverlay }
            // Two-zone drop picker overlay — visible only while a
            // drag is hovering the panel. Splits the slab into Save
            // (left) and AirDrop (right) zones; the AppKit drop
            // layer (PanelDropContainer) flips
            // `dropPickerHoveredZone` based on cursor X-position so
            // this overlay highlights the hot zone in real time.
            // The zone-routing decision lives in
            // `PanelDropContainer.performDragOperation`.
            //
            // Padded to inset from the silhouette's curved corners
            // (notchOverlap on top to clear the menu bar zone,
            // panelTopRadius on the sides to match the slab body).
            .overlay {
                if presenter.dropPickerActive && presenter.isShown {
                    DropPickerView(
                        hoveredZone: presenter.dropPickerHoveredZone,
                        fileCount: presenter.dropPickerFileCount
                    )
                        // Picker fills the ENTIRE silhouette edge-
                        // to-edge — no padding. The panelSilhouette
                        // clip catches the rounded corners and notch
                        // cutout so the picker's two halves inherit
                        // the panel's shape automatically. User
                        // confirmed: "cover the entire thing not
                        // only down side."
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .transition(.opacity.combined(with: .scale(scale: 0.97)))
                        .allowsHitTesting(false)  // AppKit layer handles drops
                }
            }
            .animation(.easeOut(duration: 0.18), value: presenter.dropPickerActive)
            .overlay { borderStroke }
            // Re-clip the entire stack (background + every overlay)
            // to the panel silhouette. Without this, scrollable
            // content like the Images grid paints over the rounded
            // bottom-corner regions, making the panel look like it
            // has a square bottom against the desktop. The background
            // alone is already clipped above; the second clip here
            // catches the overlays that ride on top of it.
            .clipShape(panelSilhouette)
            // Drop ring rendered AFTER the clip so the outer halo
            // (the most visually impactful layer) extends OUTSIDE
            // the silhouette and isn't chopped off. Without this
            // ordering the user just saw a faint "light in the
            // back" because only the inner edge of the stroke was
            // surviving the clip.
            .overlay { dropRingOverlay }
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
            // Direction-aware animation. Numbers MUST mirror the
            // PanelWindowController NSPanel-frame springs so the
            // SwiftUI-side properties (corner radius, content opacity,
            // shadow params) finish on the same beat as the window
            // geometry. Mismatch = silhouette settles at one duration
            // while panel frame is still morphing → user sees
            // "endpoint not landing."
            //
            // 2026-05-04 (rev 5): same SpringFrameAnimator class on
            // both sides of the panel-frame morph, but different
            // damping ratios:
            //   OPEN:  stiffness 240, damping 26 (ratio ≈ 0.84,
            //                                     slight overshoot,
            //                                     "alive bloom")
            //   CLOSE: stiffness 320, damping 36 (ratio ≈ 1.0,
            //                                     no overshoot,
            //                                     "decisive collapse")
            // Mirror the SwiftUI silhouette's corner-radius /
            // top-flare interpolation to MATCH each direction so the
            // shape morph runs in lockstep with the frame morph
            // without a curve mismatch at the transition seam.
            .animation(presenter.isShown
                       ? .interpolatingSpring(mass: 1.0, stiffness: 240, damping: 26, initialVelocity: 0)
                       : .interpolatingSpring(mass: 1.0, stiffness: 320, damping: 36, initialVelocity: 0),
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
            // Shadow values reverted to the original stacked
            // pair on 2026-04-29 user request ("don't touch the
            // shadow"). My optimization passes were not the
            // source of the visible 2-layer artifact, and the
            // single-shadow / smaller-radius experiments
            // changed the depth feel without fixing the bug.
            // Original values from the last known-good
            // production build, preserved:
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
        renderableContent
        // Push UI below the menu-bar zone. The top `notchOverlap`
        // points of the panel are hidden behind the notch /
        // menu-bar strip; we offset visible widgets down by exactly
        // that amount so the header lands flush below the bar.
        .padding(.top, notchOverlap)
        // Inset content horizontally by `panelTopRadius` so it
        // fits inside the silhouette's body (which is itself
        // inset by `topR` from the rect on each side — see
        // OutwardFlaredShape). Without this padding, content
        // extends to the panel's full width and gets clipped
        // by the silhouette mask at the inverse-bow shoulder
        // curves on each top corner. User: "the contents inside
        // of it ... are out of the place." 22pt on each side
        // when the slab is open, 6pt when the pill is at rest;
        // the value tracks `panelTopRadius` so the inset
        // animates in lockstep with the silhouette morph.
        .padding(.horizontal, panelTopRadius)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // CRITICAL: compositingGroup MUST come before blur so the
        // blur is applied to a flattened single layer instead of
        // to each subview independently.
        .compositingGroup()
        // Hide the regular slab content entirely while the two-zone
        // drop picker is active, so the picker is unambiguously the
        // only thing the user sees during drag. The black panel
        // background (panelBackground) stays underneath so the
        // silhouette is intact.
        .opacity(presenter.isShown ? (presenter.dropPickerActive ? 0 : 1.0) : 0)
        .animation(.easeOut(duration: 0.18), value: presenter.dropPickerActive)
        // REVERTED the asymmetric fade-with-delay attempt. The 0.15s
        // delay between "silhouette grows" and "content fades in"
        // was meant to mirror NotchNook's two-stage reveal, but in
        // practice the empty-silhouette window read as "panel is
        // broken" — the user caught it mid-open in a screenshot
        // and reported "what the fuck is this." Without the delay,
        // content fades alongside the panel's open spring (parent
        // withAnimation context), and the eye never sees a
        // visibly-empty slab. Preferable feel.
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
        //
        // Elastic content scale tied to the panel's open spring.
        // Without this the transport row + source badge looked
        // "stiff plastic" while the panel walls were jelly-
        // bouncing around them. Scaling the entire content
        // overlay with a spring matched to the panel's frame
        // morph means everything inside breathes WITH the
        // panel: 0.86 compressed when closed → 1.0 with two
        // visible bounces when opening, matching the panel's
        // 11.4% / 1.30% rhythm.
        //
        // SwiftUI mapping for panel's stiffness 200 / damping 16
        // (ω_n = 14.14, period = 0.444s, ratio = 0.566):
        //   response = 0.44s (matches panel's natural period)
        //   dampingFraction = 0.566 (matches ratio)
        // Both springs share ω_n and ratio so they trace the
        // same elastic curve at the same rate — content and
        // walls settle in lockstep, no two-stage stop.
        // PROGRESSIVE BLUR on content materialization (re-added).
        // Per direct frame-by-frame audit of NotchNook's open
        // animation (Built-in Retina Display 0930→0940→0960):
        //   • frame 0930: silhouette growing, content invisible
        //   • frame 0940: silhouette at full width, CONTENT HEAVILY
        //     BLURRED (~10-12pt gaussian) — purple album-art blob,
        //     unreadable text, faint shapes
        //   • frame 0960: silhouette settled, content fully sharp
        //   • Same pattern in reverse on close (frame 1340).
        // This is the "gentle materialization" the user asked for —
        // content doesn't pop in flat, it comes into focus through
        // a soft gaussian dissolve.
        //
        // 40pt radius — heavily bumped per direct frame audit of
        // jackson-storm/DynamicNotch's BlurFadeModifier (ships
        // blur: 40 for the active/closed state) and the user's
        // repeated feedback that 12pt and 20pt "couldn't be felt."
        // 40pt produces a clearly visible "frosted glass / out of
        // focus" state — content is recognizable as colored shapes
        // but text and details are illegible until the spring
        // settles. Reads unambiguously as a focus-pull, not a
        // micro-smear.
        //
        // The blur transition uses a SLOW HIGH-DAMPING SPRING
        // (response: 0.52, dampingFraction: 0.8) — adopted from
        // jackson-storm's "balanced" preset. Why this matters:
        //   • easeInOut is symmetric — at t=0.5 of duration,
        //     blur is at radius 20 (perception threshold), so
        //     half the animation runs with imperceptible blur.
        //   • A high-damping spring concentrates ~70% of its
        //     visible time near the start, so blur stays HIGH
        //     for most of the duration and then snaps clear at
        //     the end — that's the "focus pulling" sensation.
        //
        // The compositingGroup() above flattens content first; the
        // blur radius then applies to a single layer (proper
        // gauzy soft-focus), not to each subview independently
        // (which read as pixelated).
        .blur(radius: presenter.isShown ? 0 : 40)
        .scaleEffect(presenter.isShown ? 1.0 : 0.86, anchor: .top)
        .animation(.spring(response: 0.52, dampingFraction: 0.8),
                   value: presenter.isShown)
        // No blur on the content overlay. Earlier attempts:
        //   • `.blur(radius: 4)` (gaussian) — wrong character;
        //     reads as soft-focus / out-of-focus rather than
        //     in-motion. User explicitly rejected.
        //   • CIMotionBlur via NSView wrapper — closer to the
        //     reference (vertical directional smear) but
        //     `CALayer.filters` is restricted on macOS for
        //     CIMotionBlur in app contexts; per-frame
        //     ImageRenderer + CIFilter is too expensive.
        //   • Stacked-offset duplicates — would work, but
        //     SwiftUI's ViewModifier `Content` parameter can't
        //     cleanly be duplicated multiple times in an
        //     overlay without recursive layout issues.
        //
        // Skipping artificial blur for now. The spring's
        // natural motion at 60fps + the elastic content scale
        // already produce perceived motion; adding fake blur
        // didn't help. If we want a true motion-blur pass
        // later, the right surgery is a custom NSHostingView
        // subclass that snapshots its layer to NSImage on each
        // tick, applies CIMotionBlur with angle = motion
        // direction, and re-displays — and that's worth its
        // own focused session.
        //
        // Trailing compositingGroup REMOVED — we now have one
        // BEFORE the blur (so blur applies to a flattened layer,
        // proper soft-focus). A second compositingGroup at the
        // tail end was redundant and might have layered an extra
        // raster pass on top of the already-flattened content.
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
        // INVERTED gradient — "notch black extends down, then
        // color emerges below" rather than "color blooms FROM
        // the notch." Per user feedback: the previous design
        // had the brightest point of the radial gradient AT the
        // notch (center y=0), which read as "light is coming
        // OUT of the notch hardware." That broke the illusion
        // we wanted: the notch should feel like a solid piece
        // of CONTINUOUS HARDWARE that the panel grows out of,
        // not a light source. The user's mental model: notch
        // hardware is black → there should be a thin black band
        // continuing that black down into the panel → THEN the
        // album color emerges below.
        //
        // Two changes from the previous radial-from-notch:
        //   1. Radial center moved from (0.5, 0) to (0.5, 0.22)
        //      — the bloom is now ~22% down from the panel top,
        //      below the notch zone. Notch-adjacent pixels see
        //      the gradient at low intensity.
        //   2. Linear mask flipped: was "full opacity at top,
        //      fading down" → now "clear/dark at top, ramps to
        //      full at ~30%, fades back at ~85%". The masked
        //      gradient peaks in the upper-middle of the panel,
        //      not at the notch line.
        //
        // Net effect: the very top of the panel is solid black
        // (continuous with the hardware notch), and a soft glow
        // of the album's dominant color emerges in the upper-
        // middle area below the header. Reads as "the panel is
        // hanging from the notch, lit from within" instead of
        // "the notch is glowing."
        //
        // Gate: `isShown && !isMorphing`. The gradient ONLY
        // renders when the panel is fully open AND not currently
        // morphing (slab-open spring or tab-switch height morph).
        //
        // CRITICAL for slab-open smoothness. `isMorphing` is true
        // for the entire duration of:
        //   • The slab-open spring (pill → full slab) at line
        //     1523 of PanelWindowController, until ~1597 when the
        //     tail spring settles.
        //   • Tab-switch height morphs (line 1416 → 1434 in same
        //     file).
        //
        // While `isMorphing` is true, the panel's frame is
        // changing every spring tick (120Hz). If the masked
        // RadialGradient is rendered during that time, every
        // frame size change forces a full re-rasterization of
        // the gradient + linear mask combination. That
        // compositing work competes with the spring physics
        // for main-thread/GPU bandwidth, starves the tail
        // spring's sub-pixel motions (50/14 critically damped
        // with positionThreshold 0.1pt), and the user sees a
        // perceptual hard stop at the end of the open animation.
        // The user's exact words on the regression: "the
        // animation when finish is looking kinda stop. like i
        // can feel it's stopped. we fixed it before. why now
        // it's happening?"
        //
        // Earlier I removed the `!isMorphing` gate so the
        // gradient could "persist across tab switches" (per a
        // different user request). That broke the slab-open
        // smoothness. The right answer is: keep the gate. The
        // gradient appears AFTER the slab settles — which is
        // exactly the "nailed" version the user wants restored.
        // Tab-switch persistence is a future improvement that
        // needs a different mechanism (e.g., a separate
        // `isOpening` flag, or a fixed-size gradient layer that
        // doesn't re-rasterize as the panel resizes).
        if presenter.isShown,
           !presenter.isMorphing,
           let data = presenter.nowPlaying?.artworkData,
           let color = ArtworkColor.dominant(from: data) {
            // TOP-ANCHORED gradient — bloom emerges from the
            // upper-middle of the panel (just below the notch
            // zone) and dissolves downward into clean black
            // before reaching the transport row.
            //
            // Center at y=0.22 (22% down from the panel's top
            // edge) keeps the bloom's brightest point BELOW
            // the always-rendered black notch band — so the
            // notch hardware still reads as solid hardware,
            // not a light source, while the glow visibly
            // emerges from the upper portion of the panel.
            //
            // The brief "light from notch" flash glitch on
            // open is handled separately by:
            //   - The always-rendered black notch band
            //     (LinearGradient with hard top + soft bottom
            //     fade) which masks the gradient's top edge
            //     during the slab open animation, so no
            //     wallpaper or gradient bleed is visible
            //     through the notch zone before the slab is
            //     fully extended.
            //   - Pill content uses .transition(.identity) +
            //     .transaction { animation = nil } so it
            //     vanishes instantly when the slab opens
            //     (no cross-fade flash).
            //
            // STATIC gradient (no TimelineView). User reported
            // the slab open animation felt like it "stopped"
            // at the end — the previous TimelineView was re-
            // rendering the masked radial gradient at 30Hz,
            // and that constant compositing competed with the
            // slab's spring physics (120Hz tick + 50/14 tail
            // spring with sub-pixel-tight thresholds) for main-
            // thread/GPU bandwidth. The spring's last few sub-
            // pixel motions got starved out → perceptual hard
            // stop at the settle.
            // Removing the breathing animation eliminates the
            // per-frame gradient compositing, so the slab's
            // tail spring renders cleanly all the way to rest.
            // Trade-off: the gradient is now perfectly still.
            // Per the user's "let's revert" — this matches the
            // version that felt right before the breathing was
            // added.
            RadialGradient(
                gradient: Gradient(stops: [
                    .init(color: color.opacity(0.55), location: 0.0),
                    .init(color: color.opacity(0.30), location: 0.35),
                    .init(color: color.opacity(0.08), location: 0.7),
                    .init(color: Color.clear, location: 1.0),
                ]),
                // Top-area anchor. y=0.22 puts the bloom peak
                // just below the notch zone — close enough to
                // tint the upper panel without making the
                // notch hardware look like a light source.
                center: UnitPoint(x: 0.5, y: 0.22),
                startRadius: 0,
                endRadius: 280
            )
            .mask(
                // Full opacity at the top, fading down. Lets the
                // bloom shine clearly in the upper panel and
                // dissolves to clean black before reaching the
                // transport / tab content area at the bottom.
                LinearGradient(
                    stops: [
                        .init(color: Color.black, location: 0.0),
                        .init(color: Color.black, location: 0.45),
                        .init(color: Color.black.opacity(0.55), location: 0.7),
                        .init(color: Color.clear, location: 1.0),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .allowsHitTesting(false)
            // Cross-fade smoothly when the dominant color
            // changes (track swap).
            .animation(.easeInOut(duration: 0.4),
                       value: presenter.nowPlaying?.artworkData)
            // Fade-in/out on track-arrival or track-end. Note
            // we removed the !isMorphing gate from the outer
            // `if`, so this transition only fires when music
            // actually starts/stops — NOT on every panel-open
            // or tab-switch morph.
            //
            // REVERT: previously tried .offset(y:50) + .opacity
            // with easeOut(0.85)+0.18s delay (rise-from-bottom).
            // User reported the easeOut's zero-terminal-velocity
            // ending read as a perceptual "stop" overlapping
            // with the slab's settle, breaking the open feel.
            // Reverted to plain opacity — cleaner end, no
            // motion to compete with the slab's spring tail.
            .transition(.opacity.animation(.easeInOut(duration: 0.35)))
        }
    }

    // breathingPhase helper removed — see artworkTopGradient
    // comment for why the breathing animation was retired
    // (TimelineView's 30Hz redraws were starving the slab
    // spring's tail at the end of the open animation).

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
                    .transition(.pillPop)
                    .id("charging")
            } else if case .screenshotSaved(let count) = presenter.pendingSystemEvent {
                screenshotPillContent(count: count)
                    .transition(.pillPop)
                    // Stable id across count updates — a burst
                    // updates `count` only, the view stays mounted
                    // and the count Text re-renders in place
                    // instead of re-running the entrance bounce
                    // for every shot.
                    .id("screenshot")
            } else if case .downloadStarted(let host) = presenter.pendingSystemEvent {
                downloadPillContent(host: host, completed: false)
                    .transition(.pillPop)
                    .id("download-start-\(host)")
            } else if case .downloadCompleted(let host) = presenter.pendingSystemEvent {
                downloadPillContent(host: host, completed: true)
                    .transition(.pillPop)
                    .id("download-done-\(host)")
            } else if case .noteSaved = presenter.pendingSystemEvent {
                noteSavedPillContent
                    .transition(.pillPop)
                    .id("noteSaved")
            } else if case .bluetoothConnected(let name, let isAirPods) = presenter.pendingSystemEvent {
                bluetoothPillContent(name: name, isAirPods: isAirPods, isConnected: true)
                    .transition(.pillPop)
                    .id("btConnected-\(name)")
            } else if case .bluetoothDisconnected(let name, let isAirPods) = presenter.pendingSystemEvent {
                bluetoothPillContent(name: name, isAirPods: isAirPods, isConnected: false)
                    .transition(.pillPop)
                    .id("btDisconnected-\(name)")
            } else if case .timerRunning(let remaining) = presenter.pendingSystemEvent {
                timerRunningPillContent(remainingSeconds: remaining)
                    .transition(.opacity)
                    // Stable id across tick updates so the entrance
                    // bounce only fires once on start.
                    .id("timerRunning")
            } else if case .timerFinished = presenter.pendingSystemEvent {
                timerFinishedPillContent
                    .transition(.pillPop)
                    .id("timerFinished")
            } else if case .calendarUpcoming(let title, let minutes) = presenter.pendingSystemEvent {
                calendarUpcomingPillContent(title: title, minutesUntilStart: minutes)
                    .transition(.pillPop)
                    // Stable id while the same meeting is counting
                    // down — minute updates re-render in place.
                    .id("calendar-\(title)")
            } else if case .airDropReceived(let filename) = presenter.pendingSystemEvent {
                airDropPillContent(filename: filename)
                    .transition(.pillPop)
                    .id("airdrop-\(filename)")
            } else if case .airDropSent(let count) = presenter.pendingSystemEvent {
                airDropSentPillContent(count: count)
                    .transition(.pillPop)
                    .id("airdrop-sent-\(count)")
            } else if case .airDropFailed = presenter.pendingSystemEvent {
                airDropFailedPillContent()
                    .transition(.pillPop)
                    .id("airdrop-failed")
            } else if let videoURL = presenter.pendingVideoCandidate {
                videoPreviewPillContent(for: videoURL)
                    .transition(.pillPop)
                    .id("video")
            } else if presenter.dictationPhase != .idle {
                // DICTATION TAKES OVER the pill. ONE id for ALL
                // non-idle phases ("dictation") so the view
                // doesn't get re-mounted between recording →
                // transcribing → error — the SAME view instance
                // morphs in place via `DictationPillContent`'s
                // internal property animations. That fixes the
                // "everything off-center / jumps to another
                // layer" feel the user reported.
                //
                // Transition: scale-in from 0.7× anchored at .top
                // (so the notch hardware connection never moves)
                // + opacity fade. On exit, fade-out only — the
                // pill returns to whatever was underneath
                // (music or empty pill) without a visual jolt.
                DictationPillContent(
                    phase: presenter.dictationPhase,
                    audioLevel: presenter.dictationLevel
                )
                    // SAME outer modifiers as musicPillContent
                    // (PanelRootView lines ~1790–1800). The
                    // dictation expansion is HORIZONTAL only —
                    // the host panel grows from 278pt to 420pt
                    // wide (PanelWindowController.dictationPillWidth)
                    // while keeping the same `notchOverlap`
                    // height. With the wider host pill, the
                    // HStack's Spacer pushes the indicator and
                    // waveform onto opposite wings of the notch
                    // with substantially more breathing room
                    // than the music pill — that's the visible
                    // expansion. Vertical layout stays exactly
                    // matched to the music pill so both modes
                    // share one visual rhythm.
                    .padding(.horizontal, 10)
                    .frame(height: notchOverlap)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .transition(
                        .asymmetric(
                            insertion: .scale(scale: 0.7, anchor: .top).combined(with: .opacity),
                            removal: .opacity
                        )
                    )
                    .id("dictation")
            } else {
                musicPillContent
                    .transition(.opacity)
                    .id("music")
            }
        }
        // Critically-damped spring on the content swap. Bouncy was
        // overshooting on entrance AND exit — and on exit the
        // opacity component races to 0 before the scale's bounce-
        // back completes, so SwiftUI removes the view mid-animation
        // and the user sees the motion get cut off. That was the
        // "endpoints totally broken" complaint.
        //
        // .smooth is a critically-damped interpolating spring: it
        // runs from start to end and lands cleanly with zero
        // overshoot, so the visible motion plays out fully on both
        // sides. Combined with the bigger entrance/exit scale deltas
        // (.pillEnter 0.65, .pillExit 0.7) the user sees a clear
        // grow-in + shrink-out without any abrupt truncation.
        // Duration matched between event swap and video candidate
        // for one consistent rhythm across all transient pill swaps.
        .animation(.smooth(duration: 0.45),
                   value: presenter.pendingSystemEvent)
        .animation(.smooth(duration: 0.45),
                   value: presenter.pendingVideoCandidate)
        // Dictation pill MOUNT/UNMOUNT animation — only fires at
        // entrance (idle → non-idle) and exit (non-idle → idle).
        // Phase changes WITHIN the dictation (recording →
        // transcribing → error) stay on the SAME mounted view
        // and morph via DictationPillContent's internal property
        // animations, so this curve doesn't re-trigger and the
        // user doesn't see "another layer" appear mid-stream.
        .animation(.spring(response: 0.42, dampingFraction: 0.62),
                   value: presenter.dictationPhase == .idle)
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
            case .airDropSent(let count): return "airdropSent-\(count)"
            case .airDropFailed: return "airdropFailed"
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
            case .airDropSent: return Color(red: 0.30, green: 0.78, blue: 0.99)
            case .airDropFailed: return Color(red: 0.65, green: 0.65, blue: 0.70)
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
            // Right-wing badge — checkmark when done, three-dot
            // ellipsis when in progress. Sits past the notch so
            // it actually paints; pairs with the left-wing
            // accent-tinted tile to give the user a quick read on
            // the state without a long "Done"/"Downloading" label
            // that wouldn't fit in the right wing anyway.
            Image(systemName: completed ? "checkmark" : "ellipsis")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(accent)
                .padding(.trailing, 4)
        }
        .padding(.horizontal, 10)
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
    /// Note-saved pill — yellow pencil tile in the LEFT wing,
    /// confirmation checkmark in the RIGHT wing past the notch
    /// hardware. Earlier we rendered a "Note saved" text label
    /// after a Spacer, placing it in the central zone where the
    /// physical notch covered it. Both wings are now used:
    /// pencil signals "what" (a note write), checkmark signals
    /// "what happened" (it succeeded).
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

            // Right-wing confirmation checkmark.
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color(red: 0.99, green: 0.80, blue: 0.20))
                .padding(.trailing, 4)
        }
        .padding(.horizontal, 10)
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
        BluetoothPillBody(
            name: name,
            iconName: bluetoothIconName(isAirPods: isAirPods),
            isConnected: isConnected,
            notchOverlap: notchOverlap,
            visible: presenter.isResting && !presenter.isShown
        )
    }

    /// Live countdown pill — orange timer glyph + monospaced
    /// "MM:SS" remaining. Stays pinned the entire time the timer
    /// is counting (the service pushes a fresh `.timerRunning(...)`
    /// every second; the same `.id("timerRunning")` keeps the view
    /// stable so the time text updates in place without retriggering
    /// the entrance bounce on each tick).
    private func timerRunningPillContent(remainingSeconds: Int) -> some View {
        TimerRunningPillBody(
            remainingSeconds: remainingSeconds,
            timeText: formatTimerDuration(remainingSeconds),
            notchOverlap: notchOverlap,
            visible: presenter.isResting && !presenter.isShown
        )
    }

    /// "Timer done" celebratory pill. Green checkmark + "Time's
    /// up" badge. 3-second window so the user sees it even if
    /// they were heads-down on something else.
    private var timerFinishedPillContent: some View {
        TimerFinishedPillBody(
            notchOverlap: notchOverlap,
            visible: presenter.isResting && !presenter.isShown
        )
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
        CalendarUpcomingPillBody(
            title: title,
            minutesUntilStart: minutesUntilStart,
            timeLabel: calendarTimeLabel(minutes: minutesUntilStart),
            notchOverlap: notchOverlap,
            visible: presenter.isResting && !presenter.isShown
        )
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

    /// AirDrop arrival pill — UTI-tinted tile + filename, with a
    /// brief cosmetic "progress completing" sweep on entrance. Tap
    /// reveals the file in Finder via `presenter.onRevealAirDrop`.
    ///
    /// Progress is purely cosmetic: macOS doesn't expose Sharingd's
    /// in-flight transfer progress to third-party apps (the system
    /// AirDrop sheet uses private SharingD.framework calls), so by
    /// the time we detect the file via FSEvents + quarantine xattr
    /// it's already on disk. The 600ms arc sweep is honest about
    /// being a flourish — it gives the pill a "completing transfer"
    /// presence rather than just a static tile flash, which reads
    /// more in keeping with how iOS handles this same handoff event.
    /// After the arc fills, it fades and the file's actual UTI glyph
    /// (photo / video / audio / generic) springs in.
    @ViewBuilder
    private func airDropPillContent(filename: String) -> some View {
        AirDropPillBody(
            filename: filename,
            fileURL: presenter.lastAirDropURL,
            notchOverlap: notchOverlap,
            visible: presenter.isResting && !presenter.isShown
        )
        .contentShape(Rectangle())
        .onTapGesture {
            presenter.onRevealAirDrop?()
        }
    }

    /// Confirmation pill after the user successfully sends N files via
    /// AirDrop. AirDrop logo on the left tile (matches the "received"
    /// pill's color language so both directions feel like the same
    /// family of events), then a discreet checkmark + count on the
    /// right. Apple's NSSharingService doesn't expose the recipient
    /// name to third-party apps so we deliberately avoid showing
    /// "Sent to <name>" — just the confirmation that something landed.
    @ViewBuilder
    private func airDropSentPillContent(count: Int) -> some View {
        let visible = presenter.isResting && !presenter.isShown
        HStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color(red: 0.30, green: 0.78, blue: 0.99).opacity(0.92))
                AirDropLogo()
                    .frame(width: 14, height: 14)
            }
            .frame(width: 22, height: 22)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))

            Spacer(minLength: 0)

            HStack(spacing: 3) {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color(red: 0.30, green: 0.85, blue: 0.45))
                if count > 1 {
                    Text("\(count)")
                        .font(.system(size: 11, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.92))
                }
            }
        }
        .padding(.horizontal, 10)
        .frame(height: notchOverlap)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .opacity(visible ? 1 : 0)
    }

    /// Brief acknowledgement pill when the user cancels the AirDrop
    /// sheet or the send fails. Same blue tile so the user reads it
    /// as "AirDrop, but the other state" — and a small slashed-circle
    /// glyph on the right rather than a checkmark. Kept short (2.0s)
    /// so it doesn't camp on top of the music pill.
    @ViewBuilder
    private func airDropFailedPillContent() -> some View {
        let visible = presenter.isResting && !presenter.isShown
        HStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color(red: 0.55, green: 0.55, blue: 0.60).opacity(0.92))
                AirDropLogo()
                    .frame(width: 14, height: 14)
            }
            .frame(width: 22, height: 22)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))

            Spacer(minLength: 0)

            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white.opacity(0.78))
        }
        .padding(.horizontal, 10)
        .frame(height: notchOverlap)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .opacity(visible ? 1 : 0)
    }


    @ViewBuilder
    private func chargingPillContent(percent: Int, plugged: Bool) -> some View {
        HStack(spacing: 6) {
            ChargingTile(percent: percent, plugged: plugged)
            Spacer(minLength: 0)
            // Plain Text — no inner `.transition()`. Earlier this had
            // `.move(edge: .trailing).combined(with: .opacity)` which
            // stacked on top of the parent's `.pillPop` transition,
            // causing a visible double-transition glitch where the
            // Text slid in from the right WHILE the entire pill was
            // also bouncing in. The percent value uses .contentTransition
            // for digit-level animation across charge updates without
            // needing a SwiftUI transition modifier.
            Text("\(percent)%")
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .contentTransition(.numericText())
        }
        .padding(.horizontal, 10)
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
        .padding(.horizontal, 10)
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
        // 2026-04-29 fix v2: bundle-ID allow-list for the
        // waveform. The previous artist-non-empty check was too
        // loose because the Perl adapter's sparse-payload
        // fallback (added earlier this session) sets artist to
        // the app name when MediaRemote omits it — so Podcasts,
        // YouTube tabs, browser audio all have non-empty artist
        // and slipped through. The waveform is intended as a
        // *music* visualizer; for non-music audio sources we
        // just want the source-app icon, no animated bars.
        //
        // Allow-list: Spotify + Apple Music. Everything else
        // (browsers, Podcasts, audiobook apps, system audio)
        // gets the icon-only treatment. If the user wants to
        // add another "music" app later (e.g. youtube-music
        // Electron, doppler), append its bundle ID here.
        // 2026-04-29 final v3:
        //   • Real music (Spotify / Apple Music) → ANIMATED waveform
        //   • Any other audio source → STATIC 3-bar indicator
        //     (paused=true forced regardless of `info?.isPlaying`,
        //     so the bars are computed once and frozen — no
        //     re-evaluation, no bouncing even if isPlaying toggles
        //     in the underlying state)
        //   • Empty/no source → no waveform (gracefully hides via
        //     the `if isAnyAudio` outer gate)
        // Net effect: the pill ALWAYS has visual content on the
        // right when any audio is active, but the bars only animate
        // when actual music is playing. No flicker, no empty space.
        // 2026-05-01: dropped the bundle-ID allow-list entirely.
        // The waveform's playing state is now driven by the
        // CoreAudio-sourced `presenter.isAudioFlowing` signal
        // (PanelPresenter), which is set by SystemAudioWatcher
        // every second based on `kAudioProcessPropertyIsRunningOutput`.
        // CoreAudio reports `true` only if audio bytes are actually
        // hitting the output device this tick — it can't lie or
        // flicker the way Spotify's `isPlaying` flag did during
        // track transitions. So we can let ANY audio source drive
        // the waveform animation; if the user pauses, CoreAudio
        // drops the signal within ~1 second and the waveform
        // freezes naturally.
        let info = presenter.nowPlaying
        let hasAnyAudio = info != nil || presenter.isAudioFlowing
        return HStack(spacing: 6) {
            pillArtwork
            Spacer(minLength: 0)
            // 2026-05-01 evidence-based fix. /tmp/notetaker-mra.log
            // captured: user pauses YouTube → AUDIOWATCHER never logs
            // a flip to false. Chrome keeps its audio helper's IO
            // procs alive across the pause (presumably for low-latency
            // resume), so kAudioProcessPropertyIsRunningOutput
            // returns true with silence flowing. `isAudioFlowing` is
            // therefore NOT a reliable "is something playing?" signal
            // for browser-sourced audio.
            //
            // MediaRemote's isPlaying flag IS reliable: when the user
            // pauses, MR either flips it or stops emitting (nil),
            // both of which fail the gate below.
            //
            // Combined gate:
            //   • nowPlaying with isPlaying=true → animate
            //   • nowPlaying with isPlaying=false → freeze (user paused)
            //   • no nowPlaying but audio flowing → animate (synthetic
            //     no-MR case: Discord chime, system tone — short bursts
            //     where we want some life on the pill)
            //   • no nowPlaying, no audio → frozen
            let waveformIsPlaying: Bool = {
                if let np = presenter.nowPlaying {
                    return np.isPlaying
                }
                return presenter.isAudioFlowing
            }()
            if hasAnyAudio {
                WaveformView(
                    isPlaying: waveformIsPlaying,
                    width: 26,
                    height: 18,
                    lineWidth: 2.8,
                    tint: ArtworkColor.dominant(from: info?.artworkData) ?? .white,
                    opacity: 0.95,
                    pattern: WaveformPattern.deterministic(for: trackKey)
                )
                .scaleEffect(x: waveformPulse, y: 1, anchor: .trailing)
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.20), value: hasAnyAudio)
        // Swipe-to-skip chevron hints. As the user drags past the
        // skip threshold, a chevron arrow fades in on the side
        // OPPOSITE the drag direction — i.e., dragging right
        // (commit "next") reveals a chevron.right glyph fading in
        // from the right edge, telling the user "release to skip
        // forward." Bright + slightly larger when the threshold
        // crosses (`pillSwipeArmedDirection != 0`), faint otherwise.
        // Mirrors how Apple's Mail swipe-to-archive surfaces its
        // commit affordance.
        .overlay(
            HStack {
                Image(systemName: "chevron.left")
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(.white)
                    .opacity(swipeChevronOpacity(side: .left))
                    .scaleEffect(swipeChevronScale(side: .left))
                    .padding(.leading, 4)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(.white)
                    .opacity(swipeChevronOpacity(side: .right))
                    .scaleEffect(swipeChevronScale(side: .right))
                    .padding(.trailing, 4)
            }
            .allowsHitTesting(false)
        )
        // Swipe-to-skip. Horizontal drag on the resting pill triggers
        // previous (left swipe) or next (right swipe). Driven by a
        // SwiftUI DragGesture with a 10pt minimum distance so
        // straight clicks (used for tap-to-expand the slab) still
        // pass through. Visual feedback: the whole pill shifts
        // ±20pt during the drag (now via a soft sqrt curve so it
        // tugs less than 1:1 with the finger — feels rubber-banded
        // rather than dragged), giving the user a "tug" affordance
        // before the threshold commits.
        .offset(x: rubberBandedSwipeOffset)
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
            // Initial cache lookup for whatever's displayed.
            refreshPillArtworkImage()
        }
        .onChange(of: displayedNowPlaying) { _ in
            // Refresh the cached NSImage every time the displayed
            // track changes. Cache hit (already-decoded) returns
            // synchronously and lands in `pillArtworkImage` this
            // render — zero perceived load. Cache miss kicks off a
            // background decode; when it completes, the closure
            // updates `pillArtworkImage` and SwiftUI re-renders
            // with the new image. Either path keeps decode off
            // the main thread.
            refreshPillArtworkImage()
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
                // Sync displayed state to current if the track
                // changed while the slab was open. Comparing keys
                // avoids redundant work when nothing changed.
                let curKey = presenter.nowPlaying.map { "\($0.title)|\($0.artist)" } ?? ""
                if curKey != displayedTrackKey, let cur = presenter.nowPlaying {
                    displayedNowPlaying = cur
                    displayedTrackKey = curKey
                }
            }
            // ALWAYS refresh the pill artwork on open/close —
            // even if displayedTrackKey didn't change here. Why:
            //
            // When the user changes track from inside the slab,
            // Branch 4 of `.onChange(of: presenter.nowPlaying)`
            // takes the `isShown` early-return path and updates
            // displayedTrackKey + displayedNowPlaying to the new
            // track. If Spotify emits in two stages (track meta
            // first, artwork bytes second) AND the slab closes
            // BEFORE the artwork emission lands (or the second
            // emission is dropped by the source app — some
            // versions of Spotify only emit once), pillArtworkImage
            // stays at the nil it was set to during the first
            // emission's refresh call. The pill becomes visible
            // showing the music-note placeholder for the new track.
            //
            // Calling refreshPillArtworkImage() unconditionally
            // here recovers from that race: by the time the slab
            // closes, the source app has typically settled and
            // the artwork bytes are in `presenter.nowPlaying`.
            // refreshPillArtworkImage's "preserve on diff" logic
            // (see its body) handles the still-loading case
            // correctly — preserves existing image when key
            // matches, clears only when key truly differs.
            //
            // The earlier "comparing track keys means same-track
            // refreshes don't trip this handler" rationale was
            // wrong on a key edge: when track change + artwork-
            // load race overlap with slab-close, the pill needs
            // a defensive refresh.
            refreshPillArtworkImage()
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
            // Branch 3: music ended (or transient nil during a pause)
            if newInfo == nil {
                // 2026-05-01 sticky-on-resting fix. When the user
                // pauses YouTube and MediaRemote subsequently goes
                // silent (or emits an explicit nil), we don't want
                // to blank the pill's artwork while the pill is
                // STILL VISIBLE — it makes the thumbnail vanish for
                // the duration of the post-audio grace window. Keep
                // the last-good displayedNowPlaying as long as the
                // pill is in resting mode; the thumbnail and title
                // stay correct, the play/pause icon flips via
                // `isAudioFlowing`, and when the user resumes audio
                // the same-track emission lands in Branch 1
                // (smooth refresh, no animation).
                //
                // We only run the music-ended fade animation when
                // the pill is NOT resting — i.e. the pill is
                // actually retracting (or already retracted) and
                // the artwork-fade is the visual companion to that.
                if presenter.isResting {
                    return
                }
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
                // 2026-05-01: explicit defensive refresh of the
                // small-pill artwork. When the user changes track
                // from inside the slab (transport buttons or skip
                // gesture), `.onChange(of: displayedNowPlaying)`
                // doesn't always re-fire reliably from inside this
                // reentrant `.onChange(of: presenter.nowPlaying)`
                // handler. Without this, the pill that was hidden
                // behind the open slab keeps showing the previous
                // track's thumbnail; when the user closes the slab
                // they see stale artwork.
                refreshPillArtworkImage()
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
        // center"), 18pt (still felt off), and now 14pt (settles
        // with the new inverse-bow silhouette).
        //
        // Padding tuning history (with the inverse-bow silhouette
        // — panelTopRadius=6 for the resting pill eats 6pt off
        // each side of the rect):
        //   8pt:  artwork sat 2pt inside the body edge, visually
        //         "falling off" — user: "thumbnail is too at edge"
        //   14pt: pulled too far inward — user: "now it's too right"
        //   10pt: current — 6pt shoulder reserve + 4pt visual gap.
        //         Artwork hugs the body edge with just enough
        //         breathing room to not read as "clipped."
        .padding(.horizontal, 10)
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
        let fadeOut: TimeInterval = 0.22
        let fadeIn: TimeInterval = 0.42
        // 2026-05-01 anime.js-inspired refinement: swap point pulled
        // 40ms before fadeOut completes so the new artwork enters
        // while the old one is still mid-exit. The cross-over
        // dissolves the seam — eye reads it as one continuous
        // motion, the way anime.js stages overlapping in/out tweens
        // on the same element. Spring on the in-side picks up from
        // wherever phase landed (~-0.82, not full -1), so it
        // immediately surges back instead of starting from a dead
        // stop at full-exit.
        let swapPoint: TimeInterval = fadeOut - 0.04

        // Generation token: each invocation captures `gen` into its
        // dispatched closures, then bails on entry if the field has
        // moved on (a newer skip arrived). Prevents stale closures
        // from a prior A→B swap from clobbering the displayed state
        // mid-flight in a rapid A→B→C→D scrub. `&+=` so we don't
        // crash on Int overflow over a multi-decade session.
        trackSwapGeneration &+= 1
        let gen = trackSwapGeneration
        hasEverDisplayedTrack = true

        // Phase 1: anime.js-flavored ease-in-out cubic-bezier.
        // (0.4, 0, 0.2, 1) is the same shape anime.js calls
        // "easeInOutQuart" — slow start, accelerated middle, soft
        // landing. Replaces SwiftUI's generic `.smooth`, which has
        // a flatter middle that makes the artwork seem to drift out
        // rather than commit to leaving.
        withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: fadeOut)) {
            trackSwapPhase = -1
        }
        // Phase 2: swap data and animate back to rest from the
        // CURRENT phase (no opposite-side snap). The previous code
        // teleported from phase=-1 to phase=+1 before springing to
        // 0, which read as a visible "jump" — exactly what the user
        // reported on next-click. Now the new artwork tilts back
        // from the SAME side the old one left, one continuous
        // motion. Less dramatic visually but smoother.
        DispatchQueue.main.asyncAfter(deadline: .now() + swapPoint) {
            guard gen == trackSwapGeneration else { return }
            displayedNowPlaying = presenter.nowPlaying
            displayedTrackKey = newKey
            // anime.js's signature elastic settle: the new artwork
            // surges back with a subtle 6-7% overshoot, then double-
            // bounces into rest. response=0.55 stretches the bounce
            // period long enough that the eye reads it as ELASTIC
            // (not a snap), dampingFraction=0.66 leaves visible
            // amplitude on the secondary oscillation (~0.7%) before
            // settling. Matches the character of anime.js's
            // `spring(1, 100, 10, 0)` — playful but composed.
            withAnimation(.spring(response: 0.55, dampingFraction: 0.66)) {
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
    /// The cache key associated with the currently-displayed
    /// `pillArtworkImage`. Tracked separately so we can detect
    /// "image is for a stale track" vs. "image is for the right
    /// track but data not yet loaded" — the two cases behave
    /// differently in `refreshPillArtworkImage`.
    @State private var pillArtworkImageKey: String = ""

    /// Refresh the resting-pill's decoded NSImage from `ArtworkCache`.
    /// Synchronous cache hit lands the image in `pillArtworkImage`
    /// this render; a miss decodes the JPEG on the main thread
    /// (~30-50ms) and stores the result for subsequent renders.
    ///
    /// The displayed track key is used as the cache key, so going
    /// BACK to a recently-played track returns the prior NSImage
    /// instantly — no re-decode, no flash, no main-thread block.

    private func refreshPillArtworkImage() {
        guard let info = displayedNowPlaying else {
            MediaRemoteAdapterService.fileLog("PILL refresh: displayedNowPlaying=nil → clearing pillArtworkImage")
            pillArtworkImage = nil
            pillArtworkImageKey = ""
            return
        }
        let key = "\(info.title)|\(info.artist)"
        let bytes = info.artworkData?.count ?? 0
        let newImage = ArtworkCache.shared.image(data: info.artworkData, key: key)
        MediaRemoteAdapterService.fileLog("PILL refresh: title=\"\(info.title)\" artist=\"\(info.artist)\" bytes=\(bytes) decoded=\(newImage != nil)")

        if let newImage = newImage {
            pillArtworkImage = newImage
            pillArtworkImageKey = key
            return
        }

        // No image returned (data was nil OR decode failed). Two
        // sub-cases that need different handling:
        //
        // a) The track CHANGED (key != pillArtworkImageKey): the
        //    previous image belongs to a DIFFERENT song. Keeping it
        //    on screen would show wrong artwork for the wrong track
        //    — clear to placeholder until the right artwork loads.
        //
        // b) The track is the SAME (key == pillArtworkImageKey): the
        //    new info is just a metadata refresh that happens to lack
        //    artwork (Spotify's two-stage emission, or a play/pause
        //    update). The previous image IS for this track — KEEP it
        //    on screen to avoid the "image disappears for 1-2s while
        //    waiting for re-fetch" flash. iTunes Search / cache will
        //    populate later and a subsequent refreshPillArtworkImage
        //    call will swap to the freshly-decoded image.
        //
        // This is the same "preserve on diff" pattern boring.notch
        // (TheBoredTeam/boring.notch) uses in NowPlayingController:
        // they preserve previous artwork on partial updates, only
        // clearing on a true full-update with explicit nil.
        if key != pillArtworkImageKey {
            pillArtworkImage = nil
            pillArtworkImageKey = key
        }
        // else: same track, no new image — keep existing
        // pillArtworkImage on screen. Don't update pillArtworkImageKey.
    }

    /// 2026-05-01: REVERTED PillFlipArtworkView experiment.
    /// Multiple integration issues with the parent's state-update
    /// timing. Back to the ORIGINAL SwiftUI version that was
    /// working before any of today's flip experiments.
    private var pillArtwork: some View {
        Group {
            if let img = pillArtworkImage {
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
        // anime.js-inspired refinement (2026-05-01): the 22pt artwork
        // is too small for noisy rotation+big offset to read as
        // anything other than chaos. Stripped down to scale + opacity
        // + soft blur, with a tiny lift, all driven by a phase scalar
        // that animates with a custom timing curve out and an elastic
        // spring back. Reads as a clean iris that the new artwork
        // pops back into with a delicate bounce — anime.js's "small
        // moves, exquisitely tuned" aesthetic, not the previous
        // flip-card spectacle.
        .offset(y: trackSwapPhase * 3)
        .blur(radius: abs(trackSwapPhase) * 5)
        .opacity(1 - abs(trackSwapPhase))
        .scaleEffect(1.0 - abs(trackSwapPhase) * 0.22)
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

    /// Drop-target indicator. While a drag is hovering over the
    /// panel (`isDropTargeted == true`), three layered effects
    /// make the silhouette feel ALIVE rather than just colored:
    ///
    /// 1. **Outer halo** — a thick blurred stroke at low opacity,
    ///    breathing slowly (1.6s sine) between 0.25 and 0.55
    ///    opacity. Reads as "the panel is glowing toward you."
    ///
    /// 2. **Mid ring** — the existing 1.5pt accent stroke, also
    ///    breathing but at a higher opacity range and a slightly
    ///    different phase so the two layers don't pulse in
    ///    lockstep (looks more organic).
    ///
    /// 3. **Inner highlight** — a thin bright stroke at the very
    ///    edge of the silhouette, opacity tied to the same sine
    ///    so the whole composite reads as one rhythm with depth.
    ///
    /// All three layers fade in with the existing
    /// `.animation(.easeInOut(0.12), value: isDropTargeted)` on
    /// the parent stack, so the entrance/exit animation is
    /// preserved. The TimelineView-driven breath is independent
    /// — runs continuously while the drag is hovering.
    /// Drop-target indicator — DISABLED.
    ///
    /// Earlier iterations stroked the panel silhouette with the
    /// brand accent (which renders as a cyan-blue) during a drag.
    /// Combined with the macOS native drag-accept cursor badge
    /// (the green +) the composite read as a clashy greenish glow
    /// that destroyed the premium feel. The user explicitly asked
    /// to remove it.
    ///
    /// The macOS cursor badge alone signals "drop will be
    /// accepted," and the slab auto-expanding to Files tab on
    /// drag-enter (via `onTargeted` in the controller) is the
    /// affordance for "this is your destination" — those two
    /// signals together are enough.
    @ViewBuilder
    private var dropRingOverlay: some View {
        EmptyView()
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
    private var panelSilhouette: OutwardFlaredShape {
        // Notch-hardware silhouette for BOTH resting pill AND the
        // expanded slab. 12pt outward flare at the top corners
        // (gentle S-curve as the slab widens out from the notch
        // hardware) + larger inward rounded curve at the bottom
        // that interpolates between `pillCornerRadius` (resting)
        // and `innerCornerRadius` (slab) via `panelBottomRadius`.
        // Same shape language across both states — pill→slab
        // morph becomes a continuous radius interpolation, no
        // shape-type switch mid-animation.
        //
        // Top-flare value history:
        //   2pt  — original. So subtle it was effectively a
        //          sharp 90° top corner.
        //   12pt — tried per NotchNook frame audit. Read as
        //          two visible "frog eye" bumps at the top
        //          corners on our narrower/shorter silhouette.
        //          User: "What's those on the top? Is it a
        //          frog." Their flare looks subtle because their
        //          slab is wider/taller and the same arc radius
        //          covers a smaller proportion of the corner.
        //   4pt  — current. Softens the otherwise sharp 90°
        //          corner without creating visible shoulder
        //          bumps. Sub-perceptual at our scale (~ 8px
        //          at Retina 2x) but enough to take the hard
        //          edge off where the slab meets the menu bar.
        //
        // If we ever bump panelWidth to 900+pt and the slab
        // proportions match NotchNook's, the 12pt flare can be
        // revisited.
        //
        // CRITICAL: returns the CONCRETE `OutwardFlaredShape` type,
        // NOT `AnyShape`. AnyShape is a type eraser that strips
        // the underlying shape's `animatableData` from SwiftUI's
        // animation system — wrapping in AnyShape made every
        // panelBottomRadius change SNAP to the new value (no
        // interpolation) because SwiftUI saw two type-erased
        // shape values with no shared animation path. That was
        // the root cause of the "glitch at the bottom" the user
        // kept reporting on open: the bottom corners popped
        // wider in one frame as soon as `presenter.isShown`
        // flipped, BEFORE the spring even started growing the
        // panel. Returning the concrete type lets SwiftUI's
        // `.animation(value:)` machinery interpolate
        // `bottomCornerRadius` smoothly via OutwardFlaredShape's
        // `animatableData: AnimatablePair<CGFloat, CGFloat>`
        // override.
        return OutwardFlaredShape(
            topFlareRadius: panelTopRadius,
            bottomCornerRadius: panelBottomRadius
        )
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: DS.Spacing.sm) {
            // 2026-05-02 brand glyph. Replaces the generic
            // `square.and.pencil` SF Symbol with the nox ring-with-
            // notch brand mark — same silhouette as the app icon,
            // just compact and untinted (the glyph itself uses
            // brandLavender; the wordmark beside it uses textPrimary).
            NoxGlyph(size: 14, lineWidth: 1.4)

            Text("nox")
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

    /// Dock tab bar — per-icon rounded-square buttons inside a
    /// rounded pill. 2026-04-29 redesign per user reference shot:
    /// each tab is its OWN rounded-square button (12pt radius)
    /// with a top-to-bottom dark gradient, hairline white ring,
    /// and a soft drop shadow. Hover lifts the button -2pt and
    /// scales 1.05× — same micro-affordance the macOS Tahoe Dock
    /// and the reference Tailwind code use.
    ///
    /// Outer pill stays as a frosted Capsule so the bar still
    /// reads as a single unit; spacing between icons bumps up to
    /// 8pt so each square reads as a discrete affordance rather
    /// than a row of cells in a single segmented control. The
    /// matchedGeometryEffect "sliding active disc" is gone —
    /// with per-icon backgrounds, the active tab is signaled by
    /// a brighter gradient + opaque glyph instead.
    private var segmented: some View {
        HStack(spacing: 8) {
            ForEach(presenter.visibleTabs) { tab in
                DockTabButton(
                    tab: tab,
                    isSelected: presenter.activeTab == tab
                ) {
                    // No haptic on tab switch. Earlier we fired
                    // `HapticFeedback.generic()` on every change so
                    // the click felt tactile, but the user reported
                    // it reads as a stutter / double-click — the
                    // brief vibration registers as a second input.
                    // The visual selection animation alone is the
                    // confirmation; haptic stays reserved for
                    // genuinely physical events (charging, BT
                    // connect, screenshot save, etc).
                    withAnimation(.selection) { presenter.activeTab = tab }
                }
            }
        }
        .compositingGroup()
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            // Layered frosted pill. Same material as before but
            // with slightly bumped padding so the per-icon
            // squares have room to breathe inside it.
            ZStack {
                VisualEffectBlur(material: .hudWindow, blendingMode: .withinWindow)
                Color.black.opacity(0.30)
            }
            .clipShape(Capsule(style: .continuous))
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
        )
        // Soft halo for the dock pill — 14pt radius at 28%
        // opacity reads as ambient depth, not a defined edge
        // ring. The previous 6pt was too sharp (visible "ghost"
        // outline) and 12pt was too expensive on hover-lift
        // frames. 14pt + lower opacity is the sweet spot —
        // diffuse falloff, no visible boundary, half the
        // gaussian cost of the original 12pt × 0.5 opacity.
        .shadow(color: Color.black.opacity(0.28), radius: 14, x: 0, y: 6)
        .animation(.selection, value: presenter.visibleTabs)
    }

    // MARK: - Divider & content

    private var divider: some View {
        Rectangle()
            .fill(DS.Color.divider)
            .frame(height: 1)
    }

    @ViewBuilder
    private var content: some View {
        // LAZY tab mount via switch. Earlier I tried always-
        // mounting all 5 tabs in a ZStack to eliminate
        // first-paint-during-morph glitches — but that caused
        // a noticeable FPS drop on the open animation: SwiftUI
        // re-evaluates every mounted view's body on observable
        // state changes, and with 5 always-resident views (each
        // with LazyVStack/LazyVGrid + observed stores) running
        // alongside the 120Hz spring's frame ticks, body eval
        // and layout passes piled up enough to drop frames
        // during the morph.
        //
        // Reverted to the switch statement (lazy mount). Only
        // the active tab is in the SwiftUI tree at a time. The
        // other four don't pay any per-frame cost. The
        // first-paint glitch we tried to fix should be
        // mitigated by the OTHER recent changes — concrete
        // `OutwardFlaredShape` (no AnyShape erasure on the
        // bottom corner), `withAnimation` on `isShown` toggles,
        // `isMorphing` wired into `handleActiveTabChange`, and
        // the spring's sub-pixel render guard — without
        // burning CPU on 5 always-mounted view bodies.
        //
        // No `.opacity(isMorphing ? 0 : 1)` fade-in (the
        // workaround the user explicitly didn't want). Content
        // appears at full opacity the moment the active tab's
        // body materializes.
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

    /// Single source of truth for the panel's inner content layout.
    /// Extracted so it can be referenced both by the live render
    /// (in `contentOverlay`) AND by `ImageRenderer` when capturing
    /// the snapshot for the motion-blur overlay. Both paths render
    /// the exact same view tree at the same dimensions, so the
    /// blurred ghost aligns 1:1 with the live content underneath.
    private var renderableContent: some View {
        VStack(spacing: 0) {
            header
            segmented
                .padding(.horizontal, DS.Spacing.md)
            divider
                .padding(.top, DS.Spacing.sm)
            content
        }
    }

    // (Motion-blur snapshot lifecycle now in PanelWindowController.
    // It captures the settled panel.contentView via cacheDisplay
    // after each animateOpen completes, applies CIMotionBlur, and
    // stores on presenter.motionBlurImage for the next open's
    // overlay.)
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
/// Single rounded-square dock button. Per-icon hover state lets
/// each button independently lift + scale on cursor entry without
/// affecting its neighbours — the macOS Tahoe Dock affordance.
/// Spec mirrors the user's Tailwind reference (2026-04-29):
///   • 32×32 frame, 10pt corner radius
///   • Top-to-bottom subtle white-opacity gradient (active brighter)
///   • 0.5pt white-10% ring
///   • Soft drop shadow (always-on for depth)
///   • Hover: -2pt y-offset + 1.05 scale, 0.18s spring
///   • Active: brighter gradient + bolder glyph weight
private struct DockTabButton: View {
    let tab: PanelTab
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered: Bool = false

    var body: some View {
        Button(action: action) {
            Image(systemName: tab.icon)
                .font(.system(size: 14, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(
                    isSelected
                        ? Color.white.opacity(0.95)
                        : Color.white.opacity(0.65)
                )
                .frame(width: 34, height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(isSelected ? 0.16 : 0.08),
                                    Color.white.opacity(isSelected ? 0.08 : 0.03)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(
                            Color.white.opacity(isSelected ? 0.18 : 0.10),
                            lineWidth: 0.5
                        )
                )
                // Hover-reveal label — floats ABOVE the icon as a
                // small frosted capsule when the cursor is over it,
                // disappears when the cursor leaves. Matches the
                // macOS Dock's tooltip behavior. Less visual clutter
                // than persistent labels under each icon, but still
                // discoverable. Active tab is identified by the
                // brighter gradient + bolder glyph weight.
                .overlay(alignment: .top) {
                    if isHovered {
                        Text(tab.title)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.white.opacity(0.95))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                ZStack {
                                    VisualEffectBlur(material: .hudWindow, blendingMode: .withinWindow)
                                    Color.black.opacity(0.55)
                                }
                                .clipShape(Capsule(style: .continuous))
                            )
                            .overlay(
                                Capsule(style: .continuous)
                                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
                            )
                            .fixedSize()
                            .offset(y: -34)
                            .transition(.asymmetric(
                                insertion: .opacity.combined(with: .offset(y: 4)),
                                removal: .opacity
                            ))
                            .allowsHitTesting(false)
                    }
                }
                .scaleEffect(isHovered ? 1.05 : 1.0)
                .offset(y: isHovered ? -2 : 0)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tab.title)
        .help(tab.title)
        .onHover { hovering in
            // Lighter spring (response 0.18, damping 0.85) — no
            // overshoot, settles in ~120ms instead of 220ms. Hover
            // is a high-frequency gesture; cutting the per-tick
            // animation duration nearly halves the time the
            // animation system is interpolating geometry per
            // frame.
            withAnimation(.spring(response: 0.18, dampingFraction: 0.85)) {
                isHovered = hovering
            }
        }
    }
}

/// REMOVED 2026-05-01 — see git history for the experimental
/// two-image card-flip implementation. Reverted to the original
/// single-image SwiftUI artwork in `PanelRootView.pillArtwork`.
/// To revisit: the timing race between `pillArtworkImage` and
/// `displayedTrackKey` updates needs to be solved at the parent
/// level (atomic dual-update) before a sub-view can rely on
/// either one for change detection.
private struct _RemovedPillFlipArtworkView_DoNotUse: View {
    let image: NSImage?
    let trackKey: String

    @State private var displayedImage: NSImage? = nil
    @State private var displayedKey: String = ""
    @State private var nextImage: NSImage? = nil
    @State private var rotation: Double = 0
    @State private var isFlipping: Bool = false

    private var cosRotation: Double {
        cos(rotation * .pi / 180)
    }

    var body: some View {
        ZStack {
            artworkTile(image: displayedImage)
                .rotation3DEffect(
                    .degrees(rotation),
                    axis: (x: 0, y: 1, z: 0),
                    anchor: .center,
                    anchorZ: 0,
                    perspective: 0.6
                )
                .opacity(cosRotation >= 0 ? 1 : 0)

            artworkTile(image: nextImage)
                .rotation3DEffect(
                    .degrees(rotation - 180),
                    axis: (x: 0, y: 1, z: 0),
                    anchor: .center,
                    anchorZ: 0,
                    perspective: 0.6
                )
                .opacity(cosRotation < 0 ? 1 : 0)
        }
        .onAppear {
            // Initial mount: take the current image silently. We
            // also seed displayedKey so the first onChange of a
            // genuinely new track fires the flip (rather than
            // misfiring on first mount).
            if displayedImage == nil {
                displayedImage = image
                displayedKey = trackKey
            }
        }
        // 2026-05-01 v2: drive change detection off the String
        // trackKey, NOT the NSImage reference. SwiftUI's onChange
        // requires Equatable; NSImage's Equatable conformance via
        // NSObject isEqual is unreliable across SwiftUI's diff
        // (same content + new instance can compare unequal, and
        // ArtworkCache returns the same instance for the same key
        // so the SwiftUI diff sometimes thinks no change happened
        // even when it did). String is rock-solid Equatable —
        // when title|artist genuinely changes, this fires.
        .onChange(of: trackKey) { newKey in
            // Skip if it's the same key (defensive — onChange should
            // already filter this but be explicit).
            if newKey == displayedKey { return }
            // Skip the very first transition from "" → real key —
            // that's a fresh mount, not a track change. Same logic
            // as the artist-empty filter for the bloom: we only
            // animate when there was previously a real track and
            // now there's a different real track.
            if displayedKey.isEmpty {
                displayedImage = image
                displayedKey = newKey
                return
            }
            // Genuine track change → flip. Capture the new image
            // (which might still be nil on first publish if artwork
            // loads async — that's OK, the flip animates to a
            // placeholder back face, and a subsequent image update
            // will fill it in via onChange-of-image below).
            triggerFlip(toImage: image, newKey: newKey)
        }
        .onChange(of: image) { newImage in
            // Three cases:
            //   a) In-flight flip: update nextImage (back face).
            //   b) Same track (trackKey unchanged): silent direct
            //      update of displayedImage. This is the
            //      "artwork loaded async after title" case for
            //      Spotify's two-stage emission.
            //   c) Track is mid-change (trackKey != displayedKey):
            //      DO NOTHING. The trackKey onChange handler will
            //      fire shortly and trigger the flip, capturing
            //      this new image as the back face. If we silently
            //      updated displayedImage now, the flip would
            //      have the same image on both faces — no visible
            //      animation. This was the bug the user reported:
            //      "still using same photo for rotation."
            if isFlipping {
                nextImage = newImage
                return
            }
            if trackKey == displayedKey {
                // Same track — silent direct update.
                displayedImage = newImage
            }
            // else: track is changing, let onChange(of: trackKey)
            //       handle it. Don't touch displayedImage here.
        }
    }

    @ViewBuilder
    private func artworkTile(image: NSImage?) -> some View {
        Group {
            if let img = image {
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
    }

    private func triggerFlip(toImage newImage: NSImage?, newKey: String) {
        isFlipping = true
        nextImage = newImage
        let duration: TimeInterval = 0.45
        withAnimation(.smooth(duration: duration)) {
            rotation = 180
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.02) {
            displayedImage = nextImage
            displayedKey = newKey
            nextImage = nil
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) {
                rotation = 0
            }
            isFlipping = false
        }
    }
}

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
            // Per "the pill is not moving like apple" feedback —
            // the previous incarnation dropped scale entirely and
            // relied on glow alone, so the silhouette never read
            // as physically responding to the event. Dynamic
            // Island's tell IS the silhouette growing. Re-added
            // scale anchored at .top so the top edge stays welded
            // to the notch hardware while the bottom + sides
            // extend outward like a breath. With haloPadding=100pt
            // the panel window has plenty of room for the
            // silhouette to grow ~5% without clipping.
            //
            // Magnitude tuning:
            //   • 1.045 peak — readable as physical growth at a
            //     220pt-wide pill (~10pt outward total) without
            //     reading as goofy or jumping at the user.
            //   • Anchor .top — the silhouette's top edge is the
            //     "connection" to the notch hardware. Anchoring
            //     there means width scaling pushes equally to
            //     both sides while height scaling extends only
            //     downward. The notch handoff stays clean.
            .scaleEffect(1 + react * 0.045, anchor: .top)
            // Tinted glow that ramps with the puff. Radius scales
            // with `react` so the glow only paints during the puff
            // — zero cost when settled. Pairs with the scale to
            // give the puff a soft chromatic halo as it grows.
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
            .animation(.bouncy(duration: 0.32, extraBounce: 0.15),
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
        .padding(.horizontal, 10)
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

    /// Pill entrance transition — bouncy pop from 0.6× scale +
    /// alpha. Anchored at `.top` (NOT `.center`) because the
    /// silhouette's TOP edge is hidden behind the notch hardware
    /// and ABOVE the menu bar where overshoot is invisible. With
    /// the previous `.center` anchor, the bouncy spring's overshoot
    /// (extra ~4% during the bounce peak) was scaling the
    /// silhouette in BOTH directions — and with `closedPillBump = 0`
    /// the silhouette ends exactly at the menu-bar edge, so the
    /// downward portion of the overshoot pushed ~1pt of dark
    /// silhouette BELOW the menu bar for a frame or two before
    /// settling. That was the "glitch on top" the user reported.
    /// `.top` anchor keeps the scale pivot at the hidden top edge
    /// so all overshoot grows DOWNWARD from there — bottom moves
    /// from 60% of height to 100%, and the overshoot to ~104%
    /// stays inside the visible silhouette envelope rather than
    /// sticking out.
    static var pillEnter: AnyTransition {
        // 2026-05-04 (rev 2): scale 0.65 starting, anchor .center.
        // Earlier 0.78 was so close to 1.0 the entrance was just a
        // fade with imperceptible scale change — the user reported
        // "no animation at the endpoints." 0.65 gives a CLEAR
        // "popping in from a tiny version" motion that lands at 1.0
        // visibly. The .center anchor keeps the pivot inside the
        // silhouette so any spring overshoot stays inside the
        // visible envelope (anchor .top would put the pivot ABOVE
        // the menu bar, which sounds right but breaks anchoring on
        // the visible content's geometry).
        .scale(scale: 0.65, anchor: .center).combined(with: .opacity)
    }

    /// Pill exit transition. Scales DOWN + fades. The scale delta
    /// is INTENTIONALLY larger than the entrance so the exit reads
    /// as "the pill retreats" rather than "the pill fades" — a
    /// 1.0→0.7 scale path has 2× the visible motion of a 1.0→0.85
    /// path, and the longer the visible motion, the more the eye
    /// reads it as a deliberate animation instead of an abrupt cut.
    static var pillExit: AnyTransition {
        .scale(scale: 0.7, anchor: .center).combined(with: .opacity)
    }

    /// Convenience: the asymmetric pair as a single transition.
    static var pillPop: AnyTransition {
        .asymmetric(insertion: .pillEnter, removal: .pillExit)
    }
}

// MARK: - Panel silhouette shape (inverse-bow top, rounded bottom)
//
// The S-CURVE technique (per boring.notch / Atoll / DynamicNotchKit
// / DynamicNotch — all share MrKai77's reference implementation):
// at each TOP corner, draw an `addQuadCurve` whose CONTROL POINT
// sits at the rect's outer corner. Because the control is outside
// the eventual filled region, the curve bows INWARD into the
// silhouette, creating the concave-outward "shoulder" curve where
// the slab tucks under the menu bar.
//
// Bottom corners stay as standard convex rounded corners (a single
// quarter-arc), NOT another inverse-bow. The previous flare design
// double-inset the silhouette (top→body via topR, then body→bottom
// via bottomR), creating the visible "S-bump" / fish-tail effect
// the user reported as "we are having s bump." With normal rounded
// bottoms there's exactly one inset at the bottom — same as any
// standard rounded rectangle, no extra vertex, no visible bump.
//
// Geometry:
//   Top edge:    full rect width (minX → maxX)
//   Top corners: inverse-bow quad curve over `topR` height/width.
//                Tangent is HORIZONTAL at start (parallel to menu
//                bar) and VERTICAL at end (parallel to body side).
//   Body sides:  vertical at x = topR (inset by topR from rect)
//   Bottom corners: standard convex rounded corners, radius bottomR
//   Bottom edge: width = rect.width - 2*topR - 2*bottomR
//
// History:
//   v1: Symmetric rounded rectangle. No notch character.
//   v2: "Outward flare" via quarter-arcs at top + inset bottom
//       edge. Created S-BUMPS — two tapers stacked, visible
//       vertex at body→bottom transition. ("frog face")
//   v3: Plain rounded rect, square top. Lost the S-curve.
//   v4 (current): Inverse-bow quad curves at top, normal
//       rounded corners at bottom. Per `boring.notch`'s
//       NotchShape.swift L36-L119. Smooth shoulder curve at
//       top with no body-to-bottom vertex.
//
// Type name kept as `OutwardFlaredShape` for compat with the
// rest of the codebase. The `animatableData: AnimatablePair`
// interpolates BOTH `topFlareRadius` and `bottomCornerRadius`
// during the pill→slab morph, so the shoulder curve scales
// smoothly alongside the bottom radius animation.

private struct OutwardFlaredShape: Shape {
    /// Inverse-bow shoulder radius at the top corners. Drives the
    /// extent of the concave-outward dip where the slab edge
    /// "tucks under" the menu bar. Pill ~6pt, slab ~22pt — small
    /// values read as a chamfer; larger values read as a
    /// pronounced shoulder.
    var topFlareRadius: CGFloat
    /// Convex rounded-corner radius at the bottom. Pill ~8pt,
    /// slab ~34pt.
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
        // Clamp radii so they always fit inside `rect`.
        let topR = max(0, min(topFlareRadius, rect.height / 2, rect.width / 2))
        let bottomR = max(0, min(bottomCornerRadius,
                                 rect.height - topR,
                                 max(0, rect.width / 2 - topR)))
        let leftX = rect.minX
        let rightX = rect.maxX
        let topY = rect.minY
        let bottomY = rect.maxY
        let bodyLeftX = leftX + topR
        let bodyRightX = rightX - topR

        // Move to top-left corner of rect (full panel width).
        path.move(to: CGPoint(x: leftX, y: topY))

        // TOP-LEFT inverse-bow shoulder.
        // Control point at (bodyLeftX, topY) — sits ON the top
        // edge, INSIDE the rect's bounds but OUTSIDE the eventual
        // filled region. Pulls the quadratic Bezier inward into
        // the silhouette → concave-outward "shoulder" curve.
        // Reference: boring.notch NotchShape.swift L48-L51.
        path.addQuadCurve(
            to: CGPoint(x: bodyLeftX, y: topY + topR),
            control: CGPoint(x: bodyLeftX, y: topY)
        )

        // Left body side — straight vertical down to where the
        // bottom-left rounded corner starts.
        path.addLine(to: CGPoint(x: bodyLeftX, y: bottomY - bottomR))

        // BOTTOM-LEFT convex rounded corner.
        path.addArc(
            center: CGPoint(x: bodyLeftX + bottomR, y: bottomY - bottomR),
            radius: bottomR,
            startAngle: .degrees(180),
            endAngle: .degrees(90),
            clockwise: true
        )

        // Bottom edge between the two rounded corners.
        path.addLine(to: CGPoint(x: bodyRightX - bottomR, y: bottomY))

        // BOTTOM-RIGHT convex rounded corner.
        path.addArc(
            center: CGPoint(x: bodyRightX - bottomR, y: bottomY - bottomR),
            radius: bottomR,
            startAngle: .degrees(90),
            endAngle: .degrees(0),
            clockwise: true
        )

        // Right body side — straight vertical up to where the
        // top-right inverse-bow starts.
        path.addLine(to: CGPoint(x: bodyRightX, y: topY + topR))

        // TOP-RIGHT inverse-bow shoulder (mirror of top-left).
        path.addQuadCurve(
            to: CGPoint(x: rightX, y: topY),
            control: CGPoint(x: bodyRightX, y: topY)
        )

        // Close back along the top edge to the starting point.
        path.closeSubpath()
        return path
    }
}

// MARK: - Bluetooth pill body (ping ripple on connect, contracting on disconnect)

/// Standalone pill content for `.bluetoothConnected` / `.bluetoothDisconnected`.
///
/// On CONNECT: a single ping ripple emanates from the icon — a Circle
/// behind the tile that scales 1.0 → 2.6× over 700ms while fading
/// from 0.5 opacity to 0. Reads as the pairing handshake actually
/// completing — same visual vocabulary AirPods use on iOS when
/// they latch.
///
/// On DISCONNECT: the opposite — a contracting ring that starts at
/// 2.4× and pulls back to 1.0×, fading from 0.45 to 0. "The thing
/// just walked away."
///
/// Tile + label content matches the previous static pill so the
/// horizontal layout stays consistent across the family.
private struct BluetoothPillBody: View {
    let name: String
    let iconName: String
    let isConnected: Bool
    let notchOverlap: CGFloat
    let visible: Bool

    /// Driven by onAppear. For connect it goes 0 → 1 (ring expands);
    /// for disconnect it goes 0 → 1 (ring contracts). Read by the
    /// scale + opacity computed properties below to map onto the
    /// actual visual values.
    @State private var rippleProgress: Double = 0
    /// Tile-content scale on entrance — 0.7 → 1.0 spring so the
    /// glyph "lands" rather than fades.
    @State private var iconScale: Double = 0.7

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                // Ripple ring behind the tile. Pinned to the tile
                // size, scaled from there. Drawn first so the
                // tile's solid fill paints over the ripple's center
                // — only the ring outside the tile is visible.
                Circle()
                    .stroke(
                        (isConnected
                         ? Color(red: 0.45, green: 0.65, blue: 1.0)
                         : Color(white: 0.7)),
                        lineWidth: 1.5
                    )
                    .frame(width: 22, height: 22)
                    .scaleEffect(rippleScale)
                    .opacity(rippleOpacity)
                    .allowsHitTesting(false)

                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(
                        (isConnected
                         ? Color(red: 0.45, green: 0.65, blue: 1.0)
                         : Color(white: 0.55))
                            .opacity(0.9)
                    )
                Image(systemName: iconName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .scaleEffect(iconScale)
            }
            .frame(width: 22, height: 22)
            // Tile clips, but the ripple is drawn outside the
            // RoundedRectangle's shape inside the same ZStack —
            // we DON'T clip the ZStack so the ripple can extend.
            // (The tile clip happens via the RoundedRectangle
            // fill itself defining the visible bounds.)

            // Spacer spans the notch-hardware area (~185pt of the
            // 278pt pill). Anything rendered here is hidden by the
            // physical notch cutout — we keep the middle empty.
            Spacer(minLength: 0)

            // RIGHT-WING badge — lives past the notch hardware in the
            // ~46pt right-wing zone where pixels actually paint. Tiny
            // status dot (filled blue for connected, hollow gray for
            // disconnected) so the user can read state at a glance
            // even if they missed the ripple's expand/contract
            // direction. Keeps the pill information-dense without
            // fighting the notch.
            Image(systemName: isConnected ? "circle.fill" : "circle")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(
                    isConnected
                    ? Color(red: 0.45, green: 0.65, blue: 1.0)
                    : Color.white.opacity(0.55)
                )
                .padding(.trailing, 2)
        }
        .padding(.horizontal, 10)
        .frame(height: notchOverlap)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .opacity(visible ? 1 : 0)
        .onAppear {
            withAnimation(.spring(response: 0.36, dampingFraction: 0.65)) {
                iconScale = 1.0
            }
            // Ripple curve: ease-out so the ring leaves quickly,
            // then dwells at the outer edge before fading out.
            withAnimation(.easeOut(duration: 0.7)) {
                rippleProgress = 1.0
            }
        }
    }

    /// Connect: ring scales OUT (1 → 2.6×). Disconnect: ring
    /// scales IN (2.4 → 1.0×). Different start values give the
    /// two events distinct visual personalities.
    private var rippleScale: Double {
        if isConnected {
            return 1.0 + rippleProgress * 1.6
        } else {
            return 2.4 - rippleProgress * 1.4
        }
    }

    /// Both directions fade out — the ring shouldn't linger after
    /// the event completes. Connect starts at 0.5 alpha; disconnect
    /// starts a touch lower (0.45) since the contracting motion is
    /// more visible than the expanding one.
    private var rippleOpacity: Double {
        let start = isConnected ? 0.5 : 0.45
        return start * (1.0 - rippleProgress)
    }
}

// MARK: - Timer running pill body (ticking pulse + last-10s heartbeat)

/// Standalone pill content for `.timerRunning(remainingSeconds:)`.
///
/// Three layers of motion, all derived from the remaining time so
/// the pill's energy ramps up as the timer approaches zero:
///
/// 1. **Always-on tick**: the timer glyph does a subtle 1Hz
///    breathe (1.0 → 1.06 scale, ~0.18 amplitude opacity), driven
///    by a TimelineView from wall-clock time so it never desyncs
///    or gets hijacked by parent re-renders. Reads as the second-
///    hand of an analog clock.
/// 2. **Color shift**: tile fill transitions through the orange
///    band at start, drifts to amber (≤ 30s), then to red (≤ 10s).
///    Smooth `easeInOut` interpolation so percentage changes
///    don't snap.
/// 3. **Last-10s heartbeat**: tile + glyph briefly punch +6%
///    scale on every second tick when remainingSeconds ≤ 10.
///    Synchronized to the wall-clock seconds tick so it lands
///    on each digit change.
///
/// The countdown text uses `.contentTransition(.numericText)` for
/// smooth digit cross-fades on each tick — already there, kept as-is.
private struct TimerRunningPillBody: View {
    let remainingSeconds: Int
    let timeText: String
    let notchOverlap: CGFloat
    let visible: Bool

    /// Heartbeat scale on the tile during the last 10 seconds.
    /// Defaults to 1.0; punched to 1.06 on each tick by the
    /// onChange below, springs back down via the implicit
    /// animation.
    @State private var heartbeat: Double = 1.0

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(tileColor)

                // 1Hz breathing scale on the timer glyph, driven
                // off wall-clock time. Like the ChargingTile bolt:
                // decoupled from SwiftUI animation system so the
                // parent's bouncy on `pendingSystemEvent` updates
                // can't propagate through and jitter the pulse.
                TimelineView(.animation(minimumInterval: 1.0 / 30.0,
                                         paused: false)) { context in
                    let phase = breatheValue(at: context.date)
                    Image(systemName: "timer")
                        .font(.system(size: 11, weight: .heavy))
                        .foregroundStyle(.white)
                        .scaleEffect(1.0 + phase * 0.06)
                        .opacity(1.0 - phase * 0.12)
                }
            }
            .frame(width: 22, height: 22)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .scaleEffect(heartbeat)

            Spacer(minLength: 0)

            Text(timeText)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.95))
                .padding(.trailing, 4)
                .contentTransition(.numericText(countsDown: true))
        }
        .padding(.horizontal, 10)
        .frame(height: notchOverlap)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .opacity(visible ? 1 : 0)
        .animation(.easeInOut(duration: 0.4), value: tileColor)
        .onChange(of: remainingSeconds) { newValue in
            // Heartbeat only kicks in for the final stretch — earlier
            // ticks would fatigue the user across a 25-minute Pomodoro.
            // Punch up, then spring back down on the same value so the
            // animation completes within the second.
            guard newValue > 0 && newValue <= 10 else { return }
            heartbeat = 1.06
            withAnimation(.spring(response: 0.42, dampingFraction: 0.55)) {
                heartbeat = 1.0
            }
        }
    }

    /// Sinusoidal 0…1 breathing curve — same shape the charging
    /// bolt uses, scaled to the timer-glyph budget. 1Hz period so
    /// it lines up with the digit ticks visually.
    private func breatheValue(at date: Date) -> Double {
        let t = date.timeIntervalSinceReferenceDate
        let omega = 2.0 * Double.pi / 1.0   // 1s period
        return (sin(t * omega) + 1.0) / 2.0
    }

    /// Tile color ramps with urgency:
    /// - > 30s: warm orange (start state)
    /// - 11–30s: amber (heads-up)
    /// - ≤ 10s: red (final stretch)
    /// SwiftUI interpolates between Color values automatically, so
    /// the `.animation(.easeInOut, value: tileColor)` on the parent
    /// view crossfades the fill smoothly on each band change.
    private var tileColor: Color {
        if remainingSeconds <= 10 {
            return Color(red: 0.95, green: 0.30, blue: 0.30).opacity(0.95)
        }
        if remainingSeconds <= 30 {
            return Color(red: 0.99, green: 0.70, blue: 0.20).opacity(0.94)
        }
        return Color(red: 1.00, green: 0.55, blue: 0.20).opacity(0.92)
    }
}

// MARK: - Timer finished pill body (checkmark draw-in + halo flash)

/// Standalone pill content for `.timerFinished`.
///
/// Two synchronized animations on entrance:
/// 1. **Checkmark draw-in**: trim from 0 → 1 over 320ms with
///    ease-out, so the strokes appear to be hand-written rather
///    than just popping into existence.
/// 2. **Halo flash**: a green Circle behind the tile scales
///    1.0 → 1.7× and fades from 0.4 alpha to 0 over 600ms — the
///    "celebratory pop" that punctuates the timer hitting zero.
///
/// After the checkmark settles, the whole tile does a small
/// 1.0 → 1.04 → 1.0 pulse to draw the eye, mirroring iOS's
/// "task complete" cell affordance.
private struct TimerFinishedPillBody: View {
    let notchOverlap: CGFloat
    let visible: Bool

    @State private var checkProgress: Double = 0
    @State private var haloScale: Double = 1.0
    @State private var haloOpacity: Double = 0.4
    @State private var pulse: Double = 1.0

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(Color(red: 0.30, green: 0.85, blue: 0.45))
                    .frame(width: 22, height: 22)
                    .scaleEffect(haloScale)
                    .opacity(haloOpacity)
                    .allowsHitTesting(false)

                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color(red: 0.30, green: 0.85, blue: 0.45).opacity(0.92))
                    .frame(width: 22, height: 22)

                CheckmarkShape()
                    .trim(from: 0, to: checkProgress)
                    .stroke(
                        Color.white,
                        style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round)
                    )
                    .frame(width: 12, height: 9)
            }
            .frame(width: 22, height: 22)
            .scaleEffect(pulse)

            Spacer(minLength: 0)

            // Right-wing bell glyph. Reinforces "timer just rang"
            // beyond the green checkmark + halo burst on the left.
            // Sits past the notch hardware so it actually paints.
            Image(systemName: "bell.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color(red: 0.30, green: 0.85, blue: 0.45))
                .padding(.trailing, 4)
        }
        .padding(.horizontal, 10)
        .frame(height: notchOverlap)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .opacity(visible ? 1 : 0)
        .onAppear {
            // Halo flash: scale out + fade out over 600ms.
            withAnimation(.easeOut(duration: 0.6)) {
                haloScale = 1.7
                haloOpacity = 0
            }
            // Checkmark draws in slightly behind the halo's start —
            // 60ms delay so the user's eye lands on the green burst
            // first, then resolves to the checkmark.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                withAnimation(.easeOut(duration: 0.32)) {
                    checkProgress = 1.0
                }
            }
            // Settle pulse: small bounce after the checkmark
            // completes so the tile reads as "task done."
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                withAnimation(.spring(response: 0.34, dampingFraction: 0.55)) {
                    pulse = 1.04
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.7)) {
                        pulse = 1.0
                    }
                }
            }
        }
    }
}

/// Hand-drawn checkmark path for the `.trim(from:to:)` draw-in
/// animation. Two-segment polyline — short down-right stroke
/// from (0, 0.55) to (0.35, 1.0), then a longer up-right stroke
/// from (0.35, 1.0) to (1.0, 0). Coordinates are normalized to a
/// 1×1 box; the parent `.frame(width: 12, height: 9)` scales it
/// to the right pixel size for the 22pt tile.
private struct CheckmarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.55))
        p.addLine(to: CGPoint(x: rect.minX + rect.width * 0.35,
                              y: rect.minY + rect.height * 1.0))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        return p
    }
}

/// Apple's AirDrop logo, drawn as a SwiftUI Shape. There is no
/// public SF Symbol matching the logo (verified via enumeration of
/// `NSImage(systemSymbolName:)`), and the closest fallbacks
/// (`shareplay`, `dot.radiowaves.up.forward`) don't read as AirDrop
/// — wrong arc orientation, wrong brand silhouette. So we draw it.
///
/// The AirDrop mark is three concentric semicircle arcs forming a
/// dome, with a small upward-pointing triangular wedge cut at the
/// bottom (where the dome meets its baseline). Each arc has a tiny
/// gap on either side of the wedge so the wedge appears to "punch
/// through" the lower arcs.
///
/// The shape is a STROKED path — the caller wraps it in a
/// `.stroke()` modifier with the desired tint and line width. The
/// triangular wedge is rendered as a separate filled path (same
/// `AirDropLogo` view stacks both via ZStack).
struct AirDropLogo: View {
    /// Stroke + fill color for both the dome arcs and the wedge.
    /// Defaults to white so existing call sites don't need to change.
    var tint: Color = .white
    /// Stroke width for the arcs. The wedge fill uses the same `tint`.
    /// Default 1.2 matches the original transient-pill rendering;
    /// callers wanting a heavier mark for larger sizes (e.g. the
    /// drop picker) can bump this.
    var lineWidth: CGFloat = 1.2

    var body: some View {
        ZStack {
            AirDropArcs()
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            AirDropWedge()
                .fill(tint)
        }
    }
}

struct AirDropArcs: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        // Dome center — slightly above geometric middle so arcs
        // fit comfortably inside the rect height and the wedge
        // has room to land below the arc legs without poking out
        // the bottom of the frame.
        let cx = rect.midX
        let cy = rect.minY + rect.height * 0.45
        // Half-width of the wedge gap at the bottom of the dome.
        // Each arc skips this much on either side of the bottom.
        let wedgeHalfDeg: Double = 28
        // Three concentric arcs, decreasing radii.
        let radii: [CGFloat] = [
            rect.width * 0.40,
            rect.width * 0.27,
            rect.width * 0.14
        ]
        // Bypass `addArc`'s clockwise convention entirely by drawing
        // each arc as a polyline of small line segments. Math is
        // unambiguous: for angle θ, point in user-space y-down is
        // `(cx + r·cos θ, cy - r·sin θ)` — the `-sin` flip makes
        // positive θ map to "above center" visually, so:
        //   θ =   0° → right of center (3 o'clock)
        //   θ =  90° → above center (12 o'clock = visual top)
        //   θ = 180° → left of center (9 o'clock)
        //   θ = 270° (or -90°) → below center (6 o'clock = visual bottom)
        //
        // Dome traces from `-90° + wedgeHalfDeg` (just RIGHT of the
        // bottom = around 5 o'clock visually) by INCREASING θ
        // (visually CCW) over the top, ending at `270° - wedgeHalfDeg`
        // (just LEFT of bottom = around 7 o'clock visually).
        //
        // Earlier this used `addArc` with `clockwise: false` and the
        // visual result was just the wedge — arc never appeared in
        // the screenshot. Polyline approach gives us full control.
        let startDeg = -90.0 + wedgeHalfDeg   // ≈ -62°
        let endDeg = 270.0 - wedgeHalfDeg     // ≈ 242°
        let steps = 60
        for r in radii {
            for i in 0...steps {
                let t = Double(i) / Double(steps)
                let deg = startDeg + (endDeg - startDeg) * t
                let rad = deg * .pi / 180.0
                let x = cx + r * CGFloat(cos(rad))
                let y = cy - r * CGFloat(sin(rad))
                if i == 0 {
                    p.move(to: CGPoint(x: x, y: y))
                } else {
                    p.addLine(to: CGPoint(x: x, y: y))
                }
            }
        }
        return p
    }
}

struct AirDropWedge: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        // Small upward-pointing isoceles triangle centered between
        // the arc legs. The arc legs end at:
        //   y = cy + r*sin(wedgeHalfDeg) where cy=0.45*h, r=0.40*w,
        //   sin(28°)≈0.47 → y ≈ 0.45h + 0.40w*0.47 ≈ 0.45h + 0.19w
        // For square 14×14: y ≈ 0.45*14 + 0.19*14 ≈ 6.3 + 2.65 = 8.95
        // Wedge apex starts ABOVE the arc legs' meeting line and
        // base sits BELOW. Centered at midX.
        let cx = rect.midX
        let apexY = rect.minY + rect.height * 0.45
        let baseY = rect.minY + rect.height * 0.85
        let halfBase = rect.width * 0.13
        p.move(to: CGPoint(x: cx, y: apexY))                  // apex (top)
        p.addLine(to: CGPoint(x: cx - halfBase, y: baseY))   // bottom-left
        p.addLine(to: CGPoint(x: cx + halfBase, y: baseY))   // bottom-right
        p.closeSubpath()
        return p
    }
}

// MARK: - Calendar upcoming pill body (urgency pulse on imminent)

/// Standalone pill content for `.calendarUpcoming(title:minutesUntilStart:)`.
///
/// Two animation modes based on imminence:
/// - **> 1 minute out**: static — pill is informational. Calendar
///   icon scales in once on entrance (0.7 → 1.0 spring), no looping
///   animation. We don't want to spam the eye for a 5-minute lead.
/// - **≤ 1 minute (or already started)**: subtle 1.5Hz pulse on the
///   icon (1.0 → 1.08 scale + 1.0 → 0.85 opacity). Reads as
///   "this is starting now, look up." Driven by TimelineView so it
///   doesn't conflict with parent re-renders the same way the
///   charging bolt was glitching before.
///
/// Time-remaining label uses `.contentTransition(.numericText)` so
/// minute decrements crossfade smoothly across pushes.
private struct CalendarUpcomingPillBody: View {
    let title: String
    let minutesUntilStart: Int
    let timeLabel: String
    let notchOverlap: CGFloat
    let visible: Bool

    @State private var iconScale: Double = 0.7

    private var isImminent: Bool { minutesUntilStart <= 1 }

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color(red: 0.99, green: 0.45, blue: 0.30).opacity(0.92))

                // Calendar glyph — pulses when imminent, static
                // otherwise. The same TimelineView pattern as the
                // timer breathe — wall-clock-driven so it survives
                // parent animation propagation untouched.
                TimelineView(.animation(minimumInterval: 1.0 / 30.0,
                                         paused: !isImminent)) { context in
                    let phase = isImminent ? pulseValue(at: context.date) : 0
                    Image(systemName: "calendar")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .scaleEffect(iconScale * (1.0 + phase * 0.08))
                        .opacity(1.0 - phase * 0.15)
                }
            }
            .frame(width: 22, height: 22)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))

            // Spacer crosses the notch hardware zone.
            Spacer(minLength: 0)

            // RIGHT-WING countdown — "2m", "now", "1h" — short enough
            // to fit past the notch. Full meeting title can't fit
            // here (right wing is ~46pt) and would just truncate to
            // garbage; the time-until-start is the actionable bit
            // anyway. Tap-to-join still routes through the whole
            // pill, so the title isn't lost — it lives in the
            // panel's calendar pane when the user opens it.
            Text(shortCountdownLabel(timeLabel: timeLabel, minutes: minutesUntilStart))
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1)
                .contentTransition(.numericText(countsDown: true))
                .padding(.trailing, 2)
        }
        .padding(.horizontal, 10)
        .frame(height: notchOverlap)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .opacity(visible ? 1 : 0)
        .onAppear {
            withAnimation(.spring(response: 0.36, dampingFraction: 0.65)) {
                iconScale = 1.0
            }
        }
    }

    /// Compress the parent's "in 2 min" / "in 1 hr 5 min" / "now"
    /// label into a 3-4-character right-wing badge. The pill's
    /// right wing is ~46pt past the notch — enough for a short
    /// numeric badge but not the full prose timeLabel.
    ///
    /// Format priority:
    ///   • now / starting → "now"
    ///   • >= 60 min      → "Nh" rounded down (e.g. 90 min → "1h")
    ///   • else           → "Nm" (e.g. "2m", "12m")
    private func shortCountdownLabel(timeLabel: String, minutes: Int) -> String {
        if minutes <= 0 { return "now" }
        if minutes >= 60 {
            let h = minutes / 60
            return "\(h)h"
        }
        return "\(minutes)m"
    }

    /// 1.5Hz urgency pulse — slightly faster than the timer's 1Hz
    /// breathe to read as "act now" rather than "still ticking."
    private func pulseValue(at date: Date) -> Double {
        let t = date.timeIntervalSinceReferenceDate
        let omega = 2.0 * Double.pi / 0.66   // 1.5Hz
        return (sin(t * omega) + 1.0) / 2.0
    }
}

// MARK: - AirDrop pill body (cosmetic progress sweep + UTI icon)

/// Standalone pill content for `.airDropReceived`. Owns its own
/// `@State` so the entrance animation runs once per arrival even
/// when the parent re-renders (e.g. when the system event slot
/// is replaced). Two phases:
///
/// 1. **0–600ms**: white arc sweeps 0 → 1 around the empty tile
///    (the tile background fills with the AirDrop blue tint). Text
///    label reads "Receiving…". This is purely cosmetic — by the
///    time we get an `onArrival` callback, the file is already on
///    disk; macOS doesn't expose Sharingd's in-flight progress to
///    third parties so we can't show real %. The 600ms duration is
///    short enough that the user reads it as "transfer just
///    completed" rather than waiting for nothing.
///
/// 2. **600ms onward**: arc fades, the UTI-specific glyph (photo /
///    video / music / generic) springs in (0.6 → 1.0 bouncy), and
///    the label flips to the actual filename. Stays in this state
///    for the remainder of the pill's lifetime (~3.4s of the 4s
///    total `airDropReceived` timeout).
private struct AirDropPillBody: View {
    let filename: String
    let fileURL: URL?
    let notchOverlap: CGFloat
    let visible: Bool

    /// 0…1 fill of the entrance arc. Animates from 0 to 1 over the
    /// first 600ms via withAnimation in onAppear.
    @State private var arcFill: Double = 0
    /// True after the arc completes. Drives the cross-fade from arc
    /// → file glyph and the label swap from "Receiving…" to filename.
    @State private var didComplete: Bool = false
    /// Glyph scale on settle — 0.6 at the moment of completion,
    /// springs to 1.0 to give the file icon a tactile "pop in"
    /// rather than a flat fade.
    @State private var iconScale: Double = 0.6

    private static let arcDuration: Double = 0.6

    var body: some View {
        // AirDrop pill: blue tile, AirDrop logo as the persistent
        // icon throughout the pill's lifetime. The earlier design
        // showed the logo only during a 600ms pre-completion phase
        // and then swapped to a UTI glyph (photo.fill / etc.) —
        // but that meant users almost never saw the AirDrop logo
        // itself, since the brief glimpse passed before they
        // looked. Now the logo IS the icon. Icon-only — no text.
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color(red: 0.30, green: 0.78, blue: 0.99).opacity(0.92))

                // Hand-drawn AirDrop logo (`AirDropLogo` SwiftUI
                // View). Apple keeps the actual `airdrop` symbol
                // private (verified by SF Symbols enumeration) so
                // we draw it: 3 concentric dome arcs + upward
                // wedge, matching the system mark.
                AirDropLogo()
                    .frame(width: 14, height: 14)
                    .scaleEffect(iconScale)
            }
            .frame(width: 22, height: 22)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: notchOverlap)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .opacity(visible ? 1 : 0)
        .onAppear {
            // Single-step entrance: AirDrop logo springs in from
            // 0.6× → 1.0× scale. No arc-sweep state machine, no
            // UTI-glyph swap — just the logo appearing with a
            // tactile "pop in" so the entrance still feels alive.
            withAnimation(.spring(response: 0.36, dampingFraction: 0.62)) {
                iconScale = 1.0
            }
        }
    }

    /// SF Symbol for the arrived file based on its UTI. Reads via
    /// `URL.resourceValues(forKeys: [.contentTypeKey])` (the modern
    /// UniformTypeIdentifiers path), falling back to extension-based
    /// guessing if the resource read fails (e.g. file moved by the
    /// time we ask). Symbols are chosen to match Apple's own quick-
    /// look glyph language: `photo` for images, `play.rectangle.fill`
    /// for video, `music.note` for audio, `doc.fill` otherwise.
    private var glyphForFile: String {
        guard let url = fileURL else { return "doc.fill" }
        if let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType {
            if type.conforms(to: .image) { return "photo.fill" }
            if type.conforms(to: .movie) || type.conforms(to: .video) { return "play.rectangle.fill" }
            if type.conforms(to: .audio) { return "music.note" }
            if type.conforms(to: .pdf) { return "doc.richtext.fill" }
            if type.conforms(to: .archive) { return "doc.zipper" }
        }
        // Extension fallback in case the resource fetch fails.
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg", "png", "heic", "gif", "webp", "tiff": return "photo.fill"
        case "mov", "mp4", "m4v", "avi", "mkv", "webm": return "play.rectangle.fill"
        case "mp3", "wav", "m4a", "flac", "aac", "ogg": return "music.note"
        case "pdf": return "doc.richtext.fill"
        case "zip", "tar", "gz", "rar", "7z": return "doc.zipper"
        default: return "doc.fill"
        }
    }
}

// MARK: - Charging tile (pill content for charging events)

/// 22pt rounded square that shows a battery/bolt glyph and animates
/// while the pill is in "charging" mode. The bolt does a continuous
/// 1.0 → 1.18 scale + opacity pulse (~1.4s cycle) to convey "energy
/// flowing in"; the unplugged battery glyph stays static. On first
/// appearance the entire tile springs from 0.6 → 1.0 scale to give
/// the pill morph a satisfying tactile pop.
///
/// The pulse runs off `TimelineView(.animation)` rather than
/// `withAnimation` / `.animation(...repeatForever, value:)`. The
/// parent `chargingPillContent` lives inside a SwiftUI subtree
/// that has `.animation(.bouncy, value: presenter.pendingSystemEvent)`
/// applied to it — every time the OS reports a fresh charging
/// snapshot (which can land mid-pulse), the bouncy curve was
/// propagating into the icon's animation context and briefly
/// hijacking the pulse, reading as a visible jitter / glitch on
/// the bolt. TimelineView computes the scale/opacity from wall-
/// clock time per refresh tick, so it has no dependency on
/// SwiftUI's state-driven animation system and the parent's
/// bouncy can't reach it. As a bonus, this also fixes the
/// timing-drift issue where `repeatForever` would desync after
/// a few seconds because `.animation(...,value:)` doesn't
/// faithfully resume from the same phase across re-evaluations.
private struct ChargingTile: View {
    let percent: Int
    let plugged: Bool

    @State private var appeared: Bool = false

    /// Pulse period in seconds. 1.4s end-to-end (~0.7s up,
    /// ~0.7s down) reads as "breathing" rather than "twitching."
    private let pulsePeriod: Double = 1.4

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(tileColor)
            // Wall-clock-driven pulse. TimelineView ticks at the
            // display's refresh rate (capped to `minimumInterval`
            // when paused / occluded) and recomputes the scale +
            // opacity on each tick. Because the values are derived
            // directly from `context.date`, no @State changes are
            // involved — the parent's `.animation(.bouncy, value:)`
            // can't propagate into this subtree because there's no
            // animation event to attach to. While unplugged the
            // timeline is effectively idle (paused: true), so we
            // don't burn the GPU on a static glyph.
            TimelineView(.animation(minimumInterval: 1.0 / 60.0,
                                     paused: !plugged)) { context in
                let phase = pulsePhase(for: context.date)
                Image(systemName: plugged ? "bolt.fill" : "battery.50")
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundStyle(.white)
                    .scaleEffect(plugged ? 1.0 + phase * 0.18 : 1.0)
                    .opacity(plugged ? 1.0 - phase * 0.15 : 1.0)
                    // Force a clean unmount/remount when plugged
                    // flips. SwiftUI's `.id(_:)` makes it treat
                    // pre/post values as DIFFERENT views — the
                    // old Image is dropped instantly, the new
                    // one mounts instantly. Without this, the
                    // parent pillContentOverlay's
                    // `.animation(.bouncy, value: pendingSystemEvent)`
                    // was propagating into the Image's
                    // `systemName` swap and crossfading between
                    // `battery.50` and `bolt.fill` — both
                    // visible during the fade, which the user
                    // saw as the discharged logo overlapping
                    // the charging pill icon.
                    .id(plugged)
            }
            // Belt-and-braces: also kill any animation on the
            // ZStack containing tile + icon so unintended
            // crossfades from outside this view tree can't
            // sneak in.
            .transaction { $0.animation = nil }
        }
        .frame(width: 22, height: 22)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .scaleEffect(appeared ? 1.0 : 0.6)
        .onAppear {
            withAnimation(.bouncy(duration: 0.45, extraBounce: 0.3)) {
                appeared = true
            }
        }
    }

    /// Sinusoidal 0…1 pulse derived from wall-clock time. Using
    /// `(sin + 1) / 2` instead of a raw sin gives a smooth
    /// up-and-down curve in the 0..1 range that the scale and
    /// opacity readers can scale into their target ranges.
    private func pulsePhase(for date: Date) -> Double {
        let t = date.timeIntervalSinceReferenceDate
        let omega = 2.0 * Double.pi / pulsePeriod
        return (sin(t * omega) + 1.0) / 2.0
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


/// Breathing drop-target halo. Lives in its own View struct so
/// the `.animation(.repeatForever)` lifecycle is bound to a
/// stable `@State` flag that flips on first appear — this is
/// SwiftUI's blessed pattern for continuous animations and is
/// far more reliable than embedding a TimelineView under a
/// conditional. The previous implementation had the breath
/// rendering invisibly because TimelineView under `if` was being
/// optimized out.
private struct DropRingBreath: View {
    let silhouette: OutwardFlaredShape
    let accent: Color

    @State private var pulsing = false

    var body: some View {
        ZStack {
            // Wide soft halo — large stroke + blur, high opacity
            // contrast so the breath is unmistakable visually.
            silhouette
                .stroke(accent.opacity(pulsing ? 0.65 : 0.20), lineWidth: 12)
                .blur(radius: 6)

            // Mid stroke — sharp 2pt accent for definition.
            silhouette
                .stroke(accent.opacity(pulsing ? 0.95 : 0.55), lineWidth: 2)
        }
        .onAppear {
            // Kick the pulse the moment the view mounts.
            // 1.4s autoreverse breath, infinite loop.
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                pulsing = true
            }
        }
    }
}
