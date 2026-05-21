# Alcove.app Banner + Pill↔Slab Morph Decode

**Target:** `/Applications/Alcove.app/Contents/MacOS/Alcove` (universal x86_64 + arm64)
**Version:** Alcove 1.7.2, build 188 (Xcode 26.4, SDK 26.4, min macOS 14.0)
**Date:** 2026-05-21
**Scope:** the "new media banner" reveal + the multi-stage morph between the compact resting pill and the expanded slab. Builds on `2026-05-21-alcove-deep-decode.md` (do not re-read the spring-table / blur basics there — this goes deeper on the *transition mechanics* only).

**Method note:** the binary is stripped of local function symbols (only 1 internal text symbol; `nm -gU | swift-demangle` returns nothing useful). All findings below come from: (a) the Swift `__swift5_fieldmd` field-descriptor table — which preserves **class/struct field names** even when type names are symbolic refs — fully parsed via custom Python; (b) the Swift `__swift5_reflstr` reflection strings; (c) `otool -tV` disassembly with the import stub table (`otool -Iv`) used to identify SwiftUI calls; (d) IEEE-754 double decoding from `__TEXT,__const` with proper RIP-relative resolution (displacement is relative to the *next* instruction). Every claim cites one of these.

---

## TL;DR for nox

- **The morph is ONE continuous spring on a progress scalar, not discrete tiers.** The compact pill and the expanded slab are the two endpoints (`_notchWidth/_notchHeight` → `_notchExpandedWidth/_notchExpandedHeight`); everything in between is `_expandedProgress` (a 0→1 Double) driving `_shellScale` / `_shellWidthProgress` around a `_shellScaleAnchor`. There is no `medium`/`compact` slab-width tier. (`medium` in the binary is an unrelated radius size-class enum `mini/small/medium/large/extraLarge`.)
- **The morph runs as THREE separate async tasks** so size, corner radius, and blur can be timed independently: `expandedTransitionTask`, `expandedRadiusTransitionTask`, `progressiveBlurTransitionTask` (all fields of `NotchController`).
- **Two animation families:** a bouncy `Spring(duration:bounce:)` family (the default "Fast" feel) and a critically-damped `spring(response:dampingFraction: 1.0)` family (the "Smooth" / "Disable overshoot" feel). The expand morph uses **`Spring(duration: 0.35, bounce: 0.3)`**; the recede uses **`Spring(duration: 0.35, bounce: -0.2)`** anchored at the **top**.
- **The banner is the "notification" subsystem.** New media → a transient notification is presented over the pill, dwells, then auto-closes. State lives in `_hasNotification` / `_notification` / `notificationClosingType` / `notificationClosingUntil`, with debounce/generation guards `notificationSwapDebounce` / `notificationCloseDebounce` / `notificationCloseGeneration` / `notificationRestoreDebounce`.
- **Inner content morphs with `ScaleTransition(anchor:)` (per-element anchors) + a `blurRadius/verticalOffset/opacity/delay/duration` modifier; text swaps use `BlurReplaceTransition.Configuration.downUp`.** Micro-fades are `easeOut(duration: 0.1)`.

---

## 1. Banner / notification state machine

Alcove does not have a type literally named "banner." The transient "new media" reveal is the **notification** path, and the state is a flat set of fields on the `Alcove.NotchController` `@Observable` class. The full 94-field layout was recovered from `__swift5_fieldmd`. The banner/morph-relevant fields, **in binary order**:

```
space, windowController, blurWindowController,        ← 2-window arch (content + blur), matches prior report
cancellables,
disableTransitionNonce,
notificationSwapDebounce,                             ← banner: debounce swapping one banner for the next
notificationCloseDebounce,                            ← banner: debounce before close
notificationCloseGeneration,                          ← banner: monotonic token to cancel stale closes
notificationRestoreDebounce,                          ← banner: debounce restoring prior activity after banner
notificationClosingType,                              ← banner: ENUM — how the banner is dismissing
notificationClosingUntil,                             ← banner: Date/time the close animation runs until
liveActivitySwapDebounce,
quickPeekDebounce, quickPeekGeneration,
adjustDebounce, mediaKeyEdgeRestoreDebounce,
expandedTransitionTask,                               ← MORPH: size transition (async Task)
expandedRadiusTransitionTask,                         ← MORPH: corner-radius transition (separate Task)
progressiveBlurTransitionTask,                        ← MORPH: progressive-blur ramp (separate Task)
dismissedLiveActivityStack,
isHidden, visibilityDebounce,
animateNonNotchShellTransition,                       ← separate morph path for notchless displays
...settings flags...
_isEnabled, _isVisible,
_isMouseInside, _isMouseInsideLeftContent, _isMouseInsideRightContent,   ← hover hit-testing per wing
_isElevated, _isPressed, _isQuickPeeking,
_isExpanded,                                          ← MORPH: terminal state bool
_expandedProgress,                                    ← MORPH: the continuous 0→1 driver
_isExpanding, _isCollapsing, _isWidening, _isAdjusting,  ← MORPH: in-flight direction bools
_hasProgressiveBlur, _hasLiveActivity, _hasOutput,
_hasNotification,                                     ← BANNER: is a banner currently shown
_notification, _notificationIntent,                  ← BANNER: payload + tap intent
_liveActivity, _liveActivityIntent,
_quickPeek,
_expandedActivityTransitionNonce,
_controlStripSnapshotRefreshNonce,
_expandedActivity,
_notificationContext,                                ← BANNER: context the banner was raised in
_notchWidth, _notchHeight,                            ← GEOM: compact pill endpoint
_notchExpandedWidth, _notchExpandedHeight,            ← GEOM: slab endpoint
_lastAdjustment, _shouldResetSwipes,
...gesture/swipe scroll fields...
_$observationRegistrar
```
*(Evidence: `__swift5_fieldmd` parse of the 94-field class; printed in full during analysis.)*

### Trigger: "when media changes"
- Setting key `settings.nowPlaying.whenMediaChanges`, label **"When media changes"** (`Localizable.strings`). No sibling option keys exist → it is a single toggle ("show the banner on media change: on/off"), not a multi-choice picker.
- The now-playing source is `Alcove.MediaManager` (`@Observable`, 75 fields). The change event is tokenized: field **`_songChangeToken`** plus the local view copy **`_whenSongChanges`** and **`_peekDuration`**. The progress slider carries `songChangeToken` and **`_shouldSuppressNextExternalAnimation`** — i.e. on a song change Alcove bumps the token and *suppresses* the seeker's normal animation so the banner/morph owns the motion.
  *(Evidence: `__swift5_fieldmd` MediaManager + ProgressSlider field rows; `__swift5_reflstr` `_songChangeToken`, `_whenSongChanges`.)*

### Dwell / auto-dismiss timing
- The banner is closed on a timer: **`notificationClosingUntil`** (the deadline) + **`notificationCloseGeneration`** (a counter that invalidates a pending close if a new banner arrives first) + **`notificationCloseDebounce`**. Swapping banner→banner without a full retract uses **`notificationSwapDebounce`**; returning to the prior idle activity afterward uses **`notificationRestoreDebounce`**.
- The dwell duration itself is the user-facing **`_peekDuration`** ("Peek duration" slider) for the now-playing peek, and **`transientMediaDurationThreshold`** (a `MediaManager` field) — the minimum track-length below which media is treated as "transient" (e.g. UI sounds / short clips are ignored rather than raising a banner). These are configurable sliders, so they are not fixed constants in the binary.
  *(Evidence: `MediaManager` field `transientMediaDurationThreshold`; `common.peekDuration` label; `NotchController` fields `notificationClosing*`.)*
- **`notificationClosingType`** is an enum (a `Defaults`-encoded `RawRepresentable: String`), but its cases are stored as symbolic refs and did not resolve to plain strings. Functionally it selects *how* the banner leaves (e.g. retract vs fade vs swap) — pair it with `notificationClosingUntil` as the close clock.

---

## 2. Progressive blur transition

The prior report covered the static `ProgressiveBlurView` setup (CABackdropLayer, `bleedAmount=12`, `CIMaskedVariableBlur`). New here — how it *transitions*:

- **It is its own animation task:** `progressiveBlurTransitionTask` on `NotchController`, sequenced independently of the size/radius tasks. So the blur can ramp on a different curve/delay than the geometry.
- **What triggers it:** the blur is gated by `_hasProgressiveBlur` (state bool) and the user setting `settings.general.behaviour.progressiveBlur` ("Progressive blur"). It is raised/lowered as part of the expand/collapse mutation, not continuously.
- **The blur effect's parameters** come from two recovered structs:
  - `maskProvider | maxBlurRadius | scale` — the variable-blur engine driver (a mask provider + a *max* radius it ramps toward + a scale).
  - `cornerRadius | blurRadius | edgeConfigurations | invertAlpha` — the per-edge progressive blur (which edges get the gradient mask, and whether the mask alpha is inverted). `progressiveMask` and `_progressiveBlur` are the NotchController-side handles.
  *(Evidence: `__swift5_fieldmd` rows `maskProvider|maxBlurRadius|scale` and `cornerRadius|blurRadius|edgeConfigurations|invertAlpha`.)*
- **Ramp curve/duration:** the blur ramp and the opacity micro-fades use **`Animation.easeOut(duration: 0.1)`** — this is by far the most common easeOut (33 of 36 callsites). A slow **`easeOut(duration: 0.6)`** exists (×1) — likely the blur fade-*out* on collapse. `easeOut(0.15)` ×2 and `easeInOut(0.2)` ×2 round it out.
  *(Evidence: decoded RIP doubles at the 36 `Animation.easeOut(duration:)` callsites, stub `0x100489b4e`.)*
- **Filter type:** unchanged from prior report — `CIMaskedVariableBlur` (uses `inputNormalizeEdges`) with a `CISmoothLinearGradient` mask, plus a `gaussianBlurFilter`. The single SwiftUI `.blur(radius:)` modifier is **radius = 10.0** (one callsite, stub `0x1004897e2`).

---

## 3. Morph geometry — CONTINUOUS, not discrete stages

**Verdict: one continuous spring-driven progress, two geometric endpoints. No intermediate slab sizes.**

Evidence:
1. **Only two geometry endpoints exist as fields:** `_notchWidth/_notchHeight` (compact pill) and `_notchExpandedWidth/_notchExpandedHeight` (slab). There is no `_mediumWidth`, `_compactWidth`, `_bannerWidth`, etc.
2. **The interpolator is `_expandedProgress`** (a single Double field), assisted by the "rubber-band" trio at the tail of the main NotchView state struct: **`_shellScale | _shellWidthProgress | _shellScaleAnchor`**. Growth is expressed as a *scale about an anchor* + a *width progress*, not a width keyframe sequence.
   *(Evidence: `__swift5_fieldmd` NotchView struct ends `..._shellScale|_shellWidthProgress|_shellScaleAnchor`; NotchController has `_expandedProgress`, `_isExpanding`, `_isCollapsing`, `_isWidening`, `_isAdjusting`.)*
3. **`medium` is a red herring:** it appears only in the contiguous reflstr group `mini, small, medium, large, extraLarge` immediately after `radiusMultiplier` → that's a corner-radius *size class*, unrelated to slab width. The morph has no medium tier.
   *(Evidence: `__swift5_reflstr` ordering around `radiusMultiplier`.)*
4. **Discrete *presentation contexts* do exist** (these are which content fills the shell, not intermediate sizes): enum `liveActivity | expandedView | both` (idle-activity content), enum `notchExpanded | lockscreen` (presentation surface), and a per-item `item | showsSymbol | _isExpanded`. The shell geometry still interpolates continuously between pill and slab regardless of which context is shown.
5. **The NotchShape itself reacts to banner presence:** the shape driver struct is `kind | progress | isMuted | hasPhysicalNotch | hasNotification | shape | showsLabel` — note `progress` (the morph progress) AND `hasNotification` both feed the path. So the silhouette is a function of morph-progress and whether a banner is up.
   *(Evidence: `__swift5_fieldmd` row `kind|progress|isMuted|hasPhysicalNotch|hasNotification|shape|showsLabel`.)*

### Asymmetric radius during morph
Corner radius animates on its **own** task (`expandedRadiusTransitionTask`) separate from size, and uses the per-corner fields from the prior report (`topLeft/Right`, `bottomLeft/Right`, `bottomLeadingCornerBoost`, `bottomTrailingCornerBoost`, `radiusMultiplier`). Decoupling radius from size is what lets the corners "catch up" with a slightly different curve than the width — part of the squeeze feel.

---

## 4. Content transitions during the morph

As the shell resizes, inner content (artwork, title, transport) animates with a small library of custom modifiers + SwiftUI transitions. All confirmed present:

- **`ScaleTransition(_:anchor:)`** — used repeatedly in the NotchView `body` with **different anchors per element**: `center` (main content), `trailing` (right wing / audio bars), `bottom` (lower transport), `top` (whole-shell recede). This per-anchor scaling is the staggered "everything converges toward its home edge" effect.
  *(Evidence: in the body function starting `0x1000028d0`, `ScaleTransition` init stub `0x10048915e` is called after `UnitPoint.center` `0x100489ba2`, `.trailing` `0x100489bae`, `.bottom` `0x100489b9c`, `.top` `0x100489b96`.)*
- **A combined opacity+blur+offset modifier** with fields **`opacity | blurRadius | verticalOffset | delay | duration`** — recovered intact from `__swift5_fieldmd`. This is the `SlideBlurScaleModifier` / `DelayedBlurFadeModifier` family (`__swift5_reflstr` names `SlideBlurScaleModifier`, `DelayedBlurFadeModifier`, `ScaleAndFade`, `VerticalOffsetModifier`, `ScaledFontSizeModifier`, `ExpandedActivityTransitionModifier`, `ProgressiveBlurEffect`, `ShakeEffect`). The presence of `delay` as a field is the **stagger knob** — content elements fade/slide/blur in with per-element delays.
  *(Evidence: `__swift5_fieldmd` row `opacity|blurRadius|verticalOffset|delay|duration`; modifier type names in `__swift5_reflstr`.)*
- **Text/title swap = `BlurReplaceTransition.Configuration.downUp`.** When the track title changes, the old text blur-replaces *upward* and the new text arrives from *below*. Four `BlurReplaceTransition` callsites; the ones near `Foundation.localized`/`LocalizationValue` are the localized-text swaps (title/subtitle).
  *(Evidence: stub `0x100489422` = `...Configuration.downUp` getter; callsites at `0x100003bf0`, `0x10000480b`, `0x1000a061a`, `0x1000b8a3a`; two are adjacent to `localized`/`LocalizationValue`.)*
- **Numeric content (timecodes) = `ContentTransition.numericText(countsDown:)`** and SF Symbols use `ContentTransition.symbolEffect`.
  *(Evidence: stubs `0x1004891ac` numericText, `0x1004891b2` symbolEffect; `EnvironmentValues.contentTransition` getter/setter `0x100489218`/`0x10048921e`.)*
- **Micro-fade timing for content = `easeOut(0.1)`** (the 33× cluster), so content opacity changes are ~100ms, faster than the ~350ms shell spring — content settles before the shell finishes, which reads as "snappy."

---

## 5. Spring tuples mapped to each transition

Two distinct animation families (confirmed by decoding the literal pool at every callsite):

### Family A — bouncy: `SwiftUI.Spring(duration:bounce:)` (stub `0x100489a22`, 185 callsites)
Decoded distribution (duration, bounce → count):

| duration | bounce | count | role |
|---|---|---|---|
| 0.35 | **−0.20** | **40** | **recede / collapse / settle** (no overshoot, soft landing) |
| 0.35 | **0.30** | **35** | **expand / open** (the primary morph) |
| 0.40 | 0.30 | 12 | secondary grow |
| 0.45 | 0.40 | 11 | heavier grow w/ overshoot |
| 0.40 | 0.35 | 6 | grow variant (prior report's "primary slab grow") |
| 0.60 | 0.40 | 7 | slow grow |
| 0.60 | 0.35 | 6 | slow grow w/ overshoot |
| 0.60 | 0.30 | 4 | slow ease-in |
| 0.50 | 0.375 | 4 | |
| 1.50 | 0.40 | 4 | long mellow (idle-activity reveals) |
| 0.20 | 0.30 | 2 | fast snappy |
| 0.30 | 0.325 | 2 | |
| (others, ≤2 each) | | | |

*(Evidence: per-callsite RIP-double decode; the two `movsd xmm0/xmm1` immediately preceding each `Spring.init`.)*

### Family B — critically damped: `Animation.spring(response:dampingFraction:blendDuration:)` (stub `0x100489b3c`, 282 callsites)
Almost universally `dampingFraction = 1.0` (never overshoots). This is the **"Smooth" / "Disable overshoot"** path (`settings.hud.disableOvershoot` = "Disable overshoot"; `settings.hud.speed.smooth` = "Smooth").

| response | dampingFraction | count |
|---|---|---|
| **0.20** | 1.0 | **98** |
| 0.40 | 1.0 | 46 |
| 0.25 | 1.0 | 27 |
| 0.4875 | 1.0 | 21 |
| 0.30 | 1.0 | 16 |
| 0.50 | 1.0 | 17 |
| 0.45 | 1.0 | 11 |
| 0.60 | 1.0 | 8 |
| 0.15 | 1.0 | 6 |
| (others ≤4) | | |

*(Evidence: per-callsite decode at the 282 `spring(response:dampingFraction:)` sites.)*

### Mapping to the four transitions (with disassembly evidence)

| Transition | Spring | Anchor | Evidence |
|---|---|---|---|
| **Pill → slab (expand / open)** | `Spring(duration: 0.35, bounce: 0.3)` | center | Function `0x10001ef35` does `Observation.access` → `withMutation(of: keyPath)` → loads `Spring(0.35, 0.3)` (decoded at `0x10001f217`/`0x10001f21f`) → `Animation.spring(_:blendDuration:)` → `withAnimation{}`. A **second identical `Spring(0.35, 0.3)`** at `0x10001f2bc` animates a second property in the same closure (the two are `isExpanded` + `expandedProgress`/shell). So expand = one feel, `0.35/0.3`. |
| **Slab → pill (recede / collapse)** | `Spring(duration: 0.35, bounce: −0.2)` | **top** | In the NotchView `body` (`0x1000028d0`), `UnitPoint.top` (`0x100002d55`) is loaded just before `Spring(0.35, −0.2)` (`0x100002db9`). Negative bounce = critically-overdamped soft landing; top anchor = retracts up into the notch. This `0.35/−0.2` is the single most-used spring (×40) → it is the global "settle/dismiss" feel, reused for banner retract too. |
| **Banner expand (pill → banner)** | `Spring(0.35, 0.3)` (same as slab open) | center / per-element | The banner is presented via the same expand mutation path (`_hasNotification` raised → `_isExpanding` → `_expandedProgress`), so it shares the `0.35/0.3` open spring. Content arrives via `ScaleTransition` + the `opacity/blurRadius/verticalOffset/delay` modifier + `BlurReplace.downUp` for the title. |
| **Banner retract (banner → pill)** | `Spring(0.35, −0.2)` anchored top | top | Same recede path as slab close, gated by `notificationClosingType` / `notificationClosingUntil` / `notificationCloseGeneration`. |
| **"Smooth" mode (any of the above, overshoot disabled)** | `spring(response: 0.2, dampingFraction: 1.0)` | as above | When the user picks Smooth / Disable overshoot, the bouncy springs are replaced by the damped family; `response 0.2 / damping 1.0` ×98 is the dominant substitute. |

Note: `0.4875` (×21 in Family B) = `0.65 × 0.75` — a derived response, likely `baseResponse * speedMultiplier` for one of the HUD speed presets.

---

## 6. What nox should copy

1. **Drive the morph with one continuous progress scalar, not size tiers.** Keep two stored sizes (compact pill, expanded slab) and animate a single `expandedProgress: Double` (0→1) that interpolates width/height. Express growth as scale-about-an-anchor + width-progress (`shellScale`, `shellWidthProgress`, `shellScaleAnchor`) rather than animating a frame. Do **not** add a "medium" stop.

2. **Split the morph into three independently-timed animations:** (a) size, (b) corner radius, (c) progressive blur. Run them as separate tasks/animations so radius can lag/lead size slightly and the blur can ramp on `easeOut(0.1)` while the shell rides the spring. This decoupling is a big part of the "premium squeeze."

3. **Use two springs, anchored differently:**
   - Open / expand / banner-in → `Spring(duration: 0.35, bounce: 0.3)`, scale anchor **center**.
   - Close / recede / banner-out → `Spring(duration: 0.35, bounce: -0.2)`, scale anchor **top** (retracts into the notch). The negative bounce is essential — it lands softly without overshoot.

4. **Treat the new-media banner as a transient presentation over the pill with a generation-guarded auto-close**, not a separate window state. Mirror Alcove's guards: a `closingType` + `closingUntil` deadline + a monotonic `closeGeneration` counter so a new track arriving mid-dismiss cancels the stale close and swaps content instead of fully retracting (`swapDebounce`), then restores the prior idle activity after (`restoreDebounce`).

5. **Suppress the seeker's own animation on a song change** (Alcove's `_shouldSuppressNextExternalAnimation` + `songChangeToken`). When the track flips, bump a token and let the banner/morph own all motion for that frame — otherwise the progress bar fights the morph.

6. **Content transitions:**
   - Title/subtitle text swap → `.contentTransition(...)` is not enough; use a **blur-replace, down-up direction** (old text blurs out upward, new text blurs in from below).
   - Timecodes → `.contentTransition(.numericText())`.
   - Artwork / wings / transport → `.transition(.scale(anchor:).combined(with: .opacity))` with **per-element anchors** (center / trailing / bottom) and **per-element `delay`** for stagger; or a single modifier exposing `opacity + blurRadius + verticalOffset + delay + duration`.
   - Keep content fades fast: `easeOut(duration: 0.1)`, so content settles before the ~350ms shell spring finishes.

7. **Offer a "disable overshoot / smooth" toggle** that swaps the whole bouncy family for `spring(response: 0.2, dampingFraction: 1.0)` (critically damped). Alcove ships this as a first-class setting.

8. **NotchShape should take both `progress` and `hasBanner` as inputs** so the silhouette responds to the banner, not just the size. Continuous corners, asymmetric bottom-corner boost (from prior report) still apply.

---

## Evidence index (offsets / symbols)

- NotchController 94-field layout, MediaManager 75-field layout, NotchView state struct (`..._shellScale|_shellWidthProgress|_shellScaleAnchor`), modifier fields `opacity|blurRadius|verticalOffset|delay|duration`, blur structs `maskProvider|maxBlurRadius|scale` and `cornerRadius|blurRadius|edgeConfigurations|invertAlpha`, shape driver `kind|progress|...|hasNotification|shape|showsLabel`, enums `liveActivity|expandedView|both` / `notchExpanded|lockscreen` / `item|showsSymbol|_isExpanded` — all from `__TEXT,__swift5_fieldmd` (x86_64 slice, addr `0x10057a344`, size 50724), parsed in this session.
- Expand setter: function `0x10001ef35`; `Spring(0.35,0.3)` literals decoded at `0x10001f217`/`0x10001f21f` and again `0x10001f2ac`/`0x10001f2b4`; `withMutation` stub `0x100488cf0`, `withAnimation` stub `0x100489056`.
- Recede: NotchView body `0x1000028d0`; `UnitPoint.top` `0x100489b96` at `0x100002d55`; `Spring(0.35,−0.2)` at `0x100002db9`.
- Spring stubs: `Spring(duration:bounce:)` `0x100489a22`; `Animation.spring(_:blendDuration:)` `0x100489b42`; `Animation.spring(response:dampingFraction:blendDuration:)` `0x100489b3c`.
- Transition stubs: `ScaleTransition(_:anchor:)` `0x10048915e`; `BlurReplaceTransition.Configuration.downUp` `0x100489422`; `BlurReplaceTransition.init(configuration:)` `0x10048942e`; `ContentTransition.numericText` `0x1004891ac`; `ContentTransition.symbolEffect` `0x1004891b2`; `EnvironmentValues.contentTransition` `0x100489218`/`0x10048921e`; `AnyTransition.combined(with:)` `0x100488fa2`.
- Timing: `easeOut(duration:)` stub `0x100489b4e` → 33×0.1, 2×0.15, 1×0.6; `easeInOut(duration:)` stub `0x100489b54` → 2×0.2; `.blur(radius:)` stub `0x1004897e2` → 10.0 (single callsite).
- Settings/labels: `settings.nowPlaying.whenMediaChanges` = "When media changes"; `settings.general.behaviour.progressiveBlur` = "Progressive blur"; `settings.hud.disableOvershoot` = "Disable overshoot"; `settings.hud.speed.{smooth,fast,instant}`; `common.peekDuration` = "Peek duration" (`en.lproj/Localizable.strings`).
- Reflection strings (`__TEXT,__swift5_reflstr`, arm64): `_songChangeToken`, `_whenSongChanges`, `transientMediaDurationThreshold`, `notificationClosingType`, `notificationClosingUntil`, `notificationSwapDebounce`, `expandedTransitionTask`, `expandedRadiusTransitionTask`, `progressiveBlurTransitionTask`, `animateNonNotchShellTransition`, `_expandedProgress`, `_isExpanding`, `_isCollapsing`, `_isWidening`.
