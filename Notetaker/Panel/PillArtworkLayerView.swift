import AppKit
import SwiftUI

/// CALayer-backed artwork tile for the resting notch pill.
///
/// **Why this isn't SwiftUI**: Alcove (verified via reverse-engineering
/// the binary on 2026-04-29) renders its pill artwork as a dedicated
/// CALayer tree (`artworkContainerLayer`, `artworkLayer`, `artworkMaskLayer`)
/// with track-change flips animated via `CABasicAnimation` on
/// `transform.rotation.y`. This is what gives Alcove its buttery
/// flip — Core Animation runs on the render-server thread, never
/// blocks the main thread, and the swap is one-frame atomic via
/// `CATransaction.setDisableActions(true)`.
///
/// The previous SwiftUI implementation in `PanelRootView.pillArtwork`
/// re-rasterized the entire artwork view + 5-axis transform stack
/// (offset + blur + scale + rotation3DEffect + opacity) on every
/// frame of the swap — which is what the user described as "kind of
/// jumpy" / "not as smooth as Alcove."
///
/// **Layer structure**:
/// ```
/// containerLayer  (sublayerTransform: perspective m34 = -1/800)
///   ├─ placeholderBgLayer  (white @ 8%, fixed)
///   ├─ placeholderGlyphLayer (SF Symbol music.note, fixed)
///   ├─ imageLayer       (FRONT face — current artwork)
///   ├─ nextImageLayer   (BACK face — incoming artwork during a flip;
///   │                    intrinsically pre-rotated 180° around Y so
///   │                    when the outer rotation reaches 180° the
///   │                    back content is right-side up. Empty at
///   │                    rest, populated by `setImage` when a track
///   │                    change triggers an animated swap.)
///   └─ strokeLayer      (CAShapeLayer, 0.5pt 10%-white border)
/// ```
///
/// The container has `masksToBounds = true` + `cornerRadius = 5`
/// so all sublayers are clipped to the rounded square. The
/// `sublayerTransform` applies perspective to children only — that
/// way the 3D rotation on the image layers reads as having depth.
///
/// **Two-faced flip pattern** (2026-05-06): on a track change, the
/// NEW artwork is pre-loaded onto `nextImageLayer` while the OLD
/// artwork stays on `imageLayer`. Both rotate 180° around Y in sync,
/// and step-keyframed opacity gates which face is visible — front
/// fades to 0 at midpoint, back fades to 1. The user sees the OLD
/// artwork rotating away on the front and the NEW artwork rotating
/// into view on the back. After the flip settles `imageLayer`
/// receives the new contents and `nextImageLayer` is cleared so the
/// next flip starts from the same clean state.
struct PillArtworkLayerView: NSViewRepresentable {
    let image: NSImage?
    let trackKey: String
    let size: CGFloat
    let cornerRadius: CGFloat

    init(image: NSImage?, trackKey: String, size: CGFloat = 22, cornerRadius: CGFloat = 5) {
        self.image = image
        self.trackKey = trackKey
        self.size = size
        self.cornerRadius = cornerRadius
    }

    func makeNSView(context: Context) -> PillArtworkNSView {
        let view = PillArtworkNSView(size: size, cornerRadius: cornerRadius)
        view.setImage(image, animated: false)
        context.coordinator.lastTrackKey = trackKey
        return view
    }

    func updateNSView(_ view: PillArtworkNSView, context: Context) {
        let isTrackChange = !trackKey.isEmpty
            && trackKey != context.coordinator.lastTrackKey
            && !context.coordinator.lastTrackKey.isEmpty
        // Animate ONLY for genuine track changes — first-ever
        // mount, placeholder→placeholder, or same-track artwork
        // refresh all use the silent direct-swap path.
        view.setImage(image, animated: isTrackChange)
        context.coordinator.lastTrackKey = trackKey
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        var lastTrackKey: String = ""
    }
}

/// The actual NSView with the CALayer tree. Owns the layers,
/// handles resize, and exposes `setImage(_:animated:)` for the
/// SwiftUI representable to call on update.
final class PillArtworkNSView: NSView {
    private let containerLayer = CALayer()
    private let imageLayer = CALayer()
    /// BACK face for the two-faced flip — populated with the
    /// incoming artwork only during a track-change flip. Has an
    /// intrinsic 180° Y-rotation so when the outer rotation
    /// reaches π the back content is right-side up. Empty at
    /// rest.
    private let nextImageLayer = CALayer()
    private let placeholderBgLayer = CALayer()
    private let placeholderGlyphLayer = CALayer()
    private let strokeLayer = CAShapeLayer()
    private let cornerRadius: CGFloat
    private var hasContentLoaded = false

    init(size: CGFloat, cornerRadius: CGFloat) {
        self.cornerRadius = cornerRadius
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        wantsLayer = true
        layer = containerLayer
        configureLayers()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported — use init(size:cornerRadius:)")
    }

    override func layout() {
        super.layout()
        updateLayerFrames()
    }

    // MARK: - Layer setup

    private func configureLayers() {
        // Container clips to rounded rect.
        containerLayer.cornerRadius = cornerRadius
        containerLayer.masksToBounds = true
        containerLayer.contentsGravity = .resizeAspectFill
        // Subtle perspective on sublayers — m34 = -1/d where d is
        // the perspective depth in pixels. 800 gives gentle depth
        // on a 22pt tile (500 was too dramatic — the foreshortening
        // dominated and read as "carnival ride," not "subtle 3D
        // flip"). Larger d = subtler perspective.
        var perspective = CATransform3DIdentity
        perspective.m34 = -1.0 / 800.0
        containerLayer.sublayerTransform = perspective

        // Placeholder background (white @ 8%).
        placeholderBgLayer.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
        containerLayer.addSublayer(placeholderBgLayer)

        // Placeholder music-note glyph. We render the SF Symbol as
        // an NSImage and set it as layer contents. macOS 11+ has
        // proper SF Symbol rendering via `NSImage(systemSymbolName:)`.
        if let glyph = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil) {
            let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
            placeholderGlyphLayer.contents = glyph
                .withSymbolConfiguration(config)
            placeholderGlyphLayer.contentsGravity = .resizeAspect
        }
        // Tint the glyph by recoloring via filter would require
        // CIFilter — simpler: pre-render the glyph at the desired
        // alpha via NSImage's symbolConfiguration tint when we
        // place it, OR just draw a translucent white over the
        // glyph layer. Below: tint via opacity on the layer.
        placeholderGlyphLayer.opacity = 0.55
        containerLayer.addSublayer(placeholderGlyphLayer)

        // Image layer — initially empty. This is the FRONT face
        // of the two-faced flip card.
        imageLayer.contentsGravity = .resizeAspectFill
        imageLayer.opacity = 0
        containerLayer.addSublayer(imageLayer)

        // Next-image layer — the BACK face. Pre-rotated 180°
        // around Y so when the outer rotation passes through π
        // the back content is right-side up (intrinsic 180° +
        // outer 180° = 360° = 0° mod 2π). Hidden at rest;
        // populated only during a track-change flip.
        nextImageLayer.contentsGravity = .resizeAspectFill
        nextImageLayer.opacity = 0
        nextImageLayer.transform = CATransform3DMakeRotation(.pi, 0, 1, 0)
        containerLayer.addSublayer(nextImageLayer)

        // Stroke (0.5pt 10%-white border).
        strokeLayer.fillColor = NSColor.clear.cgColor
        strokeLayer.strokeColor = NSColor.white.withAlphaComponent(0.10).cgColor
        strokeLayer.lineWidth = 0.5
        containerLayer.addSublayer(strokeLayer)

        updateLayerFrames()
    }

    private func updateLayerFrames() {
        let b = bounds
        // No animation when laying out subframes — these are
        // intrinsic geometry updates, not user-visible transitions.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        placeholderBgLayer.frame = b
        // Glyph centered at ~50% of the tile size.
        let glyphSize: CGFloat = b.width * 0.55
        placeholderGlyphLayer.frame = NSRect(
            x: (b.width - glyphSize) / 2,
            y: (b.height - glyphSize) / 2,
            width: glyphSize,
            height: glyphSize
        )
        imageLayer.frame = b
        nextImageLayer.frame = b
        strokeLayer.frame = b
        // Inset stroke by 0.25pt so the 0.5pt line is centered on
        // the rounded rect edge — without inset half the stroke
        // gets clipped by `masksToBounds`.
        let stroked = b.insetBy(dx: 0.25, dy: 0.25)
        strokeLayer.path = CGPath(
            roundedRect: stroked,
            cornerWidth: cornerRadius,
            cornerHeight: cornerRadius,
            transform: nil
        )
        CATransaction.commit()
    }

    // MARK: - Public API

    /// Set the artwork image. When `animated` is true, performs a
    /// 3D Y-axis flip (CABasicAnimation on `transform.rotation.y`)
    /// with the image swap landing at the edge-on midpoint. When
    /// false, the swap is one-frame atomic via setDisableActions.
    func setImage(_ image: NSImage?, animated: Bool) {
        let cgImage = image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        let hasImage = cgImage != nil

        if animated && hasContentLoaded {
            performFlipSwap(to: cgImage, hasImage: hasImage)
        } else {
            applyImageContent(cgImage, hasImage: hasImage, animated: false)
        }

        if hasImage {
            hasContentLoaded = true
        }
    }

    private func performFlipSwap(to newCGImage: CGImage?, hasImage: Bool) {
        // Two-faced flip. Pre-load the new artwork onto nextImageLayer
        // (which lives behind imageLayer with an intrinsic 180° Y
        // rotation), then animate BOTH layers' rotation 0→π in lockstep
        // while step-keyframing opacity to swap which face is visible.
        //
        // Result: user sees OLD artwork rotating away on the front face
        // for the first 90° of motion, then NEW artwork rotating into
        // place on the back face for the second 90°. True card flip,
        // no mid-motion content snap.
        //
        // After the rotation settles, imageLayer is promoted to hold
        // the new contents and nextImageLayer is cleared so the next
        // flip starts from the same clean state.
        let duration: TimeInterval = 0.36

        // 1. Pre-load the new artwork onto the BACK face. No animation
        //    here — direct content swap while the back is invisible.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        nextImageLayer.contents = newCGImage
        // nextImageLayer.opacity stays 0 until the keyframe flips it
        // to 1 at the midpoint. Setting transform back to its
        // intrinsic 180° rotation in case a previous flip's cleanup
        // didn't land cleanly.
        nextImageLayer.transform = CATransform3DMakeRotation(.pi, 0, 1, 0)
        CATransaction.commit()

        // 2. Build the rotation animation. Front layer rotates 0→π;
        //    back layer rotates from its intrinsic π to 2π so it
        //    ends at identity (right-side up) when the flip lands.
        //    Same easing on both so they stay in lockstep.
        let timing = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.6, 1)

        let frontRotate = CABasicAnimation(keyPath: "transform.rotation.y")
        frontRotate.fromValue = 0
        frontRotate.toValue = CGFloat.pi
        frontRotate.duration = duration
        frontRotate.timingFunction = timing
        frontRotate.fillMode = .forwards
        frontRotate.isRemovedOnCompletion = false

        let backRotate = CABasicAnimation(keyPath: "transform.rotation.y")
        backRotate.fromValue = CGFloat.pi
        backRotate.toValue = 2 * CGFloat.pi
        backRotate.duration = duration
        backRotate.timingFunction = timing
        backRotate.fillMode = .forwards
        backRotate.isRemovedOnCompletion = false

        // 3. Opacity step-keyframes — invisible-to-1 swap at midpoint.
        //    The 0.499/0.501 split is one frame wide so the eye sees
        //    one face crossfade out into the other at the edge-on
        //    moment; with both faces at zero visible width during
        //    that one frame the discrete swap is imperceptible.
        let frontOpacity = CAKeyframeAnimation(keyPath: "opacity")
        frontOpacity.values = [1.0, 1.0, 0.0, 0.0]
        frontOpacity.keyTimes = [0.0, 0.499, 0.501, 1.0]
        frontOpacity.calculationMode = .discrete
        frontOpacity.duration = duration
        frontOpacity.fillMode = .forwards
        frontOpacity.isRemovedOnCompletion = false

        let backOpacity = CAKeyframeAnimation(keyPath: "opacity")
        backOpacity.values = [0.0, 0.0, 1.0, 1.0]
        backOpacity.keyTimes = [0.0, 0.499, 0.501, 1.0]
        backOpacity.calculationMode = .discrete
        backOpacity.duration = duration
        backOpacity.fillMode = .forwards
        backOpacity.isRemovedOnCompletion = false

        imageLayer.add(frontRotate, forKey: "flipRotate")
        imageLayer.add(frontOpacity, forKey: "flipOpacity")
        nextImageLayer.add(backRotate, forKey: "flipRotate")
        nextImageLayer.add(backOpacity, forKey: "flipOpacity")

        // 4. After the rotation settles: promote the new artwork to
        //    the front layer and clean up the back. Done in one
        //    CATransaction with actions disabled so SwiftUI's diff
        //    pass doesn't see an intermediate state.
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.01) { [weak self] in
            guard let self else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            // Front: receive the new image, reset rotation/opacity.
            self.imageLayer.contents = newCGImage
            self.imageLayer.opacity = hasImage ? 1 : 0
            self.imageLayer.transform = CATransform3DIdentity
            self.imageLayer.removeAnimation(forKey: "flipRotate")
            self.imageLayer.removeAnimation(forKey: "flipOpacity")
            // Back: clear contents, reset to its at-rest state
            // (opacity 0, intrinsic 180° rotation). Animations
            // removed so the next flip starts clean.
            self.nextImageLayer.contents = nil
            self.nextImageLayer.opacity = 0
            self.nextImageLayer.transform = CATransform3DMakeRotation(.pi, 0, 1, 0)
            self.nextImageLayer.removeAnimation(forKey: "flipRotate")
            self.nextImageLayer.removeAnimation(forKey: "flipOpacity")
            // Placeholder visibility tracks the new image presence.
            self.placeholderBgLayer.opacity = hasImage ? 0 : 1
            self.placeholderGlyphLayer.opacity = hasImage ? 0 : 0.55
            CATransaction.commit()
        }
    }

    private func applyImageContent(_ cgImage: CGImage?, hasImage: Bool, animated: Bool) {
        CATransaction.begin()
        if !animated {
            CATransaction.setDisableActions(true)
        }
        imageLayer.contents = cgImage
        imageLayer.opacity = hasImage ? 1 : 0
        placeholderBgLayer.opacity = hasImage ? 0 : 1
        placeholderGlyphLayer.opacity = hasImage ? 0 : 0.55
        CATransaction.commit()
    }
}
