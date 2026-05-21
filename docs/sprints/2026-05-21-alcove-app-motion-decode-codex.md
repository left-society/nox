# Alcove App Motion Decode

Date: 2026-05-21
Target: `/Applications/Alcove.app`
Version: Alcove 1.7.2, build 188
Binary: `/Applications/Alcove.app/Contents/MacOS/Alcove`
Related frame sources:

- `/Users/apple/Downloads/alcove/Area*.jpg`
- `/Users/apple/Downloads/alcove/Alcove 2`
- `/Users/apple/Downloads/alcove/Alcove 3`

This is the Codex pass, written fresh from the local app bundle and frame exports. Treat it as the canonical implementation reference for nox. The goal is not to copy Alcove visually one-to-one; it is to understand the architecture and motion grammar so fixes stop becoming random slabs, random bounce, or random glass.

## Executive Summary

Alcove is not a big floating panel that happens to sit near the notch. It is a notch shell controlled by one central state object. The shell changes shape through a small set of presentation states: idle, live activity, notification/banner, quick peek, expanded view, HUD overlays, and lock-screen style presentations.

The premium feel comes from five choices:

1. The shell is always centered on the physical notch/screen center.
2. The shell shape is driven by continuous progress values, not independent manually placed panels.
3. Size, corner radius, and progressive blur are separate transition tasks.
4. Content transitions are smaller and faster than the shell transition.
5. Close/recede motion is overdamped and monotonic. Open/arrival motion may bounce, but only subtly.

For nox: do not solve this by adding more panels. Build a single notch presentation state machine, then let the music banner, live tabs, HUDs, quick peek, and expanded slab be presentations inside that shell.

## App Bundle Inventory

Confirmed from `Info.plist`, `codesign`, `otool -L`, and resources:

- Bundle ID: `com.henrikruscon.Alcove`
- Version: `1.7.2`, build `188`
- LSUIElement app: runs without Dock icon
- Built with Xcode `26.4`, macOS SDK `26.4`, minimum macOS `14`
- Signed by `Developer ID Application: Henrik Ruscon (287NUTSP69)`
- Main binary is universal `x86_64 + arm64`
- XPC helper: `/Applications/Alcove.app/Contents/XPCServices/AlcoveHelper.xpc`
- Helper bundle ID: `com.apple.controlcenter.AlcoveHelper`

Linked frameworks that matter for motion/features:

- SwiftUI and AppKit: shell UI and AppKit windows/views.
- QuartzCore and CoreImage: layer animation, corner curves, blur filters.
- MediaRemote private framework: now-playing state.
- DisplayServices private framework: brightness HUD/control.
- EventKit, WeatherKit, CoreBluetooth, IOBluetooth, CoreLocation: calendar/weather/audio-device live activities.
- AVFoundation/AVFAudio/AudioToolbox: sounds, AirPods videos, feedback.

Resources:

- 18 AirPods device videos, all 96x96 H.264 at 60 fps and 6 seconds long.
- Sound assets: `haptic.caf` is 10.6 ms; lock/unlock/volume are short feedback clips; `chime.caf`, `sleep.caf`, `alt-jingle.m4a`, `blips.m4a`, and `pad.m4a` are longer ambient/notification sounds.
- `Assets.car` has 257 asset records, including app icons, browser/music app icons, and many tokenized colors.

## Main Architecture

Recovered class/type names and reflection fields show these app-level controllers:

- `NotchController`
- `NotchPanel`
- `NotchProgressiveBlurPanel`
- `NotchView`
- `NotchShape`
- `NotchExpandedView`
- `NotchNotificationsView`
- `NotchQuickPeekView`
- `MediaManager`
- `MediaKeyManager`
- `VolumeManager`
- `BrightnessManager`
- `BatteryManager`
- `CalendarManager`
- `WeatherManager`
- `FocusManager`
- `ConnectivityManager`
- `LockManager`
- `SoundManager`
- `ScreenManager`
- `SpaceManager`
- `MissionControlManager`
- `SettingsController`

The important part is that `NotchController` owns the shell state. Reflection strings confirm these fields:

```text
expandedTransitionTask
expandedRadiusTransitionTask
progressiveBlurTransitionTask
notificationSwapDebounce
notificationCloseDebounce
notificationCloseGeneration
notificationRestoreDebounce
notificationClosingType
notificationClosingUntil
liveActivitySwapDebounce
quickPeekDebounce
quickPeekGeneration
_isExpanded
_expandedProgress
_isExpanding
_isCollapsing
_isWidening
_isAdjusting
_notchWidth
_notchHeight
_notchExpandedWidth
_notchExpandedHeight
_shellScale
_shellWidthProgress
_shellScaleAnchor
_hasNotification
_hasProgressiveBlur
_hasLiveActivity
_hasOutput
_notification
_notificationIntent
_notificationContext
_liveActivity
_liveActivityIntent
_quickPeek
```

This tells us the intended model:

- Two geometry endpoints: compact notch and expanded notch.
- One progress path: `_expandedProgress` plus `_shellScale`, `_shellWidthProgress`, and `_shellScaleAnchor`.
- Independent async tasks for geometry, radius, and blur.
- Notification/banner state guarded by generation/debounce fields.

Do not implement separate geometry systems for music, hover, tabs, HUDs, and drag. That is how nox gets stuck, over-expanded, and hard to reason about.

## Notch Shape Inputs

Reflection exposes a shape-driving struct with:

```text
kind
progress
isMuted
hasPhysicalNotch
hasNotification
shape
showsLabel
```

Meaning:

- Shape is not just width and height.
- Notification presence changes the path.
- Physical notch presence changes the path.
- Muted/media state can alter the shape.
- Label visibility is part of the shape model.

For nox: `NotchShape` should take a presentation kind and progress, not just a rectangle.

## Animation API Inventory

Confirmed SwiftUI imports:

- `SwiftUI.Spring(duration:bounce:)`
- `SwiftUI.Animation.spring(_:blendDuration:)`
- `SwiftUI.Animation.spring(response:dampingFraction:blendDuration:)`
- `SwiftUI.Animation.easeOut(duration:)`
- `SwiftUI.Animation.easeInOut(duration:)`
- `SwiftUI.Animation.linear(duration:)`
- `SwiftUI.Animation.delay(_:)`
- `SwiftUI.Animation.repeatForever(autoreverses:)`
- `SwiftUI.withAnimation`
- `SwiftUI.withAnimation(... completionCriteria:)`
- `SwiftUI.PhaseAnimator`
- `SwiftUI.TimelineView`
- `SwiftUI.ScaleTransition`
- `SwiftUI.BlurReplaceTransition.Configuration.downUp`
- `SwiftUI.ContentTransition.numericText`
- `SwiftUI.ContentTransition.symbolEffect`
- `SwiftUI.View.blur(radius:opaque:)`
- `SwiftUI.View.shadow(color:radius:x:y:)`

Not found in import stubs:

- `matchedGeometryEffect`
- `KeyframeAnimator`

This does not prove Alcove never uses equivalent inlined/private layout tricks, but the imported API surface says its motion is mostly spring/state driven, not matchedGeometryEffect driven.

## Animation Constants

Full extracted summary: `docs/sprints/2026-05-21-alcove-animation-constants.csv`.

The extractor decoded direct RIP-relative double literals before SwiftUI animation calls. Some entries show `unknown` where the value came from a stack variable or runtime setting rather than a nearby literal.

### Spring(duration:bounce:)

185 callsites. Most common direct literal pairs:

| Count | Duration | Bounce | Likely role |
|---:|---:|---:|---|
| 40 | 0.35 | -0.20 | Recede/close/settle. Overdamped, no visual rebound. |
| 35 | 0.35 | 0.30 | Primary open/arrival family. |
| 21 | 0.40 | 0.30 | Secondary grow/open family. |
| 11 | 0.45 | 0.40 | Heavier grow/emphasis. |
| 7 | 0.60 | 0.40 | Slow grow/emphasis. |
| 6 | 0.40 | 0.35 | Bouncier grow variant. |
| 6 | 0.60 | 0.35 | Slow bouncy variant. |
| 4 | 0.60 | 0.30 | Slow ease-in/grow. |
| 4 | 0.50 | 0.375 | Medium emphasis. |
| 2 | 0.20 | 0.30 | Fast snappy micro motion. |
| 1 | 0.45 | 0.10 | Subtle slow bounce. |
| 1 | 0.30 | 1.00 | Very bouncy emphasis, probably not shell. |

### Animation.spring(response:dampingFraction:)

282 callsites. The dominant damping fraction is `1.0`, so this is the smooth/no-overshoot family.

| Count | Response | Damping | Likely role |
|---:|---:|---:|---|
| 98 | 0.20 | 1.00 | Fast critically damped micro transition. |
| 46 | 0.40 | 1.00 | Smooth medium transition. |
| 27 | 0.25 | 1.00 | Fast smooth transition. |
| 21 | 0.4875 | 1.00 | Derived preset, likely speed-scaled. |
| 17 | 0.50 | 1.00 | Slower smooth transition. |
| 16 | 0.30 | 1.00 | Standard smooth transition. |
| 11 | 0.45 | 1.00 | Medium smooth transition. |
| 8 | 0.60 | 1.00 | Slow smooth transition. |
| 6 | 0.15 | 1.00 | Very fast smooth micro transition. |

### Other timing

| API | Values |
|---|---|
| `easeOut(duration:)` | 33x `0.10`, 2x `0.15`, 1x `0.60` |
| `easeInOut(duration:)` | 2x `0.20` |
| `linear(duration:)` | `1.0`, `1.5`, plus one runtime value |
| `delay(_:)` | `0.05`, `0.075`, `0.10`, `0.25`, `0.30`, `0.60`, and longer values `1.557`, `2.292`, `2.70`, `3.023`, `3.265`, `4.324` |

Interpretation:

- Shell open/arrival can be bouncy.
- Shell close is usually `0.35, -0.20`.
- Smooth/disable-overshoot settings map to `spring(response:..., dampingFraction:1.0)`.
- Content fades and glyph swaps cluster around `easeOut(0.10)`.
- Long delays are dwell/restore timers, not physical motion curves.

## Reconciling Binary Constants With Frame Measurements

The binary gives families. The frame exports tell us which family a visible transition actually used.

From `docs/sprints/2026-05-21-alcove-frame-analysis.md`:

- Large slab open measured about 25 frames, 417 ms, with only 1.8% overshoot.
- Best visible fit for that capture: approximately `Spring(duration: 0.40, bounce: 0.21)`.
- Large slab close measured about 20 frames, 333 ms, monotonic.
- Best visible fit for close: `Spring(duration: 0.35, bounce: -0.20)`.

From `docs/sprints/2026-05-21-alcove2-music-banner-motion-spec.md`:

- Music-change banner is much smaller than the slab.
- Compact media capsule is about 15.5% of captured screen width.
- Music banner is about 16.7% of captured screen width.
- Text dwell is about 1.9 seconds.
- Opening/closing body is roughly 100-217 ms, with text reveal delayed after shell movement begins.

Conclusion:

- Do not pick the most common spring and apply it everywhere.
- Use frame measurements for visible shell states when available.
- Use binary families for hidden/internal states and content micro-transitions.

## Material, Blur, And Depth

Confirmed strings/symbols:

```text
NSGlassEffectView
NSVisualEffectView
GlassEffectView
ProgressiveBlurView
VariableBlurEngine
Alcove.ProgressiveBlurView
windowServerAware
allowsInPlaceFiltering
allowsGroupBlending
allowsGroupOpacity
allowsEdgeAntialiasing
disablesOccludedBackdropBlurs
inputNormalizeEdges
setMaterial:
setBlendingMode:
setState:
setCornerCurve:
setCornerRadius:
setHasShadow:
kCACornerCurveContinuous
kCAGravityResizeAspectFill
```

SwiftUI `View.blur(radius:opaque:)` appears only once, with radius `10.0`.

SwiftUI `View.shadow(color:radius:x:y:)` appears only once:

- Radius: `1.0`
- x: `0.0`
- y: `1.0`

Alcove’s dark-mode depth is not a big drop shadow. It is:

- Black/dark fill.
- Continuous corners.
- Thin inner border/highlight tokens.
- Progressive backdrop blur.
- Minimal or no shadow in dark mode.

Relevant asset colors:

| Token | Light | Dark |
|---|---|---|
| `ContainerBackground` | black 2.5% alpha | black 7.5% alpha |
| `ContainerInnerBorder` | transparent | near-white 8% alpha |
| `ButtonBackground` | near-white 75% alpha | near-white 5% alpha |
| `ButtonBorder` | black 12% alpha | near-white 8% alpha |
| `ButtonShadow` | black 10% alpha | black 0% alpha |
| `SegmentedButtonBackground` | black 5% alpha | near-white 5% alpha |
| `AlcovePrimaryColor` | black | near-white |
| `AccentColor` | `#2DD4BF` | `#2DD4BF` |

For nox: if the user says "premium dark macOS," do not add a huge glass card or heavy shadow. Use black, continuous corners, restrained borders, and mild material/blur.

## Content Transition Grammar

Alcove imports these APIs for content motion:

- `ScaleTransition.init(_:anchor:)`
- `BlurReplaceTransition.Configuration.downUp`
- `ContentTransition.numericText(countsDown:)`
- `ContentTransition.symbolEffect`
- `PhaseAnimator`
- `TimelineView`
- `AnimationTimelineSchedule`

Use this grammar:

- Shell shape leads.
- Album art/image content can scale/transition with the shell, but should not drive shell size.
- Title/subtitle changes use blur-replace down/up, not a basic hard text swap.
- Numbers use numeric text transitions.
- Symbols use symbol effects.
- Small content fades use `easeOut(0.10)`.
- Per-element anchors matter: center, trailing, bottom, and top are all imported and used with transition APIs.

## Media / Music State

Media-related types and fields:

```text
MediaManager
MediaKeyManager
MediaPlayer
MediaControlStrip
MediaPlayPauseButton
MediaProgressSection
MediaProgressSlider
PrivateMediaRemote
_songChangeToken
_whenSongChanges
_peekDuration
_shouldSuppressNextExternalAnimation
_currentTrack
_trackDuration
_progressUntilEnd
_hideSongTitleExtras
_songTitleBadge
_disableWaveform
_disableAlbumArtFlip
_controlChoice
_automaticMusicApp
_musicApp
_hideWhileSourceIsActive
```

Settings confirm:

- `settings.nowPlaying.whenMediaChanges` = "When media changes"
- `common.peekDuration` = "Peek duration"
- `settings.nowPlaying.disableCompactWaveform`
- `settings.nowPlaying.disableArtworkFlip`
- `settings.nowPlaying.hideMediaTitleExtras`
- `settings.nowPlaying.hideSymbol`
- `settings.nowPlaying.colorStyle.artwork/color/gradient/mono`
- `settings.nowPlaying.mediaSource.automatic`
- `settings.nowPlaying.musicApp.music/spotify/system`

Implementation meaning:

- Track changes are tokenized with `_songChangeToken`.
- The UI has a specific "when media changes" path, not just general hover/open.
- `_shouldSuppressNextExternalAnimation` exists because progress/seek animation must not fight the banner morph on the first changed frame.
- The media banner should reset a dwell timer on new tracks and swap in place if already open.

For nox: create a media-change presentation separate from the full live slab. The full slab is user-initiated/hover/click; the media-change banner is transient.

## Notifications And Live Activities

Alcove uses these visible concepts:

- `Notification`
- `NotificationContext`
- `NotchNotificationsView`
- `LiveActivity`
- `ExpandedActivity`
- `NotchQuickPeekView`
- `_hasNotification`
- `_hasLiveActivity`
- `_hasOutput`
- `dismissedLiveActivityStack`

Settings/labels confirm live activity categories:

- Battery
- Calendar
- Connectivity
- Focus
- Volume
- Brightness
- Now Playing
- Weather
- Lock Screen

Each domain has its own duration or peek-duration setting:

- `_batteryDuration`
- `_brightnessDuration`
- `_volumeDuration`
- `_focusDuration`
- `_connectivityDuration`
- `_calendarPeekDuration`
- `_timeToLeaveDuration`
- `_hideIdleDuration`
- `_idleDuration`
- `_peekDuration`

For nox: each event source should generate a normalized presentation request with:

```swift
enum PresentationKind {
    case idle
    case liveActivity(ActivityKind)
    case transientNotification(NotificationKind)
    case musicChange(trackID: String)
    case quickPeek(ActivityKind)
    case expanded(tab: PanelTab)
    case hud(HUDKind)
}
```

Then the shell decides geometry, not each source.

## Gestures And Hover

Recovered strings/settings:

- `expandNotchOnHover`
- `_expandNotchOnHover`
- `_hoverDuration`
- `_hoverDebounce`
- `_isMouseInside`
- `_isMouseInsideLeftContent`
- `_isMouseInsideRightContent`
- `SwipeGestureView`
- `SwipeDirection`
- `Swipe to skip media`
- `Swipe to toggle open`
- `Swipe to cycle activity`
- `Swipe to dismiss activity`
- `_gestureHorizontalProgress`
- `_gestureVerticalProgress`
- `_hasPassedHorizontalSwipeThreshold`
- `_hasTriggeredVerticalSwipeAction`
- `_cycleSwipeReadyOnRelease`

Interpretation:

- Hover, swipe, and quick-peek are controller states, not one-off window hacks.
- Horizontal and vertical gestures have separate progress fields.
- There are thresholds and reset debounces.

For nox: the hover-close bug should live in this state machine. If a drag/drop opens or interacts with the shell, it must set the same presentation mode and dismissal policy as hover/quick-peek rather than creating a sticky panel mode.

## HUDs

HUD settings:

- `settings.hud.speed.fast`
- `settings.hud.speed.instant`
- `settings.hud.speed.smooth`
- `settings.hud.disableOvershoot`
- `settings.hud.duration`
- `settings.hud.progressStyle.accent/stylized/white`
- `settings.hud.linkSettings`

Managers:

- `VolumeManager`
- `BrightnessManager`
- `MediaKeyManager`

Private/system hooks:

- `_DisplayServicesSetBrightnessSmooth`
- Accessibility permission for replacing system HUDs.
- Media key event tap state.

Interpretation:

- HUD speed is user-configurable and maps to different animation families.
- "Smooth" and "Disable overshoot" should route to damping fraction `1.0`.
- Instant mode should bypass shell spring and content transitions.

## Windowing Model

Types:

- `NotchPanel`
- `NotchProgressiveBlurPanel`
- `LockPanel`
- `ModalWindow`
- `SettingsWindow`
- `NSHostingView`

Fields:

- `windowController`
- `blurWindowController`
- `spaceID`
- `windows`
- `_showOnDisplay`
- `_forceSimulatedNotch`
- `_hideWhileInFullscreen`
- `_hideWhileInMissionControl`
- `_hideFromScreenCapture`

Interpretation:

- Alcove separates main content and progressive blur windowing.
- It knows about Spaces/Mission Control/fullscreen.
- It can force simulated notch and tune notch width/height.

For nox: keep panel geometry and blur/material ownership in one AppKit controller layer, with SwiftUI content inside. Avoid letting individual SwiftUI views reposition NSWindow frames.

## Implementation Rules For nox / Claude

1. One shell state machine. No separate accidental slabs for music, hover, drag, and tabs.
2. Shell center is locked to notch/screen center.
3. Store compact and expanded geometry endpoints; drive transitions with progress.
4. Keep radius and blur on separate clocks/tasks from size.
5. Open can use subtle bounce. Close should use negative bounce/overdamping.
6. Content reveal must lag shell reveal. Do not show title/content on the first shell expansion frame.
7. Music-change banner is not the full live slab.
8. Track changes should suppress progress-bar animation for the first external update.
9. New notification while open should swap/reset dwell in place, not close/reopen.
10. Use `easeOut(0.10)` for micro-fades and text/label reveal.
11. Use `BlurReplaceTransition` style direction for text swaps.
12. Use numeric transitions for timers/progress labels.
13. Dark premium material is black + continuous corners + inner edge + progressive blur, not a big shadow.
14. Avoid synchronous artwork decoding or heavy blur activation on the same frame as shell open.
15. If performance drops, instrument shell frame dt separately from content appearance. The architecture has independent tasks for a reason.

## Open Questions / Limits

This pass is static binary and frame analysis. It does not include live debugger tracing of Alcove internals, because the app is signed/release and Swift metadata names are partial. Some binary constants could not be assigned to exact UI states without runtime tracing. Where we have frame evidence, use the frame evidence.

The most actionable source hierarchy is:

1. Frame measurements for visible motion.
2. Binary API/constants for motion families.
3. Reflection strings for architecture/state.
4. Localization/settings for user-facing feature semantics.
5. Asset tokens for colors/depth.

## Files Produced In This Pass

- `docs/sprints/2026-05-21-alcove-app-motion-decode-codex.md`
- `docs/sprints/2026-05-21-alcove-animation-constants.csv`

Related prior frame-specific docs:

- `docs/sprints/2026-05-21-alcove2-music-banner-motion-spec.md`
- `docs/sprints/2026-05-21-alcove2-motion-metrics.csv`
- `docs/sprints/2026-05-21-alcove-frame-analysis.md`
