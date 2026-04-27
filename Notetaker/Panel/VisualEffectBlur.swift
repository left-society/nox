import SwiftUI
import AppKit

/// SwiftUI wrapper around `NSVisualEffectView` — gives any SwiftUI
/// view tree access to macOS's native vibrancy / gaussian blur
/// materials. Used as the panel background so the slab gets a
/// frosted-glass look that samples the desktop content directly
/// behind it (`.behindWindow` blending mode).
///
/// Confined to whatever container clip-shape the caller applies, so
/// the blur stays inside the panel silhouette — doesn't bleed into
/// the surrounding halo padding or the screen at large.
struct VisualEffectBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
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
