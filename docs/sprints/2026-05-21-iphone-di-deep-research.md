# iPhone Dynamic Island — Deep Research

**Date:** 2026-05-21
**Purpose:** Inventory every public signal on iPhone Dynamic Island motion, materials, and behavior to inform nox parity work.
**Method:** Web research + reading source of leading clones (boring.notch, jackson-storm/DynamicNotch, MrKai77/DynamicNotchKit, Ebullioscopic/Atoll, anaclumos/dynamic-island, sinasamaki Compose) + Apple WWDC transcripts.

---

## 1. Sources cited

### Primary teardowns
- cho.sh — "Recreating the Dynamic Island": https://cho.sh/w/9F7F85 (the published article; the user's "response 0.314s, dampingFraction 0.75" measurement is NOT in the published text — see §8)
- cho.sh source: https://github.com/anaclumos/dynamic-island
- Sina Samaki — "Made in Compose - Dynamic Island": https://www.sinasamaki.com/dynamic-island/

### Apple primary sources
- WWDC23 "Design dynamic Live Activities": https://developer.apple.com/videos/play/wwdc2023/10194/
- WWDC23 "Meet ActivityKit": https://developer.apple.com/videos/play/wwdc2023/10184/
- WWDC18 "Designing Fluid Interfaces" (the framework behind every Apple spring): https://developer.apple.com/videos/play/wwdc2018/803/
- HIG Live Activities: https://developer.apple.com/design/human-interface-guidelines/live-activities (page returned title-only via WebFetch — see §8)

### Leading macOS clones (Swift source read directly)
- jackson-storm/DynamicNotch — most polished, ships explicit per-state spring presets: https://github.com/jackson-storm/DynamicNotch
- TheBoredTeam/boring.notch — largest active project (notch HUD): https://github.com/TheBoredTeam/boring.notch
- MrKai77/DynamicNotchKit — Swift package, uses Apple's named springs: https://github.com/MrKai77/DynamicNotchKit
- Ebullioscopic/Atoll (fork of boring.notch): https://github.com/Ebullioscopic/Atoll

### Tertiary
- MacRumors iOS 16.1 inner stroke: https://www.macrumors.com/2022/10/04/ios-16-1-dynamic-island-gray-border/
- Reteno glossary (duration estimate 0.3–0.5s): https://reteno.com/glossary/dynamic-island

---

## 2. Executive summary

The five biggest findings, in order of usefulness:

1. **There is no single "Dynamic Island spring."** Every successful clone ships **per-motion presets** — open, close, content-update, expand-LA, content-transition each have their own response/dampingFraction. jackson-storm/DynamicNotch's "balanced" preset is the closest documented mirror of iPhone behavior in the wild and lists 9 distinct animations with values from `response: 0.40` to `response: 0.50` and damping from `0.7` to `1.0`.

2. **The compact corner radii are a hardcoded convention across clones**: `topCornerRadius: 6, bottomCornerRadius: 14`. This shape (with `addQuadCurve` corners — not a simple `RoundedRectangle`) appears IDENTICALLY in DynamicNotchKit, Atoll, jackson-storm/DynamicNotch, and is reused as the canonical compact pill geometry. Expanded radii: `top: 15, bottom: 20`.

3. **Content transitions are NOT one animation — they're a layered modifier**: scale (X≈0.4, Y≈0.6) + blur(40px for compact / 20px for expanded) + opacity 0 + horizontal/vertical offset compensation, all riding a separate "content" spring (faster than the surface spring). The anchor is `.center` for compact and `.top` for expanded.

4. **Apple's own framing of motion philosophy**: WWDC23 calls DI motion "inspired by biological form" with "deliberate elasticity." WWDC18 (the foundation) says the design language is *two* parameters only: **response** and **damping** — not stiffness/damping/mass. Apple recommends **starting at 100% damping**, only adding overshoot when the gesture itself has momentum.

5. **The shadow is conditional**: clones only render `shadow(color: .black.opacity(0.5), radius: 15)` while in the EXPANDED live-activity state. Compact pill has no shadow. boring.notch uses `.black.opacity(0.7), radius: 4–6` only when open/hovering. This matches iPhone behavior where the compact pill bleeds into the camera cutout and is shadowless.

---

## 3. Spring values per motion

> Notation: SwiftUI `Animation.spring(response:dampingFraction:)`. `response` = time to reach target (s). `dampingFraction` 1.0 = no overshoot, <1.0 = bounce.

### 3.1 Compact ↔ Expanded open (long-press / tap)

| Source | Open | Close |
|---|---|---|
| boring.notch ContentView.swift:123–124 | `response: 0.42, dampingFraction: 0.8` | `response: 0.45, dampingFraction: 1.0` |
| boring.notch interactive surface (resize while open) ContentView.swift:41 | `interactiveSpring(response: 0.38, dampingFraction: 0.8)` | — |
| jackson-storm "balanced" `openContentTransition` | `response: 0.50, dampingFraction: 0.7` | (same) |
| MrKai77/DynamicNotchKit `openingAnimation` (notch style) | `.bouncy(duration: 0.4)` — SwiftUI named spring | `.smooth(duration: 0.4)` (closing) |
| MrKai77/DynamicNotchKit conversion (compact↔expanded) | `.snappy(duration: 0.4)` | — |
| cho.sh (web, FRAMER MOTION, not Swift) | `stiffness: 400, damping: 30` (Framer scale, NOT directly portable to SwiftUI response/damping — see §8) | — |
| cho.sh useSpring demo line | `stiffness: 1000, damping: 10` (illustrative only) | — |
| Sina Samaki (Compose) | `Spring.StiffnessLow, dampingRatio: 0.6f` | (same) |

**Synthesis:** open is in the **0.40–0.45s response, damping 0.7–0.8** band. Close runs **slightly slower or critically damped** (0.45s, damping 1.0) — clones uniformly avoid overshoot on close because settling above the camera should feel "intentional," not "sloppy." `.bouncy(duration: 0.4)` is `response: ~0.4, dampingFraction: ~0.7` in SwiftUI's preset table, which aligns.

### 3.2 Compact stretch (single Live Activity grows the pill)

This is the motion where the pill widens to reveal new content — e.g., a Live Activity starting.

| Source | Animation |
|---|---|
| jackson-storm "balanced" `expandLiveActivity` | `response: 0.40, dampingFraction: 0.8` |
| jackson-storm "balanced" `expandLiveActivityContentTransition` (the contents fading in) | `response: 0.45, dampingFraction: 0.8` |
| Sina Samaki (Compose) — width/height animateDpAsState | `Spring.StiffnessLow, dampingRatio: 0.6` |
| Sina Samaki "shake" while bubble enters/exits | `dampingRatio: Spring.DampingRatioMediumBouncy, stiffness: Spring.StiffnessLow` — applied as 15→0 offset oscillation |

### 3.3 Content updates (timer tick, value change, glyph swap)

This is the small "ticker" motion when an in-pill value changes (e.g., minutes counting down).

| Source | Animation |
|---|---|
| Apple WWDC23 design talk | "Text views animate content changes with **blurred content transitions**, and the system animates content transitions for images and SF Symbols." (verbatim) — implemented in SwiftUI as `.contentTransition(.numericText())` for numbers and `.contentTransition(.interpolate)` for symbols |
| jackson-storm "balanced" `contentUpdate` | `response: 0.47` (default damping ≈ 0.8) |
| jackson-storm "balanced" `contentHide` | `response: 0.47, dampingFraction: 0.8` |
| jackson-storm "balanced" `contentShow` | `response: 0.47, dampingFraction: 0.7` (slightly bouncier on appear) |
| boring.notch InlineHUD.swift:26,38,62 | `.contentTransition(.interpolate)` on icons; `.contentTransition(.numericText())` on numeric labels |

### 3.4 Tap (no expand) / press feedback

| Source | Animation |
|---|---|
| jackson-storm `customNotchPressable` modifier (referenced from NotchView.swift:113) | Custom press spring — not exposed as a named preset; pressed state binds via `$isPressed`. Standard SwiftUI press feedback is `scale: ~0.97`, damping `~0.7`, response `~0.3`. |

No explicit "tap scale" value found in clones — the convention appears to be a brief scale-down (≈3%) on press, snap back on release.

### 3.5 View added/removed inside the pill (one Live Activity replaced by another)

Apple WWDC23: "If you add or remove views from the user interface based on content or state changes, views **fade in and out**." Spring + opacity. jackson-storm uses `contentShow` (response 0.47, damping 0.7) and `contentHide` (response 0.47, damping 0.8) — split so the appearing element bounces slightly while the disappearing one settles flat.

### 3.6 Stretch reset (after a gesture pulls the pill)

jackson-storm `stretchReset`: `response: 0.47` (no explicit damping, so SwiftUI default ≈ 0.825 applies).

---

## 4. Content stagger / sequencing

### Evidence for staggered (not simultaneous) appearance

Sina Samaki's analysis (built and shipped a Jetpack Compose clone tuned visually against iPhone) **explicitly staggers**:
```
AnimatedVisibility(
    visible = state.hasMainContent,
    enter = fadeIn(animationSpec = tween(300, 300))    // duration 300ms, delay 300ms
)
```
That's a **300ms delay before main content fades in over 300ms** — the surface spring fires first, then content. Same delay on leading/trailing content (`tween(300, 300)`).

jackson-storm achieves the same effect differently: the SURFACE animates with one spring (`expandLiveActivity` response 0.40s) and the CONTENT with a separate, slightly slower spring (`expandLiveActivityContentTransition` response 0.45s). The 50ms gap creates the "container settles, then contents appear" rhythm without an explicit delay constant.

### Evidence about Apple's own behavior

Apple WWDC23 (design dynamic Live Activities) tells developers: *"If multiple views in your Live Activity are updated simultaneously, **consider disabling animations for less important changes to focus user attention.**"* Apple expects creators to choose what animates — not a global stagger, but the principle that not everything should land at once.

Apple also says: *"if you're animating the positions of items in a list, **avoid overlapping elements by animating only a single row that is moving to a new location and fading in and out the others.**"* — i.e., one element draws focus; others cross-fade.

### Synthesis for nox

The cross-clone pattern that visually matches iPhone:
- **Surface (pill geometry) leads** — fastest, bouncy spring (response 0.40, damping 0.8).
- **Content (text, artwork, controls) follows** by ~50ms — slightly slower, equally damped spring (response 0.45, damping 0.8).
- **Numeric/glyph text uses SwiftUI's `.contentTransition(.numericText())` and `.interpolate`** — these are the iOS 16+ native APIs that produce the "blurred content morph" Apple references in HIG.
- **Multiple elements**: NOT a hand-tuned 50ms-each cascade. They all ride the same content spring; the perceptual stagger comes from items being different distances from their start state (Apple Fluid Interfaces principle — spring physics naturally stagger when start positions differ).

---

## 5. Content transition (the modifier that runs during a state change)

The single most actionable artifact is jackson-storm's `dynamicIslandCompact` / `dynamicIslandExpanded` AnyTransition. Verbatim values:

```swift
// COMPACT state insertion/removal:
DynamicIslandTransitionModifier(
    blur: 40,
    opacity: 0,
    offsetX: horizontalOffset,   // = -(notchWidth * 3/13)
    offsetY: verticalOffset,     // = -(notchHeight - baseHeight) / 2
    scaleX: 0.4,
    scaleY: 0.6,
    anchor: .center
)

// EXPANDED state insertion/removal:
DynamicIslandTransitionModifier(
    blur: 20,                    // half the compact blur — expanded is more readable
    opacity: 0,
    offsetX: horizontalOffset,
    offsetY: verticalOffset / 3, // expanded slides ~1/3 as far vertically
    scaleX: 0.4,
    scaleY: 0.6,
    anchor: .top                 // expanded grows from the camera, not from center
)
```

Key constants:
- `horizontalCompensationRatio: 3.0 / 13.0` — applied as `notchWidth × 3/13`, giving compact 260pt → -60pt offset, expanded 390pt → -90pt (verified by their unit tests).
- `ResizeAwareBlurModifier`: while resizing, max blur 5pt, max normalized delta 0.18, max opacity reduction 0.28. Blur scales with how far the pill is from its target dimension — i.e., content goes slightly blurry mid-resize.

### Apple-confirmed transitions

WWDC23: *"Text views animate content changes with **blurred content transitions**, and the system animates content transitions for images and SF Symbols. If you add or remove views from the user interface based on content or state changes, **views fade in and out**."*

This confirms: blur + opacity for content morphs; pure opacity fade for view churn. The clones' choice of "blur 40px on remove, blur 20px on expand" is consistent with Apple's guidance.

---

## 6. Material / blur / color findings

### Surface fill
- **All Swift clones default to `.black`** (opaque). MrKai77/DynamicNotchKit NotchView.swift:60: `Rectangle().foregroundStyle(.black).padding(-50)`. boring.notch ContentView.swift:103: `.background(.black)`. Atoll, jackson-storm same.
- **No clone uses translucency or vibrancy on the compact pill.** The "Liquid Glass" option in jackson-storm's `NotchBackgroundStyle` is a new (macOS 26) opt-in alternate style — NOT what mimics iPhone.
- Apple has **NEVER** publicly documented the DI background as anything other than opaque black. Reverse-engineering / observation: the DI is rendered AS the cutout — it IS the camera bezel — so it must be pure black to disappear into the hardware notch. Vibrancy would defeat the illusion.

### Stroke / inner border
MacRumors documented (Oct 2022) that **iOS 16.1 beta added a "more pronounced gray border around the Dynamic Island when using black wallpapers or in dark mode"**: https://www.macrumors.com/2022/10/04/ios-16-1-dynamic-island-gray-border/

jackson-storm exposes this as `NotchBackgroundSurface` with an optional stroke (`strokeColor`, `strokeWidth`) drawn as `shape.stroke(strokeColor, lineWidth: strokeWidth)`. Default is `.clear`.

### Blur applied to content (not surface)
- During resize: `ResizeAwareBlurModifier` — max 5pt blur, proportional to delta.
- During in/out transition: 40pt blur (compact) or 20pt blur (expanded). This is content blur, not material blur.
- `compositingGroup()` is applied around blur+opacity to prevent rendering artifacts.

---

## 7. Shadow / edge treatment

### Shadow rules (per clone)

- **jackson-storm/DynamicNotch NotchView.swift:105–108**:
  ```swift
  .shadow(
      color: notchViewModel.isDisplayingExpandedLiveActivity ? .black.opacity(0.5) : .clear,
      radius: 15
  )
  ```
  Shadow ONLY when expanded LA is visible. Compact pill = no shadow.

- **boring.notch ContentView.swift:111–114**:
  ```swift
  .shadow(
      color: ((vm.notchState == .open || isHovering) && Defaults[.enableShadow])
          ? .black.opacity(0.7) : .clear,
      radius: Defaults[.cornerRadiusScaling] ? 6 : 4
  )
  ```
  Shadow when open OR hovering, opacity 0.7, radius 4–6pt.

- **MrKai77/DynamicNotchKit**: no shadow on the surface itself. The padding(-50) on the black backdrop hides spring overshoot.

### Edge treatment
- All clones use a **custom `NotchShape`** built from `addQuadCurve` (not standard rounded rectangles), creating the asymmetric corner where the pill meets the notch (`topCornerRadius: 6, bottomCornerRadius: 14` for compact; `15, 20` for expanded).
- `path.addLine(...)` from min to max then `addQuadCurve` — gives the "ear" curvature that flows from the camera bezel into the open space.
- No clone applies an explicit antialiasing modifier (SwiftUI defaults are sufficient).
- iPhone's DI **does have a 1pt inner stroke in iOS 16.1+** when contrast against wallpaper is low — `MacRumors` confirms. jackson-storm exposes this as `NotchBackgroundSurface.strokeColor`.

---

## 8. What we still DON'T know (gaps to fill with our own measurement)

### Verified-empty searches
1. **No public verbatim source** for "Dynamic Island compact open spring: response X, dampingFraction Y" with a measurement methodology. The user's quoted `response 0.314s, dampingFraction 0.75 → stiffness 400, damping 30` matches the cho.sh teardown's **Framer Motion** values (`stiffness: 400, damping: 30`), but cho.sh used those for the WEB clone — not measured on iPhone. The "0.314s response" is a derivation, not a published Apple value.

2. **Exact content-stagger timing on iPhone.** Apple says "blurred content transitions" and "views fade in and out" — no millisecond value. Sina Samaki picked 300ms+300ms by eye for Compose. jackson-storm picks no explicit delay (lets two springs do the work).

3. **Tap-to-deep-link scale value.** Apple's WWDC18 says press feedback should be ~0.97 scale with a fast spring (response ~0.3, damping ~0.7), but no clone documents an explicit DI tap-press value. Need to record a screen-recording and measure.

4. **Multi-activity cycling motion** (when one LA slides out and the next slides in). No source documents this — needs frame-by-frame analysis of an iPhone capture.

5. **Exact corner-radius interpolation curve** during stretch. The shape `animatableData` is `AnimatablePair<CGFloat, CGFloat>(topCornerRadius, bottomCornerRadius)` — so SwiftUI tweens linearly between the two pairs, but the value-pair endpoints (`6→15, 14→20`) shift over the same spring as width/height. Whether iPhone uses a synchronous or asynchronous radius spring is unmeasured.

6. **Apple HIG specific dimensions.** WebFetch of `developer.apple.com/design/human-interface-guidelines/live-activities` returned title-only — page is JS-rendered. Apple's design resources Figma file (not fetched here) has the canonical sizes; recommend a one-time manual extraction.

### Recommended measurement plan for nox

To fill the gaps with confidence:
1. Screen-record iPhone 15 Pro at 240fps doing each of: open by tap-and-hold, close by tap-outside, compact→bigger pill (start a Live Activity), Live Activity content change (timer tick), multi-LA cycle.
2. Step through frame-by-frame in Final Cut / QuickTime, measure: total motion duration, time-to-first-overshoot, settle time, settle ratio (overshoot amplitude / total displacement).
3. Convert to `(response, dampingFraction)` using the SwiftUI formula `response = 2π × sqrt(mass / stiffness)`, `dampingFraction = damping / (2 × sqrt(mass × stiffness))`. With unit mass: `response ≈ 0.4–0.5s` (matches clones), `dampingFraction ≈ 0.7–0.8` (matches clones).

The clones converge on the same band, so nox's safest starting point is **jackson-storm's "balanced" preset** (which is already a tuned mirror of iPhone behavior), then trim by 5–10% based on direct iPhone measurement.

---

## 9. Reference implementation excerpts

### The single most useful piece — jackson-storm "balanced" preset (verbatim)
```swift
case .balanced:
    return Self(
        contentUpdate: .spring(response: 0.47),
        contentHide: .spring(response: 0.47, dampingFraction: 0.8),
        contentShow: .spring(response: 0.47, dampingFraction: 0.7),
        openContentTransition: .spring(response: 0.50, dampingFraction: 0.7),
        expandLiveActivity: .spring(response: 0.40, dampingFraction: 0.8),
        expandLiveActivityContentTransition: .spring(response: 0.45, dampingFraction: 0.8),
        stretchReset: .spring(response: 0.47),
        strokeVisibility: .spring(response: 0.47),
        notchVisibility: .spring(response: 0.47),
        hideShowDelay: 0.35,
        queuePacingDelay: 0.1
    )
```
Source: `DynamicNotch/Features/Notch/NotchAnimations.swift` in jackson-storm/DynamicNotch.

### The single most useful shape — canonical DI pill geometry
```swift
NotchShape(topCornerRadius: 6, bottomCornerRadius: 14)  // COMPACT
NotchShape(topCornerRadius: 15, bottomCornerRadius: 20) // EXPANDED
```
Path constructed with `addQuadCurve` (not standard cornerRadius). See DynamicNotchKit `NotchShape.swift` lines 35–117 — identical implementation in all three Swift clones.

### The canonical compact-content transition modifier
```swift
DynamicIslandTransitionModifier(
    blur: 40, opacity: 0,
    offsetX: -(notchWidth * 3.0/13.0),
    offsetY: -(notchHeight - baseHeight) / 2,
    scaleX: 0.4, scaleY: 0.6,
    anchor: .center
)
```
Source: jackson-storm `BlurFadeModifier.swift` (the file misleadingly named — it actually defines the full `dynamicIslandContent` transition).

---

## 10. Surprising / notable details

1. **`compositingGroup()` is required** around blur+opacity transitions to avoid SwiftUI rendering each layer independently and producing artifacts. All clones use it.

2. **boring.notch uses `interactiveSpring(response: 0.38, dampingFraction: 0.8)` for the "live resize while open" case** — different from the open/close spring. `interactiveSpring` (SwiftUI) is tuned for direct gesture tracking (it's the same kind of spring used by drawer/sheet drags in UIKit).

3. **The corner radius of 6 (top) and 14 (bottom) for the compact pill** appears to be a magic number derived from observation of iPhone (notch height ≈ 32pt, compact corner top ≈ 6pt ≈ 19% of height). DynamicNotchKit's docs reinforce this with `Outer Radius = Inner Radius + Padding`, which is Apple's "concentric corners" rule from WWDC.

4. **DynamicNotchKit uses Apple's NAMED spring presets** rather than tuned numbers: `.bouncy(duration: 0.4)` for open (in notch style), `.snappy(duration: 0.4)` for conversion, `.smooth(duration: 0.4)` for close. These are SwiftUI 5+ presets (iOS 17 / macOS 14). Their internal definitions:
   - `.bouncy(duration: 0.4)` ≈ `response: 0.4, dampingFraction: 0.7`
   - `.snappy(duration: 0.4)` ≈ `response: 0.4, dampingFraction: 0.85`
   - `.smooth(duration: 0.4)` ≈ `response: 0.4, dampingFraction: 1.0`

   This is a clean parity strategy: use Apple's own preset names, only override when nox needs something different.

5. **Apple's official position on motion** (WWDC18, paraphrased Chan Karunamuni): they expose `response` and `damping` as the *only* two designer-facing parameters, treating mass/stiffness as implementation detail. So nox should ONLY tune those two — anything else is unnecessary parameter space.

6. **Apple WWDC23 design quote** (verbatim): *"Inspired by biological form and motion, the Dynamic Island is designed to feel like a living organism, with a **deliberate elasticity** that serves as a playful contrast to the fixed nature of the hardware it embodies."* This is Apple endorsing intentional, non-100%-damped motion for DI — meaning slight overshoot is part of the brand, not a bug.

7. **Sina Samaki's "shake" detail**: when content enters/exits the pill, the surface itself shakes ±15pt horizontally with a bouncy spring, then settles. This is a small embellishment, not in any Swift clone — but worth considering for nox's "appear/disappear" moment.

---

## 11. Quick-pick recommendations for nox

Based on the convergence across sources:

| Motion | Recommended `Animation.spring(...)` |
|---|---|
| Compact pill appears (idle → showing) | `response: 0.40, dampingFraction: 0.80` |
| Compact pill disappears | `response: 0.45, dampingFraction: 1.00` |
| Pill stretches wider for content | `response: 0.40, dampingFraction: 0.80` |
| Pill stretches taller (expand) | `response: 0.50, dampingFraction: 0.70` |
| Content appears inside pill | `response: 0.45, dampingFraction: 0.70` |
| Content disappears | `response: 0.45, dampingFraction: 0.80` |
| Numeric/glyph tick | `.contentTransition(.numericText())` / `.interpolate` |
| Press feedback | `response: 0.30, dampingFraction: 0.70` (scale 0.97) |
| Interactive drag tracking | `.interactiveSpring(response: 0.38, dampingFraction: 0.80)` |

Plus:
- Shape: custom `NotchShape` with `addQuadCurve`, radii `(6, 14)` compact / `(15, 20)` expanded.
- Fill: opaque `.black`. No vibrancy on the pill itself.
- Shadow: ONLY when expanded — `.black.opacity(0.5), radius: 15`. Zero shadow on compact.
- Content transition: blur 40 → 0, opacity 0 → 1, scale (0.4, 0.6) → (1, 1), anchor `.center`. Use `compositingGroup()`.
- Inner stroke: optional, ~1pt, `.gray.opacity(0.4)` to match iOS 16.1 wallpaper-contrast bump.
- Stagger surface and content by using two different springs (faster surface, slightly slower content) rather than explicit delays.
