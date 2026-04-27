import Foundation

/// Rhythmic envelope generator for `WaveformView`. Each case is a
/// procedurally-generated "music-like" amplitude curve that pulses
/// with a specific BPM and stylistic feel — kick on the downbeat,
/// slow swells over measures, occasional fills. Combined with the
/// underlying sine-wave silhouette in `WaveformView`, this gives the
/// visualizer the LOOK of a real audio waveform without needing
/// system audio capture.
///
/// Five distinct patterns cover the major BPM/feel ranges:
///   - `.downtempo`  — 75 BPM, soft ambient swells
///   - `.lofi`       — 88 BPM, gentle hip-hop swing
///   - `.midtempo`   — 102 BPM, steady pop pulse
///   - `.uptempo`    — 124 BPM, energetic dance kick
///   - `.driving`    — 140 BPM, hard rock attack
///
/// Per-track selection: call `WaveformPattern.deterministic(for:)`
/// with the track key — the pattern is hashed-stable, so the same
/// song always gets the same visualizer feel (consistent visual
/// identity per track), and different songs cycle through the set.
enum WaveformPattern: CaseIterable {
    case downtempo
    case lofi
    case midtempo
    case uptempo
    case driving

    /// Tempo in beats per minute. Drives the kick spike spacing.
    var bpm: Double {
        switch self {
        case .downtempo: return 75
        case .lofi:      return 88
        case .midtempo:  return 102
        case .uptempo:   return 124
        case .driving:   return 140
        }
    }

    /// Sharpness of the kick attack. Higher = tighter, more
    /// percussive spike. Lower = softer, more rounded swell.
    var kickAttack: Double {
        switch self {
        case .downtempo: return 5.0
        case .lofi:      return 6.0
        case .midtempo:  return 8.0
        case .uptempo:   return 10.0
        case .driving:   return 14.0
        }
    }

    /// Per-pattern envelope at the given time. Returns a multiplier
    /// in roughly [0.4, 1.4] that scales the base wave amplitude.
    /// Combines:
    ///   1. Kick — sharp spike on every beat (decays fast)
    ///   2. Swell — slow rise/fall over each 4-beat measure
    ///   3. Fill — occasional accent every 8 beats (rolling ghost
    ///      hits between the main kicks)
    ///   4. Texture — fine high-frequency wobble
    ///
    /// Time is `Date.timeIntervalSinceReferenceDate` — a number in
    /// the ~7.6e8 range today, growing ~3e7 per year. After a few
    /// hours of uptime the raw `time` is ≥ 7.6e8; multiplying by 13.7
    /// inside `sin()` doesn't lose precision, but the floor of the
    /// truncatingRemainder operation does start to drift if we do
    /// large divisions first. We pre-fold time by the longest period
    /// (8 beats) to keep all downstream arithmetic in a small range,
    /// and clamp the final result so an unexpected NaN/inf can never
    /// scale the wave amplitude to a non-finite value.
    func envelope(at time: Double) -> Double {
        let beatInterval = 60.0 / bpm
        // Fold time into an 8-beat window first. This keeps every
        // downstream `truncatingRemainder` operating on values in
        // [0, 8 * beatInterval] regardless of how long the app has
        // been running, avoiding precision loss at large `time`.
        let folded = time.truncatingRemainder(dividingBy: 8 * beatInterval)
        let safeFolded = folded.isFinite ? folded : 0
        let beatTime = safeFolded / beatInterval
        let beatPhase = beatTime.truncatingRemainder(dividingBy: 1)
        let measurePhase = (beatTime / 4).truncatingRemainder(dividingBy: 1)
        let fillPhase = (beatTime / 8).truncatingRemainder(dividingBy: 1)

        // Kick: sharp exponential decay on every beat. `kickAttack`
        // controls the decay rate — bigger = tighter spike.
        let kick = exp(-beatPhase * kickAttack) * 0.55

        // Swell: gentle sin over each 4-beat measure. Adds a
        // "verse breathing" feel between kicks.
        let swell = (sin(measurePhase * 2 * .pi - .pi / 2) + 1) * 0.18

        // Fill: tiny ghost-hit accents on the half-beat over an
        // 8-beat cycle, giving the pattern a rolling rhythmic
        // texture between the main kicks.
        let halfBeat = (beatPhase * 2).truncatingRemainder(dividingBy: 1)
        let fillStrength = max(0, 1 - abs(fillPhase - 0.625) * 5) * 0.15
        let fill = exp(-halfBeat * 6) * fillStrength

        // Texture: separately folded into a tight period so the
        // multiply-by-13.7 inside sin() never trips precision. 1Hz
        // base period means we fold time mod 1.0 first.
        let textTime = time.truncatingRemainder(dividingBy: 1.0)
        let texture = sin(textTime * 13.7 * 2 * .pi) * 0.08

        let raw = 0.45 + kick + swell + fill + texture
        // Defensive clamp — if any of the components ever produce
        // a non-finite value, fall back to the idle baseline rather
        // than letting NaN propagate into Canvas geometry.
        return raw.isFinite ? raw : 0.45
    }

    /// Pick a pattern deterministically from a string key (e.g.
    /// trackKey = "title|artist"). Same key → same pattern, so
    /// each song has a stable visual identity. Different songs
    /// cycle through the five available patterns.
    ///
    /// Uses an FNV-1a-style positional hash rather than a simple
    /// scalar sum — the previous implementation collided trivially
    /// (anagrams hashed identically: "ab" == "ba"). With only 5
    /// pattern buckets the practical impact was small, but a real
    /// hash gives a better distribution across the catalog and
    /// costs essentially nothing.
    static func deterministic(for key: String) -> WaveformPattern {
        guard !key.isEmpty else { return .midtempo }
        var hash: UInt64 = 0xcbf29ce484222325 // FNV-1a 64-bit offset
        for scalar in key.unicodeScalars {
            hash ^= UInt64(scalar.value)
            hash = hash &* 0x100000001b3 // FNV prime
        }
        let all = WaveformPattern.allCases
        let bucket = Int(hash % UInt64(all.count))
        return all[bucket]
    }
}
