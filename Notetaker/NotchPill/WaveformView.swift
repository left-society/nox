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
    /// Optional rhythmic pattern that drives the amplitude envelope.
    /// When provided, the wave's height pulses to a programmatically-
    /// generated beat structure (kick, swell, fills) instead of a
    /// continuous sine — gives the visualizer the LOOK of real audio
    /// without needing system audio capture. Pick one per track via
    /// `WaveformPattern.deterministic(for:)` for stable per-track
    /// visual identity.
    var pattern: WaveformPattern = .midtempo

    var body: some View {
        // TimelineView re-evaluates the body at each refresh. Inside the
        // closure we recompute the entire path from `context.date` —
        // cheap because Canvas just walks the path once per frame, no
        // SwiftUI view diffing per-sample. `paused: !isPlaying` halts
        // the timeline when playback pauses; the closure is then never
        // re-invoked, so the view freezes at the last drawn frame
        // (visually equivalent to a "muted, ready" state).
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !isPlaying)) { context in
            // Fold the absolute reference-date time (currently ~7.6e8
            // and growing ~3e7/year) into a small repeating window
            // before feeding it into sin(). For very large arguments,
            // sin/cos lose precision because each radian represents
            // a smaller fraction of the magnitude. Folding by
            // `2π * 1000` keeps the value < ~6283 — comfortably below
            // the precision-loss regime — while preserving the visual
            // continuity (the wave loops every 1000 seconds, longer
            // than any reasonable continuous viewing session).
            let raw = context.date.timeIntervalSinceReferenceDate
            let foldedTime = raw.truncatingRemainder(dividingBy: 2 * .pi * 1000)
            let time = foldedTime.isFinite ? foldedTime : 0
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
                // Rhythmic envelope from the selected pattern — drives
                // the wave's height as if it were sampling a real
                // audio signal. Each pattern has its own BPM and
                // dynamic feel (kick spikes, swells, fills); the
                // visualizer pulses in time with that simulated
                // beat instead of a continuous sine.
                let envelope = pattern.envelope(at: time)
                let envFinite = envelope.isFinite ? envelope : 1.0
                let amplitudeMul: Double = (isPlaying ? 0.55 : 0.05) * envFinite
                for i in 0...steps {
                    let t = Double(i) / Double(steps)
                    let x = CGFloat(t) * size.width
                    // FOUR summed sinusoids at incommensurate
                    // frequencies. Each has a different spatial
                    // frequency (cycles across the width) AND a
                    // different phase scroll rate, with no integer
                    // ratios between them — the sum never repeats
                    // periodically and never falls into a
                    // recognizable static pattern. Mixing weights
                    // (0.45/0.28/0.18/0.09) put most energy in the
                    // low-frequency carrier with progressively
                    // smaller contributions from higher harmonics —
                    // gives a "natural musical" silhouette rather
                    // than a synthetic pure-tone sawtooth feel.
                    let p1 = t * 3.4 * .pi - time * 4.7
                    let p2 = t * 5.9 * .pi - time * 3.1
                    let p3 = t * 9.1 * .pi - time * 6.3
                    let p4 = t * 13.7 * .pi - time * 2.4
                    let signal = sin(p1) * 0.45
                                + sin(p2) * 0.28
                                + sin(p3) * 0.18
                                + sin(p4) * 0.09
                    // Final NaN/inf guard — if any sin() returned a
                    // non-finite value (vanishingly unlikely with the
                    // folded `time`, but cheap to enforce), fall
                    // back to the centerline so we draw a flat line
                    // rather than corrupting the Canvas path.
                    let safeSignal = signal.isFinite ? signal : 0
                    let y = size.height / 2 + CGFloat(safeSignal * amplitudeMul) * size.height
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
