import SwiftUI
import AppKit

private struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        // `.hudWindow` has the heaviest gaussian blur of any macOS
        // material. That heavy blur is the "liquid" property: text and
        // shapes behind the panel get smeared into colored fog rather
        // than staying readable, the same way iOS's Notification Center
        // music widget renders. We then reduce the OVERALL strength via
        // SwiftUI `.opacity()` upstream so the dark tint contribution
        // drops while the blur radius stays high — that gives the panel
        // wallpaper-bleed-through with smeared content instead of
        // sharp visible text.
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.isEmphasized = false
        view.appearance = NSAppearance(named: .vibrantDark)
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// Outer rim — clean white edge stroke around the whole panel. The
/// rim must be visible on all four corners or the panel reads as
/// asymmetric ("dissolving away at the bottom"). Was a 0.45 → 0.06
/// gradient which made bottom corners nearly invisible against a dark
/// wallpaper; now a tighter 0.40 → 0.20 range so every corner is
/// clearly defined while keeping a slight overhead-light bias.
private struct GlassEdge: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
            .strokeBorder(
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.42),
                        Color.white.opacity(0.28),
                        Color.white.opacity(0.20)
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

/// Focused specular reflection — a small, bright arc at the very top
/// of the panel that reads as overhead light catching the curve of a
/// thick lens. This is the key "liquid" detail: a real specular looks
/// like a focused reflection, not a wide gradient wash. Concentrated
/// in the upper third, falls off fast, with a brighter horizontal
/// streak that suggests the wet/glossy surface.
private struct LiquidSpecular: View {
    var body: some View {
        ZStack {
            // Bright focused arc just inside the top edge — the "lens
            // catches the overhead light" highlight. Radial so it reads
            // as a curved reflection rather than a flat band.
            RadialGradient(
                colors: [
                    Color.white.opacity(0.35),
                    Color.white.opacity(0.10),
                    Color.clear
                ],
                center: UnitPoint(x: 0.5, y: -0.15),
                startRadius: 0,
                endRadius: 220
            )
            // Subtle horizontal sheen line near the top — the "wet
            // surface" highlight that sells the liquid feel.
            LinearGradient(
                colors: [
                    Color.clear,
                    Color.white.opacity(0.12),
                    Color.clear
                ],
                startPoint: UnitPoint(x: 0, y: 0.04),
                endPoint: UnitPoint(x: 1, y: 0.04)
            )
            .frame(height: 1.5)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, 6)
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .allowsHitTesting(false)
    }
}

/// Edge vignette — darkens the perimeter (left + right + bottom) so
/// the panel reads as a "rich" glass slab rather than a flat translucent
/// rectangle. The user pointed to an iOS music widget where the sides
/// are visibly blacker than the center; a real glass slab catches less
/// ambient light at its periphery, and matching that creates the
/// premium feel.
///
/// Implementation: a radial gradient from clear at the center to dark
/// at the corners, biased downward so the top stays lighter (where the
/// specular highlight lives). Multiplied with the wallpaper-bleed
/// material below, so it darkens *the wallpaper showing through* rather
/// than painting an opaque rectangle on top.
private struct EdgeVignette: View {
    var body: some View {
        ZStack {
            // Primary radial — center clear, corners darken to ~50%
            // black. Center biased slightly upward (y: 0.40) so the
            // bottom darkens more than the top, matching a real overhead
            // light source. Tighter inner stop (clear out to 0.4) keeps
            // the lit area focused so the vignette reads as a "halo of
            // shadow around the rim" rather than a global dimming.
            RadialGradient(
                colors: [
                    Color.clear,
                    Color.clear,
                    Color.black.opacity(0.30),
                    Color.black.opacity(0.50)
                ],
                center: UnitPoint(x: 0.5, y: 0.40),
                startRadius: 50,
                endRadius: 230
            )
            // Side reinforcement — a left-to-right gradient that
            // darkens the LEFT and RIGHT edges specifically, since a
            // pure radial only catches the corners and the straight
            // side panels would still look flat. Symmetric horizontal
            // mask hits both sides equally. Pushed hard (0.48) so the
            // long vertical sides read as clearly black — that's the
            // cue the user pointed to in the iOS music widget. Falls
            // off quickly (clear by 25% in) so the visible dark band
            // is a tight rim, not a global dim.
            LinearGradient(
                stops: [
                    .init(color: Color.black.opacity(0.48), location: 0.0),
                    .init(color: Color.black.opacity(0.18), location: 0.10),
                    .init(color: Color.clear, location: 0.25),
                    .init(color: Color.clear, location: 0.75),
                    .init(color: Color.black.opacity(0.18), location: 0.90),
                    .init(color: Color.black.opacity(0.48), location: 1.0)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            // Bottom lift — softer extra darkening on just the bottom
            // edge. Sells the "light comes from above" lighting model
            // and keeps the panel from feeling bottom-heavy.
            LinearGradient(
                stops: [
                    .init(color: Color.clear, location: 0.0),
                    .init(color: Color.clear, location: 0.78),
                    .init(color: Color.black.opacity(0.22), location: 1.0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .allowsHitTesting(false)
    }
}

/// Inner lens shadow — soft inset shadow that hugs the rim, simulating
/// the way light bends through the curved edge of a thick glass element.
/// Adds dimension without darkening the body, so the wallpaper still
/// bleeds through clearly. The shadow is concentrated at the bottom and
/// sides where a real lens would refract most.
private struct InnerLensShadow: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
            .stroke(
                LinearGradient(
                    colors: [
                        Color.clear,
                        Color.black.opacity(0.15),
                        Color.black.opacity(0.25)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                lineWidth: 6
            )
            .blur(radius: 4)
            .mask(RoundedRectangle(cornerRadius: 20, style: .continuous))
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
                // Behind-window blur — `.hudWindow` is macOS's heaviest
                // single material. Wallpaper colors smear through as
                // diffuse fog, the panel content stays visible on top.
                VisualEffectBackground()
                // Dark tint over the blurred wallpaper. Two competing
                // requirements: (1) text behind must dissolve out — pure
                // blur from .hudWindow isn't strong enough on its own, so
                // the dark layer has to carry some of the obscuring;
                // (2) wallpaper hue must still bleed through visibly so
                // the panel reads as "glass on top of the desktop"
                // rather than a solid sheet. 0.20 leans toward bleed:
                // wallpaper color is clearly visible in the center,
                // body text smears into a soft gradient (with the
                // .hudWindow blur doing the heavy lifting), and the
                // vignette layer below adds back the necessary darkness
                // at the periphery for the rich premium feel.
                Color.black.opacity(0.20)
                // Edge vignette — darker sides + bottom for the "rich
                // premium" vibe the user pointed to in the music widget.
                // A real glass slab catches less light at its periphery
                // than at its center; this gradient simulates that.
                EdgeVignette()
                // Focused specular reflection — bright arc at the top
                // edge that reads as overhead light catching the curve.
                LiquidSpecular()
                // Inner lens shadow — soft inset shadow that hugs the
                // rim, simulating the curved edge of a thick glass lens.
                InnerLensShadow()
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
