# Area 4 vs Alcove Music Motion Pass

Date: 2026-05-22

Source videos:

- Nox: `/Users/apple/Downloads/Videos/Area 4.mp4`
- Alcove: `/Users/apple/Downloads/Videos/alcove .mp4`

Artifacts:

- `docs/sprints/alcove-motion-pass/alcove-top-banner-frame-metrics.csv`
- `docs/sprints/alcove-motion-pass/nox-top-banner-frame-metrics.csv`
- `docs/sprints/alcove-motion-pass/alcove-row-width-metrics.csv`
- `docs/sprints/alcove-motion-pass/nox-row-width-metrics.csv`
- `docs/sprints/alcove-motion-pass/alcove-top-banner-bursts-1.jpg`
- `docs/sprints/alcove-motion-pass/nox-top-banner-bursts-1.jpg`

## Capture Facts

Both videos are 1636 x 1080 at 60fps. Alcove is 15.55s / 933 frames.
Nox Area 4 is 11.03s / 662 frames.

The Gemini video-analyzer script could not run because the local environment is
missing `google-genai`, so the pass used deterministic local frame extraction
and OpenCV/PIL-derived metrics instead.

## What The Frames Show

This pass is about the menubar music-change capsule/banner, not the full slab.
Alcove keeps the music UI anchored to the notch, lets the black shell lead, then
reveals the title/artist inside that already-expanding shell. The title is not
visible in the compact media pill before the shell starts opening.

Nox had the right broad idea, but the event was split in two:

1. `trackChangedFiring` was set first.
2. `presenter.nowPlaying` changed immediately.
3. The pill artwork and title apron reacted to `trackChangedFiring`.
4. The actual `.trackChanged` event and shell expansion were installed about
   120ms later.

That meant the new title/artwork could begin growing while the compact pill was
still visually compact. It read like content got ahead of the shell.

## Burst Comparison

High-energy top-banner bursts from the 60fps pass:

| App | Burst frames | Time | Peak energy | Interpretation |
| --- | ---: | ---: | ---: | --- |
| Alcove | 83-102 | 1.38-1.70s | 4.71 | controlled shell/content motion |
| Alcove | 208-228 | 3.47-3.80s | 5.43 | track/banner reaction |
| Alcove | 251-270 | 4.18-4.50s | 5.18 | close/restore |
| Alcove | 367-389 | 6.12-6.48s | 5.89 | track/banner reaction |
| Alcove | 679-698 | 11.32-11.63s | 5.91 | track/banner reaction |
| Alcove | 741-763 | 12.35-12.72s | 6.54 | close/restore |
| Alcove | 816-890 | 13.60-14.83s | 6.71 | longer visible motion in recording |
| Nox | 190-239 | 3.17-3.98s | 3.85 | content begins before banner state |
| Nox | 364-428 | 6.07-7.13s | 9.07 | larger, less synchronized change |
| Nox | 469-503 | 7.82-8.38s | 5.13 | shell/content restore |
| Nox | 529-548 | 8.82-9.13s | 11.12 | visible spike from staged content/shell timing |
| Nox | 564-585 | 9.40-9.75s | 1.04 | trailing restore |

The actionable difference is not just "lower energy." Alcove's motion is
organized: the shell starts first and content follows inside it. Nox had a
visual pre-roll because `trackChangedFiring` was doing double duty as both an
internal suppression flag and a visual banner flag.

## Code Fix Applied

`PanelRootView` now separates those meanings:

- `trackChangedFiring`: early internal suppressor for ordinary pill swaps.
- `trackBannerVisualActive`: true only when `trackChangedFiring` and the actual
  `.trackChanged` system event are both present.

The title apron and artwork enlargement now wait for `trackBannerVisualActive`.
That keeps the title/artwork inside the banner shell instead of letting them
grow inside the compact pill.

The title/artist row also uses a small explicit down/up blur replacement helper
instead of relying on `contentTransition(.opacity)`, which was too weak for this
NSHostingView path.

## Remaining Parity Targets

- If rapid skip still shows a close/reopen flash, move the timer ownership from
  `AppDelegate` into a generation-guarded media banner controller.
- If artwork still feels late, decode/cache artwork off the SwiftUI body path
  and attach only ready images to the active track token.
- If the flip feels slow, compare `pillArtwork`'s 0.42s flip against Alcove's
  shorter micro-motion window and tune toward 0.28-0.32s.
