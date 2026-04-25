import SwiftUI

/// Animated audio-bar visualizer — same vocabulary Alcove and Apple's
/// own Now Playing widget use to communicate "audio is moving" without
/// actually analyzing the signal. We don't have access to the system
/// audio stream (and tapping it would be a privacy mess), so the bars
/// are driven by phase-offset sinusoids — purely cosmetic, but reads as
/// "music is alive" the moment you glance at it.
///
/// The animation is driven by `TimelineView(.animation)` so each bar's
/// height is recomputed from the current wall-clock time on every
/// display refresh — no per-bar `@State` springs to coordinate, no
/// timer to invalidate when the view goes off screen. When `isPlaying`
/// is false we hand TimelineView `paused: true`, which freezes the
/// timeline; the bars settle to their minimum height (1/3 of max),
/// reading as "playback paused" without disappearing entirely.
///
/// Used in two places:
/// 1. The notch HUD pill — replaces the play/pause/skip cluster on the
///    right edge so the pill reads as a status indicator first and a
///    transport remote second. (Transport stays in the main panel's
///    Music page, where the user has the screen real estate to mash
///    big buttons without missing them.)
/// 2. The Music page — small badge near the source credit, gives the
///    expanded player the same "alive while playing" tell the closed
///    pill has, without competing with the larger artwork for attention.
struct WaveformView: View {
    let isPlaying: Bool

    /// Total bar count. Four reads as a clear "audio bars" silhouette
    /// at the small size we use; three feels sparse, five+ starts
    /// looking like an EQ.
    var barCount: Int = 4
    /// Width of each individual bar. 2.5pt is the smallest visually
    /// confident size for a Capsule that needs to hold a clean
    /// rounded-rect shape on retina.
    var barWidth: CGFloat = 2.5
    /// Inter-bar spacing.
    var spacing: CGFloat = 2.5
    /// Maximum bar height — the bars oscillate between `maxHeight/3`
    /// (idle / paused floor) and `maxHeight` (peak swing).
    var maxHeight: CGFloat = 14
    /// Tint applied to all bars. Defaults to `Color.white` so the view
    /// works on any dark background; pass an explicit color for callers
    /// that need brand alignment.
    var tint: Color = .white
    /// Foreground opacity. Used to dial the bars down to a quiet
    /// secondary-info brightness — they're decorative, not the focal
    /// point.
    var opacity: Double = 0.85

    var body: some View {
        // TimelineView is the right primitive here. A `.linear repeatForever`
        // animation on a single phase variable would only let SwiftUI
        // interpolate ONE value across time — but each bar needs its own
        // height computed from the same phase with a per-bar offset.
        // TimelineView re-evaluates the body at each refresh, so we can
        // compute all four heights in lockstep against `context.date`.
        //
        // `paused: !isPlaying` halts the timeline exactly when playback
        // pauses — the bars freeze at their then-current heights, then
        // settle down to the idle floor via the height calculation
        // (which short-circuits to baseHeight when isPlaying is false).
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !isPlaying)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: spacing) {
                ForEach(0..<barCount, id: \.self) { index in
                    Capsule(style: .continuous)
                        .fill(tint.opacity(opacity))
                        .frame(width: barWidth, height: barHeight(at: time, bar: index))
                        // animation() on the height interpolates the
                        // 30Hz steps so the bars don't read as a stop-
                        // motion staircase on slower displays.
                        .animation(.easeInOut(duration: 0.16), value: barHeight(at: time, bar: index))
                }
            }
            .frame(height: maxHeight, alignment: .center)
        }
        .frame(width: totalWidth, height: maxHeight)
        // Kill default accessibility; the bars are decorative. The
        // surrounding view (pill, badge) carries the actual semantics.
        .accessibilityHidden(true)
    }

    // MARK: - Geometry

    /// Computed total width — `barCount` bars + `(barCount-1)` gaps.
    /// Saves callers from doing the arithmetic when they need to size
    /// a parent container around the visualizer.
    private var totalWidth: CGFloat {
        let bars = CGFloat(barCount) * barWidth
        let gaps = CGFloat(barCount - 1) * spacing
        return bars + gaps
    }

    /// Bar height at a given moment in time. Each bar oscillates on a
    /// sine wave with a per-bar phase offset so the four bars read as
    /// a flowing wave rather than a single chord.
    ///
    /// When idle (paused), all bars sit at `baseHeight` (1/3 of max)
    /// — visible enough to communicate "this is an audio control" but
    /// quiet enough to read as "not currently playing."
    private func barHeight(at time: TimeInterval, bar: Int) -> CGFloat {
        let baseHeight = maxHeight / 3
        guard isPlaying else { return baseHeight }
        // Frequency tuning: 1.6 Hz oscillation reads as "lively but not
        // frantic" — slower (~1Hz) feels sluggish for music, faster
        // (~3Hz+) feels jittery. Per-bar phase offset of 0.7 rad keeps
        // adjacent bars visibly out-of-phase.
        let phase = time * 1.6 + Double(bar) * 0.7
        // sin returns -1...1 → normalize to 0...1 for height blend.
        let normalized = (sin(phase) + 1) / 2
        return baseHeight + (maxHeight - baseHeight) * CGFloat(normalized)
    }
}

#Preview("Playing") {
    HStack(spacing: 30) {
        WaveformView(isPlaying: true)
        WaveformView(isPlaying: true, barCount: 5, maxHeight: 24, tint: .green)
        WaveformView(isPlaying: false)
    }
    .padding(40)
    .background(Color.black)
}
