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

/// Outer rim — clean white edge stroke around the whole panel. Takes
/// the cornerRadius as a param so it can morph alongside the panel
/// during the Alcove notch-emerge animation (pill → full slab).
private struct GlassEdge: View {
    let cornerRadius: CGFloat
    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
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

/// Inner wall — second stroke inset 1.2pt from the outer rim. cornerRadius
/// param tracks the morphing panel radius.
private struct GlassInnerWall: View {
    let cornerRadius: CGFloat
    var body: some View {
        RoundedRectangle(
            cornerRadius: max(cornerRadius - 1.2, 0),
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
    let cornerRadius: CGFloat
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
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
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
    let cornerRadius: CGFloat
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
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .allowsHitTesting(false)
    }
}

/// Inner lens shadow — soft inset shadow that hugs the rim. cornerRadius
/// param tracks the morph so the inset shadow follows the pill→slab
/// transition.
private struct InnerLensShadow: View {
    let cornerRadius: CGFloat
    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
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
            .mask(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .allowsHitTesting(false)
    }
}

enum PanelTab: String, CaseIterable, Identifiable {
    case notes, images, videos, files

    var id: String { rawValue }

    var title: String {
        switch self {
        case .notes: return "Notes"
        case .images: return "Images"
        case .videos: return "Videos"
        case .files: return "Files"
        }
    }
}

struct PanelRootView: View {
    @EnvironmentObject var presenter: PanelPresenter
    @Namespace private var segmentedPill

    /// Closed-state geometry — the "pill at the notch" the panel emerges
    /// from. Width matches a typical notch span (~200pt), height is
    /// thin enough to read as a tab/pill of menu-bar substance, radius
    /// hits the same pill-shape as the macOS notch's bottom corners.
    private static let notchPillWidth: CGFloat = 200
    private static let notchPillHeight: CGFloat = 32
    private static let notchPillRadius: CGFloat = 16

    private var currentWidth: CGFloat {
        presenter.isShown
            ? PanelWindowController.innerPanelWidth
            : Self.notchPillWidth
    }
    private var currentHeight: CGFloat {
        presenter.isShown
            ? PanelWindowController.innerPanelHeight
            : Self.notchPillHeight
    }
    private var currentRadius: CGFloat {
        presenter.isShown
            ? PanelWindowController.innerCornerRadius
            : Self.notchPillRadius
    }

    var body: some View {
        // Alcove-style notch emergence: the inner panel starts as a tiny
        // rounded pill stuck to the top-center of the NSPanel (right
        // under the menu bar / notch) and springs out into the full
        // 340×620 slab. Width, height, and corner radius all morph in
        // a single spring; content inside fades in *after* the shell
        // finishes growing so the pill never shows squished UI.
        //
        // Anchor: .top — so the inner panel always pins to the menu bar
        // edge and grows DOWNWARD only, exactly like Alcove drops out
        // of the notch.
        ZStack(alignment: .top) {
            haloLayer
                .opacity(presenter.isShown ? 1 : 0)
            innerPanel
                .frame(width: currentWidth, height: currentHeight)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .compositingGroup()
        .animation(
            presenter.isShown
                ? .spring(response: 0.55, dampingFraction: 0.66)
                : .spring(response: 0.28, dampingFraction: 0.92),
            value: presenter.isShown
        )
    }

    // MARK: - Halo

    /// Soft blur halo extending past the inner panel on three sides.
    /// Same `.behindWindow` material as the inner panel, but masked so
    /// it shows ONLY in a band around the inner panel — never as a
    /// rectangle that touches the outer NSPanel edges.
    ///
    /// Why the mask must extend PAST the inner panel:
    ///
    /// First boxy attempt sized the mask to nearly fill the frame and
    /// blurred heavily — alpha-1 reached the outer NSPanel boundary,
    /// which is rectangular, and the user saw a hard box.
    ///
    /// Second attempt over-corrected: mask was 20pt SMALLER than the
    /// inner panel on every side. That made alpha-1 sit fully UNDER the
    /// inner panel, with only the very faint blur fringe peeking out.
    /// Result: no halo visible at all — the content next to the panel
    /// stayed sharp, the opposite of what the music-widget reference
    /// shows. User reported "nothing?" on a screenshot.
    ///
    /// Right answer: the alpha-1 zone of the mask must extend OUTWARD
    /// past the inner panel by enough to be obviously blurred (so the
    /// strip directly next to the panel edge clearly smears whatever's
    /// behind it), then blur fades the outer edge of the alpha-1 zone
    /// to alpha-0 well inside the 100pt of frame slack so it never
    /// reaches the rectangular outer NSPanel boundary.
    ///
    /// Numbers (frame is 440×820, inner panel 340×620 anchored
    /// trailing/center, so 100pt of slack on left/top/bottom):
    /// - Mask shape: 400×720 anchored trailing, vertically centered.
    ///   That puts alpha-1 at x∈[40,440] and y∈[50,770]. Inner panel
    ///   is x∈[100,440], y∈[100,720]. So the alpha-1 zone extends
    ///   60pt past inner panel's LEFT edge, and 50pt past TOP/BOTTOM.
    ///   Right edge is flush (panel docks at screen edge — nothing to
    ///   halo into).
    /// - Blur(radius: 30): the alpha-1 edge fades to ~0 over ~60pt of
    ///   visual extent (3σ). With mask left edge at x=40 and outer
    ///   frame at x=0, the fade lands well inside the 40pt of remaining
    ///   slack. Same on top/bottom (mask edges at 50/770, frame at
    ///   0/820, 50pt of slack).
    private var haloLayer: some View {
        // Depth-of-field halo: tracks the morphing inner panel. When
        // the panel is in pill state, the halo wraps the small pill;
        // as the panel springs open, the halo grows alongside.
        // Anchored .top to match the inner panel anchor.
        //
        // Stack inside the mask:
        //   1. VisualEffectBackground — .hudWindow blur of the content
        //      behind, so wallpaper colors next to the panel are smeared.
        //   2. Color.black.opacity(0.30) — explicit darkening so the
        //      halo zone reads as "out-of-focus / recessed" even against
        //      bright wallpapers (Google's saturated blob shapes had
        //      hidden the pure-blur halo entirely).
        //
        // Mask geometry:
        //   - Shape extends 20pt past the inner panel on left and
        //     10pt past on top/bottom so the alpha-1 darkening zone
        //     sits visibly OUTSIDE the panel, not just under it.
        //   - blur(24) on the mask means alpha decays as a Gaussian
        //     from the shape edge. With mask edge at x=80 (20pt past
        //     panel) and frame edge at x=0, that's 80pt of falloff.
        //     alpha at frame edge ≈ exp(-(80/24)²/2) ≈ 0.001, which
        //     is invisible. Same on top/bottom (90pt of slack vs. ~70pt
        //     of effective fade extent at 3σ).
        //
        // Explicit outer .frame() — without it the masked
        // NSViewRepresentable has no size hint and renders blank.
        ZStack {
            VisualEffectBackground()
            Color.black.opacity(0.72)
        }
        .frame(
            width: PanelWindowController.panelWidth,
            height: PanelWindowController.panelHeight
        )
        .mask(
            RoundedRectangle(
                cornerRadius: currentRadius + 6,
                style: .continuous
            )
            .frame(
                width: currentWidth + 20,
                height: currentHeight + 20
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .blur(radius: 24)
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
        // Content fades in *after* the shell finishes springing open
        // — otherwise the header + tabs + list flash inside the tiny
        // pill state and look squished. Reverse on close: content fades
        // out fast so the shell can collapse back into a clean pill.
        .opacity(presenter.isShown ? 1 : 0)
        .animation(
            presenter.isShown
                ? .easeOut(duration: 0.22).delay(0.18)
                : .easeIn(duration: 0.08),
            value: presenter.isShown
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            ZStack {
                VisualEffectBackground()
                Color.black.opacity(0.32)
                EdgeVignette(cornerRadius: currentRadius)
                LiquidSpecular(cornerRadius: currentRadius)
                InnerLensShadow(cornerRadius: currentRadius)
            }
        )
        .overlay(GlassEdge(cornerRadius: currentRadius))
        .overlay(GlassInnerWall(cornerRadius: currentRadius))
        .overlay(
            RoundedRectangle(cornerRadius: currentRadius, style: .continuous)
                .strokeBorder(DS.Color.accent.opacity(presenter.isDropTargeted ? 0.85 : 0), lineWidth: 1.5)
                .animation(.easeInOut(duration: 0.12), value: presenter.isDropTargeted)
                .allowsHitTesting(false)
        )
        .clipShape(RoundedRectangle(cornerRadius: currentRadius, style: .continuous))
        // Stronger drop shadow now that the panel hangs out of the menu
        // bar — Alcove uses a clean black-30 shadow with ~16pt blur and
        // 8pt y-offset to sell the "dropped down out of the notch" feel.
        .shadow(color: Color.black.opacity(0.40), radius: 16, x: 0, y: 8)
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
        case .files:
            FilesGridView()
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
