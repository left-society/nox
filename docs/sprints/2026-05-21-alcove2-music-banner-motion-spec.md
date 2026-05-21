# Alcove 2 Music Banner Motion Spec

Date: 2026-05-21
Source frames: `/Users/apple/Downloads/alcove/Alcove 2`
Frame count: 1,151 JPG frames, `PGS _ Cinematic (Slog3)_ 01.cube0000.jpg` through `...1150.jpg`
Frame size: 3276 x 1080 px
Assumed capture rate: 60 fps
Per-frame metrics: `docs/sprints/2026-05-21-alcove2-motion-metrics.csv`

This is the Alcove **menubar music-change banner**, not the large hover slab. Do not mix these numbers with the `Area*.jpg` slab-hover measurements in `2026-05-21-alcove-frame-analysis.md`.

## What Actually Happens

When music changes, Alcove does not open a full slab. It keeps a compact black menubar capsule anchored to the notch, then briefly extends it into a short notification banner:

1. A compact media capsule sits inside the menubar with album art on the left and a tiny animated audio/waveform glyph on the right.
2. On a track change, the capsule grows a little wider and drops a rounded black label body downward.
3. The new album art swaps into the left slot.
4. The title line appears below with a small music-note glyph: `Title · Artist`.
5. The label dwells for about two seconds.
6. The title fades/blurs away first, then the body retracts back into the compact media capsule.

The important part: the shell is calm. Width changes are small. The perceived premium feel comes from the anchored black shape, continuous corners, short dwell, and text/art choreography.

## Coordinate System

The capture is 3276 px wide. Measurements below are in captured pixels, with ratios against the captured width so they can be scaled to the active MacBook screen.

The current machine's built-in panel is 3456 x 2234 Retina, usually 1728 pt wide at 2x. For implementation, prefer:

```swift
let screenWidth = NSScreen.main?.frame.width ?? 1728
let mediaCompactWidth = screenWidth * 0.15476
let mediaBannerWidth = screenWidth * 0.16728
```

For vertical sizes, use points rather than screen-height percentages because macOS menubar/notch geometry is fixed-height:

- Capsule height: `60 px`, about `30 pt`.
- Expanded banner total visual height: `148 px`, about `74 pt`.
- Collapsed album art: `39-40 px`, about `20 pt`.
- Expanded/banner album art visual box: about `49-53 px`, or `24.5-26.5 pt` including softened edges.

## Component Ratios

| State | Captured frame range | X | Width | Width ratio | On 1728 pt screen | Height |
|---|---:|---:|---:|---:|---:|---:|
| Idle notch / no media | 0000-0379 | 1457 px | 357 px | 0.10897 | 188 pt | 30 pt |
| Compact media capsule | 0388-0513, 0645-0757, 0893-0943, 1079-1150 | 1382 px | 507 px | 0.15476 | 267 pt | 30 pt |
| Music-change banner | 0520-0635, 0771-0883, 0957-1070 | 1362 px | 548 px | 0.16728 | 289 pt | 74 pt total |

Horizontal anchoring:

| State | Left ratio | Center ratio | Right ratio |
|---|---:|---:|---:|
| Idle notch | 0.44475 | 0.49924 | 0.55372 |
| Compact media | 0.42186 | 0.49924 | 0.57662 |
| Music banner | 0.41575 | 0.49939 | 0.58303 |

The center stays essentially locked to screen center. The shape grows out from the notch center; it should not drift left or right.

## Timeline From Alcove 2 Frames

At 60 fps, one frame is 16.67 ms.

| Frames | Approx time | State | Notes |
|---|---:|---|---|
| 0000-0379 | 0.00-6.32s | Idle notch | Width holds around 355-359 px. No music banner. |
| 0380-0387 | 6.33-6.45s | Media capsule appears | Short transition into compact media state. |
| 0388-0513 | 6.47-8.55s | Compact media | Width holds around 503-509 px. Album art + right waveform only. No title label. |
| 0514-0519 | 8.57-8.65s | Banner opening | Width grows past 520 px; lower body begins appearing. Title is not readable yet. |
| 0520-0635 | 8.67-10.58s | Title visible | `The Fate of Ophelia · Taylor Swift`. Dwell is about 116 frames, 1.93s. |
| 0636-0644 | 10.60-10.73s | Banner closing | Text disappears before the body fully retracts. |
| 0645-0757 | 10.75-12.62s | Compact media | Taylor artwork remains in the small capsule. |
| 0758-0770 | 12.63-12.83s | Second banner opening | Dark body appears before text becomes readable. |
| 0771-0883 | 12.85-14.72s | Title visible | `Babydoll · Dominic Fike`. Dwell is about 113 frames, 1.88s. |
| 0884-0892 | 14.73-14.87s | Banner closing | Returns to compact media capsule. |
| 0893-0943 | 14.88-15.72s | Compact media | Babydoll art remains. |
| 0944-0956 | 15.73-15.93s | Third banner opening | Body opens; text is delayed about 13 frames. |
| 0957-1070 | 15.95-17.83s | Title visible | `Love Potions Slowed and Reverbed · ...` visible/truncated by available width. |
| 1071-1078 | 17.85-17.97s | Banner closing | Text fades/blur-retracts, then shell returns. |
| 1079-1150 | 17.98-19.17s | Compact media | Final artwork remains in compact state. |

## Motion Rules To Copy

Use a three-state model:

```swift
enum NotchMusicPresentation {
    case idleNotch
    case compactMedia(trackID: String)
    case mediaChangeBanner(trackID: String)
}
```

Transitions:

- `idleNotch -> compactMedia`: short width reveal into the media capsule. Do not open the full slab.
- `compactMedia -> mediaChangeBanner`: grow from 507 px to about 548 px and drop the label to 148 px total height.
- `mediaChangeBanner -> compactMedia`: remove title first, then retract shell. It should feel more monotonic than bouncy.
- `mediaChangeBanner(track A) -> mediaChangeBanner(track B)`: if a new track arrives while the banner is still visible, swap the content in place and reset dwell. Do not fully close and reopen.

Suggested durations based on the frame ranges:

| Motion | Frames | Duration |
|---|---:|---:|
| Compact media appears | 8-10 frames | 130-170 ms |
| Banner shell opens before readable text | 6-13 frames | 100-217 ms |
| Title dwell | 113-116 frames | 1.88-1.93s |
| Text/body close | 8-10 frames | 130-170 ms |

## Content Choreography

Album art:

- Compact state: approximately 20 pt square.
- Banner state: approximately 25 pt square including edge softness.
- Anchor to the leading side of the capsule, not to the label text.
- Swap art as part of the track-change event before or during the label text reveal.
- Use aspect fill and continuous clipping; do not stretch.

Title:

- Appears only in the banner state, never in compact media state.
- Begins roughly below the center line of the capsule, not aligned to the top.
- Text should be a single line, truncated if necessary.
- Use `music.note` or equivalent symbol as a small leading glyph.
- The text becomes readable after the shell/body has already started moving. Do not show text on frame 1 of the shell expansion.

Waveform / audio glyph:

- Stays in the trailing wing in compact and banner states.
- It does not move much; the shell grows around it.
- Color subtly follows the artwork tint. The glyph should never dominate the title.

Shell:

- Black fill, continuous corners.
- No big shadow.
- Depth comes from shape, subtle inner edge, and blur/opacity layering.
- Keep the capsule vertically locked to the menubar/notch. The banner extends downward; the top edge does not jump.

## What Not To Do

- Do not open the full notes/images/videos slab for a song change.
- Do not make the banner width larger than about 16.7% of the screen width.
- Do not animate every child with its own unrelated spring. The shell should lead, content should follow.
- Do not resize the surrounding app content or push layout below the menubar.
- Do not leave the title visible while the shell is already collapsed.
- Do not decode artwork synchronously on the first animation frame; prepare the image first, then trigger the banner.

## How The Per-Frame CSV Was Produced

The CSV stores one row per frame:

- `capsule_x`, `capsule_y`, `capsule_w`, `capsule_h`: black top capsule component in the upper 60 px.
- `title_bright`: count of readable bright title pixels in the banner text area.
- `under_dark`: count of dark pixels in the lower banner body area.
- `art_color`: count of textured/colorful pixels around the leading artwork slot.

Threshold interpretation:

- `capsule_w < 420`: idle notch.
- `480 <= capsule_w <= 520`: compact media capsule.
- `capsule_w > 520` plus `under_dark > 16000`: banner body is open.
- `title_bright > 700`: title text is visibly readable.

The first ~68 rows have false-positive `title_bright` from background text in the recording; ignore title thresholds before the music UI is active.

## Implementation Checklist For Claude

- Build one central music presentation state machine.
- Center all music states on the notch center.
- Use width ratios from this doc for horizontal sizing.
- Use fixed point heights for the menubar and dropdown.
- Make text reveal delayed relative to shell reveal.
- Auto-close after roughly 1.9s of readable title dwell.
- If another track arrives mid-banner, swap in place and reset dwell.
- Keep the full slab and the music banner as separate presentations.
