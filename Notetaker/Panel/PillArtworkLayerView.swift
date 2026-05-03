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
/// containerLayer  (sublayerTransform: perspective m34 = -1/500)
///   ├─ imageLayer       (contents = NSImage.cgImage)
///   ├─ placeholderLayer (NSImage of "music.note" SF Symbol, hidden when image present)
///   └─ strokeLayer      (CAShapeLayer for the 0.5pt 10%-white border)
/// ```
///
/// The container has `masksToBounds = true` + `cornerRadius = 5`
/// so all sublayers are clipped to the rounded square. The
/// `sublayerTransform` applies perspective to children only — that
/// way the 3D rotation on `imageLayer` reads as having depth, not
/// a flat 2D rotation.
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

        // Image layer — initially empty.
        imageLayer.contentsGravity = .resizeAspectFill
        imageLayer.opacity = 0
        containerLayer.addSublayer(imageLayer)

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

    private func performFlipSwap(to cgImage: CGImage?, hasImage: Bool) {
        // SINGLE continuous rotation + scale.x mirror compensation.
        //
        // Why this is smoother than the two-phase approach:
        //   • Two phases (0→-π/2 then π/2→0) split the rotation
        //     into separate animations that meet at the edge-on
        //     moment. With ease-in on phase 1 and ease-out on
        //     phase 2, the rotation DECELERATES into the midpoint,
        //     pauses for one frame, then ACCELERATES out — visible
        //     as a hesitation.
        //   • One continuous 0→π rotation never decelerates at the
        //     midpoint. The motion reads as one fluid gesture.
        //
        // The mirror-compensation trick:
        //   Rotating around Y axis flips the texture horizontally
        //   when it passes 90° (the back face shows mirrored). To
        //   compensate, we animate `transform.scale.x` as a step
        //   keyframe: 1 from start to just before midpoint, then
        //   -1 from just after midpoint to end. The instantaneous
        //   sign flip at the edge-on moment is invisible (layer is
        //   already foreshortened to a vertical line) but makes the
        //   continuing rotation past 90° show the new content
        //   un-mirrored. This is the `cosineSign` trick from
        //   jackson-storm/DynamicNotch's AlbumArtFlipModifier
        //   (referenced in the 2026-04-29 reverse-engineering
        //   research) translated to Core Animation.
        let duration: TimeInterval = 0.36
        let beginTime = CACurrentMediaTime()

        let rotate = CABasicAnimation(keyPath: "transform.rotation.y")
        rotate.fromValue = 0
        rotate.toValue = CGFloat.pi
        rotate.duration = duration
        // Smooth ease-in-out with a slightly steeper acceleration —
        // (0.4, 0, 0.6, 1) is a clean S-curve that doesn't linger
        // at either end. Standard "smooth" bezier used by Alcove
        // and most polished macOS animations.
        rotate.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.6, 1)
        rotate.fillMode = .forwards
        rotate.isRemovedOnCompletion = false

        let mirror = CAKeyframeAnimation(keyPath: "transform.scale.x")
        mirror.values = [1.0, 1.0, -1.0, -1.0]
        mirror.keyTimes = [0.0, 0.499, 0.501, 1.0]
        mirror.calculationMode = .discrete  // step-function, no interpolation
        mirror.duration = duration
        mirror.fillMode = .forwards
        mirror.isRemovedOnCompletion = false

        imageLayer.add(rotate, forKey: "flipRotate")
        imageLayer.add(mirror, forKey: "flipMirror")

        // Swap content at the edge-on moment — the layer is a
        // zero-width line at this instant, so the user never sees
        // the swap itself, only the new content rotating in.
        DispatchQueue.main.asyncAfter(deadline: .now() + duration / 2) { [weak self] in
            self?.applyImageContent(cgImage, hasImage: hasImage, animated: false)
        }

        // After the full rotation completes, the layer is at
        // rotation=π and scale.x=-1 — i.e. mirrored 180° upside-down
        // from identity. Visually it READS as identical to identity
        // (rotated 180° + horizontally mirrored = original), but
        // we should explicitly reset to clean identity so cumulative
        // animations don't drift over many flips.
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.01) { [weak self] in
            guard let self else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.imageLayer.removeAnimation(forKey: "flipRotate")
            self.imageLayer.removeAnimation(forKey: "flipMirror")
            self.imageLayer.transform = CATransform3DIdentity
            CATransaction.commit()
            _ = beginTime  // silence unused-variable warning if compiler complains
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
