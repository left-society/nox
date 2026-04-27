//
//  LiquidGlass.metal
//  Notetaker
//
//  Real macOS-Tahoe Liquid Glass approximation: per-pixel
//  displacement + per-channel chromatic aberration.
//
//  Technique (adapted from nikdelvin's web Liquid Glass library —
//  https://github.com/nikdelvin/liquid-glass — which uses SVG
//  `feDisplacementMap` + 3-pass channel splitting):
//
//   1. Compute a displacement vector per pixel based on its
//      position relative to the card center. Displacement is zero
//      at center and ramps up smoothly toward the edges (the
//      classic "lensing through curved glass" curve).
//
//   2. Sample the input layer THREE times — once for R, once for
//      G, once for B — each with a slightly different displacement
//      strength. R gets the most extra displacement, B the least.
//      The differential is what creates the **red/blue fringe at
//      edges = chromatic aberration**, the visual cue real glass
//      has and faked glass doesn't.
//
//   3. Recombine each channel from its respective sample. The
//      result is a layer that looks like the input bent through
//      a piece of curved glass with proper refraction.
//
//  Apple's `.glassEffect()` modifier on macOS 26 does this
//  internally — but it's degraded on the lock-screen compositor
//  (loginwindow doesn't give third-party windows the proper
//  context for the lensing pass). This shader runs in our app's
//  rendering pipeline and works regardless of compositor context.

#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

/// Compute the displacement vector for a pixel.
///
/// We model the glass as a slightly-rounded curved surface: zero
/// curvature in the central region (no displacement), ramping up
/// quadratically toward the edges. The result is a 2D vector
/// pointing outward from the center, with magnitude scaled by
/// `strength`.
///
/// Convex-lens displacement profile. The shape we want:
///
///         ╱╲
///        ╱  ╲     ← displacement peak ~70% from center
///       ╱    ╲
///   ───┴──────┴──── ← zero at center AND zero at edge
///
/// Zero at the very edge is critical: it means pixels right at
/// the card boundary aren't displaced, so they line up with the
/// surrounding wallpaper and there's no visible "crack" at the
/// rim. Zero at the center is just physically accurate (light
/// passes straight through the center of a convex lens). The
/// peak in the middle is where the actual lensing happens —
/// where the glass curves most relative to the viewer.
///
/// Profile: `smoothstep(0, peak, d) * (1 - smoothstep(peak, 1, d))`
/// — ramp UP from center to peak, then ramp DOWN from peak to edge.
static float2 ntkComputeDisplacement(
    float2 position,
    float2 size,
    float strength
) {
    float2 normalized = (position / size) * 2.0 - 1.0;
    float distFromCenter = length(normalized);

    // 0 at center, 1 at peak (~70% radius), 0 at edge (radius=1).
    float rampUp = smoothstep(0.0, 0.7, distFromCenter);
    float rampDown = 1.0 - smoothstep(0.7, 1.0, distFromCenter);
    float edgeFactor = rampUp * rampDown;

    float2 direction = (distFromCenter > 0.0001)
        ? (normalized / distFromCenter)
        : float2(0.0, 0.0);

    return direction * edgeFactor * strength;
}

/// Liquid Glass: lensing + chromatic aberration in one pass.
///
/// `strength`: base displacement magnitude in pixels at the
/// edge. 20–30 reads as "subtle premium glass," 50+ reads as
/// "pronounced fish-eye."
///
/// `aberration`: extra displacement applied to the R channel
/// (and half of it to G), creating the chromatic fringe. 4–10
/// is the "real glass" sweet spot — enough to read as glass,
/// not so much that it looks like a broken filter.
[[ stitchable ]]
half4 ntkLiquidGlass(
    float2 position,
    SwiftUI::Layer layer,
    float2 size,
    float strength,
    float aberration
) {
    float2 baseDisplacement = ntkComputeDisplacement(
        position,
        size,
        strength
    );

    // Per-channel displacement scales. R = most, G = middle,
    // B = baseline. The relative offset is what produces the
    // visible color fringe at edges.
    float2 dispR = baseDisplacement * (1.0 + aberration * 0.06);
    float2 dispG = baseDisplacement * (1.0 + aberration * 0.03);
    float2 dispB = baseDisplacement;

    half4 sampleR = layer.sample(position + dispR);
    half4 sampleG = layer.sample(position + dispG);
    half4 sampleB = layer.sample(position + dispB);

    // Recombine channel-by-channel. Alpha taken from R sample;
    // any of them works since they're all the same input layer
    // sampled at slightly different positions.
    return half4(sampleR.r, sampleG.g, sampleB.b, sampleR.a);
}
