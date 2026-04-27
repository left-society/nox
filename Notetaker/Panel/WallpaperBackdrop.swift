import SwiftUI
import AppKit

/// Renders the user's current desktop wallpaper as a SwiftUI Image,
/// positioned so the visible region inside this view matches what
/// would be behind the lock-screen card on screen.
///
/// **Why we need this.** SwiftUI's `.layerEffect()` Metal shaders
/// can only sample from views with normal raster pixels. The
/// wallpaper-blur path on lock screen (`NSVisualEffectView` with
/// `.behindWindow` blending) uses WindowServer-level backdrop
/// compositing — its output isn't a normal raster, so the shader
/// gets garbage when it tries to sample it. By loading the
/// wallpaper image FILE directly via
/// `NSWorkspace.shared.desktopImageURL(for:)`, we get a normal
/// `NSImage`/raster that we render through SwiftUI as a regular
/// `Image`, which the shader CAN sample cleanly. This is what
/// makes our liquid-glass displacement + chromatic aberration
/// actually work on the lock card.
///
/// **No permission prompt.** `NSWorkspace.desktopImageURL(for:)`
/// is a public API that returns the URL of the current wallpaper
/// (or nil), and reading from `/System/Library/Desktop Pictures/…`
/// or `~/Library/Application Support/com.apple.wallpaper/…` does
/// NOT trigger a screen-recording / TCC prompt. This is the key
/// advantage over a `CGWindowListCreateImage` capture pipeline.
///
/// **Limitations.**
///   • Static snapshot — animated wallpapers won't animate.
///   • Doesn't include other windows behind us (just the
///     wallpaper). On lock screen this is fine because the lock
///     UI is composited at level 300 and we're at level 400 —
///     basically only the wallpaper is behind us anyway.
///   • If the user's lock-screen wallpaper differs from the
///     desktop wallpaper (rare but possible), this shows the
///     desktop one. Acceptable trade-off.
struct WallpaperBackdrop: View {
    /// The card's frame in **screen coordinates** (AppKit, with
    /// origin at bottom-left of the screen). Used to compute how
    /// much to offset the full-screen wallpaper so the region
    /// visible inside our `420×160` SwiftUI view matches what
    /// would be behind us on screen.
    let cardScreenFrame: NSRect

    @State private var wallpaper: NSImage?
    @State private var screenSize: NSSize = .zero

    var body: some View {
        Group {
            if let wallpaper, screenSize != .zero {
                let topAnchorY = screenSize.height - cardScreenFrame.maxY
                Image(nsImage: wallpaper)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: screenSize.width, height: screenSize.height)
                    // Offset the full-screen wallpaper so the
                    // card-region lines up with our (0,0). SwiftUI
                    // y is top-down; AppKit screen y is bottom-up;
                    // convert via `screenH - maxY`.
                    .offset(
                        x: -cardScreenFrame.minX,
                        y: -topAnchorY
                    )
                    .frame(
                        width: cardScreenFrame.width,
                        height: cardScreenFrame.height,
                        alignment: .topLeading
                    )
                    .clipped()
                    .allowsHitTesting(false)
            } else {
                // While loading, render a wallpaper-color
                // approximation so the shader has SOMETHING to
                // sample (transparent would produce visible
                // empty edges).
                Color(white: 0.5)
                    .allowsHitTesting(false)
            }
        }
        .onAppear { reload() }
    }

    /// Load the current wallpaper file. Should be called whenever
    /// the underlying wallpaper might have changed; `onAppear` is
    /// enough for v1 since the lock card is created fresh on each
    /// lock-screen show. If we ever need live-updates for animated
    /// wallpapers, schedule a 1Hz timer here.
    private func reload() {
        guard let screen = NSScreen.main,
              let url = NSWorkspace.shared.desktopImageURL(for: screen),
              let image = NSImage(contentsOf: url)
        else { return }
        wallpaper = image
        screenSize = screen.frame.size
    }
}
