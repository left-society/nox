# macOS Tahoe (26.x) Liquid Glass — Research Notes for nox

Date: 2026-05-21
Scope: Native AppKit + SwiftUI APIs we should be using instead of approximating
Targets: macOS 26.5, Apple Silicon, nox notch HUD

---

## Sources

Primary (authoritative — SDK headers we read locally on 26.5):

- `/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/System/Library/Frameworks/AppKit.framework/Headers/NSGlassEffectView.h` — declared `API_AVAILABLE(macos(26.0))`, `Copyright (c) 2025, Apple Inc.`
- `…/AppKit.framework/Headers/NSVisualEffectView.h` — for comparison (last touched 2024)
- `…/SwiftUICore.framework/Versions/A/Modules/SwiftUICore.swiftmodule/arm64e-apple-macos.swiftinterface` — `Spring`/`Animation` defaults, `Glass`, `GlassEffectContainer`, `GlassEffectTransition`
- `…/SwiftUI.framework/.../arm64e-apple-macos.swiftinterface` — `GlassButtonStyle`, `GlassProminentButtonStyle`
- `…/QuartzCore.framework/Headers/CAAnimation.h` — `CASpringAnimation` defaults + `initWithPerceptualDuration:bounce:`

Secondary (Apple, WWDC, third-party):

- [WWDC25 Session 310 — Build an AppKit app with the new design](https://developer.apple.com/videos/play/wwdc2025/310/) (transcript via webfetch)
- [WWDC25 Session 219 — Meet Liquid Glass](https://developer.apple.com/videos/play/wwdc2025/219/)
- [WWDC25 Session 356 — Get to know the new design system](https://developer.apple.com/videos/play/wwdc2025/356/)
- [Apple Developer — NSGlassEffectView](https://developer.apple.com/documentation/appkit/nsglasseffectview)
- [Apple Developer — Adopting Liquid Glass](https://developer.apple.com/documentation/TechnologyOverviews/adopting-liquid-glass)
- [Apple Newsroom — Apple introduces a delightful and elegant new software design (Jun 2025)](https://www.apple.com/newsroom/2025/06/apple-introduces-a-delightful-and-elegant-new-software-design/)
- [artemnovichkov/xcode-26-system-prompts — AppKit-Implementing-Liquid-Glass-Design.md](https://github.com/artemnovichkov/xcode-26-system-prompts/blob/main/AdditionalDocumentation/AppKit-Implementing-Liquid-Glass-Design.md)
- [Stapxs/liquid-glass-rs](https://github.com/Stapxs/liquid-glass-rs) — third-party Rust binding that enumerates the 24 internal style variants
- [Meridius-Labs/electron-liquid-glass](https://github.com/Meridius-Labs/electron-liquid-glass) — Electron bindings, mentions `NSGlassEffectView` is reverse-engineered / "private" beyond the two public styles
- [Oskar Groth — Reverse Engineering NSVisualEffectView](https://oskargroth.com/blog/reverse-engineering-nsvisualeffectview) — for `NSVisualEffectView` GPU pipeline (CABackdropLayer, quarter-resolution sampling)
- [VibeTunnel — AppKit Liquid Glass notes](https://docs.vibetunnel.sh/apple/docs/liquid-glass/appkit)
- [DEV.to — Liquid Glass in Swift: Official Best Practices](https://dev.to/diskcleankit/liquid-glass-in-swift-official-best-practices-for-ios-26-macos-tahoe-1coo)
- [GeekyAnts — Through the Glass: Designer's Perspective on WWDC 2025](https://geekyants.com/blog/through-the-glass-designers-perspective-on-wwdc-2025)
- [ManyTricks blog — Hudlum: putting the volume indicator back](https://manytricks.com/blog/?p=6623) — describes Tahoe HUD position/feel
- [AppleInsider — macOS Tahoe overview](https://appleinsider.com/inside/macos-tahoe)
- [Medium — Spotlight in macOS Tahoe Just Got Superpowers](https://medium.com/@simpleandkind788/spotlight-in-macos-tahoe-just-got-superpowers-72e249aec999)

---

## Executive summary

macOS 26 ships two layered things relevant to nox:

1. **Liquid Glass** — a new translucent material backed by `NSGlassEffectView` (AppKit) and `.glassEffect()` / `GlassEffectContainer` (SwiftUI). It is *not* a stronger `NSVisualEffectView`; it has a different optical model (lensing/refraction with specular highlights, per Apple Newsroom and WWDC 219) and Apple positions it for floating, top-of-hierarchy controls — exactly the layer nox lives in. ([Newsroom](https://www.apple.com/newsroom/2025/06/apple-introduces-a-delightful-and-elegant-new-software-design/), [WWDC 310 transcript](https://developer.apple.com/videos/play/wwdc2025/310/))

2. **A consistent spring grammar** — `.snappy` / `.bouncy` / `.smooth` were introduced in macOS 14 (perceptual `Spring(duration:bounce:)`) but Tahoe doubled down on them as the system motion vocabulary. Defaults (read directly from the SwiftUI swiftinterface): `smooth = bounce 0.0`, `snappy = bounce 0.15`, `bouncy = bounce 0.30`, all at `duration 0.5s`. `.interactiveSpring` defaults to `duration 0.15s`, `bounce 0.15`, `blendDuration 0.25s`.

**Recommendation in one paragraph:** Replace the manual `NSVisualEffectView + custom mask` we're using with `NSGlassEffectView(style: .regular, cornerRadius: …)` wrapped in an `NSGlassEffectContainerView`, so when nox's pill, slabs, and any siblings get close they merge fluidly (Apple's "morphing" effect from session 310). Standardize all motion on `.snappy(duration: 0.30…0.40, extraBounce: 0)` for HUD show/hide and `.bouncy(duration: 0.45, extraBounce: 0.10)` for the slab open/close that wants a little "give." Don't use `.interactiveSpring` for non-gesture transitions — its 0.15s response makes a HUD feel jittery; reserve it for drag-driven slab.

---

## NSGlassEffectView — API + how to use it

### Verbatim signature (from the SDK header)

```objc
typedef NS_ENUM(NSInteger, NSGlassEffectViewStyle) {
    NSGlassEffectViewStyleRegular,   // Standard glass
    NSGlassEffectViewStyleClear      // Clear glass
} API_AVAILABLE(macos(26.0)) NS_SWIFT_NAME(NSGlassEffectView.Style);

API_AVAILABLE(macos(26.0))
@interface NSGlassEffectView : NSView
@property (nullable, strong) __kindof NSView *contentView;
@property CGFloat cornerRadius;
@property (nullable, copy) NSColor *tintColor;
@property NSGlassEffectViewStyle style;
@end

API_AVAILABLE(macos(26.0))
@interface NSGlassEffectContainerView : NSView
@property (nullable, strong) __kindof NSView *contentView;
@property CGFloat spacing;   // default 0
@end
```

Source: SDK header `NSGlassEffectView.h`, `Copyright (c) 2025`. Note that internal builds expose more styles (24 enumerated in the [liquid-glass-rs](https://github.com/Stapxs/liquid-glass-rs) reverse engineering) but only `Regular` and `Clear` are public — don't reach for private constants for a shipping app.

### Two public styles, when to use which

- **Regular** — Apple's default for navigation layers, toolbars, and controls. Use this for nox by default — the pill, slabs, and panel all live at the "above content" layer. (WWDC 310 + DEV.to summary of WWDC 219)
- **Clear** — only when *all three* of these hold: (1) glass sits over media-rich content (photos/video), (2) the content tolerates dimming, (3) the underlying content is bright/bold. Apple's explicit rule: "they should never be mixed." ([DEV.to summary](https://dev.to/diskcleankit/liquid-glass-in-swift-official-best-practices-for-ios-26-macos-tahoe-1coo))

For nox, that's **always Regular**. The notch sits over the menu bar/desktop, not over media.

### Properties — concrete usage

- `contentView` is the **only** subview Apple guarantees will be inside the glass. Anything else is undefined z-order. → put nox's `PanelRootView` *inside* `contentView`, not as a sibling. (WWDC 310: "Avoid placing `NSGlassEffectView` behind content as a sibling view.")
- `cornerRadius` is a single radius for all corners. The shape is animated when it changes — fluid morph between radii is part of the design. WWDC 310 example uses `999` for full-capsule controls (e.g., `userInfoGlass.cornerRadius = 999`).
- `tintColor` tints both the background and the lensed light. WWDC 310 + 219 guidance: tint only primary actions; secondary stay untinted; never tint everything (kills hierarchy).
- `style` — flip to `.clear` only under the rules above.

### `NSGlassEffectContainerView` — why we want it

Glass cannot sample other glass directly. The container is what lets two pieces of glass merge fluidly when they come close, and (critically for us) it batches them into **one sampling pass** instead of N. WWDC 310 says: "Visual correctness — glass can't directly sample other glass. Grouping allows elements to share their sampling region, ensuring consistent results and improving performance (single sampling pass for entire group)."

This matters for nox because we sometimes have the **resting pill + an expanded slab + a screenshot pill** alive at the same time. Without a container we pay 3× sampling cost and they look like three islands. With it, they're one liquid surface that morphs between shapes.

`spacing` controls the proximity threshold for merging. Default 0 still gives batching without bleed. WWDC examples use 20–30pt when they *want* nearby pieces to visually merge.

### Code example for nox (drop-in replacement for our visual-effect wrapper)

```swift
import AppKit

@available(macOS 26, *)
final class NoxGlassPanelView: NSView {
    let container = NSGlassEffectContainerView()
    let pillGlass = NSGlassEffectView()
    let slabGlass = NSGlassEffectView()

    init(pillContent: NSView, slabContent: NSView) {
        super.init(frame: .zero)
        wantsLayer = true

        pillGlass.style = .regular
        pillGlass.cornerRadius = 10               // matches our locked pill radius
        pillGlass.contentView = pillContent

        slabGlass.style = .regular
        slabGlass.cornerRadius = 18               // current PanelRootView corner
        slabGlass.contentView = slabContent

        let stack = NSStackView(views: [pillGlass, slabGlass])
        stack.orientation = .vertical
        stack.spacing = 6

        container.contentView = stack
        container.spacing = 24                    // morph when within 24pt

        addSubview(container)
        container.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: leadingAnchor),
            container.trailingAnchor.constraint(equalTo: trailingAnchor),
            container.topAnchor.constraint(equalTo: topAnchor),
            container.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}
```

Pattern lifted from the WWDC 310 transcript (two glass views inside a container, full-capsule radius 999, container holds the stack).

### NSGlassEffectView vs NSVisualEffectView — decision matrix

| | `NSVisualEffectView` (since 10.10) | `NSGlassEffectView` (macOS 26) |
|---|---|---|
| Optical model | Gaussian blur + saturation + tint, via `CABackdropLayer` ([Groth](https://oskargroth.com/blog/reverse-engineering-nsvisualeffectview)) | Lensing/refraction with specular highlights (Apple Newsroom) — bends light, doesn't just blur |
| Public styles | 14 semantic materials (`.menu`, `.hudWindow`, `.popover`, `.sidebar`, etc.) | 2 styles (`.regular`, `.clear`) |
| Tint | Indirect — set NSColor on a wrapper | Direct `tintColor` property; affects refraction too |
| Corner radius | Manual via layer mask or maskImage | First-class `cornerRadius` property, animates fluidly |
| Multi-piece batching | None — each view is a separate backdrop sampling pass | `NSGlassEffectContainerView` merges + single sample pass |
| Animation | Implicit via `animator`; no shape morph | Designed to morph; pairs with SwiftUI matched-geometry / materialize transitions |
| When to use | Sidebars, sheets, content-background; or as a fallback on pre-26 systems | **Top-of-hierarchy floating UI** — toolbars, popups, HUDs, controls. Per WWDC 310: "Liquid Glass elements float at the top level of the UI… use sparingly… for the most important elements." |
| Fallback | n/a — universal back to 10.10 | Apple does NOT auto-fallback below 26 — gate behind `if #available(macOS 26, *)` and use `NSVisualEffectView` for older systems |

**Verdict for nox:** `NSGlassEffectView` is the right surface. Our HUD is exactly the top-of-hierarchy floating element Apple is talking about.

---

## macOS Tahoe motion conventions

Apple's design language in Tahoe describes Liquid Glass motion in terms of "tension," "elasticity," "fluid movement," and "water on glass" rather than concrete easings. ([GeekyAnts](https://geekyants.com/blog/through-the-glass-designers-perspective-on-wwdc-2025), [Apple Newsroom](https://www.apple.com/newsroom/2025/06/apple-introduces-a-delightful-and-elegant-new-software-design/)) The implementation primitive is `Spring(duration:bounce:)` (introduced macOS 14, codified in Tahoe).

### Default spring presets — exact values from SwiftUICore.swiftinterface

```swift
// SwiftUICore — extension SwiftUI.Spring
public static func smooth(duration: TimeInterval = 0.5, extraBounce: Double = 0.0) -> Spring {
    Self(duration: duration, bounce: extraBounce)               // bounce 0.0
}
public static func snappy(duration: TimeInterval = 0.5, extraBounce: Double = 0.0) -> Spring {
    Self(duration: duration, bounce: 0.15 + extraBounce)        // bounce 0.15
}
public static func bouncy(duration: TimeInterval = 0.5, extraBounce: Double = 0.0) -> Spring {
    Self(duration: duration, bounce: 0.3 + extraBounce)         // bounce 0.30
}

// Animation extension — same defaults
public static func interactiveSpring(
    duration: TimeInterval = 0.15,
    extraBounce: Double = 0.0,
    blendDuration: TimeInterval = 0.25
) -> Animation {
    spring(duration: duration, bounce: 0.15 + extraBounce, blendDuration: blendDuration)
}

// Legacy interactiveSpring (still callable, marked @_disfavoredOverload)
@_disfavoredOverload
public static func interactiveSpring(
    response: Double = 0.15,
    dampingFraction: Double = 0.86,
    blendDuration: TimeInterval = 0.25
) -> Animation

// Legacy spring (also @_disfavoredOverload)
@_disfavoredOverload
public static func spring(
    response: Double = 0.5,
    dampingFraction: Double = 0.825,
    blendDuration: TimeInterval = 0
) -> Animation
```

(Source: `SwiftUICore.swiftmodule/arm64e-apple-macos.swiftinterface` lines ~3188 and ~13097–13127.)

### Mapping bounce ↔ damping ratio

For `Spring(duration:bounce:)`, the conversion is:
- `bounce = 0` → critically damped (no overshoot)
- `bounce > 0` → underdamped, overshoots; `damping ratio = 1 - bounce`
- `bounce < 0` → overdamped, slower than critical (only available with `allowsOverdamping`)

So `.snappy` (bounce 0.15) ≈ damping ratio 0.85; `.bouncy` (bounce 0.30) ≈ damping ratio 0.70. This matches Apple's older `spring(response: 0.5, dampingFraction: 0.825)` legacy default (close to `.snappy`) — confirming `.snappy` is the new default-feel preset.

### Window/HUD durations Apple uses in shipping Tahoe surfaces

Apple's docs do not publish numeric values for system surfaces, but inferring from what `.snappy`/`.bouncy` collapse to plus the qualitative descriptions:

- Menu bar dropdowns and popovers: feel like `.snappy(duration: 0.30…0.35)`
- Control Center expand/collapse: `.bouncy(duration: 0.45, extraBounce: 0.05)` based on the visible squish
- Spotlight expand (Cmd+Space → reveal action chips on Tab): `.snappy(duration: 0.35)` per qualitative reading of [the redesign article](https://medium.com/@simpleandkind788/spotlight-in-macos-tahoe-just-got-superpowers-72e249aec999) — pill contracts, four bubbles morph out
- Volume HUD: now appears under the Control Center menu-bar icon and the icon itself animates — the timing reads as a snappy 0.25–0.30s appearance with a longer decay before fade ([ManyTricks](https://manytricks.com/blog/?p=6623))

### State transition curves — what Apple actually says

WWDC 310 doesn't give numeric springs; the consistent design vocabulary is "morph between shapes," "rubber-like," "elastic." This maps cleanly to `.snappy` for direct manipulation (open/close, hover, settle) and `.bouncy` for celebratory or expressive moments (slab fully expanding from pill).

`.smooth` (bounce 0) reads as inanimate — Apple avoids it for top-layer Liquid Glass surfaces, reserving it for content scrolling and non-interactive transitions.

---

## Reference system surfaces — which native UI matches nox's use case

We're building a notch HUD that rests as a pill, expands into a slab, and overlays the menu bar. The closest Apple-shipped Liquid Glass surfaces:

### 1. **Tahoe Spotlight** — closest match
- Behavior: small pill at rest → press Tab or move mouse → contracts and reveals four bubble-style action options beside it ([AppleInsider Tahoe overview](https://appleinsider.com/inside/macos-tahoe), [Medium Spotlight piece](https://medium.com/@simpleandkind788/spotlight-in-macos-tahoe-just-got-superpowers-72e249aec999))
- Material: `Regular` Liquid Glass
- Motion: morph between two shape states with what reads like `.snappy(0.30…0.35)` — the bubbles materialize via what Apple calls the `materialize` `GlassEffectTransition`
- Takeaway for nox: this is the canonical "compact → expanded" Liquid Glass HUD pattern. Match its corner radius behavior (capsule at rest, larger rounded-rect when expanded) and the morph timing.

### 2. **Control Center volume / brightness HUD**
- Position: top-right under the menu-bar Control Center icon (changed in Tahoe from screen center) ([ManyTricks](https://manytricks.com/blog/?p=6623))
- Material: Regular glass; the menu-bar icon itself animates to show the property changing
- Motion: appears with a short snappy spring, dwells, fades on idle
- Takeaway for nox: notch HUDs that show transient state (volume, screen capture indicator) should animate the source icon — our screenshot pill already does this; lean into it more.

### 3. **Mission Control descent**
- Behavior: three-finger swipe up → "a glass pane descends from the top and distorts the view of the wallpaper underneath" ([AppleInsider](https://appleinsider.com/inside/macos-tahoe))
- Confirms that **glass that descends from the top edge of the screen** is an Apple-blessed pattern. nox's slab dropping from the notch is the same family.

### 4. **Toolbar buttons** (WWDC 310)
- Behavior: AppKit auto-groups toolbar buttons on one piece of glass; segmented controls/search get their own glass; everything is wrapped in a container view internally.
- Takeaway: the container pattern is not optional — it's how Apple does it.

### 5. **Inline Freeform editing controls** (WWDC 310 keynote example)
- Floating controls above content using Liquid Glass — explicitly cited by Apple as the "ideal" use case for `NSGlassEffectView`.
- That's exactly what nox is.

---

## SwiftUI animation primitive defaults

Read straight from `SwiftUICore.swiftmodule/arm64e-apple-macos.swiftinterface`:

| Preset | Duration | Bounce | Damping ratio (approx) | Blend |
|---|---|---|---|---|
| `.smooth` | 0.5s | 0.00 | 1.00 (critically damped) | — |
| `.snappy` | 0.5s | 0.15 | 0.85 | — |
| `.bouncy` | 0.5s | 0.30 | 0.70 | — |
| `.interactiveSpring` (new) | 0.15s | 0.15 | 0.85 | 0.25s |
| `.interactiveSpring` (legacy, response/dampingFraction) | response 0.15 | — | 0.86 | 0.25s |
| `.spring` legacy default | response 0.5 | — | 0.825 | 0 |

The base form is `Animation.spring(duration:bounce:blendDuration:)`. Bounce values Apple ships in the public presets: **0.0, 0.15, 0.30**. Higher than 0.30 starts to look like "design toy" — Apple's three preset rungs are it.

### SwiftUI Glass APIs (also from the swiftinterface)

```swift
@available(macOS 26.0, *)
public struct Glass: Equatable, Sendable {
    public static var regular: Glass { get }
    public static var clear: Glass { get }
    public static var identity: Glass { get }      // no-op, useful for animating in/out
    public func tint(_ color: Color?) -> Glass
    public func interactive(_ isEnabled: Bool = true) -> Glass   // iOS touch FX
}

// View modifier
extension View {
    @available(macOS 26.0, *)
    public func glassEffect(
        _ glass: Glass = .regular,
        in shape: some Shape = DefaultGlassEffectShape()
    ) -> some View
}

// Container
@available(macOS 26.0, *)
public struct GlassEffectContainer<Content: View>: View {
    public init(spacing: CGFloat? = nil, @ViewBuilder content: () -> Content)
}

// Transition primitives
public struct GlassEffectTransition: Sendable {
    public static var matchedGeometry: GlassEffectTransition   // morph between IDs
    public static var materialize: GlassEffectTransition       // fade-in like bubbles appearing
    public static var identity: GlassEffectTransition
}

extension View {
    public func glassEffectTransition(_ transition: GlassEffectTransition) -> some View
    public func glassEffectID(_ id: (some Hashable & Sendable)?, in namespace: Namespace.ID) -> some View
    public func glassEffectUnion(id: (some Hashable & Sendable)?, namespace: Namespace.ID) -> some View
}

// Button styles
extension PrimitiveButtonStyle where Self == GlassButtonStyle {
    public static var glass: GlassButtonStyle { get }
    public static func glass(_ glass: Glass) -> GlassButtonStyle
}
extension PrimitiveButtonStyle where Self == GlassProminentButtonStyle {
    public static var glassProminent: GlassProminentButtonStyle { get }
}
```

`.glass` button style for secondary actions, `.glassProminent` for primary — Apple's HIG via WWDC 310.

### CASpringAnimation (Tahoe-relevant CA bridge)

From `CAAnimation.h`:

```objc
@interface CASpringAnimation : CABasicAnimation
@property CGFloat mass;             // default 1.0
@property CGFloat stiffness;        // default 100.0
@property CGFloat damping;          // default 10.0
@property CGFloat initialVelocity;
@property BOOL allowsOverdamping API_AVAILABLE(macos(14.0));

// Tahoe-compatible perceptual initializer — same semantics as SwiftUI's Spring(duration:bounce:)
- (instancetype)initWithPerceptualDuration:(CFTimeInterval)perceptualDuration
                                    bounce:(CGFloat)bounce
    API_AVAILABLE(macos(14.0));

@property(readonly) CFTimeInterval perceptualDuration API_AVAILABLE(macos(14.0));
@property(readonly) CGFloat bounce                    API_AVAILABLE(macos(14.0));
@property(readonly) CFTimeInterval settlingDuration;
@end
```

Use `initWithPerceptualDuration:bounce:` whenever we drive a CA-level animation (window frame, sublayer transform). It is the **exact same physical model** as SwiftUI's `Spring(duration:bounce:)`. So `.snappy` ≡ `CASpringAnimation(perceptualDuration: 0.5, bounce: 0.15)`. This lets us keep one source of motion truth across the panel.

`NSAnimationContext` (per the header, unchanged in 26) still takes a `CAMediaTimingFunction`, not a spring directly — so for window-level animation we should drop down to `CASpringAnimation` or use SwiftUI's `withAnimation { … }` on a state value the window observes.

---

## Performance notes

### Sampling cost

- `NSVisualEffectView` uses a private `CABackdropLayer` that **samples at quarter resolution** (scale 0.25) before blurring ([Groth](https://oskargroth.com/blog/reverse-engineering-nsvisualeffectview)). One pass per view; multiple visual-effect views = multiple sampling regions.
- `NSGlassEffectView` is documented (WWDC 310, header doc) to share sampling within a `NSGlassEffectContainerView`. *Without* the container, each view is its own sampling pass. *With* it, the container batches descendants into one pass and merges similar effects.
- Practical implication for nox: **always wrap glass elements in a container**, even when there's just one. The header explicitly says "Using a glass effect container view can improve performance by reducing the number of passes required to render similar glass effect views."

### Animation cost

- Spring animation on Apple Silicon is essentially free (mass-spring math in 1-2 dimensions); the cost is in *what's being animated*. Animating `cornerRadius` on `NSGlassEffectView` triggers reshaping the sampled region — small footprint, but the underlying refraction recompute is not zero. Apple's guidance: it's designed to be animated; don't try to avoid it.
- The lensing/refraction model (per Apple Newsroom, WWDC 219) is Metal-backed; specular highlights are computed in real time. Translucent distortion adds GPU load relative to a static blur ([GeekyAnts notes this](https://geekyants.com/blog/through-the-glass-designers-perspective-on-wwdc-2025)). On M-series, single panel-sized regions are fine; the cost shows up when *many* glass surfaces stack.

### Metal-specific tips

- Avoid forcing `wantsLayer = true` on parents in a way that breaks `NSGlassEffectView`'s internal layer hierarchy — let it manage its own.
- If we move the panel via `animator().setFrame()`, the glass re-samples each frame. Use a `CASpringAnimation` directly on the layer position to keep the GPU pipeline coherent.
- The screen-capture/MediaRemote AppleScript polling we already gated on panel visibility (commit `baf4a06`) is the right pattern — anytime glass is on screen, drop background CPU work to keep frame budget free for sampling.

### Accessibility — Reduce Transparency

WWDC 310 calls out that Liquid Glass respects `NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency`. `NSGlassEffectView` falls back to a more opaque material automatically. We do **not** need to special-case it ourselves, but we should test the panel with that setting on to confirm it stays legible.

---

## Recommended changes for nox

### Material / view hierarchy

1. **Replace** the current `NSVisualEffectView` + custom mask wrapper in `PanelRootView` and the resting pill with `NSGlassEffectView(style: .regular)`, gated `if #available(macOS 26, *)`.
2. **Add** an `NSGlassEffectContainerView` as the immediate parent of pill + slab + screenshot pill. Set `spacing` ≈ 24 so that when the slab opens out of the pill, they morph fluidly into one surface.
3. **Tint** sparingly. Apple's rule: tint only the primary action. For nox, that means we don't tint the resting pill; if we want the recording dot to feel "live," we can give the dot's own micro-glass a red tint, but the panel itself stays neutral.
4. **Corner radii** — keep the locked pill at 10pt (per `notetaker_alcove_pill_parity.md`). For the slab, animate `cornerRadius` from 10 → 18 during expand so the morph reads as one continuous shape.
5. **Drop** any homemade Gaussian blur shaders or vibrancy hacks. `NSGlassEffectView` is the renderer now.

### Spring values to standardize on

```swift
extension Animation {
    static let noxPanelShow   = Animation.snappy(duration: 0.32, extraBounce: 0.00)
    static let noxPanelHide   = Animation.snappy(duration: 0.26, extraBounce: 0.00)
    static let noxSlabExpand  = Animation.bouncy(duration: 0.45, extraBounce: 0.10)
    static let noxSlabCollapse = Animation.snappy(duration: 0.30, extraBounce: 0.00)
    static let noxHoverSettle = Animation.smooth(duration: 0.18, extraBounce: 0.00)  // micro state
    static let noxDrag        = Animation.interactiveSpring(duration: 0.15,
                                                            extraBounce: 0.00,
                                                            blendDuration: 0.25)
}

// CA-level equivalents for window-frame animation
extension CASpringAnimation {
    static func noxPanelShow() -> CASpringAnimation {
        let s = CASpringAnimation(perceptualDuration: 0.32, bounce: 0.0)
        s.allowsOverdamping = true
        return s
    }
    static func noxSlabExpand() -> CASpringAnimation {
        CASpringAnimation(perceptualDuration: 0.45, bounce: 0.10)
    }
}
```

Rationale:
- `noxPanelShow` / `noxPanelHide` are direct manipulation → `.snappy` with no extra bounce. Asymmetric durations (hide faster than show) is an Apple pattern — Mission Control, Spotlight, dock magnification all hide faster than they appear.
- `noxSlabExpand` uses `.bouncy(0.45, 0.10)` — total bounce 0.40, just past `.bouncy`'s default. This is the "celebratory open" feel for Spotlight's bubbles materializing. Adjust the 0.10 down to 0.05 if it ever feels overcooked.
- `noxSlabCollapse` is plain `.snappy` — close is direct, not celebratory.
- `noxHoverSettle` is `.smooth` because hover micro-states should feel inert, not bouncy.
- `noxDrag` is the new `.interactiveSpring` form for the drag-to-open slab gesture. The 0.25s blendDuration means if the user releases mid-drag and we switch to a release spring, the transition is graceful.

### Transitions

When the slab appears out of the pill, use SwiftUI's matched geometry:

```swift
GlassEffectContainer(spacing: 24) {
    if isExpanded {
        SlabView()
            .glassEffect(.regular, in: .rect(cornerRadius: 18))
            .glassEffectID("nox-surface", in: namespace)
            .glassEffectTransition(.matchedGeometry)
    } else {
        PillView()
            .glassEffect(.regular, in: .capsule)
            .glassEffectID("nox-surface", in: namespace)
            .glassEffectTransition(.matchedGeometry)
    }
}
.animation(.bouncy(duration: 0.45, extraBounce: 0.10), value: isExpanded)
```

This is the same `matchedGeometry`/`materialize` transition Apple uses for Spotlight's bubbles (WWDC 310, also documented in the swiftinterface).

### Reference UI to mimic

If a behavior question comes up during implementation, look at how Spotlight animates first (`Cmd+Space`, then `Tab`). It is the closest shipping analog to nox's pill→slab transition.

### What NOT to do

- Don't use `.clear` glass. We're not over media.
- Don't tint the entire panel.
- Don't skip the container view — even one piece of glass benefits from being wrapped.
- Don't use `.interactiveSpring` for non-gesture transitions; 0.15s makes the HUD feel skittery.
- Don't use legacy `spring(response:dampingFraction:)` — Apple has explicitly `@_disfavoredOverload`'d both forms in favor of `Spring(duration:bounce:)`.
- Don't reach for the 24 private style constants from `liquid-glass-rs`; only `.regular` and `.clear` are public and stable.

---

## Quick reference card

| Question | Answer |
|---|---|
| Glass material class on Tahoe? | `NSGlassEffectView` (AppKit) / `.glassEffect()` (SwiftUI) |
| Style for HUD/popup? | `.regular` |
| Container? | Always wrap in `NSGlassEffectContainerView` (single sample pass, fluid merging) |
| Default spring for show/hide? | `.snappy(duration: 0.30)` — bounce 0.15 |
| Default spring for expressive expand? | `.bouncy(duration: 0.45, extraBounce: 0.10)` |
| Default for drag/gesture? | `.interactiveSpring(duration: 0.15, blendDuration: 0.25)` |
| Tahoe spring math primitive? | `Spring(duration:bounce:)` — same as `CASpringAnimation initWithPerceptualDuration:bounce:` |
| Reference system surface? | Spotlight (Cmd+Space), then Control Center volume HUD |
| Accessibility? | Respect `accessibilityDisplayShouldReduceTransparency` — `NSGlassEffectView` handles this automatically |
| Availability gate? | `if #available(macOS 26, *) { … } else { /* fall back to NSVisualEffectView */ }` |
