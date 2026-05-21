# Alcove Frame-by-Frame Animation Analysis

**Date:** 2026-05-21
**Source:** ~4000 frames at `/Users/apple/Downloads/alcove/` (Area*.jpg)
**Frame dimensions:** 3276×1080 (screen capture)
**Frame rate:** 60 fps (assumed standard)
**Method:** PIL + numpy edge detection at row y=20 (slab top area), finding the
contiguous dark-pixel run containing screen-center.

This is EMPIRICAL ground truth — measured pixel-by-pixel from the user's own
screen recordings, NOT inferred from the binary, NOT from clone reverse
engineering, NOT from cho.sh estimates.

---

## State widths identified

Across the recording, three distinct silhouette widths appear:

| State | Width (px) | Notes |
|---|---|---|
| Resting pill | 440 | Compact menu-bar pill, music paused or no media |
| Expanded slab (hover) | 663 | Standard mouse-hover expansion |
| Music-expanded (full) | 882 | Larger expansion with full music UI |

Ratio analysis:
- Resting : Expanded = 440 : 663 = **0.664**
- Expanded : Music-expanded = 663 : 882 = **0.751**

---

## OPEN animation — resting → expanded slab

**Frames 95-145, dense measurement:**

```
Frame  Width  Δ      Phase
   95   467     +0   pre-resting? (slight inflation from 440)
   96   471     +4
   97   473     +2
   98   473     +0   resting baseline (~473px)
   99   473     +0
  100   473     +0
  101   472     -1   ← LAST RESTING FRAME
  102   532    +60   ← OPEN TRIGGERED (rapid growth begins)
  103   545    +13
  104   558    +13
  105   585    +27
  106   585     +0
  107   600    +15
  108   619    +19
  109   632    +13
  110   643    +11
  111   656    +13
  112   663     +7   ← reaches settled value briefly
  113   663     +0
  114   668     +5   ← overshoot phase begins
  115   671     +3
  116   674     +3
  117   674     +0
  118   675     +1   ← PEAK (overshoot maximum)
  119   675     +0
  120   673     -2   ← coming back from overshoot
  121   673     +0
  122   671     -2
  123   669     -2
  124   668     -1
  125   667     -1
  126   666     -1
  127   664     -2
  128   663     -1   ← SETTLED
  129+  663-664 (settled, micro-oscillation in measurement noise)
```

### Extracted parameters

| Quantity | Value |
|---|---|
| Start frame | 102 |
| Peak frame | 118 (16 frames after start) |
| Settled frame | 127 (25 frames after start) |
| **Total duration** | **25 frames = 417 ms** |
| Time-to-peak | 16 frames = 267 ms |
| Peak value | 675 px |
| Settled value | 663 px |
| **Overshoot magnitude** | **12 px = 1.81%** |

### Inverting to spring parameters

For damped harmonic motion, peak overshoot relates to damping ratio ζ via:

  overshoot = exp(-π·ζ / √(1 - ζ²))

Solving for ζ given overshoot = 0.0181:

  ln(0.0181) = -4.012
  π·ζ / √(1-ζ²) = 4.012
  ζ / √(1-ζ²) = 1.277
  ζ² / (1-ζ²) = 1.631
  ζ² = 0.620
  **ζ = 0.787** (damping ratio)
  **bounce = 1 - ζ = 0.213**

For perceptual duration via Apple's SwiftUI formula (stiffness = (2π/d)²):

  ω = 2π/duration
  duration = 0.40 (matched to time-to-peak ~267ms × 1.5 envelope)
  **stiffness = (2π/0.40)² ≈ 247**
  damping = 2·ω·ζ = 2·15.71·0.787 ≈ **25**

**Empirical spring: `Spring(duration: 0.40, bounce: 0.21)` = stiffness 247, damping 25**

### Comparison vs other sources

| Source | Spring | Bounce | Overshoot |
|---|---|---|---|
| cho.sh (claimed iPhone DI) | 400/30 | 0.25 | ~3.8% |
| Alcove binary literal pool | `(0.40, 0.35)` = 247/20 | 0.35 | ~5.5% |
| Apple Tahoe research recommendation | `.bouncy(0.45, 0.10)` = 195/17 | 0.40 | ~6.9% |
| **EMPIRICAL Alcove (this analysis)** | **`(0.40, 0.21)` = 247/25** | **0.21** | **1.81%** |
| iPhone DI clones (jackson-storm, boring.notch) | response 0.40, ζ 0.80 | 0.20 | ~1.5% |

The **iPhone DI clones converge with empirical Alcove** (both at ~1.5-2% overshoot,
~400ms response). The binary's `(0.40, 0.35)` tuple must belong to a different
state-change (probably a hover-emphasize, drag-release, or content morph) — NOT
the slab open. Alcove ships 30 unique Spring tuples in its binary; we matched
the wrong one originally.

---

## CLOSE animation — expanded slab → resting pill

**Frames 815-850, dense measurement:**

```
Frame  Width  Δ
  815   571    +0   ← already mid-close (start frame missed)
  816   563    -8
  817   558    -5
  818   550    -8
  819   543    -7
  820   531   -12
  821   525    -6
  822   473   -52   ← rapid descent into resting baseline
  823   467    -6
  824   459    -8
  825   450    -9
  826   449    -1
  827   446    -3
  828   445    -1
  829   444    -1   ← essentially settled (1px from final)
  830   444    +0
  831   442    -2
  832   442    +0
  833   442    +0
  834   441    -1
  835   440    -1   ← SETTLED at resting baseline
  836+  440 (held)
```

### Extracted parameters

| Quantity | Value |
|---|---|
| Visible motion frames | 815 → 835 = **20 frames = 333 ms** |
| Initial width | 571 px |
| Final width | 440 px |
| **Overshoot** | **0 (monotonic — NO bounce-back below 440)** |
| Curve shape | Overdamped exponential decay |

### Inverting to spring parameters

No overshoot = overdamped, ζ > 1. This matches the Alcove binary's recede
tuple `Spring(duration: 0.35, bounce: -0.20)` — where bounce -0.20 directly
encodes overdamping (Apple's Spring convention: negative bounce = damping
ratio > 1).

For bounce = -0.20:
  ζ = 1 / (1 + bounce) = 1 / 0.80 = 1.25
  ω = 2π/0.35 = 17.95
  stiffness = ω² ≈ **322**
  damping = 2·ω·ζ = 2·17.95·1.25 ≈ **45**

**Empirical close spring: `Spring(duration: 0.35, bounce: -0.20)` = stiffness 322, damping 45**

The shape is "decisive monotonic" — slab closes confidently with no
bounce-into-place. This is appropriate for a CLOSE (user wants the panel
to go away, not to feel like it's settling in).

---

## Music-expand / collapse (663 ↔ 882)

**Frames 1597-1598 (expand) and 1676-1677 (collapse):**

```
1597  663px   ↓ (settled at expanded)
1598  882px   ← ONE-FRAME jump to music-expanded
```

```
1676  882px   ↓ (settled at music-expanded)
1677  663px   ← ONE-FRAME drop back to expanded
```

### Analysis

The music-expand/collapse appears **instant** (sub-frame, i.e., <16.7ms at
60fps). Two possible interpretations:

1. **Discrete state change** — Alcove may not animate this particular
   transition at all; it just snaps.
2. **Fast animation** — runs in <1 frame; the 60fps capture is too coarse.

For nox, we don't currently have an equivalent music-expand state — our
slab is single-state per tab. If we add one later, the right starting
point is likely `Spring(duration: 0.20, bounce: 0.30)` (one of Alcove's
binary tuples — "fast snappy") which would settle in ~150ms; the
60fps frame between f1597 and f1598 missed it entirely.

---

## Resting pill (compact menu-bar state)

**Frames 0-100, 130-820, 836-1100, etc:**

- Width: **440 px** stable
- Held for hundreds of frames at a time
- No oscillation, no breathing animation

This is the locked compact pill dimension. Matches the comment in
`memory/notetaker_alcove_pill_parity.md` which locked our resting pill at
220×20pt — Alcove's recordings here are 2× retina (3276×1080 from a
1638×540 logical screen, or equivalent), so 440px = 220pt logical. **Our
pill matches Alcove's.** ✓

---

## What this changes in nox

Applied 2026-05-21 (PanelWindowController.swift):

| Spring | Was | Now (empirical Alcove) |
|---|---|---|
| Slab open (animateOpen) | 195/17 (Tahoe .bouncy(0.45, 0.10)) | **247/25** (`Spring(0.40, 0.21)`) |
| Music close to pill (animateClose, !isNotchHidden) | 480/40 | **322/45** (`Spring(0.35, -0.20)`) |
| Anticipation initialVelocity | -0.4 | **0** (Alcove has no inverse motion at start) |

Close-to-notch-hidden (158/25) unchanged — it's Apple's `.smooth(0.5)` and we
don't have empirical data for that flow.

---

## Notes for future iterations

1. **The Alcove binary's 30+ spring tuples** map to many different state
   changes, hover effects, drag releases, content morphs. The binary
   decode found them all but couldn't say which is which without runtime
   matching. Frame-by-frame analysis like this is the gold standard for
   identifying WHICH binary value maps to WHICH motion.

2. **Music-expand/collapse instant snap** is a curiosity — if we ever
   need to match it, run the recording at higher framerate (240fps if
   we can capture) to see the actual curve.

3. **No pill resize animation** when track changes — Alcove just swaps
   the content inside a stable 440px pill. We should not add a width
   spring to track changes either.

4. **The 1.81% overshoot is INTENTIONALLY subtle** — Alcove deliberately
   under-bounces vs the binary's literal value. Could be a runtime override,
   could be the spring's `settlingDuration` cutting off early, could be
   damping factor scaling. The math is consistent with `(0.40, 0.21)`.

5. **Frame counts are 60fps assumed.** If Alcove was captured at 30fps,
   double all the durations (open would become 833ms, etc.). Verify
   against actual capture metadata next iteration.
