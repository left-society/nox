import SwiftUI
import AppKit

/// SwiftUI wrapper around macOS 26 Tahoe's `NSGlassEffectView` —
/// the Liquid Glass material Apple shipped for the OS-wide
/// material refresh, and the same class Alcove uses for its
/// premium slab background (verified via symbol dump of their
/// 1.7.2 binary — `_OBJC_CLASS_$_NSGlassEffectView`).
///
/// **What it is.** A view that embeds its content INSIDE a
/// dynamic glass material. Unlike `NSVisualEffectView` (which IS
/// the backdrop surface that other views sit on top of),
/// `NSGlassEffectView` *contains* content and renders glass
/// around / behind it. The contentView gets the OS-managed
/// glass treatment including the specular highlight pass that
/// catches light along edges.
///
/// **What's different from NSVisualEffectView:**
///   • No `material` / `blendingMode` properties — Apple
///     simplified the choice to two styles (`.regular` and
///     `.clear`) that map to internal material configurations.
///   • Adds a `tintColor` — lets you wash the glass with a
///     color (or with `NSColor.black.withAlphaComponent(0.97)`
///     to keep nox's matte-black character while still getting
///     the specular pass).
///   • Adds a `cornerRadius` — glass has its own corner
///     curvature applied at the GPU compositor layer; cleaner
///     than `clipShape(RoundedRectangle)` on the SwiftUI side
///     because the specular highlight follows the curve
///     properly.
///   • Adds a `contentView` slot — child views go inside,
///     elevated above the glass surface, with z-order managed
///     by the OS so glass and content composite correctly.
///
/// **macOS version gate.** This view is only available on macOS
/// 26.0+. On earlier versions it renders an empty fallback —
/// callers should pair it with a `VisualEffectBlur` underlay
/// for pre-Tahoe glass character (see `panelBackground` in
/// `PanelRootView.swift` for the layering pattern).
///
/// **Why a separate view from `VisualEffectBlur`.** Earlier
/// revisions tried to overload `VisualEffectBlur` to dispatch
/// between `NSVisualEffectView` and `NSGlassEffectView` based on
/// OS version. That crashed at runtime because the two classes
/// have non-overlapping property keypaths — `material` /
/// `blendingMode` aren't defined on `NSGlassEffectView`, and
/// trying to KVC-write them throws `NSUnknownKeyException`.
/// Keeping them as two distinct SwiftUI views with explicit
/// availability markers is the only sound shape.
///
/// **Usage:**
/// ```swift
/// if #available(macOS 26.0, *) {
///     LiquidGlassView(style: .regular,
///                     tint: Color.black.opacity(0.92),
///                     cornerRadius: 18)
/// } else {
///     // Fallback to NSVisualEffectView for pre-Tahoe
///     VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow)
/// }
/// ```
@available(macOS 26.0, *)
struct LiquidGlassView: NSViewRepresentable {

    /// Maps directly to `NSGlassEffectView.Style`. Two-option
    /// choice Apple gives us:
    ///
    ///   • `.regular` — denser glass, mirrors NSVisualEffectView's
    ///     `.hudWindow` blur strength. The default for slab
    ///     backgrounds where you want clearly-frosted glass.
    ///   • `.clear`   — barely-tinted glass with the specular
    ///     pass only. Less blur, more transparency. Use for
    ///     overlay surfaces where most of the underlying content
    ///     should remain readable.
    enum Style {
        case regular
        case clear

        @available(macOS 26.0, *)
        var nsStyle: NSGlassEffectView.Style {
            switch self {
            case .regular: return .regular
            case .clear:   return .clear
            }
        }
    }

    /// Glass style (see ``Style``).
    var style: Style = .regular

    /// Tint color washed into the glass. nil = pure native glass
    /// (no tint), reads as a clean Apple white-glass. Use
    /// `Color.black.opacity(0.95)` to keep a matte-black
    /// character while still benefiting from the specular pass.
    var tint: Color? = nil

    /// Corner radius for the glass. Matches the slab silhouette's
    /// `panelTopRadius` when used as the slab background.
    var cornerRadius: CGFloat = 0

    func makeNSView(context: Context) -> NSGlassEffectView {
        let view = NSGlassEffectView()
        view.style = style.nsStyle
        view.cornerRadius = cornerRadius
        if let tint {
            view.tintColor = NSColor(tint)
        }
        return view
    }

    func updateNSView(_ view: NSGlassEffectView, context: Context) {
        // Cheap re-application on every body re-eval. The values
        // are simple property writes — no KVC overhead, no layer
        // rebuild — so the cost is negligible. SwiftUI calls this
        // each time @State / @Environment dependencies invalidate
        // the parent, which for a static slab background is rare.
        view.style = style.nsStyle
        view.cornerRadius = cornerRadius
        view.tintColor = tint.map { NSColor($0) }
    }
}

/// Convenience initializer that returns either a `LiquidGlassView`
/// on Tahoe or a `VisualEffectBlur` fallback on older macOS,
/// type-erased through `AnyView` so callers don't need an
/// `if #available` block at every consumer site.
///
/// The fallback uses `.hudWindow` material — the same blur
/// character every nox release before 1.9.21 used in production.
struct AdaptiveGlassBackground: View {
    var tint: Color? = nil
    var cornerRadius: CGFloat = 0

    var body: some View {
        if #available(macOS 26.0, *) {
            LiquidGlassView(style: .regular,
                            tint: tint,
                            cornerRadius: cornerRadius)
        } else {
            VisualEffectBlur(material: .hudWindow,
                             blendingMode: .behindWindow)
        }
    }
}
