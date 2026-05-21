# Alcove vs Nox Smoothness Report

Date: 2026-05-21
Repo: `/Users/apple/Note taker app`

## Scope

This report compares Alcove's visible motion architecture against the current Nox implementation. Alcove source is not available as Swift files, so the Alcove side is based on:

- App bundle metadata and linked frameworks from `/Applications/Alcove.app`
- Binary strings/symbol names exposed by the compiled app
- Resource inspection
- Existing frame analysis from `/Users/apple/Downloads/alcove/Alcove 2`
- Existing local decode docs under `docs/sprints/`

The Nox side is based on current source and the latest performance logs in `~/Library/Logs/nox` plus `/tmp/nox-mra.log`.

## Executive Verdict

Alcove feels seamless because it keeps the notch motion as a small, centralized presentation system. The shell, radius, material, and content transitions are separate phases of one state machine. It does not appear to mount or animate a full complex slab while the shell is resizing.

Nox has copied some of the right visual ideas, but the runtime model is still too busy during the critical frames. The current open path can resize the NSPanel, flip SwiftUI state, reveal content, animate blur/opacity/offset cascades, enable materials, decode artwork, run timelines, update shadows, and process hover/logging work in the same short window.

The latest logs prove the issue is still real:

- `/tmp/nox-mra.log` latest open at `14:30:14`: `ticks=15`, `wall=470ms`, `avgDt=30.4ms`, `maxDt=54.6ms`.
- `/tmp/nox-mra.log` later open at `14:31:26`: `ticks=20`, `wall=425ms`, `maxDt=73.3ms`.
- `performance-2026-05-21-203010.log`: `479` missed-60fps spikes, `84` multi-frame drops, `3` visible-jank spikes, and `1` freeze in that session.
- During the first open, `cascade=true` while `morphing=true`, and several spikes land between `44ms` and `54ms`.

So the main problem is not just the spring constants. The main problem is too much work being allowed to compete with the shell animation.

## What Alcove Appears To Do

### Direct Evidence

Alcove bundle metadata:

- Bundle id: `com.henrikruscon.Alcove`
- Version observed: `1.7.2`, build `188`
- `LSUIElement=true`, so it behaves like a menu-bar/accessory app rather than a normal app window.
- Links AppKit, SwiftUI, QuartzCore, CoreImage, Metal, AVFoundation, MediaRemote, and DisplayServices.

Alcove binary strings include architecture names that matter:

- `NotchController`
- `NotchPanel`
- `NotchProgressiveBlurPanel`
- `NotchExpandedView`
- `NotchQuickPeekView`
- `MediaManager`
- `MediaKeyManager`
- `expandedTransitionTask`
- `progressiveBlurTransitionTask`
- `liveActivitySwapDebounce`
- `notificationCloseDebounce`
- `NSGlassEffectView`
- `VariableBlurEngine`
- `windowServerAware`
- `disablesOccludedBackdropBlurs`

The important point is the vocabulary: Alcove is structured around a notch controller and transition tasks, not around several independent views all deciding their own timing.

### Motion Model

Existing frame analysis found these useful constants:

| Motion | Measured behavior | Useful equivalent |
| --- | --- | --- |
| Expanded open | ~417ms, small ~1.8% overshoot | `SpringFrameAnimator(stiffness: 247, damping: 25)` |
| Expanded close | ~333ms, monotonic, no overshoot | `SpringFrameAnimator(stiffness: 322, damping: 45)` |
| Common SwiftUI spring | fast, damped content motion | `response: 0.20, dampingFraction: 1.0` |
| Larger content spring | smooth, no bounce | `response: 0.40, dampingFraction: 1.0` |
| Frequent ease-out | tiny polish transitions | `easeOut(0.10)` to `easeOut(0.18)` |

The Alcove constants CSV also shows many `Spring(duration:bounce)` uses at:

- `0.35, -0.20` for calm retract/close
- `0.35, 0.30` for quick open/detail motion
- `0.40, 0.30` and `0.45, 0.40` for larger transitions

The pattern is consistent: open can have a tiny premium bounce, but closing/receding is overdamped and quiet.

### Music Banner Behavior

From `docs/sprints/2026-05-21-alcove2-music-banner-motion-spec.md`:

- Source frames: `1151` frames, `3276x1080`, assumed 60fps.
- Idle notch ratio: `0.10897` of screen width, about `188pt` on a `1728pt`-wide screen.
- Compact media ratio: `0.15476`, about `267pt`.
- Music banner ratio: `0.16728`, about `289pt`.
- Capsule height: about `30pt`.
- Music banner height: about `74pt`.
- Shell opens before readable text by roughly `100-217ms`.
- Readable title dwell is around `1.88-1.93s`.
- Close is roughly `130-170ms`.

The takeaway: Alcove's music change is a compact shell/billboard state, not the full expanded slab. It is sized by screen/notch ratio and reveals content after the shell is ready.

## What Nox Currently Does

### Current Shell Path

Relevant files:

- `Notetaker/Panel/PanelWindowController.swift`
- `Notetaker/Panel/PanelRootView.swift`
- `Notetaker/Panel/MusicPanelView.swift`
- `Notetaker/Services/ArtworkCache.swift`
- `Notetaker/Services/HoverActivator.swift`
- `Notetaker/Services/PerformanceProbe.swift`

`PanelWindowController` owns the NSPanel frame animation and much of the presentation policy:

- Fixed shell numbers live near `PanelWindowController.swift:106`: `panelWidth=730`, `innerPanelWidth=530`, `innerPanelHeightMusic=360`, `haloPadding=100`.
- `show(mode:)` starts near `PanelWindowController.swift:1613`.
- `hide()` starts near `PanelWindowController.swift:2131`.
- `animateOpen(to:)` starts near `PanelWindowController.swift:3258`.
- `animateClose(to:)` starts near `PanelWindowController.swift:3396`.
- The display-link spring animator starts near `PanelWindowController.swift:4816`.

The current open spring has moved toward Alcove's measured open:

- Open: `stiffness=247`, `damping=25`.

The current close spring is not the Alcove measured close:

- Current Nox close: `stiffness=438`, `damping=36`.
- Alcove measured close: `stiffness=322`, `damping=45`.

This is not the main FPS problem, but it changes the feel. Nox's close is more aggressive and less calm.

### Current SwiftUI Content Path

`PanelRootView` does a lot of the visual work:

- `contentOverlay` starts near `PanelRootView.swift:1181`.
- `AdaptiveGlassBackground` is gated at `PanelRootView.swift:3914` with `presenter.isShown && !presenter.isMorphing`.
- Tab switching uses `.id(presenter.activeTab)` near `PanelRootView.swift:4303`.
- Main renderable content starts near `PanelRootView.swift:4317`.
- Cascade blur/opacity/offset modifiers are around `PanelRootView.swift:4384` to `4418`.
- Track-change artwork face is near `PanelRootView.swift:6536`.
- Track-change equalizer starts near `PanelRootView.swift:6826`.

The glass gate is a good fix. The code comments correctly note that backdrop blur during morph created 40-63ms frames. But the latest logs show content cascade is still becoming active while the window is still morphing.

That is the big divergence from Alcove: Nox is not fully separating shell motion from content reveal.

### Current Music Panel Path

`MusicPanelView` is still expensive during open:

- Live home view starts near `MusicPanelView.swift:289`.
- The now-playing card, progress bar, controls row, and calendar pane each animate blur/opacity/offset around `MusicPanelView.swift:363` to `426`.
- Artwork gradient header includes `NSImage(data:)` near `MusicPanelView.swift:725`.
- Now-playing artwork calls `ArtworkCache.shared.image` near `MusicPanelView.swift:1564`, `1620`, and `1703`.
- Progress bar uses `TimelineView` near `MusicPanelView.swift:1885`.
- Other detail panels include 30Hz `TimelineView` usage later in the file.

Blur cascades look premium when isolated, but they are expensive if they overlap shell resize. A full-panel blur reveal should happen only after the shell is settled, or be replaced with opacity/offset during the morph and a tiny polish blur after settle.

### Current Artwork Path

`ArtworkCache.swift` has both an async decode path and a synchronous fallback:

- Async decode uses `NSImage(data:)` off-main near `ArtworkCache.swift:104`.
- Synchronous image fetch decodes on the caller near `ArtworkCache.swift:157`.

The comments say this may cost `30-50ms` once per track. That is exactly the size of the spikes we see. Any `NSImage(data:)` call in a SwiftUI body or open path is a frame-drop risk.

`TrackChangedPillBody.artworkFace(data:)` also decodes from `Data` inline in the body near `PanelRootView.swift:6536`. That is especially risky during music change animation.

### Current Hover/Input Path

`HoverActivator` adds global monitors and logging around the same presentation system:

- Global mouse/drag monitor starts near `HoverActivator.swift:221`.
- Poll timer is around `HoverActivator.swift:253`.
- Diagnostic `NSLog` calls are around `HoverActivator.swift:338`.

Those logs are useful while debugging, but they should not run in hot pointer/drag paths in a smooth build. On macOS, console logging can create surprisingly visible hitching if it happens during high-frequency input.

## Why Alcove Feels Smoother

### 1. Alcove Has Fewer Simultaneous Truths

Alcove appears to have a central controller with progress values and transition tasks. Nox currently has presentation truth split across:

- `PanelWindowController.isVisible`
- `panel.isVisible`
- `presenter.isShown`
- `presenter.isResting`
- `presenter.isMorphing`
- `presenter.cascadeReady`
- `presenter.isAtNotchHidden`
- `presenter.activeTab`
- drop picker flags
- hover flags
- music banner flags
- AppDelegate pill state

The latest logs even show desync recovery:

`controller.isVisible=false but panel.isVisible=true, forcing frame to hiddenStart`

That kind of recovery is good defensive code, but the need for it shows the state machine is not singular enough yet.

### 2. Alcove Separates Shell, Material, and Content

Alcove symbol names show separate transition tasks:

- expanded transition
- progressive blur transition
- notification close debounce
- live activity swap debounce

Nox has started separating material from shell by gating `AdaptiveGlassBackground` while morphing. But content reveal still overlaps morph. In the latest performance log:

- `PANEL_OPEN_ANIMATE_START` at `14:30:14.311`
- `cascade=true` by `14:30:14.424`
- `morphing=true` through `14:30:14.788`
- spikes: `44.25ms`, `54.57ms`, `49.09ms`, `50.67ms`

So the shell is resizing while the content is already revealing.

### 3. Alcove Uses Compact Purpose-Built States

Alcove's music change is a compact banner. It does not need to open a full 730x492 panel and mount the live tab just to say "track changed."

Nox currently has a lot of UI living close to the same shared slab. Even if visually hidden, SwiftUI and AppKit state changes can still cause layout, compositing, image decode, material preparation, and timeline ticks.

### 4. Alcove Avoids Main-Thread Asset Surprises

Alcove ships small local media assets for some animations, for example AirPods clips in the app resources. Its media surfaces appear designed around known lightweight assets.

Nox is dealing with arbitrary album artwork from MediaRemote/Chrome/Apple Music. That is fine, but the decode must not happen in SwiftUI body or during the first frames of shell open.

### 5. Alcove's Close Motion Is Calm

The measured Alcove close is monotonic. Nox's current close spring is faster and more aggressive. This may feel responsive, but premium macOS motion usually benefits from calm retraction:

- quick open: allowed to feel alive
- close: should feel inevitable, quiet, and overdamped

## Root Causes To Fix In Nox

### P0: Content Cascade Starts Too Early

Problem:

`cascadeReady` is true while the window is still resizing. This stacks blur/opacity/offset animation on top of panel frame animation.

Fix:

Drive presentation phases from one transition pipeline:

1. `preparing`: update data, predecode artwork, compute target frame.
2. `shellMorphing`: animate only the cheap black shell, border, and shadow path.
3. `materialSettling`: enable glass/material after shell is effectively still.
4. `contentRevealing`: reveal tab/header/content with cheap opacity/offset first.
5. `settled`: allow timelines and optional polish effects.

The important rule: `cascadeReady` must not become true on a fixed `30ms` timer. It should flip from animator progress/completion, for example after the frame spring is near rest or after `PANEL_OPEN_ANIMATE_END`.

### P0: Synchronous Artwork Decode In UI Path

Problem:

`NSImage(data:)` still exists in UI-facing paths:

- `ArtworkCache.shared.image(data:key:)`
- `TrackChangedPillBody.artworkFace(data:)`
- `MusicPanelView.artworkGradientHeader`

Fix:

- `ArtworkCache.image(data:key:)` should return cached images only. On miss it should return placeholder and start async decode.
- Presenter state should hold predecoded `NSImage?` or a stable cache key.
- `TrackChangedPillBody` should receive `fromImage` and `toImage`, not `Data`.
- Any blurred artwork gradient should be pre-rendered after settle, not decoded and blurred in the body.

Success condition:

There should be no `NSImage(data:)` reachable from `body` during open, track swap, hover reveal, or drag/drop.

### P0: Open Path Does Too Much Before First Stable Frame

Problem:

`show(mode:)` currently flips visible state, orders the panel, sets presenter flags, schedules cascade, starts monitors, and starts the spring. The latest logs show this is enough to produce 50-73ms spikes.

Fix:

Move policy to one coordinator and make `PanelWindowController` mostly a renderer:

```swift
enum NotchPresentation {
    case hidden
    case resting(PillAnchor)
    case tease
    case expanded(tab: PanelTab)
    case musicBanner(trackID: String)
    case volume(level: Double, muted: Bool)
    case dropPicker(fileCount: Int)
}

enum PresentationPhase {
    case preparing
    case shellMorphing
    case materialSettling
    case contentRevealing
    case settled
    case closing
}
```

The coordinator should own generation tokens and cancellation, so stale timers cannot reveal content after a close, drag, or track swap.

### P1: Too Many Blur Layers During Reveal

Problem:

Blur is used in:

- `PanelRootView.contentOverlay`
- header tabs
- `MusicPanelView.liveHomeView`
- track-change text
- some detail hero views

Gaussian blur is expensive at panel scale. During shell open, use opacity/offset. Add tiny blur only after the panel is stable if the visual needs it.

Fix:

- For first open, replace most `blur(radius: 8...14)` cascade with opacity + y offset.
- Keep one small text/image polish blur if needed, but after shell settles.
- Never blur the full content overlay during frame resize.

### P1: Timelines Need Strict Visibility Gates

Problem:

`TimelineView` is useful but can keep SwiftUI invalidating. Some Nox timelines are correctly gated, but the file still has many 30Hz uses.

Fix:

- Only the currently visible, settled surface should tick.
- Music banner equalizer should pause when hidden and preferably after the first settle.
- Detail-panel 30Hz timelines should not exist in the tree until that detail panel is active and settled.
- The compact waveform is acceptable at 12Hz resting and 30Hz active, but should remain paused when not visible.

### P1: Hot-Path Logging Should Be Gated

Problem:

Verbose `NSLog` and file logging around hover, panel open, pill refresh, and MediaRemote can overlap animation.

Fix:

- Replace hot path logs with `PerformanceProbe.mark` only where needed.
- Put `NSLog` behind a debug flag.
- Avoid repeated pill refresh logs while music state is unchanged.

### P2: Close Spring Should Match The Premium Feel

Problem:

Close currently uses `438/36`, which is snappier than Alcove's measured close and can look more abrupt.

Fix:

For normal expanded-to-pill or expanded-to-notch close, test:

```swift
SpringFrameAnimator(stiffness: 322, damping: 45, mass: 1.0)
```

Keep faster variants only for emergency interrupts or tiny tab-width changes.

### P2: Fixed Slab Size Should Be Rechecked Against Screen Ratios

Problem:

Nox uses fixed slab values such as `730x492` with a `100pt` halo. Alcove's compact states are ratio-based, and the music banner is much smaller than the full slab.

Fix:

- Keep expanded slab fixed only if it genuinely needs that size.
- Make compact notch states ratio-based:
  - idle notch width around `10.9%` of screen width
  - compact media width around `15.5%`
  - music banner width around `16.7%`
- Avoid resizing a huge transparent frame if only the shadow halo needs space.

## Recommended Fix Order For Claude

### Step 1: Freeze The Shell During Morph

Goal:

During `shellMorphing`, render only:

- black rounded shell
- border
- shadow
- optional pill silhouette

Do not render:

- full tab content
- live music card
- calendar
- heavy blur cascade
- glass/material
- 30Hz timelines

Implementation:

- Replace timer-driven `cascadeReady` with transition-phase-driven reveal.
- Ensure `cascadeReady == false` until `PANEL_OPEN_ANIMATE_END` or until spring progress is effectively complete.
- Keep `AdaptiveGlassBackground` gated until after morph, as it already is.

Expected result:

Open morph should stop showing 44-73ms spikes.

### Step 2: Remove Sync Artwork Decode From Body

Goal:

No synchronous `NSImage(data:)` during any animation.

Implementation:

- Make `ArtworkCache.image(data:key:)` cache-only on main.
- Add async decode request API that updates presenter state after completion.
- Pass decoded image state into `TrackChangedPillBody`.
- Delete/disable `MusicPanelView.artworkGradientHeader` from the open path unless it uses pre-rendered assets.

Expected result:

Track changes and first open with fresh artwork should stop producing 30-50ms surprises.

### Step 3: Make Music Banner A Separate Presentation

Goal:

A track change should use a compact banner, not the expanded slab pipeline.

Implementation:

- Add `NotchPresentation.musicBanner(trackID:)`.
- Use width/height ratios from the Alcove decode.
- Shell opens first, text/art follow after ~100-160ms.
- Dwell readable title for ~1.9s.
- Close shell in ~130-170ms.
- If another track arrives, swap content inside the existing banner and reset dwell.

Expected result:

Track changes feel like Alcove: small, fast, and independent of the full app panel.

### Step 4: Gate Timelines And Logs

Goal:

The settled panel should not keep missing 60fps while doing nothing.

Implementation:

- Gate `TrackChangedEqualizer`, focus detail timers, study timers, and dashboard timers by `presentationPhase == .settled` and active tab/detail.
- Remove hot path `NSLog` calls or compile them behind debug.
- Keep `PerformanceProbe` because it is useful, but do not let every subsystem also file-log during animation.

Expected result:

Steady-state open summaries should stop accumulating frequent `20-39ms` spikes.

### Step 5: Retune Close Motion

Goal:

Close should feel quiet and macOS-native.

Implementation:

- Test `322/45` close spring for normal expanded close.
- Keep current faster close only if user testing strongly prefers it.
- Do not retune open again until the work-overlap issues are fixed.

Expected result:

Close becomes less abrupt and more Alcove-like without hiding performance issues.

## Acceptance Criteria

Use the existing `PerformanceProbe` logs and `/tmp/nox-mra.log`.

Open from resting to expanded:

- `MORPH SUMMARY maxDt <= 25ms` target
- `maxDt > 33ms` should be zero in normal runs
- no `visible-jank` severity during open

Close from expanded to resting:

- no `visible-jank`
- no more than one `20-25ms` spike
- ideally `maxDt <= 25ms`

Steady open for 60 seconds:

- `over33_total == 0`
- no `visible-jank`
- no repeated 30Hz timeline invalidation unless visible and intentional

Track change banner:

- no synchronous image decode
- no full slab open
- no `maxDt > 33ms`
- readable title dwell close to `1.9s`

Drag/drop close behavior:

- after drop/drag exit, hover dismissal should not require a click outside
- drop state should be cleared by the same presentation coordinator that owns hover close
- no stale `dropPickerActive` or hit-test region should keep the slab open

## Files Claude Should Start With

1. `Notetaker/Panel/PanelWindowController.swift`
   - centralize presentation phases
   - delay cascade until spring completion
   - review close spring

2. `Notetaker/Panel/PanelRootView.swift`
   - make content rendering phase-aware
   - remove full-content blur during shell morph
   - remove inline artwork decode from track-change body

3. `Notetaker/Panel/MusicPanelView.swift`
   - reduce live-home cascade blur
   - ensure detail/timeline views are mounted only when active and settled
   - remove body-time artwork decode

4. `Notetaker/Services/ArtworkCache.swift`
   - make main-thread calls cache-only
   - async decode on miss

5. `Notetaker/Services/HoverActivator.swift`
   - remove/gate hot-path logging
   - route drag/drop close through the central presentation coordinator

6. `Notetaker/Services/PerformanceProbe.swift`
   - keep this; add marks around artwork decode, material mount, content reveal, and timeline activation

## One Sentence Summary

Alcove is smooth because it animates a cheap notch shell first and treats everything else as delayed, cancellable, phase-driven content; Nox will become smooth when it stops letting full SwiftUI content, artwork decode, blur, timelines, logging, and window resize all fight for the same 16.67ms frame budget.
