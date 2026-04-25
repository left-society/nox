import SwiftUI
import AppKit

// MORPH ARCHITECTURE
//
// The pill-to-slab morph used to live in this file: SwiftUI animated
// `currentWidth` / `currentHeight` / `currentRadius` against the
// `presenter.isShown` flip via `.animation(.spring(...), value:)`, with
// a `contentReady` gate that delayed heavy children behind a 160ms
// `Task.sleep`. That morph was fundamentally CPU-bound — every spring
// tick triggered a full SwiftUI body re-evaluation + recursive layout
// pass through the whole view tree. The user reported it as "still
// super laggy" and "not even close to smooth" through multiple rounds
// of parameter tuning, which couldn't paper over the architectural
// cost.
//
// The morph now lives in `PanelWindowController.animateOpen` /
// `animateClose`: pure Core Animation, GPU-driven, via
// `panel.animator().setFrame(...)` inside `NSAnimationContext.runAnimationGroup`.
// SwiftUI inside the panel is STATIC during the morph — no internal
// frame morph, no internal cornerRadius morph, no spring on a state
// flag that's flipping mid-animation. Body re-evaluates only on
// discrete `presenter.isShown` flips (twice per show / hide pair),
// not per frame. The visible silhouette change (wide-pill bottom curve
// → tall slab with subtle rounding) comes for free: SwiftUI re-clips
// `Color.black` with a fixed-radius `UnevenRoundedRectangle` against
// the morphing NSHostingView bounds — no Path data being interpolated,
// no shape rebuild per frame. This pattern is from ComfyNotch's
// open-source notch HUD, which we benchmarked against.

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

    /// Cached on first appear so body re-evals don't poke
    /// NSScreen.main / safeAreaInsets every time. The morph itself
    /// no longer triggers per-frame body evals (see file-level note),
    /// so this is purely a defense-in-depth optimization for the
    /// content-fade transition.
    @State private var notchOverlap: CGFloat = PanelWindowController.notchOverlap(for: NSScreen.main)

    // MARK: - Body

    var body: some View {
        // Static black slab, fixed bottom-corner radius. The visible
        // silhouette tracks the NSPanel frame via SwiftUI re-clipping
        // — when the panel is at pill size, the 34pt bottom corners
        // dominate the visible area, reading as a wide soft bump
        // emerging from the notch; when the panel is at slab size,
        // the same 34pt corners read as a subtle Dynamic-Island-style
        // bottom rounding. Continuous morph driven entirely by frame
        // change — zero SwiftUI state animation involved.
        Color.black
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(panelSilhouette)
            .overlay(alignment: .top) { contentOverlay }
            .overlay { dropRingOverlay }
            .ignoresSafeArea(.all, edges: .top)
            // Single-axis state animation: only the content opacity
            // (shown / hidden) and the shadow params interpolate when
            // `presenter.isShown` flips. Frame and radius DO NOT
            // animate here — those are NSPanel-level Core Animation
            // (see PanelWindowController.animateOpen / animateClose).
            //
            // 0.16s ease-out is fast enough that content "arriving as
            // the panel finishes blooming" reads as one cohesive motion
            // rather than two stages. Pairs with PanelWindowController
            // setting isShown=true at the seam between dive and recoil
            // — the 0.16s fade then overlaps the 0.20s recoil settle.
            .animation(.easeOut(duration: 0.16), value: presenter.isShown)
            .animation(.easeInOut(duration: 0.12), value: presenter.isDropTargeted)
            // PERF GATE: shadow renders only when isShown=true (i.e.
            // the morph has progressed past the dive and content is
            // materializing). During the morph itself the shadow
            // radius is 0 — SwiftUI's `.shadow` is a CPU-side Gaussian
            // convolution whose cost grows with radius² × surface
            // area, so radius 0 is essentially free. The fade-in /
            // fade-out is driven by the `.animation` modifier above.
            .shadow(
                color: Color.black.opacity(presenter.isShown ? 0.42 : 0),
                radius: presenter.isShown ? 12 : 0,
                x: 0,
                y: presenter.isShown ? 8 : 0
            )
    }

    // MARK: - Content overlay (header / segmented / grid)

    @ViewBuilder
    private var contentOverlay: some View {
        if presenter.isShown {
            VStack(spacing: 0) {
                header
                segmented
                    .padding(.horizontal, DS.Spacing.md)
                divider
                    .padding(.top, DS.Spacing.sm)
                content
            }
            // Push UI below the menu-bar zone. The top `notchOverlap`
            // points of the panel are hidden behind the notch /
            // menu-bar strip; we offset visible widgets down by exactly
            // that amount so the header lands flush below the bar.
            .padding(.top, notchOverlap)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            // SwiftUI's built-in opacity transition pairs with the
            // `.animation(.easeOut(duration: 0.16), value: isShown)`
            // on the parent — content fades in over 0.16s when shown
            // becomes true, fades out over 0.16s when it becomes false.
            // Heavy children (image grid cells, AVPlayer hosts, store-
            // backed lists) only mount when `isShown==true`, so they
            // never re-lay out during the morph itself.
            .transition(.opacity)
        }
    }

    // MARK: - Drop-target accent ring

    @ViewBuilder
    private var dropRingOverlay: some View {
        if presenter.isDropTargeted {
            panelSilhouette
                .stroke(DS.Color.accent.opacity(0.85), lineWidth: 1.5)
                .transition(.opacity)
                .allowsHitTesting(false)
        }
    }

    // MARK: - Silhouette

    /// Static panel silhouette — flat top edge fused with the menu-bar
    /// zone (top corners square), squircle-style 34pt rounded bottom
    /// corners. Fixed radius (no `currentRadius` morph state). Apple's
    /// `UnevenRoundedRectangle` is internally optimized for per-corner
    /// rendering; SwiftUI re-clips against new NSHostingView bounds
    /// each frame of the NSPanel.frame morph for free.
    private var panelSilhouette: some Shape {
        UnevenRoundedRectangle(
            cornerRadii: RectangleCornerRadii(
                topLeading: 0,
                bottomLeading: PanelWindowController.innerCornerRadius,
                bottomTrailing: PanelWindowController.innerCornerRadius,
                topTrailing: 0
            ),
            style: .continuous
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
