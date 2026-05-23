import SwiftUI

extension Animation {
    static let panelOpen = Animation.spring(response: 0.42, dampingFraction: 0.78)
    static let panelClose = Animation.easeOut(duration: 0.18)
    static let rowHover = Animation.spring(response: 0.22, dampingFraction: 0.9)
    static let selection = Animation.spring(response: 0.18, dampingFraction: 0.95)
    static let recordingPulse = Animation.easeInOut(duration: 0.8).repeatForever(autoreverses: true)

    /// Slide of the segmented tab-bar selection pill between tabs.
    ///
    /// macOS segmented controls move the selection lozenge with a
    /// smooth, lightly-damped spring — it travels AND resizes to the
    /// new segment in one gesture, settling without overshoot.
    ///
    /// This drives a SINGLE always-present pill's `.offset`/`.frame`
    /// (see `PanelRootView.selectionPill`), NOT a `matchedGeometryEffect`
    /// insert/remove. The matched-geometry version stranded views under
    /// rapid switching (2026-05-22 ghost bug); a single view that only
    /// changes offset+width can't orphan, so this spring is safe to run
    /// on every tap.
    ///
    /// Tuning (2026-05-22, motion research): the first pass used
    /// response 0.34 / damping 0.86, which computes to only ~0.5%
    /// overshoot — effectively critically damped. That's exactly why it
    /// read "almost there but not lively": a tap carries intent/momentum,
    /// and WWDC18 "Designing Fluid Interfaces" says momentum should be
    /// REWARDED with a touch of overshoot, not zeroed out. response 0.32
    /// / dampingFraction 0.82 lands ~1.4% overshoot — one barely-
    /// perceptible kiss past the target, then a fast settle. Crisp and
    /// alive rather than flat. (Equivalent interpolatingSpring: stiffness
    /// ≈ 385, damping ≈ 32, mass 1. Modern idiom: .snappy(0.32, +0.02).)
    /// Don't drop below 0.28 response (jitter) or above 0.36 (sluggish)
    /// for this 60–150pt travel.
    static let tabSlide = Animation.spring(response: 0.32, dampingFraction: 0.82)

    /// Spring used when a freshly-dropped file lands in its
    /// destination grid (Images / Files / Videos).
    ///
    /// Tuning history:
    ///   • response 0.42, damping 0.62 — too short. The spring
    ///     was settled before the slab finished its 450ms open
    ///     morph. The bounce was firing but lost behind the
    ///     noisier slab-open phase.
    ///   • response 0.75, damping 0.55 — too bouncy per user
    ///     feedback ("a little less"). Visible overshoot was
    ///     dramatic enough to read as "goofy" rather than
    ///     "satisfying."
    ///   • response 0.55, damping 0.72 — current. Trims the
    ///     overshoot to ~2% (vs ~6% before) — still a tactile
    ///     spring feel, no second wobble. ~700ms total settle
    ///     so the entrance is still visible after the slab open.
    static let dropSpring = Animation.spring(response: 0.55, dampingFraction: 0.72)
}

extension View {
    /// Alcove-style playback cue for album artwork: full and vibrant
    /// while playing; desaturated, slightly dimmed, and a touch smaller
    /// when paused/stopped — an at-a-glance "not playing" signal. Applied
    /// to EVERY cover (the resting notch pill + the open slab) so the cue
    /// reads identically everywhere. (2026-05-22, matching Alcove: "when
    /// playing the artwork is normal, when not playing it becomes less
    /// vibrant and a little smaller.")
    ///
    /// Tuning: saturation 1.0→0.5 ("less vibrant"), scale 1.0→0.9 ("a
    /// little smaller"), a gentle opacity dip to read as "muted." The
    /// 0.3s easeInOut keeps the play↔pause transition smooth, not abrupt.
    func playbackArtworkTreatment(isPlaying: Bool) -> some View {
        self
            .saturation(isPlaying ? 1.0 : 0.5)
            .opacity(isPlaying ? 1.0 : 0.85)
            .scaleEffect(isPlaying ? 1.0 : 0.9, anchor: .center)
            .animation(.easeInOut(duration: 0.3), value: isPlaying)
    }
}

/// Apple's rubber-band overscroll physics — the math behind the
/// "perfect stretch" on two-finger swipes. Two pieces, both lifted from
/// Apple's own implementations (2026-05-23 research pass):
///
///   • `resist(_:dimension:)` — the DURING-DRAG resistance curve. The
///     chpwn / UIKit formula, identical to what WebKit's
///     `ScrollElasticityController` applies: a raw pull `x` maps to a
///     damped offset that grows with diminishing returns and asymptotes
///     to `dimension` (you can pull forever, but the surface only ever
///     travels < dimension). `c = 0.55` is Apple's measured constant
///     (confirmed in WebKit + `@use-gesture`, whose source literally
///     comments "iOS constant = 0.55"). Signed, so it works for both
///     up/down and left/right.
///
///   • `reboundOffset(...)` — WebKit's LITERAL spring-back decay from
///     `ScrollAnimationRubberBand.mm`: a velocity-kicked exponential
///     `offset(t) = (pos₀ − v₀·t·0.31)·e^(−t·20/1.6)` (time constant
///     τ = period/stiffness = 80 ms). Used to release the stretch with
///     exact macOS fidelity rather than a generic spring.
enum RubberBand {
    static func resist(_ x: CGFloat, dimension d: CGFloat, constant c: CGFloat = 0.55) -> CGFloat {
        guard d > 0 else { return 0 }
        let sign: CGFloat = x < 0 ? -1 : 1
        let ax = abs(x)
        return sign * (ax * d * c) / (d + c * ax)
    }

    static func reboundOffset(position pos0: CGFloat,
                              velocity v0: CGFloat,
                              elapsed t: CGFloat,
                              stiffness: CGFloat = 20,
                              amplitude: CGFloat = 0.31,
                              period: CGFloat = 1.6) -> CGFloat {
        let dampen = CGFloat(exp(Double((-t * stiffness) / period)))
        return (pos0 + (-v0 * t * amplitude)) * dampen
    }
}

extension AnyTransition {
    /// Entrance transition for a freshly-dropped item.
    ///
    /// Tuning history:
    ///   • scale 0.55 — too subtle. Cell looked the same size,
    ///     no "landing" read.
    ///   • scale 0.30 — too dramatic, paired with the bouncy
    ///     spring it felt like the cell jumped at the user.
    ///   • scale 0.55 — current (returned). With the toned-down
    ///     `.dropSpring` (damping 0.72) the smaller scale gives
    ///     a clean "lands and settles" rather than "shoots up."
    ///
    /// Removal stays on a quick fade so deletes don't feel
    /// theatrical.
    static let dropLanding: AnyTransition = .asymmetric(
        insertion: .scale(scale: 0.55).combined(with: .opacity),
        removal: .opacity.combined(with: .scale(scale: 0.92))
    )
}
