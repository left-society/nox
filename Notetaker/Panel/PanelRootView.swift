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

    /// Bottom-corner radius for the panel silhouette. 16pt when sitting
    /// at the resting closed-pill geometry (gives quarter-circle corners
    /// reading as a pill), 34pt when expanded into the slab (subtle
    /// squircle reading as a HUD card). SwiftUI animates this via the
    /// chained `.animation(.easeOut(duration: 0.18), value: presenter.isShown)`
    /// modifier on the parent — `UnevenRoundedRectangle` interpolates
    /// `RectangleCornerRadii` continuously, so the corners morph in
    /// lockstep with the panel-frame morph driven by Core Animation.
    /// During the ~450ms expand animation the SwiftUI radius animation
    /// (0.18s) lands first, but the corners are barely visible during
    /// the early part of the morph (panel still close to pill size, so
    /// the bottom edge fills the visible silhouette regardless of
    /// radius) — the visual handoff reads as one continuous shape change.
    private var panelBottomRadius: CGFloat {
        presenter.isShown
            ? PanelWindowController.innerCornerRadius
            : PanelWindowController.pillCornerRadius
    }

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
            .overlay(alignment: .top) { pillContentOverlay }
            .overlay(alignment: .top) { contentOverlay }
            .overlay { borderStroke }
            .overlay { dropRingOverlay }
            .padding(.horizontal, PanelWindowController.haloPadding)
            .padding(.bottom, PanelWindowController.haloPadding)
            .ignoresSafeArea(.all, edges: .top)
            // Single-axis state animation: content opacity, shadow
            // params, AND the bottom-corner radius interpolation
            // (UnevenRoundedRectangle's `RectangleCornerRadii` is
            // animatable) all run on this one timeline. Frame morph
            // is driven separately at the NSPanel level via Core
            // Animation (see PanelWindowController.animateOpen).
            //
            // `.smooth` is SwiftUI's interpolating-spring preset —
            // settled landing, no overshoot. Same Animation value
            // Alcove uses (the literal `smooth` is in their binary
            // alongside damping/stiffness symbols), and it gives the
            // radius morph a calmer, more "premium hardware" feel
            // than a linear ease-out on the corner shape.
            .animation(.smooth, value: presenter.isShown)
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
        // Progressive-blur materialization. When the panel is closed
        // (or morphing toward closed), the content tree is rendered
        // with a 10pt gaussian blur; as `presenter.isShown` flips true
        // the blur animates to 0 alongside the parent's `.smooth`
        // animation. The user sees the header / segmented bar / list
        // dissolve INTO focus rather than fade in flat — same
        // "progressive blur" effect Alcove ships (its binary contains
        // a `progressiveBlurTransitionTask` symbol). The 10pt radius
        // is heavy enough to feel like the content is materializing
        // (not just appearing), but light enough that mid-morph reads
        // are still legible — typography stays decipherable through
        // the blur, so the transition feels like a focus pull rather
        // than a fog-of-war reveal.
        //
        // SwiftUI's `.blur` runs as a Metal filter on the off-screen
        // surface for this overlay only. Cost is proportional to the
        // surface area × radius²; at 10pt with a ~380×480 slab this
        // is well under one frame's GPU budget on Apple Silicon. We
        // pay it only during the ~0.5s morph (radius 0 outside the
        // animation, so the steady-state cost is zero).
        .blur(radius: presenter.isShown ? 0 : 10)
        .allowsHitTesting(presenter.isShown)
    }

    // MARK: - Pill content overlay (resting now-playing indicator)

    /// Artwork + waveform pill body — rendered inside the SAME NSPanel
    /// that hosts the full slab content, so the resting pill and the
    /// expanded slab are literally one window morphing. This is the
    /// architectural shift the user asked for: "the pill should be
    /// always there... when you press the cursor to that, it just
    /// expands the music thing." Confirmed against Alcove's binary
    /// (NotchController + NotchPanel + _isExpanded/_isHovering flags
    /// in `/Applications/Alcove.app/Contents/MacOS/Alcove`).
    ///
    /// Visibility gate: `isResting && !isShown`. Mutually exclusive with
    /// `contentOverlay` (which is gated on `isShown`). When the panel
    /// expands, isShown flips true → pill fades out as the full content
    /// fades in. The 0.18s easeOut on the parent runs both crossfades
    /// in lockstep alongside the Core Animation frame morph.
    ///
    /// Layout: the pill content (artwork + waveform) sits ENTIRELY
    /// within the notch+menu-bar zone (the upper `notchOverlap` of the
    /// panel, ~32pt on a 16"/14" notched Mac). With closedPillBump=0pt
    /// there is no visible-below-menu-bar strip — the content reads as
    /// if it's PART OF the notch hardware itself, the same trick Alcove
    /// uses. Pixel measurement of `/Applications/Alcove.app` showed
    /// their resting pill silhouette ends at y=31.5pt — half a point
    /// shy of the menu-bar bottom — and content is rendered in the
    /// lower portion of the notch zone (below the camera lens). HStack
    /// with 14pt artwork + 16×8 waveform, centered vertically within
    /// the 32pt notch zone with horizontal padding tuned so the pair
    /// reads as integrated rather than crammed.
    @ViewBuilder
    private var pillContentOverlay: some View {
        HStack(spacing: 6) {
            pillArtwork
            Spacer(minLength: 0)
            WaveformView(
                isPlaying: presenter.nowPlaying?.isPlaying ?? false,
                width: 16,
                height: 8,
                lineWidth: 1.2,
                tint: .white,
                opacity: 0.85
            )
        }
        .padding(.horizontal, 10)
        // Content fills exactly the notch+menu-bar zone (notchOverlap),
        // centered vertically. The HStack's children (14pt artwork +
        // 16×8 waveform) end up roughly centered vertically inside the
        // 32pt zone — clears the camera lens (top of notch) AND the
        // menu-bar bottom edge with a few points of breathing room
        // above and below.
        .frame(height: notchOverlap)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .opacity(presenter.isResting && !presenter.isShown ? 1 : 0)
        // Symmetric dissolve on the pill artwork+waveform during
        // the morph TO slab. At rest (isResting && !isShown) the
        // pill body is sharp; the moment isShown flips the pill
        // content blurs out alongside its opacity fade so it dissolves
        // INTO the materializing slab content rather than just popping
        // out. Smaller radius (6pt) than the slab's 10pt because the
        // pill content is tiny (16×16 artwork + 16×10 waveform) — a
        // larger blur would smear it into invisibility instantly,
        // whereas 6pt lets it ghost briefly during the cross-fade.
        .blur(radius: presenter.isResting && !presenter.isShown ? 0 : 6)
        .allowsHitTesting(false)
    }

    /// 14×14 album-art tile sized to fit inside the 32pt notch zone
    /// (downsized from 16pt to clear the camera lens above and the
    /// menu-bar bottom below with a few points of breathing room).
    /// Reads cleanly at retina without dominating — proportions match
    /// Alcove's resting-pill thumbnail. Kept inline rather than
    /// imported because NowPlayingPillView is gated on its own isShown /
    /// motion-blur state machine that doesn't apply inside the unified
    /// panel.
    @ViewBuilder
    private var pillArtwork: some View {
        Group {
            if let data = presenter.nowPlaying?.artworkData,
               let img = NSImage(data: data) {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color.white.opacity(0.08)
                    Image(systemName: "music.note")
                        .font(.system(size: 7, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
        }
        .frame(width: 14, height: 14)
        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
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

    /// Panel silhouette — flat top edge fused with the menu-bar zone
    /// (top corners square), and a state-dependent bottom-corner radius.
    /// 16pt when resting (closed-pill quarter-circle corners), 34pt
    /// when expanded (slab squircle). SwiftUI re-clips against the
    /// morphing NSHostingView bounds each frame of the NSPanel.frame
    /// Core Animation morph, and the `RectangleCornerRadii`
    /// interpolation handles the radius transition so the silhouette
    /// shape changes smoothly alongside the size morph.
    private var panelSilhouette: some Shape {
        UnevenRoundedRectangle(
            cornerRadii: RectangleCornerRadii(
                topLeading: 0,
                bottomLeading: panelBottomRadius,
                bottomTrailing: panelBottomRadius,
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
        // We deliberately do NOT use `SettingsLink` or the SwiftUI
        // `Settings { }` scene. The panel's SwiftUI tree is mounted via
        // `NSHostingController` inside an `NSPanel`, which creates a
        // separate SwiftUI root that does not inherit the App scene's
        // environment. `SettingsLink` resolves an unbound `\.openSettings`
        // there and silently no-ops; the legacy `showSettingsWindow:`
        // action selector also fails because `LSUIElement = true` means
        // there's no main window in the responder chain.
        //
        // `SettingsWindow.open()` instead routes to AppDelegate, which
        // owns an `NSWindow` directly and pushes a SwiftUI `SettingsView`
        // into it via `NSHostingController` — bypassing the scene
        // plumbing entirely.
        Button {
            NSLog("Notetaker: gear button tapped")
            SettingsWindow.open()
        } label: {
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
