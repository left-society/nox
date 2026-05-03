import SwiftUI

extension Animation {
    static let panelOpen = Animation.spring(response: 0.42, dampingFraction: 0.78)
    static let panelClose = Animation.easeOut(duration: 0.18)
    static let rowHover = Animation.spring(response: 0.22, dampingFraction: 0.9)
    static let selection = Animation.spring(response: 0.18, dampingFraction: 0.95)
    static let recordingPulse = Animation.easeInOut(duration: 0.8).repeatForever(autoreverses: true)

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
