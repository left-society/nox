import SwiftUI

/// SwiftUI modifier that applies real Liquid-Glass-style refraction
/// (per-pixel displacement) plus chromatic aberration to the
/// modified view. Wraps the `ntkLiquidGlass` Metal shader via
/// `.layerEffect()`.
///
/// Apple's native `.glassEffect()` on macOS 26 does the same thing
/// internally, but it degrades on the lock-screen compositor (the
/// lensing pass needs context that `loginwindow` doesn't give us).
/// This modifier runs in our app's rendering pipeline so it works
/// both on desktop and during lock.
///
/// Usage:
///
///     someView
///         .liquidGlass(strength: 25, aberration: 8)
///         .clipShape(RoundedRectangle(cornerRadius: 22))
///
/// Apply BEFORE `.clipShape` so the displacement happens on the
/// rectangular source. Sampling beyond the clip would cull the
/// displaced pixels.
@available(macOS 14.0, *)
struct LiquidGlassModifier: ViewModifier {
    /// Maximum displacement magnitude at the edges, in pixels.
    /// 20–30 = subtle premium glass; 50+ = pronounced fish-eye.
    let strength: CGFloat
    /// Extra displacement applied to R/G channels for the
    /// chromatic-aberration fringe. 4–10 is the real-glass sweet
    /// spot.
    let aberration: CGFloat

    @State private var size: CGSize = .zero

    private var shader: Shader {
        ShaderLibrary.default.ntkLiquidGlass(
            .float2(size),
            .float(Float(strength)),
            .float(Float(aberration))
        )
    }

    func body(content: Content) -> some View {
        content
            .overlay {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: LiquidGlassSizeKey.self,
                        value: proxy.size
                    )
                }
                .allowsHitTesting(false)
            }
            .onPreferenceChange(LiquidGlassSizeKey.self) { newSize in
                size = newSize
            }
            // `maxSampleOffset` tells SwiftUI the shader will
            // sample up to this far outside the source rectangle.
            // Must be >= max displacement (strength + aberration
            // contribution) or sampled-outside pixels get clamped
            // to transparent and cause edge artifacts.
            .layerEffect(
                shader,
                maxSampleOffset: CGSize(
                    width: strength + aberration * 0.06,
                    height: strength + aberration * 0.06
                )
            )
    }
}

private struct LiquidGlassSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

extension View {
    /// Apply Liquid-Glass-style displacement + chromatic
    /// aberration to this view. macOS 14+ only — falls back to
    /// no-op below that.
    @ViewBuilder
    func liquidGlass(
        strength: CGFloat = 25,
        aberration: CGFloat = 8
    ) -> some View {
        if #available(macOS 14.0, *) {
            modifier(LiquidGlassModifier(
                strength: strength,
                aberration: aberration
            ))
        } else {
            self
        }
    }
}
