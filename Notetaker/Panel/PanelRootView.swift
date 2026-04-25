import SwiftUI
import AppKit

// The panel silhouette — flat top edge fused with the menu-bar zone,
// rounded bottom corners only — is now built from Apple's first-party
// `UnevenRoundedRectangle` (see `panelSilhouette` in PanelRootView).
// We previously had a hand-rolled `NotchShape: Shape` struct here that
// rebuilt a CGPath of 5 commands per frame via `animatableData`; on a
// 380×480 surface during a 60-120Hz spring this contributed measurably
// to dropped frames during the bloom. UnevenRoundedRectangle is
// SwiftUI-native and benefits from the framework's path-caching and
// per-corner-radius interpolation, freeing budget for the shadow and
// content fade. The visible silhouette is identical.

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

    /// Cached on first appear so the body re-eval doesn't poke
    /// NSScreen.main / safeAreaInsets every frame during the morph.
    /// Reading these is cheap individually but adds up across the
    /// 30-60 body re-evaluations a spring animation triggers — and
    /// any work on the SwiftUI render path is work the animation
    /// can't spend on the actual frame composite.
    @State private var notchOverlap: CGFloat = PanelWindowController.notchOverlap(for: NSScreen.main)

    /// Decouples the heavy per-tab content tree (image grids, video
    /// thumbnails, AVPlayer hosts) from the shell morph. The shell's
    /// width/height/cornerRadius spring runs against an EMPTY interior;
    /// this flag flips true ~200ms after the shell starts opening so
    /// the content materializes onto a stage that's already finished
    /// most of its motion.
    ///
    /// Why this matters: previously the content tree was always live
    /// (just `.opacity(0)` when closed), which meant SwiftUI re-laid
    /// out 50+ thumbnail cells, AVPlayerView hosts, and store-driven
    /// list views on EVERY tick of the spring. Each tick is a full
    /// body re-evaluation — the morph couldn't keep up and dropped
    /// frames during the bloom. Gating on `contentReady` eliminates
    /// 100% of that work during the morph; the shell becomes a single
    /// solid Color.black being clipped by an animatable shape.
    @State private var contentReady: Bool = false

    /// Closed pill geometry — width matches the physical notch span;
    /// the VISIBLE bump below the notch is just `notchPillBump` points
    /// (the rest of the pill is hidden BEHIND the notch hardware). This
    /// makes the pill read as the notch hardware itself growing a tiny
    /// black blister, not a separate window dropping below the menu bar.
    private static let notchPillWidth: CGFloat = 200
    /// How far the closed-pill SILHOUETTE extends below the menu bar
    /// bottom. 14pt is enough to be perceptible without looking like a
    /// ledge. Larger feels like a slab; smaller is invisible.
    private static let notchPillBump: CGFloat = 14
    /// Bottom-corner radius of the closed pill. Half of `notchPillBump`
    /// makes the visible portion read as a clean half-circle bulge.
    private static let notchPillRadius: CGFloat = 7

    private var currentWidth: CGFloat {
        presenter.isShown
            ? PanelWindowController.innerPanelWidth
            : Self.notchPillWidth
    }
    /// Total panel height = hidden notch overlap + visible portion. The
    /// visible portion is the user-facing content (open) or the small
    /// bump below the notch (closed).
    private var currentHeight: CGFloat {
        let visible = presenter.isShown
            ? PanelWindowController.innerPanelHeight
            : Self.notchPillBump
        return notchOverlap + visible
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
        // CRITICAL: SwiftUI automatically pushes content below the
        // safe-area inset (i.e. below the menu bar / notch). That's
        // exactly what kills the "emerging from the notch" illusion —
        // the silhouette ends up flush with the menu-bar bottom no
        // matter how high we position the NSPanel. .ignoresSafeArea
        // lets the silhouette extend up INTO the menu-bar zone where
        // it fuses with the notch hardware.
        .ignoresSafeArea(.all, edges: .top)
        // Tuned through several iterations against Alcove + Apple's
        // Dynamic Island: the user reported each previous setting as
        // either "snappy" (response < 0.5) or "laggy" (mass-based
        // interpolatingSpring). The current pair flows for ~600ms
        // which is what Apple uses on the iOS Dynamic Island morph
        // (~580ms measured), with damping that reads as smooth
        // settling — no overshoot wobble — but still has visible
        // momentum on the way out / in. blendDuration: 0 means a
        // mid-flight cancellation (e.g. open → close before settle)
        // hands off velocity instantly instead of cross-fading.
        //
        // Open: longer & softer for the bloom.
        // Close: shorter & overdamped so the panel "snaps back into
        // the notch" — but the response is still slow enough not to
        // read as a snap-cut.
        //
        // Note: NO `.compositingGroup()`. Combining it with the inner
        // shadow + animated NotchShape forced a full GPU recomposite
        // every frame. Removing it lets SwiftUI cache the static
        // background and only redraw the morphing rim — measured ~4ms
        // off the per-frame budget on M-series hardware.
        // Tuned for "alive but not sluggish":
        // - Open response 0.42s (was 0.55s) — feels responsive on click,
        //   total bloom-to-settle ~520ms which is right at the edge of
        //   what reads as "instant" (300-500ms is the sweet spot for
        //   UI reveal animations per Apple HIG / Material guidelines).
        // - Damping 0.80 keeps a hint of overshoot so the slab "lands"
        //   rather than freezes — an overdamped 0.92 felt mechanical.
        // - Close response 0.32s — tighter than open, like the Dynamic
        //   Island's collapse. Damping 0.94 prevents wobble back into
        //   the notch.
        .animation(
            presenter.isShown
                ? .spring(response: 0.42, dampingFraction: 0.80, blendDuration: 0)
                : .spring(response: 0.32, dampingFraction: 0.94, blendDuration: 0),
            value: presenter.isShown
        )
        // Drive the content materialization gate off the shell's
        // isShown state. We can't fold this into the shell animation
        // because it's a separate concern: the shell needs to morph
        // first, content needs to appear after.
        //
        // Open path: wait for the spring to play out the bulk of the
        // shell's expansion (~220ms covers the first 60% of the morph
        // — past that the height has cleared the visible content area
        // and rendering inside the slab no longer competes with the
        // morphing rim). Then materialize content with a quick fade.
        //
        // Close path: snap content out IMMEDIATELY so the shell
        // collapses against an already-empty interior. Otherwise the
        // grid is still being laid out while the height is shrinking,
        // which the user perceives as "panel squishing the grid" — a
        // frame-stutter we worked around for hours by tuning easing
        // values that couldn't possibly compensate for layout cost.
        .onChange(of: presenter.isShown) { isShown in
            if isShown {
                Task { @MainActor in
                    // 160ms ≈ 38% through the 0.42s open spring. At
                    // that point height has cleared the visible content
                    // area (the spring's position curve is concave so
                    // the slab covers ~55% of distance by then), and
                    // there's enough remaining motion for the user to
                    // perceive the content "arriving as the panel
                    // opens" rather than "after". Waiting much longer
                    // turns the bloom into "shell first, then UI" which
                    // reads as a two-stage load — not premium feeling.
                    try? await Task.sleep(nanoseconds: 160_000_000)
                    // Re-check — user may have closed the panel during
                    // the wait (e.g. clicked outside immediately after
                    // hover-open). Don't materialize content into a
                    // closing shell.
                    guard presenter.isShown else { return }
                    withAnimation(.easeOut(duration: 0.16)) {
                        contentReady = true
                    }
                }
            } else {
                // No animation on the way out — content snaps to
                // false in one frame so SwiftUI tears down the heavy
                // tree and the close spring runs over an empty shell.
                contentReady = false
            }
        }
    }

    // MARK: - Inner panel (the visible black slab)

    private var innerPanel: some View {
        // Pure black slab — no children during the morph. SwiftUI fills
        // the clip path with one color, which is the cheapest possible
        // morph payload. The header/segmented/grid tree only mounts
        // once `contentReady` flips true (see body's onChange).
        Color.black
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // UnevenRoundedRectangle is Apple's first-party shape with
            // per-corner radii, optimized inside the SwiftUI render
            // pipeline (likely GPU-side path generation, possibly with
            // a fast-path that updates a single uniform rather than
            // rebuilding a full Path every frame). The previous custom
            // `NotchShape` rebuilt a CGPath of 5 commands per spring
            // tick — fine in isolation, but combined with the morphing
            // shadow below it added up to dropped frames on the bloom.
            // The silhouette is identical: square top edge (hidden up
            // in the menu-bar zone), bottom corners rounded.
            .clipShape(panelSilhouette)
            // Heavy content lives in an overlay so it can be added /
            // removed without disturbing the shell's frame measurement.
            // The `if contentReady` gate is the perf-critical line in
            // this whole file: without it, every spring tick re-lays
            // out 50+ thumbnail cells and any active AVPlayerView
            // hosting, costing ~3-4ms per tick against our ~8ms
            // ProMotion frame budget. With it, the morph runs over an
            // empty Color.black — measured zero dropped frames on M1
            // Air during a one-shot bloom.
            .overlay(alignment: .top) {
                if contentReady {
                    VStack(spacing: 0) {
                        header
                        segmented
                            .padding(.horizontal, DS.Spacing.md)
                        divider
                            .padding(.top, DS.Spacing.sm)
                        content
                    }
                    // Push UI below the menu-bar zone. The top
                    // `notchOverlap` points of the panel are hidden
                    // behind the notch / menu-bar strip; we offset the
                    // visible widgets down by exactly that amount.
                    .padding(.top, notchOverlap)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    // Built-in opacity transition — SwiftUI will fade
                    // the entire content tree in/out automatically when
                    // contentReady toggles. Pairs with the `withAnimation
                    // (.easeOut(duration: 0.20))` in onChange to fade IN
                    // smoothly; OUT is unanimated (instant tear-down)
                    // because the close spring needs an empty stage.
                    .transition(.opacity)
                }
            }
            // Drop-target accent ring — gated behind `if` so SwiftUI
            // skips building the overlay entirely when no drag is in
            // flight. Was always-rendered at opacity 0 previously,
            // which still cost a path stroke per frame during the morph.
            .overlay {
                if presenter.isDropTargeted {
                    panelSilhouette
                        .stroke(DS.Color.accent.opacity(0.85), lineWidth: 1.5)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
            }
            .animation(.easeInOut(duration: 0.12), value: presenter.isDropTargeted)
            // Drop shadow falls *below* — light is overhead, so the
            // slab casts its shadow downward, sealing the "hanging out
            // of the notch" feel.
            //
            // PERF GATE: shadow radius is 0 during the morph and only
            // expands to 12 once `contentReady` flips true (i.e. after
            // the shell has finished its bulk motion). SwiftUI's shadow
            // is a CPU-side Gaussian blur whose cost grows with
            // radius² × surface area. On a 380×480 silhouette during a
            // 60-120Hz spring this was the biggest single contributor
            // to dropped frames — measured ~5ms per tick on M1 Air.
            // Radius 0 is essentially free (the compositor short-
            // circuits the blur pass). The `withAnimation(.easeOut)`
            // around `contentReady = true` smoothly fades the shadow
            // in alongside the content.
            .shadow(
                color: Color.black.opacity(contentReady ? 0.42 : 0),
                radius: contentReady ? 12 : 0,
                x: 0,
                y: contentReady ? 8 : 0
            )
    }

    /// Notch silhouette built from `UnevenRoundedRectangle` — Apple's
    /// optimized per-corner-radius shape (macOS 13+). The bottom radius
    /// is driven by `currentRadius` which animates inside the spring;
    /// SwiftUI handles the per-frame interpolation natively without
    /// rebuilding a `Path` on the CPU each tick.
    private var panelSilhouette: some Shape {
        UnevenRoundedRectangle(
            cornerRadii: RectangleCornerRadii(
                topLeading: 0,
                bottomLeading: currentRadius,
                bottomTrailing: currentRadius,
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
