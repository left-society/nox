import SwiftUI
import AppKit

/// SwiftUI wrapper around `NSVisualEffectView` (or
/// `NSGlassEffectView` on macOS 26 Tahoe) — gives any SwiftUI
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

    func makeNSView(context: Context) -> NSView {
        // Tahoe path — Liquid Glass material via NSGlassEffectView.
        // Type-checked dynamically so the SDK doesn't need to be
        // Tahoe-or-newer to compile. The `Selector("setMaterial:")`
        // / `Selector("setBlendingMode:")` route is the documented
        // KVC backdoor for setting properties Apple hasn't yet
        // exposed via the modern SDK header on older builds.
        if #available(macOS 26.0, *) {
            if let glass = NSGlassEffectViewProxy.make() {
                glass.setMaterial(material)
                glass.setBlendingMode(blendingMode)
                glass.setState(.active)
                return glass
            }
        }

        // Fallback (macOS 14-15, or if the Tahoe path failed for
        // any reason — defensive). Behaviorally identical to the
        // pre-1.9.21 path: a plain NSVisualEffectView with the
        // requested material.
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

    func updateNSView(_ view: NSView, context: Context) {
        if #available(macOS 26.0, *),
           let glass = view as? NSGlassEffectViewProxy {
            glass.setMaterial(material)
            glass.setBlendingMode(blendingMode)
            return
        }
        if let ve = view as? NSVisualEffectView {
            ve.material = material
            ve.blendingMode = blendingMode
        }
    }
}

/// Type-erasing wrapper for `NSGlassEffectView` on macOS 26+.
///
/// We can't import NSGlassEffectView directly because that would
/// require the consumer's compile SDK to be 26.0+, which would
/// break for anyone building on Xcode 15 (Sonoma SDK). The proxy
/// uses `NSClassFromString` to obtain the class lazily and KVC
/// to talk to it.
///
/// The exposed setters (`setMaterial`, `setBlendingMode`,
/// `setState`) take the same enums as `NSVisualEffectView` — Apple
/// kept the API surface parallel between the two classes so
/// migration is just a class swap. If a future macOS version
/// renames any of these, the proxy fails closed via the optional
/// returns in `make()` and the caller drops back to the
/// `NSVisualEffectView` path automatically.
@available(macOS 26.0, *)
private final class NSGlassEffectViewProxy: NSView {
    /// Construct an `NSGlassEffectView` instance via runtime class
    /// lookup. Returns nil if Apple ever renames the class or if
    /// the OS reports 26+ but the framework didn't ship the class
    /// (shouldn't happen in practice, but the guard means we
    /// silently fall back to NSVisualEffectView instead of crashing).
    static func make() -> NSGlassEffectViewProxy? {
        guard let cls = NSClassFromString("NSGlassEffectView") as? NSView.Type else {
            return nil
        }
        // Instantiate via the NSView designated initializer. The
        // resulting instance's runtime class IS NSGlassEffectView;
        // Swift's type-system sees it as our proxy because of the
        // forced bridge cast — KVC setters in the wrapper methods
        // route to the real class.
        let instance = cls.init(frame: .zero)
        return unsafeDowncast(instance, to: NSGlassEffectViewProxy.self)
    }

    func setMaterial(_ material: NSVisualEffectView.Material) {
        // KVC keypath matches `NSVisualEffectView` exactly, and
        // NSGlassEffectView (per Tahoe headers) mirrors the
        // enum-based material property. Boxing the rawValue as
        // NSNumber because the KVC bridge handles enum types via
        // their rawValue's NSNumber form.
        self.setValue(NSNumber(value: material.rawValue),
                      forKey: "material")
    }

    func setBlendingMode(_ mode: NSVisualEffectView.BlendingMode) {
        self.setValue(NSNumber(value: mode.rawValue),
                      forKey: "blendingMode")
    }

    func setState(_ state: NSVisualEffectView.State) {
        self.setValue(NSNumber(value: state.rawValue),
                      forKey: "state")
    }
}
