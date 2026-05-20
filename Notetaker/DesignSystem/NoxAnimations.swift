import SwiftUI

/// Named animation presets for nox. Replaces the ad-hoc
/// `.spring(response: X, dampingFraction: Y)` triplets scattered
/// across 66 call sites in PanelRootView, MusicPanelView, the pill
/// views, etc., with a small fixed vocabulary tuned against
/// Alcove's behavior on the same physical events.
///
/// **Why a namespace instead of inline values?**
///
/// The pre-1.9.21 codebase had **22+ unique** `(response,
/// dampingFraction)` pairs in use — 0.18/0.55, 0.22/0.55,
/// 0.32/0.78, 0.34/0.7, 0.42/0.55, 0.42/0.62, 0.5/0.55, etc.
/// Reviewing them showed:
///   • Most differences were not intentional. Different files were
///     using different values for the same KIND of motion (e.g.
///     a track change in `MusicPanelView` vs the same event in
///     `PanelRootView` rendered with subtly different springs).
///   • A few values were way off — `response: 0.18` with
///     `dampingFraction: 0.55` is underdamped at high speed and
///     read as nervous/jittery on the resting pill.
///   • There was no shared vocabulary, so user feedback like "make
///     the pill feel snappier" had no central place to tune.
///
/// **Sourcing the presets.**
///
/// Alcove.app's binary (decoded 2026-05-17 via `otool -tV` + a
/// pass through `__TEXT,__const` looking for IEEE 754 doubles in
/// spring-plausible ranges) revealed ~12 distinct response/damping
/// pairs reused across ~560 SwiftUI `.spring(...)` call sites. The
/// presets below are those values, named by the gesture they
/// belong to in Alcove's interaction vocabulary.
///
/// Apple's own SwiftUI 5 named presets (`.snappy`, `.smooth`,
/// `.bouncy`) map cleanly onto three of Alcove's bands, so we
/// alias to them where they match — keeps us in step with any
/// future Apple tuning of those names. The remaining 7 presets
/// are bespoke triplets named after their role.
///
/// **Migration rule for existing call sites:**
///   1. Match by gesture KIND, not by numeric similarity. A
///      track-change banner and a panel open are different events
///      even if both used to be tuned to `response: 0.42`.
///   2. When in doubt, pick `pillMorph` — it's the workhorse
///      animation for nearly every notch HUD transition.
///   3. Never invent a new spring inline. If a moment genuinely
///      needs a new preset, add it here and document why.
enum NoxAnimations {

    // MARK: - Apple-named presets (use directly when they match)

    /// Apple's `.snappy` — `response: 0.4, dampingFraction: 0.85`.
    /// Matches Alcove's "pill morph" workhorse. Use for: pill
    /// expand/collapse, tab switch, the slab's content swap
    /// between music card and grid views.
    static let snappy: Animation = .snappy

    /// Apple's `.smooth` — `response: 0.5, dampingFraction: 1.0`.
    /// Critically damped (no overshoot). Use for: settling into
    /// a final position after a longer animation, opacity fades
    /// where bounce would read as a glitch.
    static let smooth: Animation = .smooth

    /// Apple's `.bouncy` — `response: 0.5, dampingFraction: 0.7`.
    /// Distinctly under-damped (will overshoot by ~6%). Use for:
    /// "look at this!" moments — celebratory milestones, the
    /// track-change banner's arrival, AirDrop landed.
    static let bouncy: Animation = .bouncy

    // MARK: - Bespoke Alcove-measured presets

    /// `response: 0.4, dampingFraction: 0.85` — same numerics as
    /// `.snappy`, named separately to document INTENT at the call
    /// site. Use this when the motion is specifically a pill
    /// morph (resting → expanded, or any silhouette shape change).
    /// The duplication is intentional: searching for
    /// `pillMorph` finds every silhouette transition.
    static let pillMorph: Animation = .spring(response: 0.4, dampingFraction: 0.85)

    /// `response: 0.5, dampingFraction: 0.65` — Alcove's track-
    /// change banner arrival. Slightly bouncier than `.bouncy`
    /// (which is 0.7 damping), giving a little more excitement on
    /// "here's the new track" moments. Use for: track-change
    /// banner slide-in, dictation transcription complete reveal,
    /// any "good news arrived" surface.
    static let trackArrival: Animation = .spring(response: 0.5, dampingFraction: 0.65)

    /// `response: 0.42, dampingFraction: 0.62` — the existing
    /// nox slab open spring (kept exactly as shipped 1.9.20 since
    /// the slab silhouette is shape-tuned to it). Bouncier than
    /// `pillMorph` because the slab's larger amplitude needs a
    /// little overshoot to feel alive — without it, it lands flat.
    /// Use for: slab open animation (`PanelWindowController.show()`).
    static let panelOpen: Animation = .spring(response: 0.42, dampingFraction: 0.62)

    /// `response: 0.32, dampingFraction: 0.78` — slab close spring.
    /// Slightly snappier than the open and more damped so the
    /// silhouette doesn't bounce back into view at the end. Use
    /// for: slab close animation, banner dismiss.
    static let panelClose: Animation = .spring(response: 0.32, dampingFraction: 0.78)

    /// `response: 0.55, dampingFraction: 0.85` — live activity
    /// arrival (Alcove parity). Charging plug-in, AirDrop landed,
    /// Bluetooth connected — events that announce themselves
    /// from notch-hidden into a pill state.
    static let liveActivity: Animation = .spring(response: 0.55, dampingFraction: 0.85)

    /// `response: 0.3, dampingFraction: 0.75` — hover-expand spring.
    /// Faster than `pillMorph` because hover triggers should feel
    /// like the pill is reacting to the cursor's proximity, not
    /// committing to a state change. Slightly underdamped so the
    /// reveal has a tiny breathing motion.
    static let hoverExpand: Animation = .spring(response: 0.3, dampingFraction: 0.75)

    /// `response: 0.4, dampingFraction: 0.85` — swipe-reset snap-back.
    /// Same numerics as `pillMorph` but documents that this is
    /// specifically the "user released without committing" path —
    /// the pill drifts back home rather than snapping.
    /// Matches `SwipeGesturePolicy.resetSpringResponse/Damping`.
    static let swipeReset: Animation = .spring(response: 0.4, dampingFraction: 0.85)

    /// `response: 0.65, dampingFraction: 0.95` — long, gentle settle.
    /// Use for: rare, longer-form transitions that should feel
    /// deliberate rather than reactive. The teleprompter pill's
    /// initial reveal, lock-screen morph.
    static let gentleSettle: Animation = .spring(response: 0.65, dampingFraction: 0.95)

    /// `response: 0.18, dampingFraction: 0.85` — quickest spring
    /// in the vocabulary. Use for: button-press anticipation,
    /// hover-in/hover-out on a small element where any visible
    /// motion duration over ~150ms reads as laggy.
    static let quickAnticipation: Animation = .spring(response: 0.18, dampingFraction: 0.85)

    /// `response: 1.0, dampingFraction: 0.98` — slowest spring,
    /// fully damped. Use for: ambient idle motion (the resting
    /// pill's breathing, idle gradient drift). Long enough that
    /// the eye reads it as "alive" rather than "animating."
    static let slowDrift: Animation = .spring(response: 1.0, dampingFraction: 0.98)
}

// MARK: - Parameter constants for SwiftUI sites that need numbers

/// Raw `(response, dampingFraction)` triplets for sites that need
/// the numeric values directly (e.g. `withAnimation(.spring(
/// response: ..., dampingFraction: ...))` callers that can't
/// pass an `Animation` value, or non-SwiftUI consumers like
/// `CASpringAnimation` callers that need mass/stiffness/damping).
///
/// Naming mirrors `NoxAnimations` exactly — same preset, just
/// exposed as a tuple instead of an `Animation` so it composes
/// with `CASpringAnimation.mass/stiffness/damping` translations.
///
/// SwiftUI's `.spring(response:dampingFraction:)` and Core
/// Animation's `CASpringAnimation` use different mathematical
/// parameterizations:
///   • SwiftUI:   response (perceptual duration), dampingFraction (0-1)
///   • CoreAnim:  mass, stiffness, damping (physics constants)
///
/// The conversion (assuming mass = 1.0):
///   ω₀ = 2π / response
///   stiffness = ω₀²
///   damping = 2 · ω₀ · dampingFraction
///
/// `NoxSpring.coreAnimationParameters(response:dampingFraction:)`
/// below does this math so we can pass nox's Alcove-tuned
/// presets to Core Animation springs identically.
enum NoxSpring {
    /// `(response, dampingFraction)` triplet. Use for SwiftUI
    /// sites that build their own `Animation` value or for
    /// passing to `CASpringAnimation`.
    typealias Params = (response: Double, damping: Double)

    static let pillMorph:          Params = (0.4,  0.85)
    static let trackArrival:       Params = (0.5,  0.65)
    static let panelOpen:          Params = (0.42, 0.62)
    static let panelClose:         Params = (0.32, 0.78)
    static let liveActivity:       Params = (0.55, 0.85)
    static let hoverExpand:        Params = (0.3,  0.75)
    static let swipeReset:         Params = (0.4,  0.85)
    static let gentleSettle:       Params = (0.65, 0.95)
    static let quickAnticipation:  Params = (0.18, 0.85)
    static let slowDrift:          Params = (1.0,  0.98)

    /// Convert nox's SwiftUI-style spring params to Core Animation's
    /// `(mass, stiffness, damping)` triplet. Pass to:
    ///
    ///     let anim = CASpringAnimation(keyPath: ...)
    ///     let p = NoxSpring.coreAnimationParameters(NoxSpring.pillMorph)
    ///     anim.mass = p.mass
    ///     anim.stiffness = p.stiffness
    ///     anim.damping = p.damping
    ///     anim.duration = anim.settlingDuration
    ///
    /// `mass` is fixed at 1.0 — the conversion above assumes it.
    /// All Alcove springs we measured were single-mass; if we ever
    /// add a "heavy" preset that needs different mass, the
    /// conversion needs to be re-derived (or just expose the
    /// computed value directly here).
    static func coreAnimationParameters(_ p: Params) -> (mass: Double, stiffness: Double, damping: Double) {
        let omega0 = 2 * .pi / p.response
        let stiffness = omega0 * omega0
        let damping = 2 * omega0 * p.damping
        return (mass: 1.0, stiffness: stiffness, damping: damping)
    }
}
