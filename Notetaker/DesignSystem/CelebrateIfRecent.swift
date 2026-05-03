import SwiftUI

/// View modifier that plays a brief purple "celebration" glow on
/// freshly-dropped grid items, staged AFTER the slab finishes
/// opening so the user actually sees it.
///
/// Why this exists: the bouncy entrance transition (`.dropLanding`)
/// fires the instant the cell is added to the store, which happens
/// while the slab is still mid-morph (slab opens ~450ms, tab
/// switches ~300ms, content fades ~180ms). The bounce can finish
/// before the user's eye even reaches the grid. This modifier
/// adds a SECOND animation, intentionally delayed by 700ms after
/// onAppear, so the celebration plays AFTER the slab settles and
/// the user is looking at a stable surface — making the
/// "something landed" signal unmistakable.
///
/// The glow only fires for cells whose `createdAt` is recent
/// (within 5s of now). That filters out existing cells that
/// happen to appear when the user opens the slab — we don't want
/// every cell pulsing every time the user navigates to the
/// Images tab.
///
/// Apply to grid cells:
///   ```swift
///   ImageCell(record: record, …)
///       .celebrateIfRecent(record.createdAt)
///   ```
struct CelebrateIfRecent: ViewModifier {
    /// Unix epoch timestamp (matches `createdAt` on ImageRecord /
    /// FileRecord / VideoRecord — all Double).
    let createdAt: Double

    @State private var hasAppeared = false
    @State private var glowing = false

    func body(content: Content) -> some View {
        content
            // Soft brand-purple shadow that pulses brighter
            // briefly. Wraps around the cell rather than over it
            // so the cell content stays untouched.
            .shadow(
                color: Color(red: 0.62, green: 0.46, blue: 0.96).opacity(glowing ? 0.85 : 0),
                radius: glowing ? 22 : 0,
                x: 0,
                y: 0
            )
            .onAppear {
                guard !hasAppeared else { return }
                hasAppeared = true

                // Filter: only celebrate freshly-added items.
                // 5s window is generous enough to cover slow
                // imageStore.saveImageDeferred completions but
                // short enough that opening the slab a minute
                // later doesn't trigger phantom celebrations.
                let now = Date().timeIntervalSince1970
                guard now - createdAt < 5.0 else { return }

                // Wait for the slab open + tab switch + opacity
                // fade to settle (~700ms total). THEN fire the
                // glow so it's visible to the user, not buried
                // under simultaneous animations.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                    withAnimation(.easeOut(duration: 0.32)) {
                        glowing = true
                    }
                    // Hold the peak glow for ~280ms then fade
                    // out smoothly.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
                        withAnimation(.easeInOut(duration: 0.55)) {
                            glowing = false
                        }
                    }
                }
            }
    }
}

extension View {
    /// Apply a one-shot celebration glow if the item was added
    /// in the last 5 seconds. No-op for cells that have been
    /// around longer than that.
    func celebrateIfRecent(_ createdAt: Double) -> some View {
        modifier(CelebrateIfRecent(createdAt: createdAt))
    }
}
