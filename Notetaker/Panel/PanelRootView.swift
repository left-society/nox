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
    /// `.music` is special: it only appears in the segmented bar when
    /// `PanelPresenter.nowPlaying` is non-nil. It exists to give the
    /// panel a *very light* first-paint surface when the user opens
    /// while music is playing — the alternative (defaulting to .notes
    /// every open) pays the heavy NotesListView mount cost during the
    /// open animation, which the user reported as residual lag even
    /// after the always-mount + opacity-gate refactor. With Music as
    /// the auto-routed default during playback, the first frame the
    /// user sees is just album art + title + 3 buttons. The heavier
    /// tabs (Notes, Images, Videos, Files) lazy-mount only when the
    /// user explicitly switches to them — by which point the panel
    /// is already at rest and the mount hitch is far less perceptible.
    case music, notes, images, videos, files

    var id: String { rawValue }

    var title: String {
        switch self {
        case .music: return "Music"
        case .notes: return "Notes"
        case .images: return "Images"
        case .videos: return "Videos"
        case .files: return "Files"
        }
    }

    /// SF Symbol used in the segmented bar for icon-only tabs (Music
    /// is icon-only because the segmented bar is already tight at 4
    /// labels — adding a 5th text label compresses every segment to
    /// the point of unreadability).
    var icon: String? {
        switch self {
        case .music: return "music.note"
        default: return nil
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
        // Outer transparent halo + inner silhouette structure. The
        // NSPanel's frame is `(inner + 2×halo) × (inner + halo)` — the
        // SwiftUI tree here insets by `haloPadding` on left/right/bottom,
        // so the visible silhouette occupies the inner area and the
        // outer halo is transparent space for the shadow to bleed into.
        // Without that bleed area the SwiftUI `.shadow` modifier just
        // gets clipped by the rectangular NSPanel boundary and the panel
        // reads as a pasted-on rectangle — the user described this
        // exactly: "no dropshadow (liquid blur)".
        //
        // The earlier multi-stop gradient + plusLighter-blended notch
        // sheen looked too "lifted" — the user said the new design
        // looked worse and that "black was definitely the choice." The
        // fix is the Alcove vocabulary: solid pure black for the slab
        // (the premium-feeling surface they want), and the depth comes
        // from a quiet rim around the silhouette + a generous luminous
        // drop shadow that escapes into the haloPadding margin.
        //
        // Layer stack (bottom → top):
        //   1. `panelBackground`: solid `Color.black`
        //   2. `contentOverlay`: the actual UI (header/tabs/content)
        //   3. `borderStroke`: subtle 0.5pt rim around the silhouette
        //   4. `dropRingOverlay`: drag-and-drop accent ring (existing)
        // The two `.shadow` calls below stack: a TIGHT dark ground-shadow
        // (close, slightly offset down) for the contact tell, plus a
        // WIDE soft halo (large radius, lower opacity) for the floating
        // glow — same recipe Alcove uses to feel "set into the desktop"
        // rather than "stamped onto" it.
        panelBackground
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(panelSilhouette)
            .overlay(alignment: .top) { contentOverlay }
            .overlay { borderStroke }
            .overlay { dropRingOverlay }
            .padding(.horizontal, PanelWindowController.haloPadding)
            .padding(.bottom, PanelWindowController.haloPadding)
            .ignoresSafeArea(.all, edges: .top)
            // Single-axis state animation: only the content opacity
            // (shown / hidden) and the shadow params interpolate when
            // `presenter.isShown` flips. Frame and radius DO NOT
            // animate here — those are NSPanel-level Core Animation
            // (see PanelWindowController.animateOpen / animateClose).
            .animation(.easeOut(duration: 0.18), value: presenter.isShown)
            .animation(.easeInOut(duration: 0.12), value: presenter.isDropTargeted)
            // PERF GATE: both shadows render only when isShown=true.
            // During the morph itself both radii are 0 — SwiftUI's
            // `.shadow` is a CPU-side gaussian convolution whose cost
            // grows with radius² × surface area, so radius 0 is
            // essentially free. The fade-in / fade-out is driven by
            // the `.animation` modifier above.
            //
            // Two-shadow stack: contact + halo. The contact shadow
            // (tight, dark, slightly offset) reads as the panel
            // pressing down toward the desktop. The halo (wide, dim)
            // is the "liquid blur" the user described — a soft
            // luminance bleed all around the silhouette, not just at
            // the bottom.
            .shadow(
                color: Color.black.opacity(presenter.isShown ? 0.55 : 0),
                radius: presenter.isShown ? 14 : 0,
                x: 0,
                y: presenter.isShown ? 8 : 0
            )
            .shadow(
                color: Color.black.opacity(presenter.isShown ? 0.42 : 0),
                radius: presenter.isShown ? 28 : 0,
                x: 0,
                y: presenter.isShown ? 2 : 0
            )
    }

    // MARK: - Content overlay (header / segmented / grid)

    @ViewBuilder
    private var contentOverlay: some View {
        // ALWAYS-MOUNTED. The previous gated form (`if presenter.isShown
        // { ... }`) made the heavy content tree (NotesListView + image/
        // video/file grids + composer + LazyVStack + ScrollView + drag-
        // and-drop wiring + @FocusState scaffolding) un-mount and re-
        // mount on every show / hide cycle. Even after we deferred the
        // mount until AFTER the panel morph finished (so the morph
        // itself ran cleanly over an empty Color.black slab), the
        // 30-50ms SwiftUI mount + initial layout still landed AS A
        // VISIBLE HITCH right after the recoil settled — the user
        // perceived the gap between "panel arrived" and "content
        // visible" as lag. Reported across multiple iterations as
        // "much better than before but still lagging."
        //
        // Always-mount amortizes the mount cost to app launch, where
        // there's no animation competing for main-thread time and the
        // user can't see it. show() / hide() then just toggles the
        // opacity, which Core Animation can render on a single
        // CALayer alpha update — essentially free.
        //
        // Trade-off: the content tree IS evaluated when the panel is
        // hidden (e.g. @Published changes still trigger body re-evals
        // in mounted children). That's why we use `.opacity(0)` rather
        // than `.hidden()`: opacity-0 keeps layout stable but the
        // SwiftUI render path skips painting transparent fragments
        // entirely. LazyVStack inside ScrollView is lazy by definition
        // and only materializes visible cells, so the hidden cost is
        // dominated by the wrapper views (header, segmented, divider,
        // active-tab content frame), all of which are cheap to keep
        // around. ImagesGridView's thumbnail loader gates work on
        // `presenter.isShown` upstream so it doesn't decode JPEGs in
        // the background.
        //
        // `.allowsHitTesting(presenter.isShown)` ensures the invisible
        // content can't intercept clicks. Without this, a click that
        // landed in the closed-pill region while the panel is hidden
        // could be eaten by an invisible search-bar TextField or
        // segmented-control button.
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
        .opacity(presenter.isShown ? 1 : 0)
        .allowsHitTesting(presenter.isShown)
    }

    // MARK: - Background layers

    /// Solid pure black. The user explicitly asked for black after the
    /// gradient version landed: "black was definitely the choice but
    /// we need to something around it / Like alcove." Depth now comes
    /// from the drop shadow on the parent and the quiet rim below —
    /// not from any internal lift. Keeps the slab reading as a piece
    /// of premium dark hardware, not a tinted glass panel.
    private var panelBackground: some View {
        Color.black
    }

    /// Quiet 0.5pt rim around the silhouette — Alcove's signature
    /// treatment. Just enough edge definition to keep the slab from
    /// dissolving into very-dark wallpapers, but not so bright it
    /// reads as a sheen on glass. White at 6% opacity is below the
    /// noise floor of most desktops; the user reads it as "the slab
    /// has an edge" without being able to point to a specific stroke.
    @ViewBuilder
    private var borderStroke: some View {
        panelSilhouette
            .stroke(Color.white.opacity(0.06), lineWidth: 0.5)
            .allowsHitTesting(false)
            .opacity(presenter.isShown ? 1 : 0)
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
        // `presenter.visibleTabs` injects the .music tab at the head
        // when something is playing, otherwise returns the original
        // 4-tab strip. Animating on the visible-tab list ID gives a
        // tidy slide-in / slide-out when music starts or stops mid-
        // session — without it, the row would just pop new segments
        // into existence and feel jittery.
        HStack(spacing: 2) {
            ForEach(presenter.visibleTabs) { tab in
                segmentButton(for: tab)
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous)
                .fill(DS.Color.bgSubtle)
        )
        .animation(.selection, value: presenter.visibleTabs)
    }

    private func segmentButton(for tab: PanelTab) -> some View {
        let isSelected = presenter.activeTab == tab
        return Button {
            withAnimation(.selection) { presenter.activeTab = tab }
        } label: {
            // Icon-only when the tab provides one (currently Music) —
            // the segmented bar gets cramped at 5 text labels, so
            // collapsing Music to a 12pt music.note keeps every text
            // label readable. The icon's intrinsic width is also
            // narrower than a label like "Files," which lets the
            // remaining tabs spread evenly.
            Group {
                if let icon = tab.icon {
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                } else {
                    Text(tab.title)
                        .font(.nkMeta.weight(isSelected ? .semibold : .regular))
                }
            }
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
        // SwiftUI's switch-based ViewBuilder is already lazy: only the
        // active case is in the view tree, the others aren't mounted
        // at all. That's the foundation of the open-lag fix — when
        // `activeTab` is .music on open, NotesListView / ImagesGridView
        // / VideosGridView / FilesGridView are NOT instantiated, so
        // their first-paint cost (composer + LazyVStack + image decode
        // + ScrollView content-size calc + onAppear hooks for link
        // previews) is paid lazily on the first deliberate tab tap,
        // not during the panel-open animation.
        switch presenter.activeTab {
        case .music:
            MusicPanelView()
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
        // `SettingsLink` (macOS 14+) is the canonical way to open the
        // SwiftUI `Settings` scene — it goes through the proper
        // environment plumbing instead of guessing at the responder
        // chain via `NSApp.sendAction(...)`. The earlier imperative
        // call silently no-oped on this LSUIElement app because the
        // panel isn't a main/key window, so the action selector
        // couldn't find a handler. The legacy fallback below is a
        // courtesy for macOS 13 (technically still our deployment
        // target, though we expect ~zero users on it).
        Group {
            if #available(macOS 14, *) {
                SettingsLink {
                    gearGlyph
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    SettingsWindow.open()
                } label: {
                    gearGlyph
                }
                .buttonStyle(.plain)
            }
        }
        .onHover { hovering in
            withAnimation(.rowHover) { isHovered = hovering }
        }
    }

    private var gearGlyph: some View {
        Image(systemName: "gearshape")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(isHovered ? DS.Color.textSecondary : DS.Color.textTertiary)
            .frame(width: 20, height: 20)
            .contentShape(Rectangle())
    }
}

#Preview {
    PanelRootView()
        .preferredColorScheme(.dark)
        .frame(width: 340, height: 700)
        .background(Color.black)
}
