# nox 1.9.21 — Alcove-Parity Sprint Plan

> **You're reading this because the user ran 4-5 parallel Claude Code sessions, each with one slice of this sprint. You will be told "you are session N" — find your section below and execute it.**

---

## ⚡ Context Budget Note (READ FIRST)

**Each session has a 1M-token context window and Max-plan usage budget.** Don't conserve tokens — be **thorough**. Specifically:

- **Read 5-10 reference files before writing a single line.** The Required Reading list per session below names them. Absorb the existing codebase deeply.
- **Read the FULL `SettingsWindow.swift`** (~2100 lines) — don't grep, read it all. You need to understand the existing patterns for SettingsKey, @AppStorage, SettingsRow, SettingsCard, GroupTitle, the SectionHeader, and the iconTint conventions.
- **Read the FULL `PanelRootView.swift`** (~5500 lines) if your wiring touches it. You need to know the existing structure to specify precise hookup locations.
- **Write comprehensive tests** — not just the smoke cases, every meaningful branch. The policy-struct pattern below makes that cheap.
- **Document trade-offs in the code itself.** When you make a non-obvious choice, leave a 3-5 line comment explaining what you considered and why this won.

Conserving tokens here means worse code. Spend the budget.

---

## 0. Sprint Context (read this first, regardless of which session you are)

### Product
**nox** is a native macOS notch HUD app (bundle id `app.trynox`, Xcode scheme still named "Notetaker" for legacy reasons). Sole developer: Aritra Debnath. Currently on version **1.9.21 (build 30)** with these changes already committed in `250faf2`:

- Settings → Appearance customization (tab indicator style, accent color, shadow intensity)
- HoverActivator fix for phone Continuity icon causing spontaneous slab opens
- ⌘⇧D backup hotkey removed (After Effects conflict)
- Marker stroke geometry restored to original cleaner version

This sprint adds **4 more features** before shipping 1.9.21. Each feature is a single session's responsibility.

### Repo paths (always use these absolute paths)
- **Repo root:** `/Users/apple/Note taker app`
- **Pill code:** `/Users/apple/Note taker app/Notetaker/NotchPill/`
- **Services:** `/Users/apple/Note taker app/Notetaker/Services/`
- **Settings:** `/Users/apple/Note taker app/Notetaker/Settings/SettingsWindow.swift`
- **Main panel:** `/Users/apple/Note taker app/Notetaker/Panel/PanelRootView.swift`
- **Design tokens:** `/Users/apple/Note taker app/Notetaker/DesignSystem/DesignTokens.swift`

### Source for these features
We forensically decoded Alcove.app (the competitor) and identified high-leverage features nox is missing. Each session below implements **one** of those features in nox-native style — **not** a copy of Alcove's code. Match the *behavior* and *polish*, not the implementation.

---

## 1. Hard Rules (every session must follow)

### 🚫 NEVER
- **Never add `Co-Authored-By: Claude` or any "Generated with Claude Code" footer to commits.** The user is the sole author. Apple as committer (his macOS username) is fine.
- **Never run `release.sh --publish` or any deploy command.** That's the user's call after he reviews.
- **Never edit shared files** (see ownership map below). If you need a settings toggle, write a "wiring spec" — don't touch `SettingsWindow.swift` yourself.
- **Never invent UserDefaults keys that already exist** under a different name. Grep `SettingsKey` first.
- **Never delete the Perl MediaRemote bridge or any music-pipeline code.** Music is working; we're adding around it.
- **Never use emojis in code or commits** unless the user explicitly asks.
- **Never commit on your own.** The user (or the coordinator session) handles commits after review.

### ✅ ALWAYS
- **Match nox's existing code patterns.** Before writing, read 1-2 similar files (`Notetaker/Services/TimingPollPolicy.swift`, `Notetaker/Services/ScreenshotPillPolicy.swift`) to absorb the style.
- **Comments cite user feedback or date.** Example: `// 2026-05-17: user reported Continuity icon caused spontaneous opens`. No bland comments.
- **Use the policy-struct pattern** for pure logic (TimingPollPolicy.swift is the canonical example).
- **Use DS design tokens** (`DS.Color.brandLavender`, `DS.Radius.pill`, etc.) — not raw hex/floats.
- **Write XCTest tests** in `NotetakerTests/` for any pure logic policy struct.
- **Build before declaring done.** Run `./dev-deploy.sh` from the repo root. If it errors, your task isn't complete.

### 📝 Wiring Spec Format
When your new code needs a settings toggle, a hookup in `PanelRootView.swift`, or any change in a file you don't own, write a markdown block at the TOP of your new Swift file like this:

```swift
// MARK: - Wiring Spec (for coordinator)
//
// SettingsKey to add:
//   static let myFeatureEnabled = "myFeatureEnabled"  // Default: true
//
// SettingsWindow.swift hookup:
//   In MusicSettings: add a SettingsRow with a Toggle bound to @AppStorage(SettingsKey.myFeatureEnabled)
//   Subtitle text: "Plays a subtle tick when..."
//
// PanelRootView.swift hookup:
//   In segmented var, after line ~3820: pass `featurePolicy: MyFeature.current` to ScribbleTabButton
//
// END WIRING SPEC
```

The coordinator session reads these blocks and applies them serially after all 4 sessions finish.

---

## 2. Shared File Ownership Map

| File | Owner | Notes |
|---|---|---|
| `Notetaker/Settings/SettingsWindow.swift` | **Coordinator only** | All 4 sessions write wiring specs; coordinator applies them |
| `Notetaker/Panel/PanelRootView.swift` | **Coordinator only** | Same pattern |
| `Notetaker.xcodeproj/project.pbxproj` | **Coordinator only** | New Swift files get added to Compile Sources phase by coordinator |
| `Notetaker/Resources/Info.plist` | Already bumped to 1.9.21 — don't touch |
| `Notetaker/NotchPill/PillContextMenu.swift` | **Session 1** (NEW file) |
| `Notetaker/NotchPill/SwipeGesturePolicy.swift` | **Session 2** (NEW file) |
| `Notetaker/Services/SoundEffectsService.swift` | **Session 3** (NEW file) |
| `Notetaker/Services/FocusGatingPolicy.swift` | **Session 4** (NEW file) |
| Pill view files (`NowPlayingPillView`, `ChargingPillView`, etc.) | **Sessions 1-4** may edit ONLY the specific hookup their feature requires |
| `NotetakerTests/*` | **Session that owns the policy** writes its own tests |

---

## 3. Canonical Patterns (read these BEFORE you start)

The whole nox codebase has been migrating to a "policy struct" pattern — pure logic extracted from view/service classes so it can be unit-tested. Your new code MUST follow this pattern. Below are the two canonical examples, inlined so you don't need to grep.

### Pattern 1: `TimingPollPolicy` (gates a side-effect on observable state)

```swift
import Foundation

/// Decides whether the MediaRemoteService AppleScript timing poll
/// should actually send its `tell application "Spotify" / "Music"`
/// query, or skip this tick.
///
/// Background: `MediaRemoteService.startAppScriptTimingTimer` schedules
/// a Timer that fires every 2.5s while music is playing, dispatching
/// an AppleScript to read the live `player position`. The AppleScript
/// goes out via Apple Events and can synchronously block the main
/// thread for 30-80ms on a cold bridge — most aggressively in the
/// 30s-2min window after the Mac wakes from sleep, when the bridge
/// is re-warming.
///
/// The position read is only used to keep the music card's progress
/// bar accurate. When the user isn't looking at the music card (slab
/// hidden, or slab open on a non-music tab), refining position to
/// sub-second accuracy buys nothing — the next display will
/// extrapolate from the last known position + elapsed time, which is
/// within ~0.3s for typical wait windows.
///
/// PerformanceProbe trace 2026-05-15 (file `performance-2026-05-15-
/// 083614.log`) showed periodic 50-56ms spikes every 2.4-2.8s with
/// `active=false`, matching this timer exactly. After wake, the
/// cluster persists for the user-reported ~30s-2min before settling.
enum TimingPollPolicy {
    struct Inputs {
        /// Whether music is currently playing (per `lastInfo.isPlaying`).
        /// If false, the timer self-stops elsewhere; this struct only
        /// matters when music IS active.
        let musicPlaying: Bool
        /// Whether the slab is currently displayed (`presenter.isShown`).
        let panelVisible: Bool
        /// Whether the currently-active tab is the music tab
        /// (`presenter.activeTab == .music`).
        let onMusicTab: Bool
    }

    /// True iff this tick should run the AppleScript. When false,
    /// the timer fires but skips the work — keeps the timer cadence
    /// stable so it can resume the moment the user opens the panel
    /// onto the music card, without re-installing a fresh timer.
    static func shouldPollNow(_ inputs: Inputs) -> Bool {
        guard inputs.musicPlaying else { return false }
        return inputs.panelVisible && inputs.onMusicTab
    }
}
```

**What to absorb:**
- `enum` not `struct` for namespacing — there's no state, just static functions.
- Nested `Inputs` struct that names every parameter explicitly. Future inputs slot in without changing the call signature.
- Doc comment is a **narrative**, not a description. It explains the bug it was extracted to fix, with the trace evidence (file path and timestamp) that proved it.
- Single static decision method named after what it answers.

### Pattern 2: `ScreenshotPillPolicy` (suppression rule with cited user report)

```swift
import Foundation

/// Decision policy for whether a newly-saved screenshot should
/// trigger the resting-pill "screenshot saved" notification.
///
/// Extracted to its own struct so the call-site in
/// `AppDelegate.handleNewScreenshot` stays one line — and so the
/// rule can be exercised by `ScreenshotPillPolicyTests` without
/// touching AppKit, FSEvents, or the rest of the screenshot save
/// pipeline.
///
/// **Rule:** suppress the pill notification whenever the slab is
/// already showing OR in the middle of a morph (open / close /
/// banner). The Images-tab grid mounts the new screenshot through
/// `ImageStore`'s inflight pipeline regardless, so the user still
/// sees the capture; what we're avoiding is the pill's
/// `triggerPunch()` flash overlay animating in parallel with the
/// open spring — which on a partially-grown silhouette bled the
/// 55%-opacity white tile into the panel's halo (user report:
/// "glow at background when opening the thing in time of taking
/// screenshots").
///
/// Background work-in-progress also suppresses because the
/// `setPendingSystemEvent(.screenshotSaved)` write into
/// `PanelPresenter` invalidates every `@ObservedObject` consumer
/// — adding a body re-eval during a morph we're trying to keep
/// smooth.
enum ScreenshotPillPolicy {
    struct Inputs {
        let slabShown: Bool
        let slabMorphing: Bool
    }

    static func shouldFirePill(_ inputs: Inputs) -> Bool {
        if inputs.slabShown { return false }
        if inputs.slabMorphing { return false }
        return true
    }
}
```

**What to absorb (additional to Pattern 1):**
- Comments cite the literal user report (`"glow at background when opening..."`). Yours must do the same — link to source decoding doc or the user message that motivated the feature.
- The rule is stated **prominently in bold** in the doc comment. Reader doesn't have to read the code to know what it does.
- Multiple suppression branches each in their own `if` — easier to test, easier to add a new case.

### Pattern 3: Test file for a policy struct

Create `NotetakerTests/<YourPolicy>Tests.swift`:

```swift
import XCTest
@testable import Notetaker

final class TimingPollPolicyTests: XCTestCase {
    func testSkipsWhenMusicNotPlaying() {
        let r = TimingPollPolicy.shouldPollNow(.init(musicPlaying: false, panelVisible: true, onMusicTab: true))
        XCTAssertFalse(r)
    }

    func testSkipsWhenPanelHidden() {
        let r = TimingPollPolicy.shouldPollNow(.init(musicPlaying: true, panelVisible: false, onMusicTab: true))
        XCTAssertFalse(r)
    }

    func testSkipsWhenOnDifferentTab() {
        let r = TimingPollPolicy.shouldPollNow(.init(musicPlaying: true, panelVisible: true, onMusicTab: false))
        XCTAssertFalse(r)
    }

    func testRunsWhenMusicVisibleAndOnTab() {
        let r = TimingPollPolicy.shouldPollNow(.init(musicPlaying: true, panelVisible: true, onMusicTab: true))
        XCTAssertTrue(r)
    }
}
```

**Conventions:**
- One test per meaningful branch of the rule. Name describes the condition AND the expected outcome.
- Inputs constructed with named arguments at the call site — no helper factories.
- No mocks, no spies — the whole point of the policy struct is that there's nothing to mock.

---

## 4. Required Reading Per Session (do this before writing)

| Session | Files to read FULL before coding |
|---|---|
| **All sessions** | This sprint doc end-to-end · `Notetaker/Services/TimingPollPolicy.swift` · `Notetaker/Services/ScreenshotPillPolicy.swift` · `Notetaker/DesignSystem/DesignTokens.swift` · `Notetaker/Settings/SettingsWindow.swift` (full, ~2100 lines — understand SettingsKey, SettingsRow, SettingsCard, GroupTitle, SectionHeader) |
| **Session 1 (Context Menu)** | `Notetaker/NotchPill/NowPlayingPillView.swift` · `Notetaker/NotchPill/MediaRemoteService.swift` (find the `playPause`, `nextTrack`, `previousTrack` entry points) · `Notetaker/NotchPill/MediaRemoteAdapterService.swift` · grep for `NSWorkspace.shared.launchApplication` already in codebase |
| **Session 2 (Swipe)** | `Notetaker/NotchPill/NowPlayingPillView.swift` (find existing horizontal swipe handler — search for `pillSwipeToSkip`) · `Notetaker/Panel/PanelRootView.swift` (the gesture region for the resting pill) · existing haptic call sites (grep `NSHapticFeedbackManager`) |
| **Session 3 (Sound Effects)** | `Notetaker/NotchPill/PowerSourceWatcher.swift` · `Notetaker/NotchPill/LockScreenWatcher.swift` · `Notetaker/NotchPill/SystemAudioWatcher.swift` · `Notetaker/Services/FocusStatusService.swift` (find how Focus state is exposed) · grep for `NSSound\|AVAudioPlayer` already in codebase |
| **Session 4 (Focus Gating)** | `Notetaker/Services/FocusStatusService.swift` · every pill view in `Notetaker/NotchPill/` (ChargingPillView, AirDropPillView equivalent, BluetoothPillView, ScreenshotPillPolicy) · grep `respectFocusMode` to find every current consumer |

After absorbing those, you'll have full context for your slice. Don't start writing until you've actually read them.

---

# 🟢 Session 1 — Right-Click Context Menu on Resting Pill

## Goal
When the user right-clicks the resting now-playing pill, show an NSMenu with media controls. Matches Alcove's `NSMenu` with media controls (Play/Pause, Next, Previous, Forward, Back, Copy Link, Show In Source, Speed) and calendar (Join, Dismiss, Open in Calendar).

For nox v1.9.21, scope is **music only** (calendar items can wait):
- Play / Pause (toggles based on current state)
- Next Track
- Previous Track
- Copy Track Link (if Spotify/Apple Music URL is available)
- Show in Source App (focus the app that owns now-playing)
- Separator
- Open Music Settings… (opens nox Settings → Music)

## Files you own
- **NEW:** `/Users/apple/Note taker app/Notetaker/NotchPill/PillContextMenu.swift`

## Files you may edit (one hookup point only)
- The resting pill view file (find it via `grep -rn "NowPlayingPill\|RestingPill" Notetaker/NotchPill/`). Add a single `.onAppear` or `NSEvent.addLocalMonitorForEvents` hookup that routes right-click events through `PillContextMenu.show(...)`.

## Implementation requirements
1. **`PillContextMenu` class** is a pure AppKit controller. It builds an `NSMenu` on demand and presents it via `NSMenu.popUp(positioning:at:in:)`.
2. **Action targets** call into the existing `MediaRemoteAdapterService` / `MediaRemoteService` / wherever Play/Pause/Next/Prev already live. Grep for `MRMediaRemoteSendCommand` or `playPause` to find the entry point.
3. **"Show in Source"** uses `NSWorkspace.shared.launchApplication(withBundleIdentifier:)` against the current now-playing bundle ID (read from `nowPlaying.sourceBundleID` or equivalent).
4. **"Copy Track Link"** builds the Spotify/Apple Music URL from the track metadata (look for existing logic — Alcove uses `music.apple.com/api/oembed` and `open.spotify.com/track/`).
5. **Disable items that don't apply** — e.g., grey out "Copy Track Link" if there's no URL. Use `NSMenuItem.isEnabled = false`.

## Test plan (XCTest)
- `PillContextMenuTests` in `NotetakerTests/`:
  - `testMenuBuildsAllExpectedItemsWhenPlaying`
  - `testCopyLinkDisabledWhenNoURL`
  - `testShowInSourceUsesCurrentBundleID`

## Out of scope (don't do)
- Calendar actions
- Volume / Brightness controls
- AirPlay routing

## When done
- Confirm `./dev-deploy.sh` builds clean
- Right-click your live music pill and verify menu appears with working actions
- Write wiring spec at top of `PillContextMenu.swift` if any SettingsWindow / PanelRootView edits are needed
- Tell the user "Session 1 done — wiring spec is at top of PillContextMenu.swift"

---

# 🟢 Session 2 — Refined Horizontal Swipe + Natural-Movement Toggle

## Goal
Polish the existing horizontal-swipe-to-skip-track gesture to Alcove quality:
- Threshold-crossing **haptic** the moment the swipe commits (not on release)
- **Natural-movement** toggle — when on, swipe LEFT skips forward (matches macOS trackpad scroll); when off, swipe RIGHT skips forward (matches reading-direction intuition)
- Configurable swipe **success threshold** (px) and **reset threshold**
- Visual feedback: the pill **scrubs visually** as the user drags, snaps back if they don't commit

## Files you own
- **NEW:** `/Users/apple/Note taker app/Notetaker/NotchPill/SwipeGesturePolicy.swift`

## Files you may edit
- Wherever the existing horizontal swipe handler lives. Grep `pillSwipeToSkip` to find it. Edit that single handler to delegate to `SwipeGesturePolicy.decide(...)`.

## Implementation requirements

1. **`SwipeGesturePolicy` is a pure struct** (Codex policy pattern — see `Notetaker/Services/TimingPollPolicy.swift` for canonical style). Inputs: current cumulative drag delta, natural-movement preference, thresholds. Output: `.idle`, `.scrubbing(progress: Double)`, `.commitForward`, `.commitBackward`, `.reset`.

2. **Threshold-crossing haptic** — when policy returns `.commitForward` or `.commitBackward`, the consumer fires `NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)`. Policy itself does NOT touch the haptic API — it just returns the state change. Tests must be able to run without an AppKit haptic side-effect.

3. **Visual scrubbing** — `.scrubbing(progress: Double)` returns 0...1 as the user drags. The consumer view applies `offset(x:)` proportional to progress. On `.reset`, animate back to 0 with a SwiftUI spring (`response: 0.4, dampingFraction: 0.85`).

4. **Natural-movement preference** — add `SettingsKey.naturalSwipeDirection = "naturalSwipeDirection"`, default `true`. Wiring spec covers this.

5. **Thresholds** — `horizontalSwipeSuccessThreshold` default 60pt, `horizontalSwipeResetThreshold` default 30pt. Both expose-able as advanced preferences later.

## Test plan
- `SwipeGesturePolicyTests`:
  - `testIdleBelowResetThreshold`
  - `testScrubbingProgressBetweenThresholds`
  - `testCommitForwardWithNaturalMovementOn` — swipe LEFT triggers forward
  - `testCommitForwardWithNaturalMovementOff` — swipe RIGHT triggers forward
  - `testResetWhenReleasedBelowSuccessThreshold`

## Wiring spec contents
- SettingsKey: `naturalSwipeDirection`, `horizontalSwipeSuccessThreshold`, `horizontalSwipeResetThreshold` (the last two probably hidden, not in UI)
- SettingsWindow: in Music section, add a toggle row "Natural swipe direction" with subtitle "Swipe left for next track. Off = reverse."

## Out of scope
- Vertical swipes (defer to v1.10)
- Two-finger anything (Alcove doesn't actually use it)
- Cycling activities

## When done
- Build clean, smoke-test on a live track
- Verify haptic fires AT the commit threshold, not at release
- Try both natural-movement states and confirm direction inverts

---

# 🟢 Session 3 — System Sound Effects Pack

## Goal
Add subtle, optional sound effects to ambient events. Default OFF for all (opt-in to avoid surprising existing users). Use **built-in macOS sounds** (`NSSound(named:)`) — don't ship .caf files this round.

Events:
1. **Charging start** — when MagSafe / USB-C plugs in. Use `NSSound(named: "Tink")`.
2. **Bluetooth device connect** — AirPods or any BT audio device. Use `NSSound(named: "Glass")`.
3. **System lock** — screen locks. Use `NSSound(named: "Funk")`.
4. **System unlock** — wake from lock. Use `NSSound(named: "Pop")`.

(Available system sounds: Basso, Blow, Bottle, Frog, Funk, Glass, Hero, Morse, Ping, Pop, Purr, Sosumi, Submarine, Tink.)

## Files you own
- **NEW:** `/Users/apple/Note taker app/Notetaker/Services/SoundEffectsService.swift`

## Files you may edit
- The trigger points: `Notetaker/NotchPill/PowerSourceWatcher.swift` (charging), wherever Bluetooth connect/disconnect is observed, `Notetaker/NotchPill/LockScreenWatcher.swift` (lock/unlock).

In each, add ONE LINE inside the existing event handler: `SoundEffectsService.shared.playIfEnabled(.charging)`. The service handles "is this enabled? respect Focus? respect mute? do nothing if so."

## Implementation requirements

1. **`SoundEffectsService` is a singleton** (`static let shared = SoundEffectsService()`). Holds preloaded `NSSound` instances — preload once at init, don't re-fetch on every play.

2. **`SoundEvent` enum** — `.charging`, `.bluetoothConnect`, `.lock`, `.unlock`. Each maps to one `NSSound`.

3. **`playIfEnabled(_ event: SoundEvent)`** — reads its specific UserDefaults key, plays if true. Respects:
   - The relevant `playSoundOn*` toggle
   - The global `enableHaptics`-equivalent for sounds (we'll call it `enableSoundEffects`, default true so individual toggles still gate)
   - The Focus suppression rule: if `respectFocusMode` is on AND macOS Focus is active, don't play

4. **Volume** — each NSSound's `.volume = 0.4` (subtle — not jarring). User can override per-event via a future "intensity" picker; not in scope for this session.

5. **Don't play if system volume is muted** — read via `SystemVolumeWatcher` if it exists, else just trust `NSSound` to respect system mute.

## Test plan
- `SoundEffectsPolicyTests` (separate the decision logic from the playback):
  - `testNotPlayedWhenEventDisabled`
  - `testNotPlayedDuringFocusWhenRespected`
  - `testPlayedNormally`

Extract the "should-play" decision into a static `SoundEffectsPolicy.shouldPlay(...)` function so tests don't have to mock NSSound.

## Wiring spec contents
- SettingsKeys:
  - `enableSoundEffects = "enableSoundEffects"` — default true
  - `playSoundOnCharging = "playSoundOnCharging"` — default false
  - `playSoundOnBluetoothConnect = "playSoundOnBluetoothConnect"` — default false
  - `playSoundOnLock = "playSoundOnLock"` — default false
  - `playSoundOnUnlock = "playSoundOnUnlock"` — default false
- SettingsWindow: NEW "Sound" group in General settings card (or a new SettingsCategory if you want — but a sub-group in General is simpler for v1)
  - Master toggle: "Play sound effects"
  - 4 child toggles, indented or grouped: "Charging", "Bluetooth connect", "Lock", "Unlock"

## Out of scope
- Custom .caf files
- Volume HUD tick (would need to intercept volume keys — bigger lift)
- Calendar event sounds
- Low-battery sound (defer; rare event, low value)
- Sound intensity picker

## When done
- Confirm each event plays the right system sound when toggled on
- Confirm Focus suppression works (toggle macOS Focus on, charging plug, no sound)

---

# 🟢 Session 4 — Per-Widget Focus Gating

## Goal
nox already has a "Auto-hide pills during Focus" master toggle (`SettingsKey.respectFocusMode`). Alcove takes this further: per-pill exception toggles. User can say "respect Focus IN GENERAL, but I still want charging pills even while Focused."

Add per-pill `allowDuringFocus` toggles for:
- Charging
- AirDrop
- Bluetooth
- Screenshot

Default: all FALSE (current behavior — Focus suppresses everything). User can flip individual exceptions ON.

## Files you own
- **NEW:** `/Users/apple/Note taker app/Notetaker/Services/FocusGatingPolicy.swift`

## Files you may edit
- The display predicate in each pill that already reads `respectFocusMode`. Find them via `grep -rn "respectFocusMode" Notetaker/`. Add a `FocusGatingPolicy.shouldShow(pill: .charging)` call in front of the suppress logic.

## Implementation requirements

1. **`FocusGatingPolicy` is a pure struct** with one static method: `static func shouldShow(pill: PillType) -> Bool`. Inputs: global respectFocusMode flag, is-focused state, per-pill allow flag. Output: bool.

2. **`PillType` enum** — `.charging`, `.airdrop`, `.bluetooth`, `.screenshot`. Don't include music/notes — those have their own visibility rules.

3. **Logic**:
   ```
   func shouldShow(pill: PillType, isFocused: Bool, respectFocus: Bool, allowList: Set<PillType>) -> Bool {
       guard isFocused else { return true }  // not Focused → always show
       guard respectFocus else { return true }  // user disabled Focus suppression → show
       return allowList.contains(pill)  // Focused + respecting Focus → only show if exception is set
   }
   ```

4. **Per-pill UserDefaults keys** for the allow list — `allowChargingDuringFocus`, etc.

5. **Reactive updates** — if the user flips an exception toggle while Focused, the relevant pill should appear/disappear within ~1 frame. This means the consumer pills must observe `@AppStorage(SettingsKey.allowChargingDuringFocus)` etc. Wiring spec includes those bindings.

## Test plan
- `FocusGatingPolicyTests`:
  - `testNotFocusedAlwaysShows`
  - `testFocusedWithRespectFalseShows`
  - `testFocusedWithRespectAndNoAllowDoesNotShow`
  - `testFocusedWithRespectAndAllowShows`

## Wiring spec contents
- SettingsKeys (4 new):
  - `allowChargingDuringFocus = "allowChargingDuringFocus"` — default false
  - `allowAirDropDuringFocus`, `allowBluetoothDuringFocus`, `allowScreenshotDuringFocus` — same
- SettingsWindow: under General → "Behaviour" group (already exists), nested under the existing "Auto-hide pills during Focus" row, add 4 indented child toggles. Or add a disclosure-group "Exceptions" containing the 4.
- Each pill's display predicate: route through `FocusGatingPolicy.shouldShow(...)` instead of inline `respectFocusMode` check.

## Out of scope
- Per-app Focus rules (which specific Focus mode allows what)
- Time-based exceptions
- Music / notes / calendar pill gating (defer)

## When done
- Toggle macOS Focus on; verify charging pill is suppressed
- Flip "Allow Charging during Focus" on; plug in charger; verify pill appears
- Run tests

---

# 🟦 Coordinator Session (the user, or a fresh Claude session AFTER sessions 1-4 finish)

## Responsibilities
1. **Pull every wiring spec** from the top of each new Swift file:
   ```bash
   cd "/Users/apple/Note taker app"
   for f in Notetaker/NotchPill/PillContextMenu.swift \
            Notetaker/NotchPill/SwipeGesturePolicy.swift \
            Notetaker/Services/SoundEffectsService.swift \
            Notetaker/Services/FocusGatingPolicy.swift; do
       echo "=== $f ==="
       sed -n '/MARK: - Wiring Spec/,/END WIRING SPEC/p' "$f"
   done
   ```

2. **Apply all SettingsKey additions** to `SettingsWindow.swift` (the SettingsKey enum near the top).

3. **Apply all SettingsWindow UI additions** — new toggle rows in the appropriate sections.

4. **Apply all PanelRootView / pill-view hookup edits** that each spec described but the session didn't make.

5. **Add all 4 new Swift files to the Xcode project** — edit `project.pbxproj` to register them in the Compile Sources phase. Use this pattern (the user has done this many times):
   - Find the existing Compile Sources phase for the Notetaker target
   - Add a `PBXBuildFile` entry per new file
   - Add a `PBXFileReference` entry per new file
   - Add the new file to its parent `PBXGroup` (Sources / NotchPill / Services as appropriate)
   - Add the build file to the `PBXSourcesBuildPhase` files array

6. **Run `./dev-deploy.sh`** from repo root. Fix any build errors.

7. **Smoke-test all 4 features end-to-end** on the running instance.

8. **Stop and ask the user explicitly** "1.9.21 ready to ship — run release.sh --publish?" Do NOT ship without explicit per-change approval (this rule is in memory: `feedback_ship_discipline.md`).

---

# 🔍 Review Agent (dispatch this AFTER coordinator integration, BEFORE shipping)

Spawn a `code-reviewer` agent with this prompt:

> Review 4 new Swift files added in nox 1.9.21:
> - `Notetaker/NotchPill/PillContextMenu.swift`
> - `Notetaker/NotchPill/SwipeGesturePolicy.swift`
> - `Notetaker/Services/SoundEffectsService.swift`
> - `Notetaker/Services/FocusGatingPolicy.swift`
>
> And the corresponding edits in:
> - `Notetaker/Settings/SettingsWindow.swift`
> - `Notetaker/Panel/PanelRootView.swift`
> - Pill view files
>
> Check specifically:
> 1. **Pattern consistency** — do the new policy structs match the style of `TimingPollPolicy.swift` and `ScreenshotPillPolicy.swift`?
> 2. **No leaks** — singletons (`SoundEffectsService.shared`) properly retain only what they need
> 3. **No race conditions** — main-thread assumptions documented where AppKit is touched
> 4. **Comments cite rationale** — not bland boilerplate
> 5. **Tests exist** for pure logic policies and actually exercise the decision points
> 6. **No Claude footer / Co-Authored-By Claude in any new file or comment**
> 7. **Builds clean** — run `./dev-deploy.sh` and report warning count delta vs the pre-sprint baseline (50 warnings, all pre-existing)
> 8. **Settings UI matches nox conventions** — uses `SettingsRow`, `SettingsCard`, etc., not raw SwiftUI primitives
> 9. **All wiring specs were applied** — no orphan SettingsKey additions referenced but unwired
> 10. **No `release.sh` was run** — verify `git log` shows uncommitted state or one new commit at most
>
> Report findings as: blocker / nit / approve. Cap report at 400 words.

---

# 📊 Sprint Checklist for the User

After everything is integrated:

- [ ] All 4 sessions returned with wiring specs at top of their new files
- [ ] Coordinator applied all wiring specs
- [ ] `project.pbxproj` includes all 4 new files in Compile Sources
- [ ] `./dev-deploy.sh` builds clean (warning count stable)
- [ ] All 4 features work end-to-end:
  - [ ] Right-click pill shows menu with working media controls
  - [ ] Horizontal swipe skips track + haptic + natural-movement toggle works
  - [ ] All 4 system sounds play when their event fires (and are silent when toggled off)
  - [ ] Per-pill Focus exceptions work
- [ ] Tests pass: `xcodebuild test -scheme Notetaker -destination 'platform=macOS'`
- [ ] Review agent reports no blockers
- [ ] User has explicitly approved running `release.sh --publish`

---

# 🆘 If You Get Stuck

- **Can't find a file:** Use `find . -name "<pattern>"` from repo root. nox's structure: `Notetaker/{App, Panel, NotchPill, Services, Settings, DesignSystem, Resources}`.
- **Don't know the existing code pattern:** Read `Notetaker/Services/TimingPollPolicy.swift` and `Notetaker/Services/ScreenshotPillPolicy.swift` first. They're the canonical Codex-style policy structs.
- **Test target name is unclear:** Check `Notetaker.xcodeproj/project.pbxproj` for `PBXTargetDependency` entries referencing a test target.
- **Hit a system reminder about Sparkle / signing / SIP:** Stop and ask the user. Don't guess at signing config.

---

*This doc is the source of truth for this sprint. If something here conflicts with an earlier instruction, this wins (it was written with full context). If something here conflicts with the user's direct in-session feedback, the user wins.*
