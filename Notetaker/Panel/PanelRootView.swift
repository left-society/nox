import SwiftUI
import AppKit

private struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        // .hudWindow is the floating-glass material macOS uses for HUD
        // panels — same family as iOS Notification Center / Control Center
        // where you can see the wallpaper bleed through. `underWindowBackground`
        // is darker and more solid; we want the wallpaper showing.
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.isEmphasized = true
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// Outer rim — the bright bevel where the curved face of the glass
/// meets the wall. Top is hot (light source above), bottom dies off.
/// `plusLighter` blend makes it pop against any wallpaper without
/// going opaque white on bright backgrounds.
private struct GlassEdge: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
            .strokeBorder(
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.78),
                        Color.white.opacity(0.32),
                        Color.white.opacity(0.10)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                lineWidth: 1.1
            )
            .blendMode(.plusLighter)
            .allowsHitTesting(false)
    }
}

/// INNER wall — a second bright stroke inset 1.5pt from the outer rim.
/// This is the key "liquid glass" tell: it makes the glass read as a
/// thick lens rather than a flat translucent sheet. Without it, the
/// panel looks like frosted plastic; with it, you can "see" the wall
/// of the glass.
private struct GlassInnerWall: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 18.5, style: .continuous)
            .strokeBorder(
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.55),
                        Color.white.opacity(0.18),
                        Color.white.opacity(0.04),
                        Color.clear
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                lineWidth: 0.7
            )
            .padding(1.5)
            .blendMode(.plusLighter)
            .allowsHitTesting(false)
    }
}

/// Top-edge inner glow — light bleeding from the rim into the body,
/// like a curved glass lens catching overhead light.
private struct GlassHighlight: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.20),
                        Color.white.opacity(0.05),
                        Color.clear
                    ],
                    startPoint: .top,
                    endPoint: UnitPoint(x: 0.5, y: 0.30)
                )
            )
            .allowsHitTesting(false)
    }
}

/// Specular gloss in the top-left — fakes the bright glint where light
/// catches a curved glass surface. Soft blur + plusLighter blend so it
/// reads as a glow rather than a painted spot.
private struct GlassSpecular: View {
    var body: some View {
        RadialGradient(
            colors: [
                Color.white.opacity(0.34),
                Color.white.opacity(0.10),
                Color.clear
            ],
            center: UnitPoint(x: 0.18, y: 0.04),
            startRadius: 0,
            endRadius: 150
        )
        .blendMode(.plusLighter)
        .allowsHitTesting(false)
    }
}

/// Diagonal sheen running off the top-left corner — the sweep of light
/// glancing across a wet/curved glass surface. Subtle, lives just above
/// the body tint but below the rim.
private struct GlassSheen: View {
    var body: some View {
        LinearGradient(
            colors: [
                Color.white.opacity(0.14),
                Color.white.opacity(0.04),
                Color.clear
            ],
            startPoint: UnitPoint(x: 0.0, y: 0.0),
            endPoint: UnitPoint(x: 0.6, y: 0.42)
        )
        .blendMode(.plusLighter)
        .allowsHitTesting(false)
    }
}

/// Subtle darkening on the bottom half so text near the bottom of the
/// panel stays legible against bright wallpapers showing through.
private struct BottomGlassShadow: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        Color.clear,
                        Color.black.opacity(0.16)
                    ],
                    startPoint: UnitPoint(x: 0.5, y: 0.6),
                    endPoint: .bottom
                )
            )
            .allowsHitTesting(false)
    }
}

enum PanelTab: String, CaseIterable, Identifiable {
    case notes, images, videos

    var id: String { rawValue }

    var title: String {
        switch self {
        case .notes: return "Notes"
        case .images: return "Images"
        case .videos: return "Videos"
        }
    }
}

struct PanelRootView: View {
    @EnvironmentObject var presenter: PanelPresenter
    @Namespace private var segmentedPill

    var body: some View {
        VStack(spacing: 0) {
            header
            segmented
                .padding(.horizontal, DS.Spacing.md)
            divider
                .padding(.top, DS.Spacing.sm)
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            ZStack {
                // Backdrop blur of whatever's behind the panel — base
                // for the iOS Notification-Center / Control-Center vibe.
                VisualEffectBackground()
                // Body tint — much more transparent than before so the
                // wallpaper actually shows through. 0.18 gives glass-
                // body weight without being dark like frosted plastic.
                Color.black.opacity(0.18)
                // Top legibility ramp — keeps the header readable on
                // bright wallpapers, dies off by the time content starts.
                LinearGradient(
                    colors: [
                        Color.black.opacity(0.14),
                        Color.clear
                    ],
                    startPoint: .top,
                    endPoint: UnitPoint(x: 0.5, y: 0.32)
                )
                // Cool purple wash in the top-left — accent hint, very
                // subtle so the wallpaper still dominates.
                RadialGradient(
                    colors: [
                        Color(red: 0.55, green: 0.40, blue: 0.82).opacity(0.14),
                        Color.clear
                    ],
                    center: UnitPoint(x: 0.10, y: 0.02),
                    startRadius: 0,
                    endRadius: 320
                )
                // Light effects that read as "this is a thick glass lens"
                // — order matters; specular goes under sheen so the
                // sheen sweeps across it rather than the other way.
                GlassSpecular()
                GlassSheen()
                GlassHighlight()
                BottomGlassShadow()
            }
        )
        // Outer rim and inner wall stroke layered on top — these are
        // what make the panel read as a thick glass lens rather than
        // a translucent flat sheet.
        .overlay(GlassEdge())
        .overlay(GlassInnerWall())
        // Drop targeting ring — driven by PanelDropContainer (the NSPanel
        // contentView wrapper) which sits below SwiftUI and handles drops
        // before any SwiftUI hit-testing kicks in. Pure cosmetic here.
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(DS.Color.accent.opacity(presenter.isDropTargeted ? 0.85 : 0), lineWidth: 1.5)
                .animation(.easeInOut(duration: 0.12), value: presenter.isDropTargeted)
                .allowsHitTesting(false)
        )
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        // Outer drop shadow under the panel — thick lens hovering
        // above the wallpaper. Two stacked shadows: a soft far one for
        // ambient lift, a tighter one for contact.
        .shadow(color: Color.black.opacity(0.35), radius: 22, x: 0, y: 14)
        .shadow(color: Color.black.opacity(0.20), radius: 4, x: 0, y: 2)
        .compositingGroup()
        // Liquid dissolve: scale + slight rotation + blur + opacity all
        // animating together with an elastic spring, anchored at the
        // top-trailing corner where the menu-bar icon lives. The
        // rotation gives a tiny "uncoil" that reads as the glass
        // forming rather than just expanding.
        .scaleEffect(presenter.isShown ? 1.0 : 0.72, anchor: .topTrailing)
        .rotationEffect(.degrees(presenter.isShown ? 0 : -3.5), anchor: .topTrailing)
        .blur(radius: presenter.isShown ? 0 : 24)
        .opacity(presenter.isShown ? 1.0 : 0.0)
        .animation(
            presenter.isShown
                ? .spring(response: 0.50, dampingFraction: 0.70)
                : .easeOut(duration: 0.20),
            value: presenter.isShown
        )
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: DS.Spacing.sm) {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(DS.Color.textSecondary)

            Text("Notetaker")
                .font(.nkTitle)
                .foregroundStyle(DS.Color.textPrimary)

            Spacer(minLength: DS.Spacing.sm)

            KeycapLabel("⌥", "Space")

            SettingsButton()
        }
        .padding(.horizontal, DS.Spacing.md)
        .padding(.top, DS.Spacing.sm)
        .padding(.bottom, DS.Spacing.xs)
    }

    // MARK: - Segmented

    private var segmented: some View {
        HStack(spacing: 2) {
            ForEach(PanelTab.allCases) { tab in
                segmentButton(for: tab)
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous)
                .fill(DS.Color.bgSubtle)
        )
    }

    private func segmentButton(for tab: PanelTab) -> some View {
        let isSelected = presenter.activeTab == tab
        return Button {
            withAnimation(.selection) { presenter.activeTab = tab }
        } label: {
            Text(tab.title)
                .font(.nkMeta.weight(isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? DS.Color.textPrimary : DS.Color.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .background(
                    ZStack {
                        if isSelected {
                            RoundedRectangle(cornerRadius: DS.Radius.pill, style: .continuous)
                                .fill(DS.Color.bgSelected)
                                .matchedGeometryEffect(id: "pill", in: segmentedPill)
                        }
                    }
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Divider & content

    private var divider: some View {
        Rectangle()
            .fill(DS.Color.divider)
            .frame(height: 1)
    }

    @ViewBuilder
    private var content: some View {
        switch presenter.activeTab {
        case .notes:
            NotesListView()
        case .images:
            ImagesGridView()
        case .videos:
            VideosGridView()
        }
    }

    private func placeholder(_ text: String) -> some View {
        VStack {
            Text(text)
                .font(.nkBody)
                .foregroundStyle(DS.Color.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Keycap label

private struct KeycapLabel: View {
    let keys: [String]

    init(_ keys: String...) {
        self.keys = keys
    }

    var body: some View {
        HStack(spacing: 3) {
            ForEach(keys, id: \.self) { key in
                Text(key)
                    .font(.system(size: DS.FontSize.xs, weight: .medium, design: .rounded))
                    .foregroundStyle(DS.Color.textTertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(DS.Color.bgSubtle)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.06), lineWidth: 0.5)
                    )
            }
        }
    }
}

// MARK: - Settings button

private struct SettingsButton: View {
    @State private var isHovered = false

    var body: some View {
        Button(action: { SettingsWindow.open() }) {
            Image(systemName: "gearshape")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isHovered ? DS.Color.textSecondary : DS.Color.textTertiary)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.rowHover) { isHovered = hovering }
        }
    }
}

#Preview {
    PanelRootView()
        .preferredColorScheme(.dark)
        .frame(width: 340, height: 700)
        .background(Color.black.opacity(0.85))
}
