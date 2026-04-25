import SwiftUI

/// Oscilloscope-style audio waveform — a thin scrolling sine line that
/// flows left-to-right, drawn on a `Canvas` so we get one path per
/// frame instead of N animated SwiftUI views.
///
/// The previous version of this file rendered four phase-offset
/// vertical capsules. The user reported that "the waveform doesn't
/// look like this" alongside a screenshot of the pill — the four
/// bars happened to land in an ascending staircase pattern at the
/// captured moment, which read as a Wi-Fi / signal-strength bar
/// indicator rather than as an audio visualizer. That ambiguity is
/// fundamental to the bars-on-a-baseline silhouette: at any instant
/// the four heights *can* line up that way, especially with closely-
/// spaced phase offsets.
///
/// A scrolling sine wave has no such failure mode. It reads as audio
/// at every instant — the silhouette is always a curvy line, never
/// an ordered set of bars. Two summed sinusoids at incommensurate
/// frequencies give a richer "real audio" wiggle than a single pure
/// tone, and the whole signal scrolls leftward at ~5 Hz so the wave
/// visibly flows across the pill instead of standing still.
///
/// Used in two places:
/// 1. The notch HUD pill — replaces the play/pause/skip cluster on the
///    right edge so the pill reads as a status indicator first and a
///    transport remote second. (Transport stays in the main panel's
///    Music page.)
/// 2. The Music page — small badge near the source credit, gives the
///    expanded player the same "alive while playing" tell the closed
///    pill has, without competing with the larger artwork for attention.
struct WaveformView: View {
    let isPlaying: Bool

    /// Drawing width in points. Defaults size up the visualizer for
    /// the pill; pass smaller for the music-page source badge.
    var width: CGFloat = 26
    /// Drawing height in points. The wave occupies the central
    /// `height * 2 * amplitudeMul` band; the rest is breathing room
    /// so peaks don't clip against the line cap.
    var height: CGFloat = 14
    /// Stroke width — 1.6pt reads as confident at retina scale without
    /// turning into a thick line that hides the curvy silhouette.
    var lineWidth: CGFloat = 1.6
    /// Tint applied to the stroke. Defaults to `Color.white` so the view
    /// works on any dark background; pass an explicit color for callers
    /// that need brand alignment.
    var tint: Color = .white
    /// Foreground opacity. Used to dial the wave down to a quiet
    /// secondary-info brightness — it's decorative, not the focal
    /// point.
    var opacity: Double = 0.85

    var body: some View {
        // TimelineView re-evaluates the body at each refresh. Inside the
        // closure we recompute the entire path from `context.date` —
        // cheap because Canvas just walks the path once per frame, no
        // SwiftUI view diffing per-sample. `paused: !isPlaying` halts
        // the timeline when playback pauses; the closure is then never
        // re-invoked, so the view freezes at the last drawn frame
        // (visually equivalent to a "muted, ready" state).
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !isPlaying)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                var path = Path()
                // 32 vertices is enough for the curve to read smooth at
                // retina at the sizes we use (≤ 28pt wide). Higher counts
                // pay diminishing returns — the line cap rounds out any
                // remaining angularity at the joints.
                let steps = 32
                // Idle amplitude is a barely-perceptible wobble — the
                // user reads "audio is loaded but quiet" rather than
                // "view is broken / blank."
                let amplitudeMul: Double = isPlaying ? 0.42 : 0.05
                for i in 0...steps {
                    let t = Double(i) / Double(steps)
                    let x = CGFloat(t) * size.width
                    // Two summed sinusoids at incommensurate frequencies
                    // (4.0 and 6.5 cycles across the width) — the sum
                    // never repeats periodically, so the wave doesn't
                    // settle into a recognizable static pattern. Phase
                    // scrolls leftward at different rates per component
                    // (5.0 vs 3.2 rad/s), so the two layers visibly
                    // beat against each other — adds the "live signal"
                    // feeling that a single pure tone misses.
                    let p1 = t * 4.0 * .pi - time * 5.0
                    let p2 = t * 6.5 * .pi - time * 3.2
                    let signal = sin(p1) * 0.65 + sin(p2) * 0.35
                    let y = size.height / 2 + CGFloat(signal * amplitudeMul) * size.height
                    if i == 0 {
                        path.move(to: CGPoint(x: x, y: y))
                    } else {
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                }
                ctx.stroke(
                    path,
                    with: .color(tint.opacity(opacity)),
                    style: StrokeStyle(
                        lineWidth: lineWidth,
                        lineCap: .round,
                        lineJoin: .round
                    )
                )
            }
            .frame(width: width, height: height)
        }
        .frame(width: width, height: height)
        // Kill default accessibility; the waveform is decorative. The
        // surrounding view (pill, badge) carries the actual semantics.
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
