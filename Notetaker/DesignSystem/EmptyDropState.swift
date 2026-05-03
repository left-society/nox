import SwiftUI

/// Reusable empty-state view for the drop-target tabs (Images,
/// Videos, Files, and the Notes "no notes yet" surface).
///
/// Why a dedicated component:
///   • Per the user's "this thing still looks weird" feedback on
///     2026-04-29 — the previous Files empty state was a 26pt thin
///     glyph + tiny tagline floating in a black void. Felt
///     unfinished, more like "feature broken" than "ready for
///     your stuff."
///   • Material's empty-state guidance: image + tagline + helpful
///     hint, never actionable copy. Dropover / Yoink (the prime
///     macOS reference apps for this UX) all use a layered
///     illustrated icon with breathing motion + clear hierarchy.
///   • The 4 grid views had divergent empty states (Files was
///     sparse, Images was richer). Centralising here means one
///     visual identity and one place to tune.
///
/// Layered look:
///   1. Outer breathing halo — wide soft accent gradient that
///      subtly pulses ~8% scale, gives the empty state visible
///      "pulse" without being a hard animation. Apple uses this
///      pattern in Maps' loading states, Finder's connecting
///      indicator.
///   2. Inner glow disc — sharper accent radial right behind the
///      glyph, tints the glyph chromatically.
///   3. Main glyph — 38pt regular weight (was 26pt thin), with a
///      soft accent shadow so it reads as elevated rather than
///      flat-on-black.
///
/// Hierarchy:
///   • Title (16pt semibold, primary white) — the call-to-action
///     reading: "Drop files here," "Capture a thought," etc.
///   • Subtitle (12pt regular, 55% white) — explanatory body
///     copy, can wrap to 2 lines.
///   • Optional keyboard hint chip — styled as a quiet keycap
///     pair, surfaces a power-user shortcut without competing
///     with the title.
struct EmptyDropState: View {
    let icon: String
    let title: String
    let subtitle: String
    /// Optional keyboard shortcut hint, e.g. ("⌘V", "to paste").
    /// Renders as a pair: a styled keycap + dim body text.
    let keyHint: (key: String, body: String)?
    let accent: Color

    init(
        icon: String,
        title: String,
        subtitle: String,
        keyHint: (key: String, body: String)? = nil,
        accent: Color = Color(red: 0.55, green: 0.45, blue: 0.95)
    ) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.keyHint = keyHint
        self.accent = accent
    }

    var body: some View {
        // Vertically centered inside whatever container hosts us.
        // The grid views (Images / Videos / Files / Notes) drop the
        // empty state inside a ScrollView, which collapses our
        // frame to its intrinsic content height — that's why a plain
        // `.frame(maxHeight: .infinity)` was pinning the icon to the
        // top of the slab. Spacer-sandwich pattern + an explicit
        // `minHeight: 360` (slab content area is ~410pt) keeps the
        // hint visually in the MIDDLE of the empty surface, where
        // the eye expects it.
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            VStack(spacing: 12) {
                illustratedIcon
                textBlock
                if let hint = keyHint {
                    keycapHint(hint)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 360)
    }

    // MARK: - Layers

    private var illustratedIcon: some View {
        // 2026-05-03 toned down per user feedback: 38pt felt too
        // shouty in an otherwise empty surface, especially on the
        // shorter image / video / files panels where it dominated
        // the slab. 26pt regular reads as "quietly waiting" rather
        // than "FEATURE BROKEN."
        Image(systemName: icon)
            .font(.system(size: 26, weight: .regular))
            .foregroundStyle(
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.85),
                        Color.white.opacity(0.55)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
    }

    private var textBlock: some View {
        VStack(spacing: 4) {
            // Same 2026-05-03 pass: title shrunk 16 → 13 (medium
            // weight, not semibold) and subtitle 12 → 10.5 so the
            // empty-state block reads as a hint, not a headline.
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.82))
            Text(subtitle)
                .font(.system(size: 10.5, weight: .regular))
                .foregroundStyle(Color.white.opacity(0.45))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 32)
        }
    }

    /// Quiet keycap chip + body text. Styled like the system
    /// menu-bar shortcut hint (⌘+V on a flat keycap with subtle
    /// stroke), followed by descriptive copy at 40% white. Reads
    /// as "here's a power-user shortcut" without dominating the
    /// empty state.
    private func keycapHint(_ hint: (key: String, body: String)) -> some View {
        HStack(spacing: 6) {
            Text(hint.key)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.7))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
                )
            Text(hint.body)
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(Color.white.opacity(0.45))
        }
    }

}

#Preview {
    ZStack {
        Color.black
        EmptyDropState(
            icon: "tray.full",
            title: "Drop files here",
            subtitle: "Stage anything you need to paste later. Nothing is saved.",
            keyHint: ("⌘V", "to paste from clipboard")
        )
    }
    .frame(width: 540, height: 480)
}

// MARK: - Brand icon (nox)

/// Native SwiftUI rendition of the nox brand icon.
///
/// One-to-one with the canonical SVG (`Resources/nox-icon.svg`):
/// squircle background with subtle radial depth, faint inner-corona
/// atmosphere, soft outer halo, sharp gradient ring with a notched
/// camera cutout at the top.
///
/// Two variants:
///   • `NoxIcon` (full) — the squircle app-icon at any size. Use for
///     the app icon export, marketing assets, large brand displays.
///   • `NoxGlyph` (compact) — just the ring-with-notch silhouette,
///     no background, no halo. For inline UI like the panel header
///     ("nox" wordmark + glyph) and any place a small brand mark
///     belongs (8–24 pt).
///
/// Both scale parametrically — pass any `size:` and the strokes /
/// gradients / notch proportions remain visually correct.
///
/// Renders to PNG via `ImageRenderer` for `Assets.xcassets` export.
/// See the `#Preview` at the bottom for the export utility.
struct NoxIcon: View {
    /// Edge length in points. Defaults to 1024 (Apple's max icon
    /// size). Internal geometry scales linearly.
    var size: CGFloat = 1024

    /// Whether to render the squircle background. Off when used
    /// outside an icon context (e.g. on a marketing hero where the
    /// page already provides the dark canvas).
    var includeBackground: Bool = true

    var body: some View {
        Canvas { ctx, _ in
            // Geometry scales off `size` so all proportions stay
            // intact at any resolution. Numbers chosen to match the
            // canonical SVG exactly (1024-space → unit-fraction):
            //   center = 0.5, ring-radius = 290/1024 ≈ 0.283,
            //   ring-stroke = 20/1024 ≈ 0.0195,
            //   notch-w = 56/1024 ≈ 0.0547,
            //   notch-y = 200/1024 ≈ 0.1953,
            //   notch-h = 36/1024 ≈ 0.0352.
            let s = size
            let center = CGPoint(x: s * 0.5, y: s * 0.5)
            let ringRadius = s * 0.283
            let ringStroke = s * 0.0195
            let haloStroke = s * 0.045
            let notchWidth = s * 0.0547
            let notchHeight = s * 0.0352
            let notchY = s * 0.1953
            let cornerRadius = s * 0.2246

            // ─── Layer 1: squircle background with radial depth ──
            if includeBackground {
                let squircle = Path(roundedRect: CGRect(x: 0, y: 0, width: s, height: s),
                                    cornerRadius: cornerRadius)
                ctx.clip(to: squircle)
                let bg = Gradient(stops: [
                    .init(color: Color(red: 0.039, green: 0.024, blue: 0.071), location: 0.0),
                    .init(color: Color(red: 0.016, green: 0.004, blue: 0.031), location: 0.55),
                    .init(color: .black, location: 1.0)
                ])
                ctx.fill(squircle,
                         with: .radialGradient(bg,
                                              center: center,
                                              startRadius: 0,
                                              endRadius: s * 0.75))

                // ─── Layer 2: inner corona atmosphere ─────────────
                // Whisper of lavender in the center, fading to fully
                // transparent before reaching the ring's inner edge.
                let corona = Gradient(stops: [
                    .init(color: Color(red: 0.773, green: 0.639, blue: 1.0).opacity(0.10), location: 0.0),
                    .init(color: Color(red: 0.773, green: 0.639, blue: 1.0).opacity(0.04), location: 0.6),
                    .init(color: Color.clear, location: 1.0)
                ])
                ctx.fill(squircle,
                         with: .radialGradient(corona,
                                              center: center,
                                              startRadius: 0,
                                              endRadius: s * 0.36))
            }

            // ─── Notched ring path ────────────────────────────────
            // Single circular path traced from just RIGHT of the
            // notch (clockwise around the bottom and back up) to
            // just LEFT of the notch — leaves the notch as a clean
            // gap at the top.
            let notchHalfX = notchWidth / 2
            // Angle (from center) at which the ring meets the
            // right edge of the notch. Computed so the notch's
            // bottom edge lines up with the ring's outer edge at
            // notchY + notchHeight.
            let notchEdgeX = center.x + notchHalfX
            let notchEdgeY = notchY + notchHeight
            let dx = notchEdgeX - center.x
            let dy = notchEdgeY - center.y
            let startAngle = atan2(dy, dx)
            let endAngle = .pi - startAngle  // mirror across vertical
            // We want to go clockwise the LONG way (around the
            // bottom). In SwiftUI's coordinate system (y-down) and
            // Path.addArc convention, that means:
            //   startAngle = the right-of-notch angle,
            //   endAngle = the left-of-notch angle (mirrored),
            //   clockwise = false (sweep around the long way).
            var ring = Path()
            ring.addArc(center: center,
                        radius: ringRadius,
                        startAngle: .radians(startAngle),
                        endAngle: .radians(endAngle),
                        clockwise: false)

            // ─── Layer 3: outer halo (blurred, semi-transparent) ─
            ctx.drawLayer { layer in
                layer.addFilter(.blur(radius: s * 0.022))
                layer.opacity = 0.42
                layer.stroke(ring,
                             with: .color(Color(red: 0.773, green: 0.639, blue: 1.0)),
                             style: StrokeStyle(lineWidth: haloStroke, lineCap: .round))
            }

            // ─── Layer 4: sharp ring (gradient stroke) ────────────
            // Linear gradient running top-left → bottom-right with
            // five stops (highlight → mid → base → deep → shadow).
            let ringGradient = Gradient(stops: [
                .init(color: Color(red: 0.937, green: 0.871, blue: 1.0), location: 0.0),
                .init(color: Color(red: 0.851, green: 0.737, blue: 1.0), location: 0.25),
                .init(color: Color(red: 0.773, green: 0.639, blue: 1.0), location: 0.55),
                .init(color: Color(red: 0.651, green: 0.533, blue: 0.910), location: 0.80),
                .init(color: Color(red: 0.502, green: 0.392, blue: 0.784), location: 1.0)
            ])
            ctx.stroke(ring,
                       with: .linearGradient(ringGradient,
                                            startPoint: CGPoint(x: s * 0.3, y: s * 0.05),
                                            endPoint: CGPoint(x: s * 0.75, y: s * 0.98)),
                       style: StrokeStyle(lineWidth: ringStroke, lineCap: .butt))
        }
        .frame(width: size, height: size)
    }
}

/// Compact ring-with-notch glyph for inline UI (panel header, menu
/// items, anywhere a tiny brand mark is wanted). No squircle, no
/// halo — just the clean silhouette. Tints to whatever
/// foregroundStyle the parent applies.
struct NoxGlyph: View {
    var size: CGFloat = 14
    var lineWidth: CGFloat = 1.5
    /// Stroke color. Defaults to the brand lavender for in-app
    /// inline use. Override with `.black` (and rasterize via
    /// ImageRenderer with `isTemplate = true`) for menu-bar use
    /// where macOS handles the tint based on dark/light state.
    var tint: Color = DS.Color.brandLavender

    var body: some View {
        Canvas { ctx, _ in
            let s = size
            let center = CGPoint(x: s * 0.5, y: s * 0.5)
            let r = s * 0.42
            let notchHalfX = s * 0.10
            let notchY = s * 0.05
            let notchH = s * 0.10
            let notchEdgeX = center.x + notchHalfX
            let notchEdgeY = notchY + notchH
            let startAngle = atan2(notchEdgeY - center.y, notchEdgeX - center.x)
            let endAngle = .pi - startAngle
            var ring = Path()
            ring.addArc(center: center,
                        radius: r,
                        startAngle: .radians(startAngle),
                        endAngle: .radians(endAngle),
                        clockwise: false)
            ctx.stroke(ring,
                       with: .color(tint),
                       style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Asset export utility (for generating PNGs at all icon sizes)

#if DEBUG
import AppKit

/// Dev utility — call once to dump PNG variants of `NoxIcon` to
/// `~/Desktop/nox-icon-export/` at every Apple-required size.
/// After running, drag the PNGs into `Assets.xcassets → AppIcon-mac`
/// in the right slots. Only compiled in DEBUG so it doesn't ship.
@MainActor
enum NoxIconExporter {
    static let sizes: [CGFloat] = [16, 32, 64, 128, 256, 512, 1024]

    static func exportAll() {
        let outDir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Desktop/nox-icon-export", isDirectory: true)
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        for size in sizes {
            let renderer = ImageRenderer(content: NoxIcon(size: size, includeBackground: true))
            renderer.scale = 1.0  // size IS the export size; no @2x
            guard let cg = renderer.cgImage else {
                print("⚠️ NoxIconExporter: render failed for \(size)pt")
                continue
            }
            let bitmap = NSBitmapImageRep(cgImage: cg)
            guard let data = bitmap.representation(using: .png, properties: [:]) else { continue }
            let url = outDir.appendingPathComponent("nox-\(Int(size)).png")
            try? data.write(to: url)
            print("✅ NoxIconExporter: wrote \(url.path)")
        }
    }
}
#endif
