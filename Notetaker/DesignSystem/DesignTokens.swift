import SwiftUI

/// Centralised design tokens for Notetaker.
///
/// The values here are tuned against modern macOS (Sonoma → Tahoe)
/// system surfaces — Music's mini player, Settings rows, Raycast,
/// Linear, Notion's macOS shell. Two themes guided the choices:
///
///   • Generous corner radii. Apple shifted to a fully rounded
///     vocabulary in Sonoma+ (Settings rows ~10pt, content cards
///     ~12-16pt, large panels ~22pt). Anything below ~8pt reads
///     as a tab from a 2014-era flat-design app on Tahoe.
///   • Visible-but-quiet backgrounds. `bgCard` at 0.05 lifts a
///     surface enough that it reads as "this is a section,"
///     without competing with content. The previous values
///     (0.04 / 0.08) sat just below the threshold of perception
///     on a black slab, leaving every container looking like a
///     loose group of orphans.
enum DS {
    enum Color {
        // 2026-05-02 brand theme: Lavender Mist on Charcoal.
        //
        // Picked from the user's curated palette set against the
        // existing event-color system. Lavender doesn't collide
        // with the in-codebase event accents (AirDrop sky-blue,
        // note-saved warm-yellow, charging green, download red)
        // and is the macOS system signature for "intelligence /
        // voice / AI" surfaces (Siri, Dictation, Apple Intelligence).
        // Reads premium on pure black, tints cleanly through the
        // app's `VisualEffectBlur(.hudWindow)` glass material.
        //
        // Surface step (`charcoal`) is for stacked surfaces inside
        // the panel (cards, file rows, hover backgrounds) — one
        // tonal step up from the panel's pure-black silhouette
        // without leaving the dark family.
        static let brandLavender    = SwiftUI.Color(red: 0.773, green: 0.639, blue: 1.000)  // #C5A3FF — primary accent
        static let brandLavenderDeep = SwiftUI.Color(red: 0.651, green: 0.533, blue: 0.910) // #A688E8 — pressed/active
        static let brandLavenderSoft = SwiftUI.Color(red: 0.500, green: 0.420, blue: 0.700) // for muted accent fills
        static let brandCharcoal    = SwiftUI.Color(red: 0.176, green: 0.176, blue: 0.176)  // #2D2D2D — surface step-up
        static let brandTextPrimary = SwiftUI.Color(red: 0.961, green: 0.941, blue: 1.000)  // #F5F0FF — lavender-tinted white
        static let brandTextDim     = SwiftUI.Color(red: 0.608, green: 0.572, blue: 0.722)  // #9B92B8 — desaturated lavender

        /// The brand accent. Use anywhere we want the app's
        /// signature color (hover states, primary CTAs, brand
        /// touches like the Notetaker glyph in the header,
        /// drop-zone "Save" hint). Event-typed accents (AirDrop
        /// blue, note yellow, etc) STILL win on their respective
        /// pills — this is for the app's neutral-action color.
        static let accent = brandLavender

        // Layered fill stack. `bgSubtle` is the quietest — used
        // for chrome that should disappear (segmented tab strip
        // background). `bgCard` lifts an inset section so it
        // reads as "this is one cohesive thing" without dominating.
        // `bgHover` is a button hover halo. `bgSelected` is the
        // active state.
        static let bgSubtle = SwiftUI.Color.white.opacity(0.045)
        static let bgCard = SwiftUI.Color.white.opacity(0.05)
        static let bgHover = SwiftUI.Color.white.opacity(0.085)
        static let bgSelected = SwiftUI.Color.white.opacity(0.14)

        // Hairline strokes. `strokeCard` is the inset card border —
        // 0.5pt at 7% white reads as a defined edge without screaming.
        static let strokeCard = SwiftUI.Color.white.opacity(0.07)
        static let strokeHover = SwiftUI.Color.white.opacity(0.10)

        static let textPrimary = SwiftUI.Color.white.opacity(1.0)
        static let textSecondary = SwiftUI.Color.white.opacity(0.7)
        static let textTertiary = SwiftUI.Color.white.opacity(0.4)
        static let divider = SwiftUI.Color.white.opacity(0.08)
    }

    enum Spacing {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 3
        static let sm: CGFloat = 6
        static let md: CGFloat = 10
        static let lg: CGFloat = 14
        static let xl: CGFloat = 20
    }

    /// Corner-radius tokens.
    ///
    /// Mapped against Apple's system vocabulary on macOS Sonoma+:
    ///   • `pill` (10) — segmented tab pills, status pills
    ///   • `button` (8) — small inset buttons, hover halos
    ///   • `row` (10) — sidebar row selections, search-result rows
    ///   • `card` (14) — inset content cards (the "now playing"
    ///     surface, settings group cards)
    ///   • `panel` (18) — panel-level surfaces, sheets
    enum Radius {
        static let pill: CGFloat = 10
        static let button: CGFloat = 8
        static let row: CGFloat = 10
        static let card: CGFloat = 14
        static let panel: CGFloat = 18
    }

    enum FontSize {
        static let xs: CGFloat = 10
        static let sm: CGFloat = 11
        static let body: CGFloat = 12
        static let title: CGFloat = 13
        static let large: CGFloat = 16
    }
}

// MARK: - Dynamic panel accent (music-driven)

/// SwiftUI environment value that carries the slab's current accent
/// color. `PanelRootView` injects its `panelAccent` computed property
/// (now-playing artwork's dominant color when music has art, otherwise
/// brand lavender) at the root, and every descendant view that wants
/// to participate in the unified color story reads it via
/// `@Environment(\.panelAccent)` instead of the static
/// `DS.Color.accent` constant.
///
/// Adopting this in a new view is a two-line change:
///   @Environment(\.panelAccent) private var accent
///   // ...use `accent` wherever DS.Color.accent used to go...
///
/// The default value (brand lavender) makes the env value safe to read
/// from views rendered outside the panel root (Settings, onboarding,
/// previews) — they just get the brand color, same as before.
private struct PanelAccentEnvironmentKey: EnvironmentKey {
    static let defaultValue: Color = DS.Color.brandLavender
}

extension EnvironmentValues {
    /// Slab-wide accent color. Lavender at rest, follows the
    /// now-playing artwork's dominant color when music has art.
    var panelAccent: Color {
        get { self[PanelAccentEnvironmentKey.self] }
        set { self[PanelAccentEnvironmentKey.self] = newValue }
    }
}
