# Alcove Media Reaction Decode

Date: 2026-05-21
Scope: media pickup, music-change reactions, first/last media states, and why Alcove feels faster.

## Evidence

This is based on local decode evidence, not Alcove source code:

- `/Applications/Alcove.app/Contents/MacOS/Alcove` binary strings
- `/Applications/Alcove.app/Contents/Resources`
- `docs/sprints/2026-05-21-alcove2-music-banner-motion-spec.md`
- `docs/sprints/2026-05-21-alcove-banner-morph-decode.md`
- `docs/sprints/2026-05-21-alcove-app-motion-decode-codex.md`

Fresh binary strings confirm these media-specific symbols/fields:

```text
MediaManager
MusicController
MediaKeyManager
PrivateMediaRemote
MusicTrackSnapshot
SpotifyTrackSnapshot
RenderedMusicArtwork
_songChangeToken
_whenSongChanges
_shouldSuppressNextExternalAnimation
_peekDuration
transientMediaDurationThreshold
notificationSwapDebounce
notificationCloseDebounce
notificationCloseGeneration
notificationRestoreDebounce
notificationClosingUntil
notificationClosingType
com.apple.Music.playerInfo
com.spotify.client.PlaybackStateChanged
```

Alcove also ships tiny local videos for device animations. Example:

```text
airpods-pro.mp4: H.264, 96x96, 60fps, 6.0s, 31,977 bytes
```

That matters because it is not decoding large arbitrary media during the notch animation. It plays prepackaged, tiny, loopable assets.

## Alcove's Media State Model

Alcove appears to use at least these media states:

```swift
enum NotchMusicPresentation {
    case idleNotch
    case compactMedia(trackID: String)
    case mediaChangeBanner(trackID: String)
}
```

The full slab is separate. A song change does not open the big notes/images/videos/live panel. It stays in the notch media presentation.

## Reaction Matrix

| Event | Alcove reaction | Timing/behavior | Why it feels fast |
| --- | --- | --- | --- |
| App launches with no media | Stay in `idleNotch` | No music UI, no banner | No work until there is a real media source |
| First media appears | `idleNotch -> compactMedia` | 8-10 frames, about 130-170ms | Small width reveal only, no title body yet |
| First readable track title | `compactMedia -> mediaChangeBanner` | Shell/body starts first, title readable after about 100-217ms | Text does not appear on frame 1; shell leads |
| Normal track change while compact | `compactMedia(A) -> mediaChangeBanner(B)` | Banner title dwell about 1.88-1.93s | Small transient banner, not full slab |
| New track while banner is already open | `mediaChangeBanner(A) -> mediaChangeBanner(B)` | Swap in place, reset dwell | No close/reopen cycle |
| Banner timeout | `mediaChangeBanner -> compactMedia` | Text disappears first, body retracts in 8-10 frames | Close is monotonic and calm |
| Same track metadata refresh | Update existing track snapshot | No banner unless track identity changes | Prevents re-bloom on elapsed-time/artwork updates |
| Artwork arrives late | Update rendered artwork for current identity | Should not restart shell | Uses identity/generation concepts so stale art does not win |
| Pause during same track | Compact media remains, playback state changes | No big re-layout | Avoids treating pause as a new media event |
| Stop/no media | Eventually return to idle or prior live activity | Governed by duration/restore debounces | Avoids flashing on transient nil emissions |
| Very short media/system sound | Ignore or treat as transient | `transientMediaDurationThreshold` | Prevents UI sounds/short clips from opening the banner |
| User presses media keys | MediaKeyManager/MediaControlStrip reacts | Controls update without rebuilding full UI | Command path is separate from display path |
| User opens/expands notch | Full expanded view is a separate presentation | Not driven by song change | Prevents every track change from paying slab cost |

## Timeline From The Frame Decode

At 60fps:

| Frames | Time | State |
| --- | ---: | --- |
| 0000-0379 | 0.00-6.32s | Idle notch |
| 0380-0387 | 6.33-6.45s | Compact media appears |
| 0388-0513 | 6.47-8.55s | Compact media, art + waveform only |
| 0514-0519 | 8.57-8.65s | First banner body opens, title not readable yet |
| 0520-0635 | 8.67-10.58s | Title visible, dwell about 1.93s |
| 0636-0644 | 10.60-10.73s | Banner closes |
| 0645-0757 | 10.75-12.62s | Back to compact media |
| 0758-0770 | 12.63-12.83s | Second banner opens |
| 0771-0883 | 12.85-14.72s | Second title visible, dwell about 1.88s |
| 0884-0892 | 14.73-14.87s | Banner closes |
| 0944-0956 | 15.73-15.93s | Third banner opens |
| 0957-1070 | 15.95-17.83s | Third title visible |
| 1071-1078 | 17.85-17.97s | Banner closes |

The pattern repeats cleanly. Each track gets a compact reaction. None of these transitions require the full slab.

## How Alcove Picks Up Music Faster

### 1. Event-Driven Media Sources

Alcove links `/System/Library/PrivateFrameworks/MediaRemote.framework` and has `PrivateMediaRemote` symbols. It also has app-specific notifications:

```text
com.apple.Music.playerInfo
com.spotify.client.PlaybackStateChanged
```

That means it can react to the system/app media event stream instead of waiting for browser scans or polling loops.

Nox currently has:

- `MediaRemoteService.refresh()` from MediaRemote callbacks
- `MediaRemoteAdapterService` streaming JSON through a Perl helper with `--debounce=50`
- `BrowserMediaProbe` fallback polling every interval, only when MediaRemote is silent
- AppleScript/browser probing for fallback cases

The adapter is good, but Nox still has fallback paths that are slower by design. `BrowserMediaProbe` intentionally waits until MediaRemote is silent for 5s before it becomes authoritative. That is safe, but not Alcove-fast.

### 2. Track Identity Is Tokenized

Alcove has `_songChangeToken`. The progress slider has `songChangeToken` plus `_shouldSuppressNextExternalAnimation`.

Meaning:

- A real song change increments a token.
- The UI can tell "new track" apart from "same track progress/artwork refresh."
- The progress bar suppresses its own normal animation on the first song-change frame.
- The banner/morph owns the motion for that frame.

This avoids the common jank where the artwork/title/progress bar all animate independently when the track flips.

### 3. Banner Close Is Generation Guarded

Alcove has:

```text
notificationCloseGeneration
notificationClosingUntil
notificationCloseDebounce
notificationSwapDebounce
notificationRestoreDebounce
```

Meaning:

- A pending close has a generation token.
- If another track arrives before close completes, the old close is canceled.
- The banner swaps content in place.
- After the banner finishes, Alcove restores the previous live/idle activity through a restore debounce.

This is the big reason rapid skips feel stable. There is no stack of stale timers closing the wrong banner.

### 4. Artwork Is A Rendered Layer, Not SwiftUI Data Decode In Body

The decode found:

```text
RenderedMusicArtwork
artworkContainerLayer
artworkLayer
artworkMaskLayer
kCAGravityResizeAspectFill
```

That suggests album art is prepared as CALayer-backed artwork with aspect-fill and mask layers. Nox still has `NSImage(data:)` reachable from SwiftUI body paths and cache misses. That is the opposite of Alcove's fast path.

For Nox, the rule should be:

- Media event arrives.
- Compute track identity.
- Start async artwork decode/fetch.
- If art is ready, attach decoded image/layer to the banner.
- If art is not ready, show old art or placeholder, but do not block the shell animation.
- When art arrives for the same token, update the layer without restarting the shell.

### 5. Videos Are Prepackaged Or System Media, Not Heavy Runtime Decodes

Alcove's visible local videos are tiny AirPods clips:

- `96x96`
- H.264
- 60fps
- 6 seconds
- about 32KB for the sampled AirPods Pro file

The binary also has:

```text
LoopingVideo
LoopingVideoPlayback
VideoPlayerLayerView
AVQueuePlayer
AVPlayerLooper
AVPlayerLayer
```

So their "video" animation path is likely layer-backed AVPlayer looping over tiny local assets. It is not reading/thumbnailing/downloading user videos during the notch animation.

For browser video now-playing, Alcove likely gets the title/source from MediaRemote if the browser exposes a media session. It is not doing Nox-style video-download URL extraction. That is a different product feature.

## Nox Comparison

### What Nox Already Does Well

- Starts `MediaRemoteAdapterService` before browser/audio fallbacks.
- Uses `--debounce=50`, which is reasonably quick.
- Uses `--no-diff`, so every adapter event is a full snapshot.
- Dedupes `NowPlayingInfo`.
- Has a 200ms pause debounce to avoid Spotify's between-track pause flicker.
- Has generation guards for pill artwork swap.
- Has a `pendingVideoCandidate` path separate from music playback.

### Where Nox Is Still Slower Or Less Stable

1. **Browser fallback is intentionally delayed.**
   `BrowserMediaProbe` only wins after MediaRemote is silent for about 5s. This avoids clobbering good MediaRemote data, but it means browser sources that fail MediaRemote feel slow.

2. **Artwork decode can still block.**
   `ArtworkCache.image(data:key:)` can synchronously decode on miss. Track banner body also still has `NSImage(data:)` paths.

3. **Track change and full slab are still too coupled.**
   Nox has a track-change banner, but the same presenter has full slab flags, active tab routing, cascade timers, drop picker, and hover state. Alcove keeps media-change as a transient presentation over the compact pill.

4. **Progress and artwork/title can animate independently.**
   Alcove has `_shouldSuppressNextExternalAnimation` for the first changed frame. Nox should add a similar `songChangeToken` and use it to freeze/snap progress for exactly one external update.

5. **Video pickup is a separate feature in Nox.**
   Nox extracts browser URLs/drag URLs for downloading. Alcove's "fast video" path appears to be only now-playing/system media plus tiny bundled animations. Do not compare those as the same workload.

## Recommended Nox Model

Create one normalized media event:

```swift
struct MediaSnapshot: Equatable {
    let identity: String
    let title: String
    let artist: String
    let album: String?
    let sourceBundleID: String?
    let mediaType: MediaType
    let isPlaying: Bool
    let duration: TimeInterval?
    let elapsed: TimeInterval?
    let timestamp: Date
    let artworkToken: String?
}

enum MediaReaction {
    case ignoreTransient
    case firstMedia(snapshot: MediaSnapshot)
    case sameTrackRefresh(snapshot: MediaSnapshot)
    case playbackStateOnly(snapshot: MediaSnapshot)
    case trackChanged(from: MediaSnapshot?, to: MediaSnapshot)
    case mediaEnded(previous: MediaSnapshot?)
}
```

Then map reactions to presentation:

| Reaction | Presentation |
| --- | --- |
| `ignoreTransient` | Do nothing |
| `firstMedia` | Show compact media; optionally queue banner if "when media changes" is enabled |
| `sameTrackRefresh` | Update layer/text/progress silently |
| `playbackStateOnly` | Update play/pause/waveform state only |
| `trackChanged` | Raise or swap `mediaChangeBanner`, reset dwell |
| `mediaEnded` | Restore prior live activity or idle notch after debounce |

Add a monotonic token:

```swift
@Published var songChangeToken: UInt64 = 0
@Published var suppressNextProgressAnimationForToken: UInt64?
```

On every real track change:

1. Increment `songChangeToken`.
2. Publish metadata immediately.
3. Suppress progress animation for that token's first progress update.
4. Start async artwork decode/fetch.
5. Present compact/banner shell without waiting on artwork.
6. Attach decoded artwork only if the token still matches.
7. Reset the banner dwell timer.

## What To Copy Exactly

- Do not open the full slab for a song change.
- Keep compact media and media-change banner as separate from the expanded app panel.
- Use event-driven MediaRemote/app notifications as the primary path.
- Use browser polling only as fallback, and surface its slower behavior as fallback.
- Classify events before touching UI: first media, same-track refresh, playback-only, real track change, ended, transient.
- Give each real track change a token.
- Use generation-guarded close/swap timers.
- Suppress progress animation on the first song-change update.
- Never synchronously decode artwork in SwiftUI body.
- Use layer-backed/predecoded artwork for the compact pill and banner.
- Treat tiny local videos as preloaded AVPlayerLayer assets; do not run heavy video extraction during notch presentation.

## Short Answer

Alcove is faster because it does less on the critical frame. It listens to system/app media events, classifies the event with a song-change token, animates only a compact notch presentation, and lets artwork/progress update through token-guarded layers. Nox can match that by moving from "nowPlaying changed, views react" to "media snapshot classified, coordinator chooses one tiny reaction."
