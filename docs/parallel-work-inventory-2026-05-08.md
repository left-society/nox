# nox parallel work inventory — 2026-05-08

Everything we've planned, designed, or skipped today. Grouped so you can hand each chunk to a different Claude chat without overlapping file changes.

Status legend:
- 🟢 **Shipped** — already live (1.9.8 / 1.9.9)
- 🟡 **Staged** — committed locally, not yet released
- 🔵 **Designed** — spec exists, no code yet
- ⚪ **Idea** — discussed but no spec

---

## Group 1 — IN FLIGHT (don't parallelize, finish here)

These have committed code on `main` and are blocking a 1.9.10 release. Same-chat work.

- 🟡 **Resting pill option 8** (Focus moon + "Focus" text widening the music pill)
- 🟡 **Live tab status row** (Focus chip above music + calendar)
- 🟡 **Live → Focus detail panel** (sleeping moon character + behavior toggle + muted/allowed chips)
- 🟡 **Debug override to remove** (`noxDebugFocusForceOn`) before ship

Files touched: `PanelRootView.swift`, `PanelWindowController.swift`, `PanelPresenter.swift`, `MusicPanelView.swift`, `AppDelegate.swift`. Anything in a parallel chat that touches these files will conflict.

---

## Group 2 — Focus mode follow-ups (sequential, depend on Group 1 landing)

🔵 **A. Standalone Focus pill** — when no music is playing, still show a small Focus pill at the notch with `🌙 Focus 23m`. Touches `PanelWindowController.enterRestingMode`, `PanelPresenter.isResting`, `PanelRootView.musicPillContent`. Half-day.

🔵 **B. Focus duration timer** — track `focusStartedAt: Date?` in `FocusStatusService`, tick every 30s, render minutes/hours in pill cluster. Couple hours.

🔵 **C. Reward system** — ⭐ per 30 min Focus, 3⭐ daily goal, mood evolution on moon character (sleeping → smiling → satisfied), streak counter, per-day stats in detail panel. Touches `MusicPanelView`, `FocusStatusService`, new `FocusStatsService`, `Database.swift` for daily totals. Full day.

These three should ship in order. Don't parallelize.

---

## Group 3 — INDEPENDENT app features (safe to parallelize)

Each touches mostly its own new files. Hand each to a different chat.

### Bigger modules

🔵 **Battery panel module** — % + time remaining + charging state + 7-day history graph + top battery consumers list. New `Notetaker/Modules/Battery/` directory. From SuperIsland audit #1+#2.

🔵 **Weather module** — current temp + hourly forecast + AQI, CoreLocation + remote API. New `Notetaker/Modules/Weather/`. From SuperIsland audit #3.

🔵 **Wi-Fi connectivity panel** — SSID + signal via `CWWiFiClient`. Live link change notifications. New `Notetaker/Modules/Wifi/`. From SuperIsland #4.

🔵 **Bluetooth devices panel** — per-device battery for AirPods / mice / keyboards. Existing `BluetoothDeviceService` already does detection — needs the panel UI. From SuperIsland #5.

🔵 **System notifications mirror** — banners with avatars + tap-to-route. Big — 1500+ LOC equivalent. New `Notetaker/Modules/Notifications/`. From SuperIsland #7.

🔵 **Shelf — persistent drag tray** — multi-item shelf that holds files/links/text across launches with bookmark-data persistence. New `Notetaker/Modules/Shelf/`. From SuperIsland #8.

🔵 **App Intents / Shortcuts integration** — expose nox actions ("save clipboard", "start dictation", "drop file in shelf") to Shortcuts.app so any of macOS's 1000+ Shortcut-capable apps can trigger nox. New `Notetaker/AppIntents/`.

🔵 **AI quick-action panel** — global hotkey, select text in any app → nox shows Summarize / Rewrite / Translate / Explain → routes through user's BYOK key. New `Notetaker/Services/AIQuickAction.swift` + UI.

### Smaller features

🔵 **Multi-monitor display picker** — render the panel on the user's chosen screen, persist `CGDirectDisplayID`. Touches `PanelWindowController` (single-file) but specifically the screen-detection pathway — coordinate with Group 1 if both happening.

🔵 **Auto-hide on fullscreen apps** — observe fullscreen-window changes, tuck the island when a native fullscreen covers the screen. Touches `PanelWindowController` (same caveat).

🔵 **Pre-event reminder timer** — fires HUD before scheduled events, e.g. "Standup in 3 min." Touches `CalendarMonitorService` + `PanelPresenter`. From SuperIsland #28.

### User-facing Settings additions (real toggles, not visual polish)

🔵 **Hover-expand delay slider** — user picks 0–N seconds before hover opens slab. Touches `Settings` + `HoverActivator`.

🔵 **Auto-dismiss delay slider** — user picks how long expanded state lingers. Touches `Settings` + panel timer.

🔵 **Lock full-expanded toggle** — pin the deepest expansion so it doesn't auto-retract. Touches presenter + Settings.

🔵 **Long-press gesture handler** — distinct path that fully expands the island. Touches gesture handlers in `PanelWindowController`.

🔵 **Hide side slots toggle** — Settings option to declutter the pill. Touches `Settings` + pill view.

---

## Excluded (intentionally not on the list)

**Animation / motion polish from SuperIsland — skipped because nox's animation system is already better:**

- Album-art glow halo (we already use `ArtworkColor.dominant` + the existing material treatment is cleaner)
- MarqueeText auto-scroll (our `.lineLimit(1).truncationMode(.tail)` decision is intentional — Apple's own Music app does the same)
- EQ-bar music visualizer (we have waveform + sphere + can add another, but two visualizers is already plenty)
- Spring bounce / speed sliders (every spring in nox is hand-tuned for its specific motion — exposing them as sliders would invite users to break the choreography)
- Named haptic+sound vocabulary (we already pair haptics with the right moments contextually)
- Animated 3D mascot / Lottie animations elsewhere (our SwiftUI-native animations are tighter than the Lottie + AVFoundation route SuperIsland uses)

---

## Group 4 — Marketing / website / docs (totally independent of app code)

Each can run in its own chat — no Swift conflicts.

⚪ **Reddit post drafts** — three drafts written (`r/macapps`, `r/SideProject`, minimal). User hasn't picked one. See chat history for the full versions; they need a version-bump pass (refs to 1.9.7 → 1.9.9) and a hook tweak.

⚪ **YouTube description + chapter timestamps** — for the existing 6:25 demo at `mp9dOv3Fnq8`. Gemini already produced timestamped scene breakdowns; just needs formatting + writing the description copy.

⚪ **75-second hero video cut** — full storyboard + frame-accurate timing notes + on-screen text sheet already exist (`docs/`-equivalent in chat history). Just needs editing-software work.

⚪ **15-second TikTok / Reels cut** — same as above, vertical 9:16 variant + 4 hook variants for A/B testing. Spec ready.

⚪ **"100 free downloads" framing** — four options offered (scarcity hook / actually charge / founder cohort / launch goal). User hasn't picked one.

⚪ **PNG asset generation for video** — render the on-screen text sheet as 1920×1080 + 1080×1920 PNG cards, ready to drop on a video timeline. New work.

⚪ **Spec self-review for any of the above** — convert chat history into proper spec docs in `docs/superpowers/specs/`.

---

## Group 5 — KILLED ideas (don't bother)

These were considered and explicitly cut. Leaving here so a parallel chat doesn't reopen them.

❌ **JS extension runtime** (SuperIsland's JavaScriptCore sandbox) — security/maintenance burden, doesn't fit nox's curated focus.

❌ **3D animated mascot ("Otto")** (SuperIsland) — clashes with liquid-glass aesthetic.

❌ **Teleprompter module** (SuperIsland) — pulls into "creator HUD" positioning.

❌ **Per-app volume control** (SuperIsland AppleScript path) — fragile.

❌ **System-wide emoji picker** (SuperIsland) — unrelated to nox.

❌ **WhatsApp Web log polling** (SuperIsland) — coupled to their JS runtime.

❌ **Keyboard backlight IOKit** (SuperIsland) — neat trick, no fit.

❌ **Custom auto-updater** — Sparkle already does this.

---

## Suggested parallel-chat dispatch

If you want max throughput right now:

| Chat # | Task | Why parallel-safe |
|---|---|---|
| 1 (this one) | Finish Group 1 + start Group 2 | I have all the context |
| 2 | Group 3 → **App Intents / Shortcuts** | Brand new directory, zero file overlap |
| 3 | Group 3 → **Battery panel module** | New module dir, IOKit only |
| 4 | Group 3 → **Weather module** | New module dir, network only |
| 5 | Group 4 → **Reddit post + YouTube description** | Pure copywriting |
| 6 | Group 4 → **75s hero video cut** | Premiere/FCP work, no code |

Each chat can be self-sufficient if you give it:
1. A pointer to this document
2. The specific feature(s) it's responsible for
3. "Don't touch any file outside your assigned scope without checking in"

---

## Brief prompt template for spawning a parallel chat

```
You're working on nox (macOS notch HUD app at /Users/apple/Note taker app/).
Your task: <feature name from the inventory>.
Read /Users/apple/Note taker app/docs/parallel-work-inventory-2026-05-08.md
for context. Implement the feature carefully — research first, design second,
code third. Build between every meaningful change. Don't touch files outside
your feature's scope without flagging in chat. Don't run release.sh — just
land commits on a feature branch and say "ready for review."
```

Tweak the branch / shipping rules to match how you want them to coordinate.
