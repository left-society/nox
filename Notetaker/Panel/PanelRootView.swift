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

/// Bright rim around the entire panel — the "wet glass" rim-light look
/// from the iOS reference. Stronger at the top so the panel feels lit
/// from above; thins out at the bottom.
private struct GlassEdge: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
            .strokeBorder(
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.42),
                        Color.white.opacity(0.18),
                        Color.white.opacity(0.06)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                lineWidth: 0.9
            )
    }
}

/// Inner top glow — light catching the curved top edge of the glass.
private struct GlassHighlight: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.18),
                        Color.white.opacity(0.04),
                        Color.clear
                    ],
                    startPoint: .top,
                    endPoint: UnitPoint(x: 0.5, y: 0.32)
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
                        Color.black.opacity(0.12)
                    ],
                    startPoint: UnitPoint(x: 0.5, y: 0.65),
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
                // Backdrop blur of whatever's behind the panel — does
                // the heavy lifting for the iOS Notification-Center vibe.
                VisualEffectBackground()
                // Soft tint for legibility — was 0.82 (effectively
                // opaque), which killed the blur entirely. 0.32 keeps
                // text readable while still letting the wallpaper bleed
                // through.
                Color.black.opacity(0.32)
                // Top-down legibility ramp so the header doesn't compete
                // with bright wallpapers, and contrast eases off mid-panel.
                LinearGradient(
                    colors: [
                        Color.black.opacity(0.18),
                        Color.black.opacity(0.04)
                    ],
                    startPoint: .top,
                    endPoint: .center
                )
                // Cool purple wash in the top-left corner — same accent
                // hint we had before, kept subtle so the wallpaper still
                // dominates the look.
                RadialGradient(
                    colors: [
                        Color(red: 0.55, green: 0.40, blue: 0.82).opacity(0.18),
                        Color.clear
                    ],
                    center: UnitPoint(x: 0.12, y: 0.04),
                    startRadius: 0,
                    endRadius: 360
                )
                GlassHighlight()
                BottomGlassShadow()
            }
        )
        .overlay(GlassEdge())
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
        .compositingGroup()
        // Liquid dissolve: scale + blur + opacity together, anchored
        // at the top-right corner where the menu bar icon lives, so the
        // panel feels like it's condensing out of (and back into) the
        // status item rather than sliding in from off-screen.
        .scaleEffect(presenter.isShown ? 1.0 : 0.86, anchor: .topTrailing)
        .blur(radius: presenter.isShown ? 0 : 14)
        .opacity(presenter.isShown ? 1.0 : 0.0)
        .animation(presenter.isShown ? .panelOpen : .panelClose, value: presenter.isShown)
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
