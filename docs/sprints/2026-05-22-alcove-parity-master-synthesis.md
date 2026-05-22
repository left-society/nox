# Alcove-Parity Master Synthesis (2026-05-22)

Cross-validated from FOUR parallel research passes: (1) full decode-doc synthesis,
(2) frame-by-frame measurement of `Area 3.mp4` (nox) vs `Areac 2.mp4` (Alcove),
(3) complete audit of nox's animation code, (4) global Apple-animation research
(WWDC18/23/25 + open-source notch apps).

## Headline: nox's CORE morph springs already match Alcove

- **Slab OPEN**: nox `SpringFrameAnimator(247/25)` = response **0.40s, ζ 0.795** (1.8% overshoot).
  Alcove frame-measured open = **Spring(0.40, bounce 0.21)** = 1.8% overshoot. **Essentially identical.**
- **Slab CLOSE**: nox `438/36` = response 0.30s, ζ 0.85 — iteratively tuned to the user's own
  feedback (rejected 0.333s as "too slow", 0.20s as "too fast"). Do NOT re-open the *speed*.

So the "doesn't feel premium" gap is NOT the core open/close spring. It's a set of specific polish gaps below.

## The real gaps (cross-validated)

1. **Corners read tighter / harder-shouldered than Alcove.** (frame pass, med-high confidence)
   Alcove's notch shoulders + album-art use a larger, gentler squircle; nox curves more abruptly,
   reading rectangular. Album art is partially **clipped by the notch top edge** with a smaller radius.
   - nox now: slab bottom `innerCornerRadius` 44 (bumped from 34), squircle exponent 3.2 (= Alcove's
     measured 0.276·R curvature — the SHAPE matches; SIZE/clipping is the gap).
   - Fix: soften notch-shoulder radius; round the resting album art ~22% and stop clipping it; consider
     asymmetric **bottom-corner boost** (Alcove's `bottomLeading/TrailingCornerBoost`).

2. **Expand reads TWO-STAGE; Alcove is a unified blur-crossfade.** (frame + code + Apple)
   nox: empty slab drops, THEN title/content appears (track-banner content delayed 0.18–0.22s after shell).
   Alcove: art + title **blur-and-crossfade in WITH the slab drop**, settling flat.
   Apple WWDC18/23: content should lag the surface by **~50ms on a SLOWER spring**, not a long fixed delay.
   - Fix: shorten the content-after-shell delay toward ~50–80ms and use a blur-replace reveal that
     overlaps the shell (content rides a slightly slower spring, not a 180ms gap).

3. **Resting pill: nox shows empty notch; Alcove always docks art + waveform in the compact pill.**
   (frame pass) — Alcove's collapsed pill IS a now-playing pill (art left, waveform right) at all times.
   - Fix: keep art (+ small waveform) docked in the resting compact pill whenever there's now-playing,
     instead of an empty black notch.

4. **Close radii were on a different clock than the close frame.** (code audit) — FIXED 2026-05-22:
   close radii spring synced 158/25 → 438/36 (matches the frame; corners no longer trail the shrink).

5. **Artwork transition = a 3D Y-flip** — this is CORRECT (Alcove flips too; the binary has a
   `disableArtworkFlip` setting). nox's flip is `easeInOut(0.42s)`; Alcove's micro-motions are ~0.20s,
   so the flip may be a touch slow. Low-priority tune (0.42 → ~0.28).

## Authoritative Alcove numbers (for reference)

| Transition | Spring | Notes |
|---|---|---|
| Slab open (visible) | `Spring(0.40, 0.21)` | frame-measured (under-bounces its own 0.35/0.30 literal) |
| Slab close | `Spring(0.35, −0.20)` | monotonic, anchored TOP |
| Compact→banner | `Spring(0.35, 0.30)` | |
| "Smooth"/no-overshoot mode | `spring(0.20, dampingFraction 1.0)` | dominant micro (×98) |
| Micro-fade / label reveal | `easeOut(0.10)` | |
| Banner dwell | ~1.88–1.93s | swap-in-place on rapid skips, generation-guarded close |
| Corners | continuous squircle (`kCACornerCurveContinuous`), asymmetric bottom boost | |
| Content | shell leads; content lags via a SLOWER spring (~50ms), not delays; title BlurReplace.downUp; numbers numericText | |

## Apple principles (WWDC18/23/25)
1. Damping is gesture-gated: default 100% damping; bounce only when the gesture had momentum.
2. Two springs (fast surface, ~50ms-slower content), NOT one + a fixed delay.
3. Asymmetric in/out: arrive expressive, leave calm.
4. Squeeze via non-uniform scale anchored top (stretch DOWN from the notch).
5. Never break interruptibility; never `.interpolate` on glass.

## TRAPS found in the decodes
- "Artwork = blur-replace not flip" — WRONG. Artwork FLIPS (CALayer transform); blur-replace is for TEXT.
- "Slab open = 0.40/0.35" (binary) — the VISIBLE open is 0.40/0.21 (frame). Frame > binary for visible motion.
- `matchedGeometryEffect` is NOT used by Alcove (pure spring-on-progress-scalar).
- All durations assume 60fps capture — verify before treating as absolute.

## Prioritized fix order
1. (DONE) close radii sync.
2. Unified expand (shorten content delay + blur-crossfade reveal). ← biggest visible "feel" win
3. Resting pill always docks art + waveform.
4. Corner softness + album-art rounding/clip fix.
5. Artwork flip speed 0.42 → ~0.28.
