import SwiftUI

/// Resting-pill content shown when the dictation orchestrator is
/// recording or transcribing. Renders inside the same notch-pill
/// silhouette the music HUD uses — left wing of the notch hosts
/// a phase-indicator (recording dot, transcribing glyph, error
/// glyph), right wing hosts the waveform. Mirroring the music
/// pill's geometry exactly so SwiftUI lays it out the same way:
/// `HStack(spacing: 6)` with a 22×22 indicator slot + Spacer +
/// 26×18 waveform slot. No outer wrapper or `Color.clear`
/// expander — those collapsed the layout in earlier iterations
/// because they competed with the `.overlay(alignment: .top)`
/// host's intrinsic sizing.
///
/// Phase morphs in place: the indicator and waveform are single
/// ZStacks holding all phase variants, switched via opacity. No
/// re-mount per phase, so positions stay rock-solid through
/// recording → transcribing → error.
///
/// FreeFlow's RecordingOverlay (zachlatta/freeflow) was the
/// reference for the waveform amplitude curve — same `0.5 + 0.5
/// * sin(...)` traveling-wave + shimmer recipe so the bars feel
/// alive even during silence.
struct DictationPillContent: View {
    let phase: PanelPresenter.DictationPhase
    /// Live mic RMS in [0,1]. Drives waveform amplitude + dot
    /// glow when `phase == .recording`; ignored otherwise.
    let audioLevel: Float

    /// Sized to match `musicPillContent`'s exact dimensions
    /// (pillArtwork = 22×22, WaveformView = 26×18) — same
    /// vertical rhythm so the dictation pill and music pill
    /// share one visual identity. The HORIZONTAL expansion
    /// happens at the host-panel level (PanelWindowController.
    /// dictationPillWidth = 420 vs the resting 278pt). With the
    /// wider host pill, the Spacer between indicator and
    /// waveform pushes them onto OPPOSITE wings of the notch
    /// with substantially more breathing room than the music
    /// pill has — that's the visible "expansion" the user sees.
    private let indicatorSize: CGFloat = 22
    private let waveformWidth: CGFloat = 26
    private let waveformHeight: CGFloat = 18

    var body: some View {
        HStack(spacing: 6) {
            indicatorSlot
                .frame(width: indicatorSize, height: indicatorSize)

            Spacer(minLength: 0)

            waveformSlot
                .frame(width: waveformWidth, height: waveformHeight)
        }
        .onAppear {
            DictationOrchestrator.dlog("DictationPillContent.onAppear — phase=\(phase)")
        }
        .onDisappear {
            DictationOrchestrator.dlog("DictationPillContent.onDisappear — phase=\(phase)")
        }
    }

    // MARK: - Indicator slot (left wing of the notch)

    /// Single ZStack — every phase variant always rendered, opacity
    /// swaps them. Animations interpolate between phases without
    /// view re-mount, so the indicator's position never jumps.
    private var indicatorSlot: some View {
        ZStack {
            recordingDot
                .opacity(phase == .recording ? 1 : 0)
                .scaleEffect(phase == .recording ? 1 : 0.6, anchor: .center)

            transcribingGlyph
                .opacity(phase == .transcribing ? 1 : 0)
                .scaleEffect(phase == .transcribing ? 1 : 0.6, anchor: .center)

            errorGlyph
                .opacity(phase.isError ? 1 : 0)
                .scaleEffect(phase.isError ? 1 : 0.6, anchor: .center)
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.72), value: phase.indicatorKey)
    }

    /// Red recording dot with audio-reactive pulse + a continuous
    /// "breath" sine wave so the dot is never frozen during silence.
    /// The blurred halo + sharp core composite gives "pulse with
    /// depth" rather than a flat scaling circle. Halo is bounded
    /// inside the 22×22 indicator frame — does NOT bleed into the
    /// rest of the pill.
    private var recordingDot: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let breath = 0.5 + 0.5 * sin(t * 4.4)  // [0, 1]
            let levelClamped = Double(min(audioLevel, 1.0))
            // Audio dominates; breath is a quiet floor so silence
            // still has visible motion.
            let energy = levelClamped * 0.85 + breath * 0.15

            ZStack {
                // Outer halo — soft, blurred, scales with energy.
                // Sized for the 22×22 indicator slot. Stays
                // bounded inside the slot even at peak scale.
                Circle()
                    .fill(Color(red: 1.0, green: 0.27, blue: 0.27))
                    .frame(width: 11, height: 11)
                    .blur(radius: 3)
                    .scaleEffect(1.3 + CGFloat(energy) * 0.7)
                    .opacity(0.55 + energy * 0.40)

                // Core dot — sharp red, modest audio-reactive scale.
                Circle()
                    .fill(Color(red: 1.0, green: 0.27, blue: 0.27))
                    .frame(width: 11, height: 11)
                    .shadow(
                        color: Color(red: 1.0, green: 0.30, blue: 0.30).opacity(0.95),
                        radius: 3 + CGFloat(energy) * 4
                    )
                    .scaleEffect(1.0 + CGFloat(energy) * 0.25)
            }
        }
    }

    /// Pulsing waveform glyph for transcribing phase. Self-pulses
    /// via TimelineView since there's no audio level to drive it.
    private var transcribingGlyph: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let pulse = 0.65 + 0.35 * sin(t * 3.5)
            Image(systemName: "waveform")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(pulse))
                .scaleEffect(0.95 + CGFloat(pulse - 0.65) * 0.15)
        }
    }

    private var errorGlyph: some View {
        Image(systemName: "exclamationmark.circle.fill")
            .font(.system(size: 13))
            .foregroundStyle(Color(red: 1.0, green: 0.45, blue: 0.45))
    }

    // MARK: - Waveform slot (right wing of the notch)

    private var waveformSlot: some View {
        ZStack {
            DictationWaveform(audioLevel: audioLevel, autoPulse: true)
                .opacity(phase == .recording ? 1 : 0)

            DictationProcessingWaveform()
                .opacity(phase == .transcribing ? 1 : 0)

            // Idle / error: empty slot (waveform fades out).
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.72), value: phase.waveformKey)
    }
}

// MARK: - Phase keys (used as `value` for `.animation(_:value:)`)

private extension PanelPresenter.DictationPhase {
    var indicatorKey: Int {
        switch self {
        case .idle: return 0
        case .recording: return 1
        case .transcribing: return 2
        case .error: return 3
        }
    }

    var waveformKey: Int { indicatorKey }

    var isError: Bool {
        if case .error = self { return true } else { return false }
    }
}

// MARK: - Live audio waveform (recording state)

struct DictationWaveform: View {
    let audioLevel: Float
    var autoPulse: Bool = true

    private static let barCount = 9
    private static let multipliers: [CGFloat] = [0.35, 0.55, 0.75, 0.9, 1.0, 0.9, 0.75, 0.55, 0.35]
    private static let centerIndex = CGFloat((barCount - 1) / 2)

    /// Bar geometry — sized for the 26×18 waveform slot in the
    /// resting-pill height. Matches the music pill's WaveformView
    /// width/height budget so the two visualizers share the same
    /// visual rhythm. The HORIZONTAL expansion happens at the
    /// host-panel level (PanelWindowController.dictationPillWidth);
    /// the waveform itself stays at music-pill size, just sits
    /// further from the notch on the wider wing.
    private static let barWidth: CGFloat = 2.0
    private static let barSpacing: CGFloat = 1.0
    private static let minHeight: CGFloat = 3.0
    private static let maxHeight: CGFloat = 16.0

    var body: some View {
        Group {
            if autoPulse {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                    bars(pulseTime: context.date.timeIntervalSinceReferenceDate)
                }
            } else {
                bars(pulseTime: nil)
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func bars(pulseTime: TimeInterval?) -> some View {
        HStack(spacing: Self.barSpacing) {
            ForEach(0..<Self.barCount, id: \.self) { index in
                Capsule()
                    .fill(.white)
                    .frame(
                        width: Self.barWidth,
                        height: Self.minHeight + (Self.maxHeight - Self.minHeight) * amplitude(for: index, pulseTime: pulseTime)
                    )
                    .animation(
                        .spring(
                            response: 0.16 + responseDistance(for: index) * 0.06,
                            dampingFraction: 0.82
                        ).delay(barDelay(for: index)),
                        value: audioLevel
                    )
            }
        }
        .frame(maxHeight: .infinity)
    }

    /// FreeFlow's amplitude recipe (verbatim with a slightly higher
    /// quietPulse floor so silence has visibly dancing bars on
    /// Notetaker's smaller waveform footprint).
    private func amplitude(for index: Int, pulseTime: TimeInterval?) -> CGFloat {
        let level = CGFloat(max(audioLevel, 0))
        let baseAmplitude = min(level * Self.multipliers[index], 1.0)

        guard let pulseTime else { return baseAmplitude }

        let travelingWave = CGFloat(0.5 + 0.5 * sin((pulseTime * 6.2) - Double(index) * 0.78))
        let shimmer = CGFloat(0.5 + 0.5 * sin((pulseTime * 3.1) + Double(index) * 0.5))
        let pulse = travelingWave * 0.28 + shimmer * 0.10

        let saturationRelief = baseAmplitude * (0.74 + pulse)
        let quietPulse = (1.0 - baseAmplitude) * (0.10 + pulse * 0.40)
        return min(saturationRelief + quietPulse, 1.0)
    }

    private func responseDistance(for index: Int) -> Double {
        let distance = abs(CGFloat(index) - Self.centerIndex)
        return Double(distance / Self.centerIndex)
    }

    private func barDelay(for index: Int) -> Double {
        let distance = abs(CGFloat(index) - Self.centerIndex)
        return Double(distance) * 0.01
    }
}

// MARK: - Processing waveform (transcribing state)

struct DictationProcessingWaveform: View {
    private static let barCount = 9
    private static let multipliers: [CGFloat] = [0.42, 0.58, 0.76, 0.9, 1.0, 0.9, 0.76, 0.58, 0.42]
    private static let barWidth: CGFloat = 2.0
    private static let barSpacing: CGFloat = 1.0
    private static let minHeight: CGFloat = 3.0
    private static let maxHeight: CGFloat = 16.0

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: Self.barSpacing) {
                ForEach(0..<Self.barCount, id: \.self) { index in
                    let wave = 0.5 + 0.5 * sin((time * 5.6) - Double(index) * 0.5)
                    let shimmer = 0.5 + 0.5 * sin((time * 2.8) + Double(index) * 0.75)
                    let amplitude = min(
                        0.16 + CGFloat(wave) * Self.multipliers[index] * 0.52 + CGFloat(shimmer) * 0.08,
                        1.0
                    )
                    Capsule()
                        .fill(.white)
                        .frame(
                            width: Self.barWidth,
                            height: Self.minHeight + (Self.maxHeight - Self.minHeight) * amplitude
                        )
                        .opacity(0.45 + CGFloat(wave) * 0.5)
                }
            }
            .frame(maxHeight: .infinity)
        }
    }
}
