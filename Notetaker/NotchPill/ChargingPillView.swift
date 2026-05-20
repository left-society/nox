import SwiftUI
import AppKit

/// Local re-implementation of the panel's `NotchShape`. Same path math:
/// flat top edge (so the pill reads as the physical notch extending
/// downward) with rounded bottom-left and bottom-right corners only.
/// Duplicated rather than imported because the original is private to
/// `Panel/PanelRootView.swift` and the shape is only ~20 lines —
/// sharing it would require either making it public (polluting the
/// panel module's API surface) or factoring into a third file (more
/// indirection than a 20-line shape deserves).
private struct NotchPillShape: Shape {
    var bottomRadius: CGFloat

    var animatableData: CGFloat {
        get { bottomRadius }
        set { bottomRadius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let r = max(0, min(bottomRadius, min(rect.width, rect.height) / 2))
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        p.addArc(
            center: CGPoint(x: rect.maxX - r, y: rect.maxY - r),
            radius: r,
            startAngle: .degrees(0),
            endAngle: .degrees(90),
            clockwise: false
        )
        p.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        p.addArc(
            center: CGPoint(x: rect.minX + r, y: rect.maxY - r),
            radius: r,
            startAngle: .degrees(90),
            endAngle: .degrees(180),
            clockwise: false
        )
        p.closeSubpath()
        return p
    }
}

/// Alcove-style HUD pill that drops out of the menu-bar notch when the
/// power source changes. Visually it's the same vocabulary as the main
/// notes panel — solid black slab, flat top, rounded bottom corners,
/// downward shadow — just smaller (240×40) and ephemeral (auto-hides
/// after a few seconds).
///
/// The view is morph-driven: `isShown` toggles the pill between a
/// 0×0 collapsed state and the full 240×40 size, with a single spring
/// animating width, height, AND corner radius simultaneously. That
/// matches the panel's emergence pattern so both surfaces feel like
/// they belong to the same product.
struct ChargingPillView: View {
    let percent: Int
    let isCharging: Bool
    /// Externally driven. The window controller flips this in tandem
    /// with show()/hide() so the SwiftUI animation can run inside the
    /// already-orderedFront window (we never animate the window itself
    /// — only the SwiftUI content scales/clips inside it).
    let isShown: Bool

    /// Visible inner pill geometry. Width is comfortable for "100%
    /// Charging" without truncation; height matches the main panel's
    /// closed-pill height so both surfaces feel like the same family.
    private static let pillWidth: CGFloat = 240
    private static let pillHeight: CGFloat = 40
    private static let pillBottomRadius: CGFloat = 18

    private var currentWidth: CGFloat { isShown ? Self.pillWidth : 0 }
    private var currentHeight: CGFloat { isShown ? Self.pillHeight : 0 }
    private var currentRadius: CGFloat { isShown ? Self.pillBottomRadius : 0 }

    var body: some View {
        ZStack(alignment: .top) {
            innerPill.frame(width: currentWidth, height: currentHeight)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .compositingGroup()
        // Motion blur during the bloom/collapse transition. Same trick
        // and same magnitude as NowPlayingPillView — keeps both notch
        // HUDs feeling like one product, and masks per-frame jank that
        // can creep in when the spring crosses zero. The 5pt magnitude
        // is slightly less aggressive than the now-playing pill (7pt)
        // because this is a smaller slab; what looks like motion blur
        // on the bigger pill reads as out-of-focus on the smaller one
        // unless we scale the blur to the pill's size.
        .blur(radius: isShown ? 0 : 5)
        .animation(
            // Same spring values as the main panel emergence — keeps the
            // family of animations cohesive. Slightly snappier collapse
            // on the way out so the HUD doesn't linger past its
            // welcome.
            isShown
                ? NoxAnimations.liveActivity
                : NoxAnimations.panelClose,
            value: isShown
        )
    }

    // MARK: - Inner pill

    private var innerPill: some View {
        HStack(spacing: 8) {
            // Bolt: yellow when juice is flowing, neutral grey on
            // battery. Using systemYellow rather than .yellow so the
            // tint plays nicely with the system's color management
            // (matches Control Center's bolt glyph).
            Image(systemName: "bolt.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(isCharging ? Color(nsColor: .systemYellow) : Color.gray)

            Text("\(percent)%")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .monospacedDigit()

            Spacer(minLength: 4)

            Text(isCharging ? "Charging" : "On Battery")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.7))
        }
        .padding(.horizontal, 14)
        // Content fades in *after* the shell finishes growing so the
        // user never catches a frame where text is squished into a
        // collapsing pill. Mirrors the main panel pattern.
        .opacity(isShown ? 1 : 0)
        .animation(
            isShown
                ? .easeOut(duration: 0.18).delay(0.16)
                : .easeIn(duration: 0.06),
            value: isShown
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .clipShape(NotchPillShape(bottomRadius: currentRadius))
        // Downward-only drop shadow, same direction as the main panel.
        // Light is "overhead" in this design language — shadows always
        // fall straight down so the slab reads as hanging out of the
        // notch rather than floating in the middle of the screen.
        .shadow(color: Color.black.opacity(0.45), radius: 14, x: 0, y: 8)
    }
}

#Preview {
    VStack(spacing: 20) {
        ChargingPillView(percent: 87, isCharging: true, isShown: true)
        ChargingPillView(percent: 42, isCharging: false, isShown: true)
    }
    .frame(width: 320, height: 200)
    .background(Color.gray.opacity(0.2))
}
