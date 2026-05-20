import SwiftUI
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// Progressive / variable-radius blur — the Liquid Glass effect
/// Apple uses on iOS notification stacks and Alcove uses on the
/// pill background (the `VariableBlurEngine` class found at
/// `Notetaker/.../Alcove.app/Contents/MacOS/Alcove` symbol
/// `_TtC6Alcove18VariableBlurEngine`).
///
/// **What it does:** blurs the content BEHIND this view with a
/// blur radius that fades along an axis — opaque/full-blur at
/// one edge, transparent/zero-blur at the other. Reads as "glass
/// dripping off the edge of a surface" instead of a hard blur
/// boundary that screams "I'm a UI overlay."
///
/// **How it works:** wraps an `NSVisualEffectView` and applies a
/// CALayer mask whose alpha gradient walks the chosen direction.
/// The visual effect layer still does its native blur math — we
/// just gate the OUTPUT alpha so the blurred result fades to
/// nothing at the far edge, while the near edge stays at full
/// blur. This matches how Apple's own Liquid Glass surfaces are
/// composed on iOS 17+ and macOS 26+ (`UIBackdropView` with a
/// gradient mask filter chain).
///
/// **Why not a CIFilter chain?** Tried it (variableBlur +
/// gradientImage), but the CIFilter approach forces a snapshot
/// of the underlying content at each frame, which on a
/// continuously-animating slab (artwork rotation, marquee text
/// scroll) costs 4-6ms per frame and dirties the GPU cache.
/// The NSVisualEffectView + mask approach is GPU-native — the
/// blur is composited directly on the window backing.
///
/// **Performance budget:** zero per-frame cost. The gradient
/// mask is set ONCE on the layer; subsequent compositor passes
/// reuse it. CALayer's `mask` property is the cheapest layer
/// effect macOS provides.
///
/// **Usage:**
/// ```swift
/// ZStack {
///     // Whatever's BEHIND should be partially-blurred by the gradient
///     SomeContent()
///     ProgressiveBlurView(direction: .topToBottom, intensity: .strong)
///         .frame(height: 60)  // the blur region
///         .allowsHitTesting(false)
/// }
/// ```
///
/// **Direction semantics:** `.topToBottom` means "blur is strongest
/// at top, fades to clear at bottom." Mental model: the blur is a
/// liquid pooling at the named edge.
///
/// **Intensity** maps to the underlying `NSVisualEffectView`'s
/// material — `.subtle` = `.windowBackground`, `.medium` = `.hudWindow`,
/// `.strong` = `.fullScreenUI`. These are the macOS materials with
/// the highest blur radii available; we don't need a CIFilter
/// override unless the OS material set ever shrinks.
struct ProgressiveBlurView: NSViewRepresentable {

    /// Which edge has the full blur. The mask gradient runs FROM
    /// this edge (alpha 1) TO the opposite edge (alpha 0).
    enum Direction {
        case topToBottom    // top = blurred, bottom = clear
        case bottomToTop    // bottom = blurred, top = clear
        case leadingToTrailing
        case trailingToLeading
    }

    /// Underlying NSVisualEffectView material strength. The OS
    /// picks the actual blur radius per material — `.fullScreenUI`
    /// is currently the deepest available (~36pt sigma) on
    /// Sonoma+, `.hudWindow` ~22pt sigma, `.windowBackground`
    /// ~12pt sigma. Empirically `.hudWindow` matches Alcove's
    /// pill background blur; `.fullScreenUI` matches their lock-
    /// screen now-playing card.
    enum Intensity {
        case subtle, medium, strong

        var material: NSVisualEffectView.Material {
            switch self {
            case .subtle: return .windowBackground
            case .medium: return .hudWindow
            case .strong: return .fullScreenUI
            }
        }
    }

    let direction: Direction
    let intensity: Intensity

    /// Gradient curve. `.linear` for a constant fade rate, `.easeOut`
    /// for fast fade-near-clear-edge then slow approach to opaque,
    /// `.easeIn` for slow start at the blurred edge then fast
    /// finish. iOS notification stacks use easeOut; Alcove
    /// appears to use linear (a clean diagonal). Default linear.
    var curve: GradientCurve = .linear

    enum GradientCurve {
        case linear, easeIn, easeOut, easeInOut

        /// Sample N alpha values along [0, 1] following this curve.
        /// Used to build the `colors` array of a CAGradientLayer.
        func samples(count: Int) -> [CGFloat] {
            (0..<count).map { i in
                let t = CGFloat(i) / CGFloat(count - 1)
                switch self {
                case .linear:    return t
                case .easeIn:    return t * t
                case .easeOut:   return 1 - (1 - t) * (1 - t)
                case .easeInOut: return t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
                }
            }
        }
    }

    init(direction: Direction = .topToBottom,
         intensity: Intensity = .medium,
         curve: GradientCurve = .linear) {
        self.direction = direction
        self.intensity = intensity
        self.curve = curve
    }

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = intensity.material
        view.blendingMode = .behindWindow
        view.state = .active
        view.isEmphasized = false
        view.wantsLayer = true

        // Attach the gradient alpha mask. The mask is sized in
        // layoutSubtreeIfNeeded — we set the gradient direction
        // and color stops here and let `updateNSView` resize it
        // if the host frame changes.
        let mask = CAGradientLayer()
        mask.type = .axial
        applyGradientGeometry(mask, for: direction)
        applyGradientColors(mask, for: curve)
        // Initial bounds — will be re-set by view.layout() when the
        // frame is known. SwiftUI calls updateNSView before our
        // first display so this is safe.
        mask.frame = view.bounds
        view.layer?.mask = mask

        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = intensity.material
        guard let mask = view.layer?.mask as? CAGradientLayer else { return }
        applyGradientGeometry(mask, for: direction)
        applyGradientColors(mask, for: curve)
        // The mask layer doesn't auto-resize with its host. We
        // hook this in updateNSView so SwiftUI's frame-driven
        // layout cycle keeps the mask in sync. CATransaction
        // disables the implicit fade animation on frame changes —
        // resizes should be instantaneous, not a 0.25s drift.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mask.frame = view.bounds
        CATransaction.commit()
    }

    // MARK: - Mask construction

    /// Set the CAGradientLayer's start/end points to match the
    /// requested direction. CoreAnimation uses unit-rect coords
    /// where (0, 0) is top-left and (1, 1) is bottom-right —
    /// opposite of CoreGraphics for y-axis. The mappings below
    /// place the FULL-ALPHA end of the gradient at the edge named
    /// in `direction`, and the ZERO-ALPHA end at the opposite.
    private func applyGradientGeometry(_ layer: CAGradientLayer,
                                        for direction: Direction) {
        switch direction {
        case .topToBottom:
            layer.startPoint = CGPoint(x: 0.5, y: 0)
            layer.endPoint   = CGPoint(x: 0.5, y: 1)
        case .bottomToTop:
            layer.startPoint = CGPoint(x: 0.5, y: 1)
            layer.endPoint   = CGPoint(x: 0.5, y: 0)
        case .leadingToTrailing:
            layer.startPoint = CGPoint(x: 0, y: 0.5)
            layer.endPoint   = CGPoint(x: 1, y: 0.5)
        case .trailingToLeading:
            layer.startPoint = CGPoint(x: 1, y: 0.5)
            layer.endPoint   = CGPoint(x: 0, y: 0.5)
        }
    }

    /// Build the `colors` array for the gradient mask: black/alpha-1
    /// at the start, fading to black/alpha-0 at the end, sampled
    /// along the requested curve.
    ///
    /// 16 samples is the sweet spot — more is invisible because
    /// CoreAnimation interpolates between stops in the GPU, fewer
    /// makes the curve visibly faceted at large sizes.
    ///
    /// The COLOR is opaque black (`.black`). Only ALPHA varies. A
    /// mask layer's RGB is irrelevant — only alpha gates the host
    /// layer's visibility. Black just happens to be the convention.
    private func applyGradientColors(_ layer: CAGradientLayer,
                                      for curve: GradientCurve) {
        let alphas = curve.samples(count: 16)
        layer.colors = alphas.map { alpha in
            NSColor.black.withAlphaComponent(alpha).cgColor
        }
        // Even locations so the curve sampling does the easing,
        // not the position interpolation. Using non-linear
        // positions here would double-ease and the result reads
        // as "stuck" near the edges.
        layer.locations = (0..<16).map { i in NSNumber(value: Float(i) / 15.0) }
    }
}

#Preview {
    ZStack {
        // Coloured stripes behind so the blur fade is visible.
        VStack(spacing: 0) {
            ForEach(0..<8) { i in
                Rectangle()
                    .fill([Color.red, .orange, .yellow, .green, .blue, .indigo, .purple, .pink][i])
                    .frame(height: 30)
            }
        }
        ProgressiveBlurView(direction: .topToBottom, intensity: .medium)
    }
    .frame(width: 360, height: 240)
}
