import SwiftUI
import AppKit

/// SwiftUI wrapper around `NSVisualEffectView` — gives any SwiftUI
/// view tree access to macOS's native vibrancy / gaussian blur
/// material. Used as the panel background so the slab gets a
/// frosted-glass look that samples the desktop content directly
/// behind it (`.behindWindow` blending mode).
///
/// Confined to whatever container clip-shape the caller applies, so
/// the blur stays inside the panel silhouette — doesn't bleed into
/// the surrounding halo padding or the screen at large.
///
/// **2026-05-17 — Tahoe Liquid Glass migration.**
/// macOS 26 introduces `NSGlassEffectView` — a new material that
/// pairs the gaussian backdrop blur with a specular highlight pass
/// (the "Liquid Glass" look Apple shipped in iOS 17 and brought to
/// macOS in Tahoe). Alcove adopts it (their `NSGlassEffectView`
/// symbol confirms direct usage, found via `class-dump` against
/// their 1.7.2 binary). Visually it reads as a wetter, more
/// dimensional glass — the blur has a subtle inner gradient that
/// catches light along an edge.
///
/// On macOS 26+: this view renders via `NSGlassEffectView`.
/// On macOS 14-15: falls back to `NSVisualEffectView` with the
/// same material — same blur, no specular pass. Same SwiftUI
/// API, same call sites, no per-version code at consumers.
///
/// The runtime detection is via `if #available(macOS 26, *)`
/// inside `makeNSView`, which compiles cleanly against any SDK
/// (older SDKs that don't know about `NSGlassEffectView` simply
/// skip the branch). The wrapping class below provides the
/// type-erased AppKit view so SwiftUI's NSViewRepresentable
/// constraints are satisfied identically in both paths.
struct VisualEffectBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        // 2026-05-20: kept on NSVisualEffectView across all macOS
        // versions. An earlier attempt to route through
        // `NSGlassEffectView` on macOS 26 (Tahoe) crashed at
        // runtime — Apple's new Liquid Glass class doesn't accept
        // NSVisualEffectView's `material` / `blendingMode` KVC
        // keys (different API surface). Needs proper SDK headers
        // + a separate ABI mapping; deferred until that's wired.
        // NSVisualEffectView with `.hudWindow` material still
        // gives nox its frosted-glass character on every shipping
        // macOS, and is what every nox release through 1.9.21
        // has used in production.
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        // .active state keeps the blur live regardless of window
        // active/key state — without this the vibrancy effect
        // dims when the user clicks away from the panel.
        view.state = .active
        view.isEmphasized = false
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blendingMode
    }
}
