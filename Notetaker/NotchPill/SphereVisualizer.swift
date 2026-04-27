import AppKit
import SwiftUI

/// Rotating particle-cloud sphere visualizer for the music slab —
/// the Pinterest-style point-cloud orb the user shared. Driven from
/// AppKit (NSView + Timer) instead of SwiftUI's Canvas+TimelineView
/// because the SwiftUI path went dormant the moment no other
/// animation was running in the slab — user reported "It's a single
/// png now."
///
/// Audio reactivity is **synthetic**: we don't tap CoreAudio output
/// for live amplitude (would require a permission prompt the user
/// hasn't approved). Instead, `SyntheticAudioSource` mixes a slow
/// bass sine, a faster mid sine, and a beat-pulse spike to fake the
/// energy envelope of a track. The sphere breathes and pops on
/// these synthetic beats — looks alive, no permissions needed. If
/// we ever wire in real CATap-driven amplitude, only the call to
/// `SyntheticAudioSource.amplitude(at:)` needs to swap out.
struct SphereVisualizer: NSViewRepresentable {
    var isPlaying: Bool
    /// True when the sphere should freeze its 60Hz redraw cycle —
    /// typically when the panel is in resting-pill mode and the
    /// sphere is invisible (opacity 0) but still mounted in the
    /// always-mounted content tree. Without this, the sphere ticks
    /// and redraws 60×/sec on the main thread for nothing, stealing
    /// runloop slots from the panel-open morph and contributing to
    /// the jitter the user reported.
    var isPaused: Bool = false
    /// Edge length of the rendered square. 36–48pt is the sweet
    /// spot in the music slab — smaller and the particles read as
    /// static noise, larger and they look sparse.
    var size: CGFloat = 40
    var tint: Color = .white

    func makeNSView(context: Context) -> SphereVisualizerNSView {
        let v = SphereVisualizerNSView()
        v.frame = NSRect(x: 0, y: 0, width: size, height: size)
        v.translatesAutoresizingMaskIntoConstraints = false
        v.isPlaying = isPlaying
        v.isPaused = isPaused
        v.tintColor = NSColor(tint)
        return v
    }

    func updateNSView(_ nsView: SphereVisualizerNSView, context: Context) {
        nsView.isPlaying = isPlaying
        nsView.isPaused = isPaused
        nsView.tintColor = NSColor(tint)
    }

    @MainActor
    static var sizeThatFits: CGSize { CGSize(width: 40, height: 40) }
}

/// Pure AppKit view that owns its own redraw timer. SwiftUI wraps
/// this via `NSViewRepresentable`. Drawing is direct CGContext
/// fillEllipse calls per particle — at ~140 particles × 60Hz the
/// cost is well under a millisecond per frame on M-series.
@MainActor
final class SphereVisualizerNSView: NSView {

    var isPlaying: Bool = true {
        didSet {
            // No state reset — keep `time` advancing so the orb
            // doesn't jolt when playback toggles. Rotation rate
            // ramps via the `speed` calc in tick().
        }
    }
    /// External pause flag from the SwiftUI wrapper. When true the
    /// 60Hz timer is suspended entirely (zero CPU, zero needsDisplay
    /// calls). The pre-pause `time` value is retained so resuming
    /// picks up exactly where the sphere left off.
    var isPaused: Bool = false {
        didSet {
            if isPaused {
                timer?.invalidate()
                timer = nil
            } else if window != nil, timer == nil {
                startTimer()
            }
        }
    }
    var tintColor: NSColor = .white

    /// Advancing accumulator. Decoupled from wall-clock so we can
    /// slow the rotation when paused without freezing it.
    private var time: CFTimeInterval = 0
    private var lastTickAt: CFTimeInterval = 0
    /// Synthetic amplitude in [0, 1] — drives the breath pulse and
    /// the per-particle size+brightness boost.
    private var amplitude: Double = 0
    private var timer: Timer?

    /// Pre-baked unit-sphere positions on a fibonacci lattice.
    /// `phi = π · (3 − √5)`. y descends linearly from 1 to −1; the
    /// radius at that latitude is √(1 − y²); longitude steps by phi.
    /// Result: near-uniform spacing without the seams a lat/lon
    /// grid produces. Shared static so all instances reuse one
    /// 140-element float array (~3.4 KB).
    private static let particles: [SIMD3<Float>] = {
        let count = 140
        let phi = Float.pi * (3.0 - sqrt(5.0))
        var pts: [SIMD3<Float>] = []
        pts.reserveCapacity(count)
        for i in 0..<count {
            let y = 1.0 - (Float(i) / Float(count - 1)) * 2.0
            let r = sqrtf(max(0, 1.0 - y * y))
            let theta = phi * Float(i)
            pts.append(SIMD3(cosf(theta) * r, y, sinf(theta) * r))
        }
        return pts
    }()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        startTimer()
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        timer?.invalidate()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { timer?.invalidate(); timer = nil }
        else if timer == nil, !isPaused { startTimer() }
    }

    private func startTimer() {
        timer?.invalidate()
        // 60Hz timer in .common modes — keeps firing during scroll
        // tracking, menu interaction, and any other modal runloop
        // mode the panel could be in.
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let dt = lastTickAt == 0 ? 1.0 / 60.0 : (now - lastTickAt)
        lastTickAt = now

        // When paused, advance time at 18% so the orb still drifts
        // gently — looks "alive" without being energetic.
        let speedMul = isPlaying ? 1.0 : 0.18
        time += dt * speedMul

        // Synthetic amplitude envelope. Three layered components:
        //   • bass: slow 0.45Hz pulse, simulates kick drum cadence
        //   • mid: faster 0.85Hz sine, simulates vocal/instrument
        //   • beat: thresholded sine that spikes briefly above 0
        //     every ~1.7s — fakes the "beat hit" we want particles
        //     to react to.
        // Sum is clamped to [0, 1]. When paused, amplitude → 0 over
        // a few frames so the breath relaxes to neutral.
        let t = Float(time)
        let bass = (sin(t * 2.83) + 1) * 0.5            // 0..1
        let mid = (sin(t * 5.34 + 0.9) + 1) * 0.5       // 0..1
        let beatRaw = sin(t * 3.7)
        let beat = beatRaw > 0.78 ? Double((beatRaw - 0.78) / 0.22) : 0
        let target = isPlaying
            ? min(1.0, Double(bass) * 0.35 + Double(mid) * 0.25 + beat * 0.65)
            : 0
        // Lerp toward target with mild smoothing so beats land
        // sharply but the decay isn't a square wave.
        amplitude += (target - amplitude) * 0.28

        needsDisplay = true
    }

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let t = Float(time)

        // Y-axis spin: one full revolution every ~6.6s at full
        // speed. Pitch wobble adds a slow tilt so the user sees
        // both poles of the lattice over time, selling the 3D
        // shape.
        let yaw = t * 0.95
        let pitch = sin(t * 0.4) * 0.25

        // Breath couples to amplitude. At amplitude 0 the radius
        // is 0.95× of the frame; on a beat hit it punches up to
        // ~1.08× before the smoothing pulls it back. The motion
        // is what makes the sphere read as "responding to music."
        let breath = 0.95 + Float(amplitude) * 0.13

        let cx = bounds.midX
        let cy = bounds.midY
        let radius = (Float(min(bounds.width, bounds.height)) * 0.5 - 1) * breath

        let cy_ = cosf(yaw),  sy_ = sinf(yaw)
        let cp_ = cosf(pitch), sp_ = sinf(pitch)

        // Premultiply alpha into the tint once so the per-particle
        // loop is just an alpha-scale rather than a re-extract of
        // RGB components from NSColor each iteration.
        guard let baseColor = tintColor.usingColorSpace(.sRGB) else { return }
        let r = baseColor.redComponent
        let g = baseColor.greenComponent
        let b = baseColor.blueComponent

        for p in Self.particles {
            // Yaw around Y, pitch around X.
            let x1 = p.x * cy_ + p.z * sy_
            let z1 = -p.x * sy_ + p.z * cy_
            let y1 = p.y * cp_ - z1 * sp_
            let z2 = p.y * sp_ + z1 * cp_

            // Orthographic projection — perspective adds visible
            // bulge that fights the rotation read; flat keeps the
            // sphere clean against the slab artwork.
            let px = CGFloat(x1) * CGFloat(radius) + cx
            let py = CGFloat(y1) * CGFloat(radius) + cy

            // Depth shading: front bright, back dim. z ∈ [-1, 1].
            // Maps to alpha ∈ [0.16, 1.0].
            let depth = Double((z2 + 1) * 0.5)  // 0=back, 1=front
            // Brightness boost on beats — front-facing particles
            // glow harder when amplitude spikes, so the user sees
            // a visible "hit" on every synthetic beat.
            let alpha = (0.16 + depth * 0.84) * (0.85 + amplitude * 0.4)

            // Particle size: depth + amplitude. Back particles ~0.7pt,
            // front ~1.7pt, plus up to +60% on full amplitude.
            let dotSize = CGFloat(0.7 + depth * 1.0) * (1 + CGFloat(amplitude) * 0.6)

            ctx.setFillColor(red: r, green: g, blue: b, alpha: CGFloat(min(1.0, alpha)))
            ctx.fillEllipse(in: CGRect(
                x: px - dotSize / 2,
                y: py - dotSize / 2,
                width: dotSize,
                height: dotSize
            ))
        }
    }
}

#Preview {
    HStack(spacing: 24) {
        SphereVisualizer(isPlaying: true, size: 40)
        SphereVisualizer(isPlaying: false, size: 40)
        SphereVisualizer(isPlaying: true, size: 100, tint: .cyan)
    }
    .padding()
    .background(Color.black)
}
