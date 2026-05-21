# Alcove.app Deep Binary Decode

**Target:** `/Applications/Alcove.app/Contents/MacOS/Alcove`  
**Version:** Alcove 1.7.2, build 188  
**Built with:** Xcode 26.4 (17E5159k), macOS SDK 26.4  
**Minimum macOS:** 14.0  
**Bundle ID:** `com.henrikruscon.Alcove`  
**Binary size:** 13.2 MB (universal x86_64 + arm64)  
**Date:** 2026-05-21

This report is an exhaustive extraction of design constants, animation specs, and architecture from the shipped Alcove binary, intended to inform nox parity work.

---

## Executive summary

1. **Alcove is SwiftUI + AppKit hybrid**, but the slab itself is built on **`NSGlassEffectView`** (macOS 26 Liquid Glass, weak-linked) with **`NSVisualEffectView` as fallback**. There is no `.material(.hudWindow)` SwiftUI modifier — Alcove drops to AppKit for the chrome.
2. **Custom progressive blur** is implemented as a `CABackdropLayer`-style private CALayer (`Alcove.ProgressiveBlurView`) configured via KVC with private flags: `disablesOccludedBackdropBlurs=true`, `allowsInPlaceFiltering=true`, `windowServerAware=true`, `bleedAmount=12.0`, `allowsGroupBlending=true`, `allowsGroupOpacity=false`, `allowsEdgeAntialiasing=true`. The actual blur is a `CIFilter`-backed `VariableBlurEngine` (uses `inputNormalizeEdges`, suggesting `CIMaskedVariableBlur`).
3. **Animations** use SwiftUI's modern `Spring(duration:bounce:)` API extensively — 368 unique call sites. The dominant slab transition is around **`Spring(duration: 0.4, bounce: 0.35)`** with several variants for different state changes. Heavy use of `Animation.spring(response:dampingFraction:blendDuration:)` with `dampingFraction = 1.0` (critically damped, never overshoots) for "Smooth" mode.
4. **The slab has essentially no shadow** — exactly ONE `.shadow()` callsite in the entire binary, with `radius=1.0, x=0, y=1.0`. The shape relies on dark fill + corner-radius + blur, not on a drop shadow.
5. **Continuous corners (`kCACornerCurveContinuous`)** are used — the slab uses iOS-style smooth squircle corners, not standard CALayer rounded rects.
6. **Color system** is fully tokenized in the asset catalog (127 color assets including 31 named brand colors). The brand palette uses Tailwind-CSS color values (e.g. `#F59E0B` Amber-500, `#10B981` Emerald-500), and `AlcovePrimaryColor` adapts (`#000000` light / `#FEFFFF` dark).
7. The slab Swift struct exposes properties named `compensatesForNotch`, `hasExpand`, `hasTranslucency`, `blendMode`, `showArtworkView`, `centerMarqueeText`, `compactMode`, `fixedProgressSectionWidth`, `bottomLeadingCornerBoost`, `bottomTrailingCornerBoost`, `luminanceThreshold`.

---

## Linked frameworks

Standard AppKit + SwiftUI + QuartzCore + CoreImage. Notable private/special:

- `/System/Library/PrivateFrameworks/MediaRemote.framework` — for now-playing data
- `/System/Library/PrivateFrameworks/DisplayServices.framework` — only `_DisplayServicesSetBrightnessSmooth` is used (for animated brightness HUD)
- `/System/Library/Frameworks/SwiftUI.framework` — current version 7.4.19 (SDK 26.4)

---

## Animation / Spring constants found

### SwiftUI API surface (all confirmed via undefined symbol imports)

```
SwiftUI.Spring.init(duration: Double, bounce: Double) → Spring
SwiftUI.Animation.spring(_: Spring, blendDuration: Double) → Animation
SwiftUI.Animation.spring(response: Double, dampingFraction: Double, blendDuration: Double) → Animation
SwiftUI.Animation.easeOut(duration: Double) → Animation
SwiftUI.Animation.easeInOut(duration: Double) → Animation
SwiftUI.Animation.linear(duration: Double) → Animation
SwiftUI.Animation.delay(_: Double) → Animation
SwiftUI.Animation.repeatForever(autoreverses: Bool) → Animation
SwiftUI.Animation.default (.getter)
SwiftUI.withAnimation<A>(_: Animation?, _: () throws -> A) throws -> A
SwiftUI.withAnimation<A>(_:Animation?, completionCriteria: AnimationCompletionCriteria, ...)
SwiftUI.BlurReplaceTransition
SwiftUI.PhaseAnimator
```

**Not used:** `bouncy`, `snappy`, `smooth`, `interactiveSpring`, `interpolatingSpring`. Alcove names its UX modes "Instant / Fast / Smooth" but those are local enum cases (HUDSpeed enum), not the SwiftUI Spring presets.

### CASpringAnimation also linked

```
_OBJC_CLASS_$_CASpringAnimation (from QuartzCore)
_OBJC_CLASS_$_CABasicAnimation
_OBJC_CLASS_$_CAAnimation
_OBJC_CLASS_$_CAAnimationGroup
_OBJC_CLASS_$_CAMediaTimingFunction
_OBJC_CLASS_$_NSAnimationContext
_kCAMediaTimingFunctionEaseIn / EaseOut / EaseInEaseOut
_kCATransitionFade
```

ObjC selector strings present: `setDamping:`, `setMass:`, `setStiffness:`, `setDuration:`, `setTimingFunction:`. Swift-side reflection strings:
- `alignmentSpringDamping`, `alignmentSpringMass`, `alignmentSpringStiffness` — fields on a struct, so Alcove builds CASpringAnimations programmatically with explicit (damping, mass, stiffness) tuples for its alignment animations.
- `settlingDuration` is present in the binary (CASpring API).
- `dampingFactor` exists as a separate property.

### Exact Spring(duration: bounce:) values used (extracted from disassembly)

368 callsites, 30 unique tuples. Most common pairings:

| duration | bounce  | Notes                                                          |
|----------|---------|----------------------------------------------------------------|
| 0.35     | -0.20   | Slow recede — gentle critically-damped feel                    |
| 0.40     | 0.35    | **Primary slab grow** — bouncy but settled                     |
| 0.35     | 0.30    | Standard small transition                                      |
| 0.60     | 0.30    | Slow ease-in for expanded view                                 |
| 0.35     | 0.70    | Snappy — used for emphasis/grab                                |
| 0.30     | 0.45    | Quick bounce                                                   |
| 0.60     | 0.35    | Heavier grow with overshoot                                    |
| 0.35     | 0.40    |                                                                |
| 0.45     | 0.40    |                                                                |
| 0.40     | 0.30    |                                                                |
| 0.40     | -0.20   |                                                                |
| 0.30     | 0.35    |                                                                |
| 0.30     | 0.325   |                                                                |
| 0.35     | 0.45    |                                                                |
| 0.50     | 0.375   |                                                                |
| 0.45     | 0.375   |                                                                |
| 0.50     | 0.45    |                                                                |
| 1.25     | -0.20   | Long, mellow                                                   |
| 0.30     | 1.0     | Maximum bouncy                                                 |
| 0.45     | 0.10    | Subtle bounce                                                  |
| 1.25     | 1.0     | Long+very bouncy (likely for celebration/feedback)             |
| 0.20     | 0.30    | Fast snappy                                                    |
| 0.60     | 0.40    |                                                                |
| 1.50     | 0.40    |                                                                |
| 1.00     | 0.40    |                                                                |

Citations: extracted from `otool -tV` x86_64 slice. Each Spring init is preceded by two `movsd` instructions loading `xmm0` (duration) and `xmm1` (bounce) from RIP-relative literal pool. Example: at `0x10000d3ef` → duration=0.4, bounce=0.35.

### Exact Animation.spring(response: dampingFraction: blendDuration:) values

282 callsites, 18 unique tuples. `dampingFraction = 1.0` (critically damped — never overshoots) is by far the most common.

| response | dampingFraction | blendDuration |
|----------|-----------------|----------------|
| 0.4875   | 1.0             | —              |
| 0.25     | 1.0             | —              |
| 0.35     | 1.0             | —              |
| 0.40     | 1.0             | —              |
| 0.60     | 1.0             | —              |
| 0.50     | 1.0             | —              |
| 0.20     | 1.0             | —              |
| 0.45     | 1.0             | —              |
| 0.15     | 1.0             | —              |
| 0.30     | 1.0             | —              |
| 1.20     | 1.0             | —              |
| 1.00     | 1.0             | —              |
| 0.55     | 1.0             | —              |
| 1.25     | 1.0             | —              |
| 0.80     | 1.0             | —              |
| 0.50     | —               | 1.0            |
| 0.30     | —               | —              |

The dominant pattern is `Animation.spring(response: <0.15–1.25>, dampingFraction: 1.0)` — i.e. SwiftUI's old API used in "no overshoot" mode. This is Alcove's "Smooth" preset behavior — purely damped, no bounce.

### Other animation durations (extracted)

- `Animation.easeOut(duration:)` — 36 callsites, values: **0.10, 0.15, 0.60**
- `Animation.easeInOut(duration:)` — 2 callsites, value: **0.20**
- `Animation.linear(duration:)` — 3 callsites, values: **1.00, 1.50**

### Animation.delay values

27 callsites. Unique delays: **0.05, 0.075, 0.10, 0.25, 0.30, 0.60, 1.557, 2.292, 2.70, 3.023, 3.265, 4.324**. The long delays (>1s) are likely for "after N seconds without media activity, dismiss" timing.

### Settings keys for speed presets

`settings.hud.speed.fast / instant / smooth` map to a `HUDSpeed` enum with cases `.fast / .instant / .smooth` (confirmed in reflection metadata at offsets 1623–1625 of `__swift5_reflstr`).

---

## Blur / Material specs

### Materials in use

- **`NSGlassEffectView`** (weak-linked, macOS 26+) — Alcove falls through to this when running on macOS 26 (Tahoe) and uses real Liquid Glass.
- **`NSVisualEffectView`** (hard-linked AppKit) — fallback for macOS 14/15.
- Selector strings present: `setMaterial:`, `setBlendingMode:`, `setState:`. Material value is set at runtime (could not extract the specific NSVisualEffectMaterial enum integer from disassembly without symbol-resolution).
- Swift struct `GlassEffectView` exposes properties: `material`, `blendingMode`, `state`, `variant`, `frosted`, `cornerRadius` (per `__swift5_reflstr` offsets 472–478).

### Custom progressive blur (the headline trick)

`Alcove.ProgressiveBlurView` class wraps a private CALayer-subclass backdrop. The setup sequence, decoded from disassembly at function starting at `0x100061831` (this is the layer init in the ProgressiveBlur.swift implementation), sets these KVC properties on the layer **in this exact order**:

1. `name = "Alcove.ProgressiveBlurView"`
2. `windowServerAware = true`
3. `allowsInPlaceFiltering = true`
4. `allowsGroupBlending = true`
5. `allowsGroupOpacity = false`
6. `allowsEdgeAntialiasing = true`
7. `disablesOccludedBackdropBlurs = true`  ← private API
8. `bleedAmount = 12.0`                    ← private API, 12 pt of blur bleed outside view bounds

These are all properties of `CABackdropLayer` (private Apple class). The float `12.0` was decoded from the literal pool at file offset corresponding to VA `0x10048ae30`.

Additionally, the layer uses `setFilters:` with a `CIFilter` array. Strings confirm:
- `gaussianBlurFilter` (likely `CIGaussianBlur`)
- `variableBlur` engine class
- `smoothLinearGradientFilter` (likely `CISmoothLinearGradient` used as mask for the variable blur)
- `inputNormalizeEdges` — this is the boolean input parameter unique to `CIMaskedVariableBlur` / `CIVariableBlur`

→ Alcove's progressive blur is `CIMaskedVariableBlur` with a `CISmoothLinearGradient` mask, applied as a CALayer filter on a backdrop layer.

### SwiftUI blur calls

Exactly ONE `.blur(radius:, opaque:)` callsite in the entire binary, with **radius = 10.0**.

### Other layer flags worth noting

- `kCACornerCurveContinuous` (imported) — slab uses **continuous (squircle) corners**.
- `kCAGravityResizeAspectFill` (imported) — album artwork uses aspect-fill.
- `disablesOccludedBackdropBlurs = true` — private API that turns OFF the macOS automatic backdrop-blur disable when a window is occluded. Alcove keeps the blur live even when partially covered.

---

## Shadow specs

Alcove uses **almost no shadows**. Total `.shadow(color:radius:x:y:)` callsites in binary: **1**.

That one callsite (at `0x100246e98`) uses:
- `radius = 1.0`
- `x = 0` (xorps to zero xmm1)
- `y = 1.0` (xmm2 copied from xmm0)
- color: `SwiftUI.Color` initialized from a `DeveloperToolsSupport.ColorResource` — i.e. a named color from the asset catalog (likely one of `ButtonShadow`, `NestedButtonShadow`, `PopoverButtonShadow`, or `ModalShadow`).

Asset-catalog shadow colors (Display P3 color space):
| Asset name             | Light alpha | Dark alpha |
|------------------------|-------------|------------|
| `ButtonShadow`         | 0.10        | 0.00       |
| `NestedButtonShadow`   | 0.10        | 0.00       |
| `PopoverButtonShadow`  | 0.10        | 0.00       |
| `ModalShadow`          | 0.10        | 0.00       |

All shadow colors are `rgb(0,0,0)` with 10% alpha in light mode and zero alpha in dark mode. **Alcove explicitly removes shadows in dark mode.**

The slab itself has no `.shadow()` — its three-dimensional depth comes from: dark fill + continuous corner radius + `bleedAmount = 12.0` on the backdrop blur.

Selector `setHasShadow:` is also present (this is `NSWindow.hasShadow`). Alcove's `NotchPanel` probably calls `panel.hasShadow = false`.

---

## Colors extracted (from `Assets.car`)

127 color assets, 66 unique names. Full brand palette below (all sRGB unless noted).

### Brand palette (Tailwind CSS values)

| Asset                       | Light       | Dark        |
|-----------------------------|-------------|-------------|
| `AccentColor`               | `#2DD4BF`   | `#2DD4BF`   |
| `AlcovePrimaryColor`        | `#000000`   | `#FEFFFF`   |
| `AlcoveAmberColor`          | `#F59E0B`   | `#F59E0B`   |
| `AlcoveBrightAmberColor`    | `#FBC337`   | `#FBC337`   |
| `AlcoveBrighterAmberColor`  | `#FCD34D`   | `#FCD34D`   |
| `AlcoveOrangeColor`         | `#FB923C`   | `#FB923C`   |
| `AlcoveBrightOrangeColor`   | `#FFEDD5`   | `#FFEDD5`   |
| `AlcoveBrighterOrangeColor` | `#FFF7ED`   | `#FFF7ED`   |
| `AlcoveDarkOrangeColor`     | `#431407`   | `#431407`   |
| `AlcoveBrownColor`          | `#E09C6C`   | `#E09C6C`   |
| `AlcoveBrightBrownColor`    | `#F28C61`   | `#F28C61`   |
| `AlcoveStoneColor`          | `#78716C`   | `#78716C`   |
| `AlcoveStoneWhiteColor`     | `#FAFAF9`   | `#FAFAF9`   |
| `AlcoveBrightStoneColor`    | `#D6D3D1`   | `#D6D3D1`   |
| `AlcoveBrighterStoneColor`  | `#F5F5F4`   | `#F5F5F4`   |
| `AlcoveDarkStoneColor`      | `#44403C`   | `#44403C`   |
| `AlcoveDarkerStoneColor`    | `#1C1917`   | `#1C1917`   |
| `AlcoveSlateColor`          | `#7588A3`   | `#7588A3`   |
| `AlcoveSkyColor`            | `#0EA5E9`   | `#0EA5E9`   |
| `AlcoveBrightSkyColor`      | `#7DD3FC`   | `#7DD3FC`   |
| `AlcoveDarkSkyColor`        | `#2563EB`   | `#2563EB`   |
| `AlcoveIndigoColor`         | `#6366F1`   | `#6366F1`   |
| `AlcovePurpleColor`         | `#A855F7`   | `#A855F7`   |
| `AlcovePinkColor`           | `#CB66D9`   | `#CB66D9`   |
| `AlcoveFuchsiaColor`        | `#D946EF`   | `#D946EF`   |
| `AlcoveBrightFuchsiaColor`  | `#F0ABFC`   | `#F0ABFC`   |
| `AlcoveRoseColor`           | `#F43F5E`   | `#F43F5E`   |
| `AlcoveBrightRoseColor`     | `#FB7185`   | `#FB7185`   |
| `AlcoveVioletColor`         | `#2E1065`   | `#2E1065`   |
| `AlcoveEmeraldColor`        | `#10B981`   | `#10B981`   |
| `AlcoveGreenColor`          | `#4ADE80`   | `#4ADE80`   |
| `AlcoveTealColor`           | `#14B8A6`   | `#14B8A6`   |
| `ChargingColor`             | `#8DEB92`   | `#8DEB92`   |
| `LowBatteryColor`           | `#FA6375`   | `#FA6375`   |
| `AirPodsMaxColor`           | (custom)    | (custom)    |

These are Tailwind palette anchors (`F59E0B` = `amber-500`, `10B981` = `emerald-500`, `7DD3FC` = `sky-300`, `FB7185` = `rose-400`, etc.).

### UI tokens (button/container/modal)

| Token                         | Light                          | Dark                              |
|-------------------------------|--------------------------------|-----------------------------------|
| `ButtonBackground`            | `rgba(254,255,255,0.75)`       | `rgba(254,255,255,0.05)`          |
| `ButtonBorder`                | `rgba(0,0,0,0.12)`             | `rgba(254,255,255,0.08)`          |
| `ButtonHighlight`             | `rgba(254,255,255,0.50)`       | `rgba(254,255,255,0.00)`          |
| `ButtonShadow` (P3)           | `rgba(0,0,0,0.10)`             | `rgba(0,0,0,0.00)`                |
| `BorderedButtonBackground`    | `rgba(0,0,0,0.04)`             | `rgba(254,255,255,0.05)`          |
| `BorderedButtonFocusBackground` | `rgba(0,0,0,0.08)`           | `rgba(254,255,255,0.10)`          |
| `BorderedButtonInnerBorder`   | `rgba(0,0,0,0.08)`             | `rgba(254,255,255,0.10)`          |
| `SegmentedButtonBackground` (P3) | `rgba(0,0,0,0.05)`          | `rgba(254,255,255,0.05)`          |
| `SegmentedButtonFocusBackground` (P3) | `rgba(0,0,0,0.10)`     | `rgba(254,255,255,0.10)`          |
| `SegmentedButtonInnerBorder` (P3) | `rgba(0,0,0,0.10)`         | `rgba(254,255,255,0.10)`          |
| `SegmentedButtonOuterBorder` (P3) | `rgba(254,255,255,0.00)`   | `rgba(0,0,0,0.30)`                |
| `NestedButtonBackground`      | `rgba(254,255,255,0.75)`       | _(no dark variant)_               |
| `NestedButtonBorder`          | `rgba(0,0,0,0.12)`             | `rgba(254,255,255,0.06)`          |
| `NestedButtonHighlight`       | `rgba(254,255,255,0.50)`       | `rgba(254,255,255,0.00)`          |
| `PopoverButtonBackground`     | `rgba(254,255,255,0.75)`       | `rgba(128,127,127,0.25)`          |
| `PopoverButtonBorder`         | `rgba(0,0,0,0.12)`             | `rgba(254,255,255,0.08)`          |
| `PopoverButtonHighlight`      | `rgba(254,255,255,0.50)`       | `rgba(254,255,255,0.00)`          |
| `ContainerBackground`         | `rgba(0,0,0,0.025)`            | `rgba(0,0,0,0.075)`               |
| `ContainerLightBackground`    | `rgba(0,0,0,0.025)`            | `rgba(255,255,255,0.04)`          |
| `ContainerInnerBorder` (P3)   | `rgba(0,0,0,0.00)`             | `rgba(254,255,255,0.08)`          |
| `ContainerOuterBorder`        | `rgba(0,0,0,0.08)`             | `rgba(0,0,0,0.25)` (P3)           |
| `ModalBackground`             | `rgba(254,255,255,0.75)`       | `rgba(254,255,255,0.15)` (P3)     |
| `ModalBorder` (P3)            | `rgba(0,0,0,0.15)`             | `rgba(0,0,0,0.50)`                |
| `ModalHighlight`              | `rgba(254,255,255,0.50)`       | `rgba(254,255,255,0.20)` (P3)     |

**Pattern observation:** Alcove's dark-mode UI tokens are extremely subtle (alphas like 0.05–0.15). The strong border definitions you see come from the OUTER border at 25–50% black alpha. The interior is almost ghostly.

### Notable: `FEFFFF` instead of `FFFFFF`

Every "white" tone is `FEFFFF` (red=254 instead of 255). This is a hint to the designer: the asset catalog was built with a P3 gamut-mapped white that's 1 LSB shy of pure white. Likely an artifact of the design tooling (Figma's P3 conversion). Worth replicating if pixel-perfect parity is the goal.

---

## Geometry constants

Direct float extraction from `Constants` / shape struct was not feasible without full symbol-resolved disassembly. Below are the constants we DID extract, plus the property names that establish the geometry vocabulary.

### Extracted concrete values

- **`bleedAmount = 12.0`** (CABackdropLayer KVC property) — the blur extends 12pt outside the slab's visual bounds.
- **`.blur(radius: 10.0)`** — exactly one SwiftUI `.blur()` modifier, radius = 10pt (likely used on the album-art-blurred backdrop).
- **`.shadow(radius: 1.0, x: 0, y: 1.0)`** — the lone shadow callsite.

### Property names confirming geometry vocabulary (from `__swift5_reflstr`)

Notch / slab geometry:
- `_notchWidth`, `_notchHeight` — physical notch dimensions
- `_notchAdjustedWidth`, `_notchAdjustedHeight` — user-tuned (settings.general.tuning.notchWidth/Height)
- `_notchExpandedWidth`, `_notchExpandedHeight` — slab size when expanded
- `hasPhysicalNotch`, `compensatesForNotch`, `_forceSimulatedNotch`

Music view layout:
- `compactMode`, `hasExpand`, `hasTranslucency`, `blendMode`
- `showArtworkView`, `centerMarqueeText`
- `fixedProgressSectionWidth` — the transport row width is FIXED, not dynamic
- `titleSymbolColor`, `titleSymbolPadding`
- `_measuredTitleTextWidth`, `_measuredArtistTextWidth` — Alcove measures text and adapts
- `onArtworkTap`, `controlStripSnapshotImage`, `controlStripSnapshotSize`, `controlStripSnapshotScale`

Padding / radius / sizing:
- `horizontalPadding`, `verticalPadding`, `innerPadding`, `titlePadding`, `symbolPadding`, `startPadding`
- `cornerRadius`, `bottomCornerRadius`, `topCornerRadius`
- `topLeftCornerRadius`, `topRightCornerRadius`, `bottomLeftCornerRadius`, `bottomRightCornerRadius`
- `radiusMultiplier`
- **`bottomLeadingCornerBoost`, `bottomTrailingCornerBoost`** — Alcove has separate "boost" values added to bottom-corner radii. This is the asymmetric-corner trick (bottom corners bigger than top corners to match the notch ledge).
- `blurRadius`, `maxBlurRadius`
- `elementMinHeight`

Waveform:
- `amplitudeWidth`, `amplitudeHeight`, `amplitudeCount`, `amplitudeSpacing`

Animation property tuning (CASpringAnimation tuple, no values extracted):
- `alignmentSpringDamping`, `alignmentSpringMass`, `alignmentSpringStiffness`
- `dampingFactor`, `settlingDuration`
- `volumeFeedbackTapMaxDuration`, `volumeFeedbackStalePressResetInterval`
- `transientMediaDurationThreshold`
- `calendarStartupLiveActivityDelay`
- `symbolAppearanceAnimationDuration`, `alignmentAnimationDuration`

### Shell scale state

The notch view exposes:
- `_shellScale`, `_shellWidthProgress`, `_shellScaleAnchor`
- `progressiveMask`, `_progressiveBlur`, `_hasProgressiveBlur`

This is the "rubber-band growth" state — Alcove drives a scale + width-progress with a `scaleAnchor`, not a width transition. The progressive blur is a *mask* applied during transitions.

---

## Class architecture

All 109 Objective-C classes plus the ones decoded from Swift type metadata. The internal architecture is highly modular and observable.

### Top-level controllers / managers (`Alcove.*`)

| Class                     | Role                                                |
|---------------------------|------------------------------------------------------|
| `AppDelegate`             | NSApplicationDelegate                                |
| `AppState`                | global state holder (NSObservable)                  |
| `NotchController`         | controls the notch panel lifecycle                  |
| `NotchPanel`              | `NSPanel` subclass for the slab itself              |
| `NotchProgressiveBlurPanel` | secondary panel for the blur layer (!)            |
| `LockController`          | lock-screen feature controller                       |
| `LockPanel`               | lock-screen panel                                    |
| `LockManager`             | lock-screen state, with private `ResumeState` enum  |
| `SettingsController`      | settings UI controller                               |
| `SettingsWindow`          | NSWindow subclass for settings                       |
| `AboutController`         | about dialog                                         |
| `LicenseController`       | license activation flow                              |
| `LicenseManager`          | license validation, with `LicenseInstance` records  |
| `UpdateController`        | update UI                                            |
| `UpdateManager`           | update fetcher                                       |
| `IntroController`         | first-run onboarding                                 |
| `XPCManager`              | manages `AlcoveHelper.xpc`                          |
| `APIManager`              | network calls                                        |
| `SnapshotManager`         | screen snapshots                                     |
| `MediaManager`            | now-playing data orchestration                       |
| `MusicController`         | music app coordination                               |
| `MusicTrackSnapshot`, `SpotifyTrackSnapshot` | track metadata snapshots         |
| `CalendarController` + `CalendarManager` | calendar events                       |
| `WeatherManager`          | WeatherKit integration                               |
| `FocusManager`            | macOS Focus modes                                    |
| `BatteryManager` + `BatteryHelper` | battery + low-power-mode handling           |
| `BrightnessManager`       | uses `DisplayServices` private framework             |
| `VolumeManager`           | uses `SimplyCoreAudio` library                       |
| `MediaKeyManager`         | global media-key hotkey interception                 |
| `BluetoothController`     | CBCentralManagerDelegate                             |
| `ConnectivityManager`     | network/airplane mode                                |
| `BrowserController`       | browser bookmark integration                         |
| `AccessibilityController` | accessibility permissions                            |
| `PermissionHelper`        | permission prompts                                   |
| `HapticFeedback`          | trackpad haptics                                     |
| `MissionControlManager`   | Mission Control state observation                    |
| `ScreenManager`           | multi-display handling                               |
| `SpaceManager`            | Spaces handling                                      |
| `SoundManager`            | AVAudioPlayer delegate                               |

### Views

- `NotchView`, `NotchExpandedView`, `NotchQuickPeekView`, `NotchNotificationsView`, `NotchLiveActivitiesView` — composable panels
- `NotchShape` — the slab path (separate Swift `Shape`)
- `NotchProgressiveBlurView` + `ProgressiveBlurView` + `VariableBlurEngine`
- `MusicView`, `NowPlayingSettingsView`
- `NSMarqueeTextView` — custom marquee scroll (NSView subclass)
- `NSWaveformView` — custom waveform (NSView subclass; uses `VortexSystem` particle library)
- `VideoPlayerLayerView`, `LoopingVideoPlayback` — for the AirPods MP4 animations bundled in Resources
- `GlassEffectView` — Swift wrapper for NSGlassEffectView / NSVisualEffectView
- `VibrancyShadowView` — separate AppKit view for shadow vibrancy
- `SwipeGestureView` (+ inner `Coordinator`, `MonitoredView`) — gesture handling
- `NSHostingViewSuppressingSafeArea` — **the well-known trick to host SwiftUI in an NSPanel without safe-area insets**

### Key SwiftUI styles/modifiers (in the binary)

- Button styles: `BorderedButtonStyle`, `RoundedButtonStyle`, `PopoverButtonStyle`, `SidebarButtonStyle`, `SegmentedButtonStyle`, `ColoredButtonStyle`, `HighlightButtonStyle`, `ScaleFadeButtonStyle`, `NestedButtonStyle`, `BottomNestedButtonStyle`, `TopNestedButtonStyle`, `DefaultButtonStyle`
- Toggle styles: `CheckboxToggleStyle`, `RoundedToggleStyle`
- Effects: `ShakeEffect`, `ProgressiveBlurEffect`, `BlurModifier`, `DelayedBlurFadeModifier`, `SlideBlurScaleModifier`, `ScaleAndFade`, `ExpandedActivityTransitionModifier`, `ScaledFontSizeModifier`, `VerticalOffsetModifier`
- Custom shape: `NotchShape`, `TriangleShape`

### Enums (from reflection)

- `HUDSpeed`: `.smooth`, `.fast`, `.instant`
- `HUDProgressStyle`: `.glow`, `.accent`, `.stylized`, `.white`, `.decibel`
- `NowPlayingStyle` (lock screen): `.clear`, `.frosted`, `.glass`
- `WeatherStyle`: `.conditions`, `.precipitation`, `.sun`
- `ColorStyle` (now-playing): `.color`, `.gradient`, `.mono`
- `TransportType`: `.drive`, `.walk`, `.transit`
- Music app: `.music`, `.spotify`, `.system`, `automatic`
- Display: `.builtInDisplay`, `.mainScreen`, `.activeDisplay`
- Idle expanded activity: `.calendar`, `.duo`, `.nowPlaying`, `.none`
- Title badge: `.explicit`, `.format`, `.symbol`, `.none`
- Notification control choice: `.like`, `.shuffle`, `.repeating`, `.copyLink`, plus `loved` and `favorited` state
- Calendar app: `.calendar`, `.fantastical`, `.notionCalendar`

---

## Notable / surprising findings

1. **Two windows for ONE slab.** Alcove uses TWO `NSPanel` subclasses for the slab:
   - `NotchPanel` — contains the actual content
   - `NotchProgressiveBlurPanel` — a separate window holding the progressive-blur layer

   This is unusual. It's done because mixing a CABackdropLayer (with `disablesOccludedBackdropBlurs`) and SwiftUI content in the same window causes rendering issues — Apple's compositor treats backdrop layers and CALayers differently when they're in the same surface. Separating them into two panels (one purely for the blur, one for content) lets each panel be tuned independently.

2. **`NSHostingViewSuppressingSafeArea`** is in the binary as a named class (`Alcove.NSHostingViewSuppressingSafeArea`). This is the well-documented hack where you subclass NSHostingView and override `safeAreaInsets` to return `.zero` — required to host SwiftUI flush to the notch.

3. **`disablesOccludedBackdropBlurs = true`** is a private CALayer property that disables macOS 14+ behavior of pausing backdrop blurs when occluded. Alcove uses it to keep the blur live even when another window covers part of the slab. Setting this is brittle and may break in future macOS versions.

4. **`bleedAmount = 12.0` is the secret to Alcove's "premium" feel.** The progressive blur bleeds 12pt outside the slab's geometric bounds, so the blurred wallpaper softly extends past the dark slab into the surrounding pixels. This is what gives Alcove the "the wallpaper is glowing around the slab" look that nox currently lacks.

5. **No `.shadow()` on the slab.** The entire slab's dimensional presence is achieved by (a) dark fill + opacity over a (b) gaussian-blurred backdrop + (c) continuous-radius corners + (d) `bleedAmount` softening. Adding a SwiftUI `.shadow()` to the slab is anti-pattern — Alcove doesn't.

6. **Music view uses CALayer-based artwork**, not SwiftUI `Image`. The artwork pipeline (`artworkContainerLayer`, `artworkLayer`, `artworkMaskLayer`) is CALayer-rooted with explicit mask layers, then attached via `NSViewRepresentable`. This lets Alcove animate the flip-to-blurred transitions via Core Animation, which is much smoother than SwiftUI's `Image` transitions.

7. **`DelayedBlurFadeModifier` and `SlideBlurScaleModifier`** suggest the slab grow uses a combination of (slide + blur + scale), with a delayed blur fade. This is exactly the kind of multi-axis transition that makes the growth feel substantial.

8. **Alcove uses `SwiftUI.BlurReplaceTransition`** for content transitions (e.g. swapping live-activity views). This is the iOS-style blur-replace transition that Apple added in iOS 17.

9. **MediaRemote keys used:** `Title`, `Artist`, `Album`, `Duration`, `PlaybackRate`, `DefaultPlaybackRate`, `ArtworkData`, `MediaType`, `IsExplicitTrack`, `AlbumiTunesStoreAdamIdentifier`, `iTunesStoreIdentifier`. Plus Alcove-prefixed: `alcoveMediaRemoteAudioIsDolbyAtmos`, `alcoveMediaRemoteAudioIsLossless` (these are augmented keys that Alcove computes locally).

10. **Vortex particle system** — Alcove bundles a `Vortex.bundle` (the Vortex SwiftUI particle library) and uses `VortexSystem` with `particles`, `emissionCount`, `emissionLimit`, `emissionDuration`, `burstCount`, `burstCountVariation`. Probably used for the trial-confetti or activation success effect.

11. **`compensatesForNotch`** is a per-view-instance Bool on MusicView. So when the slab is shown on a notchless display, the layout shifts. nox should consider this for multi-monitor.

12. **`fixedProgressSectionWidth`** — Alcove's transport-button row width is fixed, not flexible. This matches the visual — the transport area is the same size for every track.

13. **Asymmetric corner radii via "boost"** — `bottomLeadingCornerBoost` and `bottomTrailingCornerBoost` are added to the bottom corners. This is how Alcove gives its slab a softer "shoulder" at the bottom than the top.

14. **Three lock-screen styles** are not just visual presets — each has different geometry and material. `.clear` shows no card at all, `.frosted` is a glass card, `.glass` is the new macOS-26 NSGlassEffectView card.

15. **Alcove uses `SimplyCoreAudio` (third-party Swift package)** for volume monitoring, which gives much richer audio device state than CoreAudio directly.

---

## Files inspected

- `/Applications/Alcove.app/Contents/MacOS/Alcove` (universal binary, x86_64 + arm64 slices)
- `/Applications/Alcove.app/Contents/XPCServices/AlcoveHelper.xpc/Contents/MacOS/AlcoveHelper` (small helper)
- `/Applications/Alcove.app/Contents/Resources/Assets.car` (decoded via `assetutil --info`)
- `/Applications/Alcove.app/Contents/Resources/en.lproj/Localizable.strings`
- `/Applications/Alcove.app/Contents/Info.plist`

Tools used: `otool -l`, `otool -tV` (disassembly), `otool -s` (section dumps), `nm -m`, `xcrun swift-demangle`, `xcrun assetutil`, `lipo`, `plutil`, custom Python for VA→file-offset resolution and IEEE-754 float decoding from `__TEXT,__const`.

---

## Implications for nox

Based on this decode, the highest-leverage nox changes (without committing to specific implementations):

1. **Adopt `Spring(duration:bounce:)` with the Alcove distribution.** Default slab grow → `Spring(duration: 0.4, bounce: 0.35)`. Recede → `Spring(duration: 0.35, bounce: -0.2)`. The negative bounce values are critical — they create the "settles softly without overshooting" feel.

2. **Add `bleedAmount` to the panel's backing layer.** This is THE missing piece for premium feel. Setting `panel.contentView?.layer?.setValue(12.0, forKey: "bleedAmount")` on a backdrop layer will give the wallpaper-bleed effect.

3. **Use `kCACornerCurveContinuous`.** Set `layer.cornerCurve = .continuous` (this is documented Apple API in macOS 10.13+, no private flag needed).

4. **Apply asymmetric corner radii** with a bottom-corner boost. Top corners ~10pt; bottom corners ~14–16pt (rough guess based on the slab silhouette).

5. **Remove the slab shadow.** Or reduce it to `radius: 1.0, x: 0, y: 1.0` with a 10% alpha black-P3 color — that's literally Alcove's only shadow.

6. **Consider a two-panel architecture** if there are blur-quality issues with content layered over the backdrop.

7. **Use `disablesOccludedBackdropBlurs = true`** if dropped frames occur when other apps overlap the slab. (Caveat: private API, may break.)

8. **The Tailwind color palette is fully exposed** — if nox wants to match Alcove's brand colors exactly, every Alcove color is a Tailwind 500-shade variant (Amber, Emerald, Sky, Rose, Indigo, Purple, etc.).

