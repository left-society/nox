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

/// Outer rim — clean white edge stroke, no `plusLighter` halo. Apple's
/// `moduleStroke` style on Control Center tiles is similarly clean:
/// visible bright top, fades down. Without `plusLighter` we get a
/// crisp glass edge instead of a glowing-object look.
private struct GlassEdge: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
            .strokeBorder(
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.45),
                        Color.white.opacity(0.20),
                        Color.white.opacity(0.06)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                lineWidth: 1.0
            )
            .allowsHitTesting(false)
    }
}

/// Inner wall — a second stroke inset 1.2pt from the outer rim. Gives
/// the glass visible thickness (the "wall" of the lens) without the
/// haloing `plusLighter` was producing. Subtle on purpose — Apple's
/// Glass material relies on the matrix-lift + clean stroke combo, not
/// stacked glow layers.
private struct GlassInnerWall: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 18.8, style: .continuous)
            .strokeBorder(
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.25),
                        Color.white.opacity(0.10),
                        Color.white.opacity(0.02),
                        Color.clear
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                lineWidth: 0.6
            )
            .padding(1.2)
            .allowsHitTesting(false)
    }
}

/// Soft top-edge inner glow — the gentle light bleed from the rim into
/// the body. Kept subtle; this is the only "highlight" layer left after
/// dropping the specular blob and diagonal sheen.
private struct GlassHighlight: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.10),
                        Color.white.opacity(0.02),
                        Color.clear
                    ],
                    startPoint: .top,
                    endPoint: UnitPoint(x: 0.5, y: 0.28)
                )
            )
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
                        Color.black.opacity(0.14)
                    ],
                    startPoint: UnitPoint(x: 0.5, y: 0.62),
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
                // layer for the wallpaper-bleed-through effect.
                VisualEffectBackground()
                // WHITE LIFT — Apple's `platformContentGlass` material
                // recipe applies a +0.235 brightness boost on every
                // RGB channel via its color matrix (the m15/m25/m35
                // entries). That's the "luminous glass" secret. We
                // can't apply a CIColorMatrix to NSVisualEffectView
                // directly, so we approximate it with a translucent
                // white overlay. Without this the panel reads as dark
                // frosted plastic; with it, it reads as glass.
                Color.white.opacity(0.14)
                // Soft top legibility ramp — just enough darken near
                // the menu bar so the header text stays crisp on
                // bright wallpapers. Dies off well before content.
                LinearGradient(
                    colors: [
                        Color.black.opacity(0.10),
                        Color.clear
                    ],
                    startPoint: .top,
                    endPoint: UnitPoint(x: 0.5, y: 0.22)
                )
                // Cool purple wash in the top-left — subtle accent hint.
                RadialGradient(
                    colors: [
                        Color(red: 0.55, green: 0.40, blue: 0.82).opacity(0.10),
                        Color.clear
                    ],
                    center: UnitPoint(x: 0.10, y: 0.02),
                    startRadius: 0,
                    endRadius: 320
                )
                GlassHighlight()
                BottomGlassShadow()
            }
        )
        // Outer rim and inner wall — clean white strokes, no
        // `plusLighter` halo. Combined with the white-lift body, they
        // make the glass read as a thick lens with visible walls.
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
        // Outer drop shadow stack — soft far shadow for ambient lift,
        // tighter close shadow for contact. Reads as "thick glass lens
        // hovering above the desktop."
        .shadow(color: Color.black.opacity(0.35), radius: 22, x: 0, y: 14)
        .shadow(color: Color.black.opacity(0.20), radius: 4, x: 0, y: 2)
        .compositingGroup()
        // Dissolve entry — scale + blur + opacity, anchored top-trailing
        // (where the menu-bar icon lives) so the panel feels like it's
        // condensing out of the status item. No rotation — that was a
        // SwiftUI gimmick, not part of Apple's vocabulary.
        .scaleEffect(presenter.isShown ? 1.0 : 0.86, anchor: .topTrailing)
        .blur(radius: presenter.isShown ? 0 : 14)
        .opacity(presenter.isShown ? 1.0 : 0.0)
        .animation(
            presenter.isShown
                ? .spring(response: 0.46, dampingFraction: 0.78)
                : .easeOut(duration: 0.18),
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
