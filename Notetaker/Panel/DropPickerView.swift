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
    /// Accent color for the Save zone glow + chrome. Defaults to
    /// brand lavender so the picker has its own identity at rest;
    /// callers pass the parent panel's dynamic `panelAccent` so
    /// the Save zone follows the now-playing artwork's color when
    /// music is on. AirDrop side keeps Apple's system sky blue
    /// regardless — that's the OS-native AirDrop tint and
    /// shouldn't change based on what's playing.
    var accent: Color = DS.Color.brandLavender

    var body: some View {
        // 2026-05-24 — INSET CARDS, no border. Per user feedback
        // ("go back to privious design just dont have the glows").
        //
        // Two side-by-side cards (rounded continuous squircle,
        // 14pt radius), 8pt margin from slab edges, 10pt gap
        // between cards. Save = LEFT half, AirDrop = RIGHT half
        // (VideoDropCatcher.zoneAt restored to x-based mapping).
        //
        // Rest: each card has a 4% white background fill.
        // Hover:  the hovered card's background swaps to an
        //         accent-tinted fill (~18% accent opacity).
        // No accent border, no shadow, no scale, no shadow-glow,
        // no hairline. The fill change IS the entire commit
        // affordance.
        HStack(spacing: 0) {
            DropZoneCard(
                destination: .save,
                icon: "square.and.arrow.down",
                title: "Save",
                subtitle: "to nox",
                accent: accent,
                isHovered: hoveredZone == .save,
                isOtherHovered: hoveredZone == .airDrop
            )

            DropZoneCard(
                destination: .airDrop,
                icon: nil,
                title: "AirDrop",
                subtitle: fileCount > 1 ? "\(fileCount) files · to a device" : "to a device",
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

    private var iconTint: Color {
        if isHovered { return Color.white }
        return Color.white.opacity(isOtherHovered ? 0.30 : 0.65)
    }

    var body: some View {
        VStack(spacing: 12) {
            // 36pt SF Symbol with .hierarchical rendering for
            // subtle layered depth. No shadow, no glow, no chip.
            ZStack {
                if let icon = icon {
                    Image(systemName: icon)
                        .font(.system(size: 36, weight: .semibold))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(iconTint)
                } else {
                    AirDropLogo(tint: iconTint, lineWidth: 1.8)
                        .frame(width: 42, height: 42)
                }
            }

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
        // 2026-05-24 — Plain rectangular fill, no corner radius.
        // Earlier attempts at rounded cards (14pt squircle) had
        // corners that didn't match the slab's own outer
        // silhouette (continuous-squircle bottom corners with a
        // much larger inner radius ~44pt). The card extended into
        // the slab's curve area, the slab's clip-shape cropped
        // the rectangle's corners, and the accent fill ended up
        // with awkward tapered corners — what the user saw as
        // "accent corners getting cropped."
        //
        // Now: the accent fill is a plain rectangle filling the
        // available space. The slab's OutwardFlaredShape clip
        // path naturally shapes the fill to the slab silhouette,
        // so the bottom corners follow the slab's continuous
        // squircle exactly. No mismatch possible — there's only
        // one shape involved (the slab itself).
        .background(cardFillColor)
        .animation(.easeOut(duration: 0.18), value: isHovered)
        .animation(.easeOut(duration: 0.18), value: isOtherHovered)
    }

    /// 2026-05-24 — fully transparent at rest. Per user feedback:
    /// the 4% white rest fill made the card silhouette readable
    /// against the slab black, which read as a "detached corner"
    /// floating element — basically the same "glow" the previous
    /// accent border created. Now the cards have NO visible
    /// silhouette until hovered; the icon + label sit directly on
    /// the slab. The hover-state accent fill is the entire visual
    /// affordance.
    private var cardFillColor: Color {
        if isHovered {
            return accent.opacity(0.18)
        } else {
            return Color.clear
        }
    }
}
