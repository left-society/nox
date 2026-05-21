import SwiftUI

struct WaveformRefreshPolicy {
    static let activeInterval: TimeInterval = 1.0 / 30.0
    static let compactRestingInterval: TimeInterval = 1.0 / 12.0

    static func minimumInterval(
        isCompactResting: Bool,
        isInteractionActive: Bool
    ) -> TimeInterval {
        guard isCompactResting, !isInteractionActive else {
            return activeInterval
        }
        return compactRestingInterval
    }
}

/// Equalizer-style audio visualizer — three thin vertical capsules
/// that pulse up and down from a central baseline, driven by three
/// incommensurate sinusoids so the bars never sync into a recognizable
/// pattern. Drawn on a `Canvas` for one path per frame instead of N
/// animated SwiftUI views.
///
/// History — what changed and why:
///   v1: Four phase-offset vertical capsules growing from a bottom
///       baseline. User reported the four bars sometimes landed in an
///       ASCENDING STAIRCASE that read as Wi-Fi / signal-strength
///       indicator instead of audio. Rejected.
///   v2: Scrolling sine wave (oscilloscope). No staircase failure
///       mode, but unique to us — visually distinct from NotchNook
///       and other notch HUDs that ship a bar-style equalizer.
///   v3 (current): Three bars, CENTER-JUSTIFIED (grow up AND down
///       from middle). Two anti-Wi-Fi guards:
///         • Bars grow from middle out, not from bottom up. A
///           growing-from-middle pattern is fundamentally different
///           from a Wi-Fi indicator (which always grows from a single
///           bottom baseline) — even when the heights are sorted
///           1<2<3, the visual is two centered capsules getting
///           taller, not a left-to-right ramp.
///         • Three INCOMMENSURATE periods (0.71s / 1.13s / 1.69s,
///           ratios irrational so the cycle never repeats). At any
///           instant the heights might be sorted ascending, but the
///           NEXT instant one bar will leap and break the pattern.
///           Statistical mean position of each bar over time is
///           identical, so no bar is "the loud one" or "the short one."
///
/// Used in two places (same view, different sizes):
/// 1. Notch HUD resting pill — right edge, replaces the
///    play/pause/skip cluster so the pill reads as a status indicator
///    first and a transport remote second.
/// 2. Music page in the open slab — small badge near the source
///    credit; same "alive while playing" tell as the closed pill,
///    smaller to not compete with the larger artwork.
///
/// Per direct frame-by-frame audit of NotchNook (Built-in Retina
/// Display 1300-1320): their resting pill has 3 thin vertical bars
/// at varying heights that animate frame-to-frame — exact match
/// for the equalizer pattern this view now ships.
struct WaveformView: View {
    let isPlaying: Bool

    /// Drawing width in points. Defaults size up the visualizer for
    /// the pill; pass smaller for the music-page source badge.
    var width: CGFloat = 16
    /// Drawing height in points. Bars grow up to half this height
    /// in each direction from the centerline.
    var height: CGFloat = 14
    /// Width of each individual bar capsule.
    var lineWidth: CGFloat = 2.0
    /// Tint applied to the bars. Defaults to `Color.white` so the view
    /// works on any dark background; pass an explicit color for callers
    /// that need brand alignment.
    var tint: Color = .white
    /// Foreground opacity. Used to dial the visualizer down to a quiet
    /// secondary-info brightness — it's decorative, not the focal
    /// point.
    var opacity: Double = 0.85
    /// Optional rhythmic pattern that drives the amplitude envelope.
    /// When provided, the bars' heights pulse to a programmatically-
    /// generated beat structure (kick, swell, fills) — gives the
    /// visualizer the LOOK of real audio without needing system audio
    /// capture. Pick one per track via
    /// `WaveformPattern.deterministic(for:)` for stable per-track
    /// visual identity.
    var pattern: WaveformPattern = .midtempo
    /// Resting notch pills are visible for hours. Lower their idle
    /// cadence so the visual still breathes without spending 30Hz
    /// SwiftUI/Canvas work while the user is doing something else.
    var isCompactResting: Bool = false
    /// While the user is swiping/morphing the compact pill, restore the
    /// faster cadence so the feedback feels connected to the gesture.
    var isInteractionActive: Bool = false

    /// Number of bars. **4** — Alcove parity (measured + user-confirmed
    /// 4 lines in Alcove's resting pill). The center-justified layout
    /// (bars grow up AND down from the midline) avoids the Wi-Fi-
    /// staircase ambiguity that made higher counts risky in a bottom-
    /// baseline design.
    private let barCount = 4

    var body: some View {
        let minimumInterval = WaveformRefreshPolicy.minimumInterval(
            isCompactResting: isCompactResting,
            isInteractionActive: isInteractionActive
        )
        // TimelineView re-evaluates the body at each refresh. Inside
        // the closure we recompute all bar heights from `context.date`.
        // `paused: !isPlaying` halts the timeline when playback pauses;
        // bars freeze at their last height — visually "muted, ready."
        TimelineView(.animation(minimumInterval: minimumInterval, paused: !isPlaying)) { context in
            // Fold the absolute reference-date time before feeding it
            // into sin(). Same precision-preservation reason as the
            // previous oscilloscope version: very large radian
            // arguments lose sin/cos resolution.
            let raw = context.date.timeIntervalSinceReferenceDate
            let foldedTime = raw.truncatingRemainder(dividingBy: 2 * .pi * 1000)
            let time = foldedTime.isFinite ? foldedTime : 0

            // Rhythmic envelope from the selected pattern — drives
            // the OVERALL height as if sampling a real audio signal.
            // The bars individually pulse against this envelope so
            // a "kick" beat shows as all three bars peaking at once,
            // while quiet moments dampen all bars together.
            let envelope = pattern.envelope(at: time)
            let envFinite = envelope.isFinite ? envelope : 1.0
            // Idle amplitude is a barely-perceptible wobble — reads
            // as "audio loaded but quiet" rather than "view broken."
            let amplitudeMul: Double = (isPlaying ? 0.85 : 0.10) * envFinite

            Canvas { ctx, size in
                let halfH = size.height / 2
                // Total horizontal layout: barCount bars + (barCount-1)
                // gaps. Spacing chosen so the bars hug each other
                // tightly (gap = 0.7 * lineWidth) — looks like a single
                // visualizer cluster, not three independent dots.
                let gap = lineWidth * 0.7
                let totalW = CGFloat(barCount) * lineWidth + CGFloat(barCount - 1) * gap
                let startX = (size.width - totalW) / 2

                // Three INCOMMENSURATE periods, picked so no two share
                // a rational ratio. Tuned by eye for "real-audio"
                // dynamics — the ear/eye reads bursty pulses against
                // a sustained background, not a metronome.
                //   • bar 0 period 0.71s (fastest, ~1.4 Hz)
                //   • bar 1 period 1.13s (~0.88 Hz)
                //   • bar 2 period 1.69s (slowest, ~0.59 Hz)
                // π / e / √2 family — ratios irrational, the loop
                // composed of all three never closes.
                let periods: [Double] = [0.71, 1.13, 1.69, 0.94]
                // Phase offsets so the three bars don't start in lock-
                // step. Different starting points + different periods
                // = bars are never in any predictable relative
                // configuration.
                let phases: [Double] = [0.0, 1.7, 3.3, 2.5]

                for i in 0..<barCount {
                    let phase = (time / periods[i] + phases[i]) * 2 * .pi
                    // Per-bar "audio" signal sums two harmonics so
                    // each bar pulses with character (bursty), not a
                    // pure clean sine. Different harmonic ratio per
                    // bar so each one has its own personality.
                    let h1 = sin(phase) * 0.7
                    let h2 = sin(phase * 2.3 + Double(i)) * 0.3
                    let signal = h1 + h2
                    let safeSignal = signal.isFinite ? abs(signal) : 0.5
                    // Per-bar height as fraction of half-height.
                    // Floor at 0.18 so bars are always visible (no
                    // collapsing to zero — would look broken).
                    let barHeightFrac = max(0.18, safeSignal * amplitudeMul)
                    let barHalfH = halfH * CGFloat(barHeightFrac)

                    let x = startX + CGFloat(i) * (lineWidth + gap)
                    // Capsule centered on the middle of the canvas
                    // — grows up AND down from y = halfH. This is
                    // what kills the Wi-Fi ambiguity: a Wi-Fi
                    // indicator always grows from a single bottom
                    // baseline, never from a middle line.
                    let rect = CGRect(
                        x: x,
                        y: halfH - barHalfH,
                        width: lineWidth,
                        height: barHalfH * 2
                    )
                    let path = Path(roundedRect: rect,
                                    cornerRadius: lineWidth / 2)
                    ctx.fill(path, with: .color(tint.opacity(opacity)))
                }
            }
            .frame(width: width, height: height)
        }
        .frame(width: width, height: height)
        // Kill default accessibility; the visualizer is decorative.
        // The surrounding view (pill, badge) carries the semantics.
        .accessibilityHidden(true)
    }
}

#Preview("Playing") {
    HStack(spacing: 30) {
        WaveformView(isPlaying: true)
        WaveformView(isPlaying: true, width: 40, height: 22, lineWidth: 2.0, tint: .green)
        WaveformView(isPlaying: false)
    }
    .padding(40)
    .background(Color.black)
}
