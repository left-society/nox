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
        RoundedRectangle(cornerRadius: PanelWindowController.innerCornerRadius, style: .continuous)
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
        RoundedRectangle(
            cornerRadius: PanelWindowController.innerCornerRadius - 1.2,
            style: .continuous
        )
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
        .clipShape(RoundedRectangle(cornerRadius: PanelWindowController.innerCornerRadius, style: .continuous))
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
            // Side rim only — soft dark bands on the left and right
            // edges that fall off to clear well before the middle, so
            // the rim reads as "edge" without creating a hot center.
            // The previous version stacked a strong radial gradient
            // (clear center → 62% black corners) on top of these side
            // bands, which produced a spotlight halo where the bright
            // center contrast against the rim made the panel look like
            // a glowing bulb. Pulled the radial entirely; the side rim
            // alone delivers the "rich edge" cue that matches the iOS
            // music widget without the spotlight artifact.
            LinearGradient(
                stops: [
                    .init(color: Color.black.opacity(0.42), location: 0.0),
                    .init(color: Color.black.opacity(0.12), location: 0.08),
                    .init(color: Color.clear, location: 0.22),
                    .init(color: Color.clear, location: 0.78),
                    .init(color: Color.black.opacity(0.12), location: 0.92),
                    .init(color: Color.black.opacity(0.42), location: 1.0)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            // Bottom edge darken — subtle, keeps a hint of overhead
            // light bias without pulling the eye downward. Tight stop
            // (kicks in at 0.86) so it stays a rim cue, not a body
            // darkening that fights the uniform tint.
            LinearGradient(
                stops: [
                    .init(color: Color.clear, location: 0.0),
                    .init(color: Color.clear, location: 0.86),
                    .init(color: Color.black.opacity(0.20), location: 1.0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .clipShape(RoundedRectangle(cornerRadius: PanelWindowController.innerCornerRadius, style: .continuous))
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
        RoundedRectangle(cornerRadius: PanelWindowController.innerCornerRadius, style: .continuous)
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
            .mask(RoundedRectangle(cornerRadius: PanelWindowController.innerCornerRadius, style: .continuous))
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
        // Outer 360×660 frame holds two things: the depth-halo blur
        // (behind, fades to clear at the outer edges) and the visible
        // rounded panel anchored to the trailing edge. The user pointed
        // at Apple's music widget and noted that content NEAR it gets
        // blurred while content FAR stays sharp — the sharp edge of our
        // earlier 340×620 panel sat right against readable text. The
        // halo extends the same `.behindWindow` blur past the rounded
        // slab on three sides so the wallpaper-and-text smearing fades
        // into sharpness rather than cutting hard.
        ZStack(alignment: .trailing) {
            haloLayer
            innerPanel
                .frame(
                    width: PanelWindowController.innerPanelWidth,
                    height: PanelWindowController.innerPanelHeight
                )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .compositingGroup()
        // Dissolve entry — scale + blur + opacity, anchored top-trailing
        // (where the menu-bar icon lives) so the panel feels like it's
        // condensing out of the status item. Both halo and inner slab
        // animate together because the modifiers sit on the outer ZStack.
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

    // MARK: - Halo

    /// Soft blur halo extending past the inner panel on three sides.
    /// Same `.behindWindow` material as the inner panel, but the mask is
    /// sized to MATCH THE INNER PANEL'S POSITION (not the full outer
    /// frame) and then blurred heavily — so the alpha-1 region of the
    /// halo is hidden directly behind the inner panel, and only the
    /// blurred fringe is visible peeking out.
    ///
    /// Why not fill the whole frame: the v18 mask used
    /// `RoundedRectangle(cornerRadius: 60).padding(4).blur(44)` which
    /// made alpha-1 cover almost the entire 400pt-wide frame. Blur(44)
    /// only had ~4pt of room to fade before hitting the rectangular
    /// outer NSPanel boundary, so the corners of that boundary clipped
    /// a still-non-zero halo and the user saw "way too boxy" — which
    /// is exactly what they reported.
    ///
    /// New approach (matches Apple's music widget):
    /// 1. Outer NSPanel grows to 440x820 with 100pt of halo space on
    ///    left/top/bottom (`PanelWindowController.haloPadding`).
    /// 2. Mask shape is sized to (innerPanelWidth - 20) × (innerPanelHeight
    ///    - 20), inset 10pt within the inner panel — so alpha-1 sits
    ///    fully under the inner panel and has no visible edge of its own.
    /// 3. Mask is anchored trailing (matching the inner panel) and
    ///    centered vertically.
    /// 4. Blur(70) feathers the halo ~70pt outward in all directions
    ///    where there's room (left, top, bottom), fading to ~0 well
    ///    inside the 100pt of frame slack — no rectangular clipping.
    private var haloLayer: some View {
        VisualEffectBackground()
            .mask(
                RoundedRectangle(
                    cornerRadius: PanelWindowController.innerCornerRadius - 10,
                    style: .continuous
                )
                .frame(
                    width: PanelWindowController.innerPanelWidth - 20,
                    height: PanelWindowController.innerPanelHeight - 20
                )
                // Position the mask exactly where the inner panel sits:
                // trailing-anchored, centered vertically inside the outer
                // frame. The blur then fades outward symmetrically on the
                // three sides where the frame has room.
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                .blur(radius: 70)
            )
            .allowsHitTesting(false)
    }

    // MARK: - Inner panel (the visible rounded glass slab)

    private var innerPanel: some View {
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
                // Uniform dark tint over the blurred wallpaper. Has to
                // carry most of the text-obscuring work because
                // NSVisualEffectView's blur radius is fixed by the
                // material — it isn't strong enough alone to dissolve
                // sharp text behind. Pushed to 0.32 for two reasons:
                // (1) text behind genuinely disappears, matching the
                // music-widget heaviness the user wants, and (2) it's
                // even across the whole panel, which avoids the
                // "spotlight" look that was happening when the body was
                // light (0.12) but the rim was very dark — the contrast
                // made the bright center read as a glowing bulb.
                Color.black.opacity(0.32)
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
            RoundedRectangle(cornerRadius: PanelWindowController.innerCornerRadius, style: .continuous)
                .strokeBorder(DS.Color.accent.opacity(presenter.isDropTargeted ? 0.85 : 0), lineWidth: 1.5)
                .animation(.easeInOut(duration: 0.12), value: presenter.isDropTargeted)
                .allowsHitTesting(false)
        )
        .clipShape(RoundedRectangle(cornerRadius: PanelWindowController.innerCornerRadius, style: .continuous))
        // Tight close shadow only. The previous radius-22 / y-14 stack
        // extended ~36pt below the inner panel, which got clipped hard
        // at the outer NSPanel rectangle and read as a visible square
        // edge ("shadow looks like a box"). The depth cue now comes from
        // the wallpaper-blur halo behind, so the inner slab only needs
        // a small contact shadow to feel lifted off the desktop.
        .shadow(color: Color.black.opacity(0.30), radius: 6, x: 0, y: 3)
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
