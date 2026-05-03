import SwiftUI

/// Two-zone drop picker that overlays the panel during a drag.
///
/// Visual:
///   ┌──────────────────┬──────────────────┐
///   │   ⬇ Save         │   ✈ AirDrop      │
///   │  to Notetaker    │  to a device     │
///   └──────────────────┴──────────────────┘
///
/// The hovered zone scales to ~1.04× and gains a soft purple glow;
/// the other zone fades to ~0.6 opacity to signal "the drag is
/// committed elsewhere." Releasing over a zone fires that zone's
/// destination.
///
/// State is driven by `PanelPresenter.dropPickerActive` (visibility)
/// and `PanelPresenter.dropPickerHoveredZone` (which zone is hot).
/// The `PanelDropContainer` (AppKit layer below this) computes the
/// hovered zone from cursor position during `draggingUpdated:` and
/// publishes it via the presenter — this view is purely
/// presentational.
///
/// Reference: Dropover's "Instant Actions" — same pattern, same
/// hit-test-during-drag gesture model. Industry-validated.
struct DropPickerView: View {
    /// Currently-hovered zone, or nil if cursor is between zones /
    /// outside the picker. Controlled by AppKit drop layer below.
    let hoveredZone: DropDestination?
    /// Number of files in the active drag. Surfaces as a small
    /// "✈ N" badge over the AirDrop zone so the user knows the
    /// whole batch was recognized BEFORE they drop. Default 0
    /// keeps the badge hidden when no count is available (e.g.
    /// pure-text drag).
    var fileCount: Int = 0

    var body: some View {
        // Single seamless surface — no card backgrounds, no outer
        // strokes. The panel's existing black silhouette IS the
        // surface; the picker just paints two zones on it with a
        // hairline midline divider. Matches the rest of the app's
        // restrained dark aesthetic (transient pills also paint
        // directly on the black background, no card chrome).
        HStack(spacing: 0) {
            DropZoneCard(
                destination: .save,
                // `square.and.arrow.down` is the macOS share/save
                // convention — same glyph the system uses for "save
                // a copy" in share sheets.
                icon: "square.and.arrow.down",
                title: "Save",
                subtitle: "to nox",
                // 2026-05-02: brand Lavender Mist accent for the
                // Save zone — this is the app's primary "save to
                // your storage" action, and should carry the brand
                // color. AirDrop side keeps its existing Apple-
                // sky-blue (the OS's own AirDrop accent).
                accent: DS.Color.brandLavender,
                isHovered: hoveredZone == .save,
                isOtherHovered: hoveredZone == .airDrop
            )

            // Hairline vertical divider between zones. Only visible
            // when neither zone is hovered (drops out the moment a
            // commitment forms, so the eye reads "the hovered zone
            // is the whole surface").
            Rectangle()
                .fill(Color.white.opacity(hoveredZone == nil ? 0.08 : 0))
                .frame(width: 0.5)
                .padding(.vertical, 28)
                .animation(.easeOut(duration: 0.18), value: hoveredZone)

            DropZoneCard(
                destination: .airDrop,
                // `icon: nil` tells DropZoneCard to render the
                // custom `AirDropLogo` shape instead of an SF
                // Symbol — Apple's AirDrop mark has no matching
                // SF Symbol.
                icon: nil,
                title: "AirDrop",
                // Subtitle morphs based on the drag's file count.
                // Single file or unknown → "to a device"; 2+ files
                // → "5 files · to a device" so the user sees the
                // whole batch was picked up before they release.
                subtitle: fileCount > 1 ? "\(fileCount) files · to a device" : "to a device",
                // 2026-05-02: AirDrop side uses the OS's own
                // AirDrop accent (sky blue, also used by the
                // app for `airDropReceived` / `screenshotSaved`
                // events). This creates a clear hierarchy:
                // lavender = "app's own action" (Save), sky-blue
                // = "system action" (AirDrop). Same convention
                // Apple uses internally — system services have
                // their own colors, app brand color is separate.
                accent: Color(red: 0.30, green: 0.78, blue: 0.99),
                isHovered: hoveredZone == .airDrop,
                isOtherHovered: hoveredZone == .save
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            DictationOrchestrator.dlog("🎨 DropPickerView.onAppear hoveredZone=\(String(describing: hoveredZone))")
        }
    }
}

private struct DropZoneCard: View {
    let destination: DropDestination
    /// SF Symbol name for the icon, or `nil` to render the custom
    /// `AirDropLogo` shape instead. The AirDrop mark has no
    /// matching SF Symbol — see `AirDropLogo` doc in PanelRootView.swift.
    let icon: String?
    let title: String
    let subtitle: String
    let accent: Color
    let isHovered: Bool
    /// True when the OTHER zone is the hot one. Used to fade this
    /// zone so the cursor's commitment is visually unambiguous.
    let isOtherHovered: Bool

    /// Effective icon tint. Pure-white at rest, slightly dimmer when
    /// the other zone is hovered (so the cold zone fades), full
    /// white when this zone is hovered. No color accents — the
    /// hover-state glass material provides commitment signal
    /// instead.
    private var iconTint: Color {
        if isHovered { return Color.white }
        return Color.white.opacity(isOtherHovered ? 0.30 : 0.65)
    }

    var body: some View {
        VStack(spacing: 12) {
            // Icon — bigger so it fills the larger full-coverage
            // zone proportionally.
            ZStack {
                if let icon = icon {
                    Image(systemName: icon)
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(iconTint)
                } else {
                    // Custom AirDrop mark — concentric arcs + wedge.
                    // Sized to visually match the SF-Symbol icon
                    // in the other zone.
                    AirDropLogo(tint: iconTint, lineWidth: 1.8)
                        .frame(width: 38, height: 38)
                }
            }
            .scaleEffect(isHovered ? 1.06 : 1.0)

            VStack(spacing: 3) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(
                        isHovered
                            ? Color.white
                            : Color.white.opacity(isOtherHovered ? 0.40 : 0.88)
                    )
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(
                        Color.white.opacity(
                            isHovered ? 0.65 : (isOtherHovered ? 0.25 : 0.48)
                        )
                    )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Layered backgrounds:
        //   • Rest:    very faint white (2%) — barely-there tint
        //              so the user can SEE that each half is a
        //              drop target without it shouting. Without
        //              this the zones looked invisible and the
        //              icons appeared to float in a black void.
        //   • Hovered: glass material (VisualEffectBlur sampling
        //              the desktop behind the panel) plus a
        //              brighter white overlay. The hover state
        //              reads unambiguously as "this side is
        //              committed."
        // Both fill the full half top-to-bottom, edge-to-edge.
        .background {
            ZStack {
                Color.white.opacity(0.02)
                if isHovered {
                    VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow)
                        .overlay(Color.white.opacity(0.08))
                        .transition(.opacity)
                }
            }
        }
        .animation(.easeOut(duration: 0.18), value: isHovered)
        .animation(.easeOut(duration: 0.18), value: isOtherHovered)
    }
}
