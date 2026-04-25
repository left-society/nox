import SwiftUI
import AppKit

/// Alcove-style notch shape: flat top edge (anchored to the menu bar
/// bottom so it reads as the physical notch extending downward), with
/// rounded bottom corners only. The bottom radius animates alongside
/// the panel's width and height during the morph.
///
/// Why a custom shape instead of `RoundedRectangle`: a uniformly rounded
/// rectangle reads as a "floating slab" — its top corners curve inward
/// away from the menu bar. Real notches sit FLUSH with the screen top:
/// their visible silhouette has a square top (hidden behind the menu
/// bar/notch) and curves only at the bottom-left and bottom-right where
/// they meet the screen content. Copying that silhouette is the single
/// biggest "this is Alcove" cue. Without it, no amount of black tint or
/// spring tuning sells the illusion.
private struct NotchShape: Shape {
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

    /// Closed pill geometry — sized to read as a hair-wider extension of
    /// the physical notch. Width matches a typical notch span, height
    /// matches the menu bar so the pill is the same vertical "slab" as
    /// the notch when the user first sees it bloom.
    private static let notchPillWidth: CGFloat = 200
    private static let notchPillHeight: CGFloat = 36
    private static let notchPillRadius: CGFloat = 18

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
        // Alcove emergence: the panel begins as a small black pill flush
        // with the menu bar's bottom (top corners square, bottom corners
        // rounded), and morphs into the full slab. Width, height, and
        // bottom radius all animate in a single spring. Content inside
        // fades in AFTER the shell finishes growing so the pill state
        // never displays squished UI.
        ZStack(alignment: .top) {
            innerPanel.frame(width: currentWidth, height: currentHeight)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .compositingGroup()
        .animation(
            presenter.isShown
                // Open: snappy with a hint of settle. Alcove feels confident,
                // not bouncy — response 0.42 / damping 0.78 lands the slab
                // in ~0.5s with a barely-perceptible overshoot.
                ? .spring(response: 0.42, dampingFraction: 0.78)
                // Close: faster collapse, no bounce. We don't want the pill
                // to jiggle as it disappears.
                : .spring(response: 0.32, dampingFraction: 0.96),
            value: presenter.isShown
        )
    }

    // MARK: - Inner panel (the visible black slab)

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
        // (delay 0.18s ≈ 40% into the open spring). Reverse on close:
        // content clears fast so the shell collapses cleanly.
        .opacity(presenter.isShown ? 1 : 0)
        .animation(
            presenter.isShown
                ? .easeOut(duration: 0.20).delay(0.18)
                : .easeIn(duration: 0.08),
            value: presenter.isShown
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            ZStack {
                // Solid black — Alcove's signature. The panel reads as
                // the physical notch extending downward; glass blur
                // would break the illusion (you'd see wallpaper through
                // what's supposed to be the notch hardware).
                Color.black
                // Faint top sheen — picks up "menu-bar light" along the
                // top edge so the slab doesn't look perfectly flat.
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.06),
                        Color.clear
                    ],
                    startPoint: .top,
                    endPoint: .center
                )
                .allowsHitTesting(false)
            }
        )
        .clipShape(NotchShape(bottomRadius: currentRadius))
        .overlay(
            // Drop-target accent ring — only visible when the user is
            // dragging something over the panel. Uses `.stroke` (not
            // `.strokeBorder`) because NotchShape isn't InsettableShape.
            NotchShape(bottomRadius: currentRadius)
                .stroke(
                    DS.Color.accent.opacity(presenter.isDropTargeted ? 0.85 : 0),
                    lineWidth: 1.5
                )
                .animation(.easeInOut(duration: 0.12), value: presenter.isDropTargeted)
                .allowsHitTesting(false)
        )
        // Drop shadow falls *below* — light is overhead, so the slab
        // casts its shadow downward, sealing the "hanging out of the
        // notch" feel. No blur or x-offset on the sides — those would
        // read as a floating object, not an extension of the notch.
        .shadow(color: Color.black.opacity(0.45), radius: 18, x: 0, y: 12)
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
        .background(Color.black)
}
