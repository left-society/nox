# Notetaker — Design Spec

**Date:** 2026-04-25
**Status:** Approved design, ready for implementation planning
**Scope:** v1 (personal use, local-only, macOS)
**Platform:** Native macOS, Apple Silicon primary

---

## 1. Product at a glance

Notetaker is a macOS menu bar app for friction-free capture. Press `Option+Space` anywhere — a ~480×640 glass panel drops down from the menu bar icon with spring animation. Two modes toggled at top:

- **Notes** — vertical list of text entries, newest first. Supports inline editing, voice transcription via Whisper, and image attachments.
- **Images** — 2-column grid of all images (standalone saves plus images attached to notes). Hover reveals origin.

Capture happens three ways inside the panel:

1. **Type** directly into a new note (panel always shows a "New note" composer at top).
2. **Push-to-talk voice** — press `Option+V` (configurable; default avoids `Fn` because Wispr Flow already binds it), speak, press again to stop; Whisper `small.en` transcribes offline in under 2s.
3. **Image paste / drag-drop** — from browsers, Finder, screenshots, or any app. Dropped images attach to the active note; images dropped onto the Images tab become standalone entries.

Copy any note or selection of images back to the clipboard with `⌘C`. Paste into Claude Code, Slack, browsers — anywhere. Clipboard-based handoff means no API keys, no network, no integrations.

Entries auto-recycle: active for 2 days (default, configurable), then soft-deleted to a "Recently Deleted" section for 7 more days (configurable) before being permanently removed from disk.

**North-star flow:** `⌥Space` → type/speak/drop → panel vanishes → back to work. Later: `⌥Space` → grab → paste. Target total friction: under 2 seconds from thought to captured.

---

## 2. Scope

### In scope (v1)

- Menu bar dropdown panel with spring animations
- Notes tab: text entries, inline editor, voice transcription, image attachments
- Images tab: flat grid of all images (standalone + attached), multi-select, copy out
- Whisper `small.en` bundled, runs offline on-device, Core ML encoder for Apple Silicon speed
- Global hotkeys: `Option+Space` (toggle panel), `Option+V` (push-to-talk)
- Clipboard-based copy-out with correct multi-format pasteboard for text and images
- Auto-recycle with soft-delete, user-configurable retention windows
- Settings window (retention sliders, hotkey rebinding)
- Launch at login
- Dark mode (primary), light mode (functional, not polished)
- Local SQLite storage + on-disk image/audio files in `~/Library/Application Support/Notetaker/`
- Codesigned, notarized, distributed as `.dmg`

### Out of scope (v1) — deferred to later versions

- iCloud or any cloud sync
- Full-text search (basic `LIKE` only)
- Screen recording integration with Slate (will be v1.1 via watched-folder handoff)
- Wake-word "Hey Notetaker" (push-to-talk is sufficient)
- Direct Claude API integration (clipboard is enough)
- API-key-based send-to-AI features
- Sparkle auto-updater (manual DMG drag for v1)
- Encrypted-at-rest database
- iOS/iPad companion
- Windows / Linux
- Multi-user / team features
- Export to Markdown / Notion / Obsidian
- Custom Whisper model selection beyond bundled `small.en`

### Explicitly rejected

- Electron / Tauri / web-based UI. Native Swift only.
- Always-listening microphone / wake-word in v1.
- Any telemetry, analytics, or network calls. Fully offline app.

---

## 3. Design DNA — non-negotiable rules

These are enforceable review rules. Any PR that breaks one of these fails review.

**Anchor apps** (what we steal from each):

- **Raycast** — dark translucent panel with high blur radius, tight vertical rhythm, full-row hover pill, inline `⌘K`-style shortcut hints.
- **Things 3** — generous line-height, delicate separators (not hard borders), SF Pro Display for headings / SF Pro Text for body, breathing room between elements.
- **Linear** — speed-feeling interactions (instant hovers, no lag), pill-shaped tags with muted accents, keyboard shortcuts shown inline, precise 1–2px borders.
- **Arc Browser** — spring animations with real physics (no linear fades), thoughtful micro-interactions, warm empty states, gradient accents used sparingly as focal points only.
- **Wispr Flow** — floating "recording" pill, live waveform visualization, subtle start/stop feedback, informative-not-intrusive notifications.
- **Apple Photos / Finder** — multi-select UX for images with checkmark overlays; `⌘`-click toggle, `⇧`-click range; uniform aspect-ratio grid.

**Hard rules:**

1. **Typography** — SF Pro Display for headings, SF Pro Text for body. No Inter, Helvetica, or substitutes. Size scale: 11 / 12 / 13 / 15 / 20 pt only.
2. **Materials** — `NSVisualEffectView` with `.hudWindow` or `.popover` material, `.behindWindow` blending. No CSS blur fakes, no fill-with-transparency shortcuts.
3. **Animations** — all motion uses SwiftUI spring physics (`.spring(response: 0.35, dampingFraction: 0.8)` or named presets). No linear easings anywhere.
4. **Corner radii** — 10pt panel, 7pt rows, 5pt pills. Never 8pt or 12pt — breaks the rhythm.
5. **Accent color** — system blue `#0A84FF`, used only for selection, focus rings, active state. Rest is grayscale (rgba white at 0.04 / 0.08 / 0.12 / 0.7 / 1.0).
6. **Icons** — SF Symbols only, regular weight. No emoji, no custom SVG unless absolutely necessary.
7. **Empty states** — warm and specific, never generic. SF Symbol at 36pt + subtitle below.
8. **Copy** — plain English, sentence case, no exclamation points, no emojis. "Copy" not "Copy to Clipboard!". Terse like Apple.
9. **Dark/light** — dark is primary. Light mode supported but secondary — tuned, not broken.

---

## 4. Architecture

Three tiers: AppKit shell, SwiftUI views, plain Swift services.

### 4.1 App shell (AppKit)

- `AppDelegate` — app lifecycle, Accessibility/Mic permission prompts on first run, login-item setup.
- `MenuBarController` — owns `NSStatusItem`, click handler, icon state (idle / recording).
- `HotkeyService` — registers global hotkeys via Carbon HotKey APIs. Emits typed events: `.togglePanel`, `.startRecording`, `.stopRecording`, `.newNote`.
- `PanelWindowController` — custom `NSPanel` subclass. Positions under the menu bar icon (right-aligned, 8pt gap), spring show/hide, click-outside-to-dismiss, `.hudWindow` material. Hosts SwiftUI root via `NSHostingView`.

### 4.2 UI (SwiftUI)

- `PanelRootView` — segmented control (Notes / Images), search bar, content area, footer with retention hint.
- `NotesListView` — vertical list with "New note" composer at top, row rendering, swipe-to-delete, `⌘C` on focused row.
- `NoteEditorView` — inline editor when a row is tapped. Voice button, image drop zone, delete/restore.
- `ImagesGridView` — 2-column `LazyVGrid`, checkmark multi-select, hover reveals origin ("in: Claude prompt draft"), `⌘`-click / `⇧`-click selection semantics.
- `RecordingPillView` — separate floating `NSWindow`, not part of the panel. Visible whenever voice capture is active. Live waveform + elapsed time + transition states (Listening → Transcribing → Success).
- `SettingsWindow` — retention sliders, hotkey rebinding, Whisper model picker (future-facing), launch-at-login toggle.

### 4.3 Services

All plain Swift classes. `ObservableObject` where views consume them. Dependency-injected into `PanelRootView` via `@EnvironmentObject`.

- `NoteStore` — CRUD for notes + images + audio. Single source of truth. Publishes changes via `@Published` arrays.
- `Database` — GRDB.swift wrapper. Migrations, typed queries, WAL mode, connection pool.
- `ImageStore` — writes image blobs to `Application Support/Notetaker/images/{uuid}.{ext}`, generates 256px thumbnails to `thumbs/`, returns URLs.
- `AudioRecorder` — AVFoundation mic capture at 16kHz mono, outputs WAV.
- `WhisperService` — wraps whisper.cpp. Lazy-loads `small.en` GGML + Core ML encoder on first use, keeps resident. Always transcribes on background `DispatchQueue(qos: .userInitiated)`.
- `ClipboardService` — pasteboard writes. Text notes: `NSString` plain + RTF. Images: `NSImage` (yields TIFF + PNG reps). Multi-image: `[NSImage]` + file-URL items for apps that need paths.
- `RetentionService` — timer every 30 minutes (and on launch). Two passes: active → trashed, trashed → permanent-deleted (including files).

### 4.4 Design system

- `DesignTokens.swift` — colors, spacing scale, corner radii, typography presets as Swift types. Imported everywhere. No magic numbers in views.
- `Animations.swift` — named spring presets: `.panelOpen`, `.rowHover`, `.selection`, `.recordingPulse`.
- `Typography.swift` — font helpers that return correctly-configured `Font` with tracking, weight, size.

### 4.5 Dependencies (three external)

- **GRDB.swift** (SwiftPM) — SQLite. Used by Lyft, Capture One. Simpler than Core Data.
- **HotKey** by soffes (SwiftPM) — global hotkey registration. ~200 lines wrapping Carbon APIs.
- **whisper.cpp** (SwiftPM) — offline transcription with Core ML acceleration.

Everything else is Apple frameworks (AppKit, SwiftUI, AVFoundation, Core Graphics, UniformTypeIdentifiers).

---

## 5. Data model

### 5.1 SQLite schema

Database: `~/Library/Application Support/Notetaker/notetaker.db`, WAL mode.

```sql
-- Text notes (the Notes tab)
CREATE TABLE notes (
  id              TEXT PRIMARY KEY,               -- UUID
  title           TEXT,                            -- first-line derived, or user-set
  body            TEXT NOT NULL DEFAULT '',
  created_at      REAL NOT NULL,                   -- unix epoch
  updated_at      REAL NOT NULL,
  status          TEXT NOT NULL DEFAULT 'active',  -- 'active' | 'trashed'
  trashed_at      REAL                              -- nullable; set when moved to trash
);

-- Images (Images tab + note attachments)
CREATE TABLE images (
  id              TEXT PRIMARY KEY,
  note_id         TEXT REFERENCES notes(id) ON DELETE CASCADE, -- NULL = standalone
  file_path       TEXT NOT NULL,                    -- images/{uuid}.png
  thumb_path      TEXT NOT NULL,                    -- thumbs/{uuid}.jpg
  width           INTEGER,
  height          INTEGER,
  mime_type       TEXT,                             -- 'image/png' etc.
  source          TEXT,                             -- 'paste' | 'drop' | 'screenshot' | 'attach'
  created_at      REAL NOT NULL,
  status          TEXT NOT NULL DEFAULT 'active',
  trashed_at      REAL
);

-- Audio recordings (voice-note source audio, kept for replay/re-transcription)
CREATE TABLE audio_recordings (
  id              TEXT PRIMARY KEY,
  note_id         TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
  file_path       TEXT NOT NULL,                    -- audio/{uuid}.wav
  duration_sec    REAL,
  created_at      REAL NOT NULL
);

CREATE INDEX idx_notes_status_updated ON notes(status, updated_at DESC);
CREATE INDEX idx_images_status_note ON images(status, note_id, created_at DESC);
```

### 5.2 On-disk layout

```
~/Library/Application Support/Notetaker/
├── notetaker.db                        SQLite (WAL mode)
├── notetaker.db-wal
├── notetaker.db-shm
├── images/{uuid}.{png,jpg,gif,webp}    full-resolution originals
├── thumbs/{uuid}.jpg                    256px thumbnails for grid rendering
└── audio/{uuid}.wav                     16kHz mono voice-note audio
```

### 5.3 Conventions

- IDs are UUIDv4 strings (GRDB-friendly, not auto-increment).
- Timestamps are `REAL` (SQLite double) storing Unix epoch seconds with microsecond precision.
- Images tab shows **all** active images (standalone + attached to notes), with hover tooltip revealing the parent note title when attached.
- Voice notes become text notes: Whisper transcription is written to `notes.body`; the original WAV is stored in `audio_recordings` linked via `note_id` for potential replay or re-transcription.
- Trash is true soft-delete: `status='trashed'` + `trashed_at` timestamp. `RetentionService` later purges rows (and their files) past the trash retention window.

---

## 6. Core user flows

### F1 · Open / close panel

1. User presses `Option+Space` anywhere in macOS.
2. `HotkeyService` fires `.togglePanel`.
3. `PanelWindowController` positions the `NSPanel` under the menu bar icon (right-aligned, 8pt gap).
4. Animation: scale 0.95→1.0, opacity 0→1, y-offset −8→0 over 280ms with spring physics.
5. First focusable field receives focus (new-note composer by default).
6. `Esc` or click-outside → reverse animation, panel orders-out. All in-progress text is preserved (autosaved).

### F2 · Capture a text note

1. Panel open, Notes tab active.
2. A persistent "New note" composer row sits at the top of the list.
3. On first keystroke, a new row inserts into `notes` with `status='active'`. Autosaves every 500ms of idle (debounced).
4. Title derives from first line, trimmed to 60 chars. `updated_at` refreshes on each edit.
5. `Esc` dismisses panel. Note persists.

### F3 · Capture a voice note (push-to-talk)

1. User presses `Option+V` (panel open or closed).
2. `AudioRecorder` starts capturing mic at 16kHz mono WAV.
3. `RecordingPillView` appears (separate floating window, glass, under menu bar or configured position).
4. Pill shows live waveform + elapsed seconds. No transcription yet.
5. User presses `Option+V` again. Recording stops. Pill switches to "Transcribing…" with shimmer.
6. `WhisperService` runs `small.en` on the WAV on a background queue. Target: ~1s for 10s clip on Apple Silicon.
7. On success: new `notes` row created with `body = transcription`, new `audio_recordings` row stores the WAV. Pill shows success checkmark (green, 600ms) then fades out.
8. If panel is open, the new note animates to top of list with a brief highlight pulse.

### F4 · Capture an image

- **Paste** (`⌘V` inside panel) — reads `NSPasteboard.general`, extracts image data. Saves `images/{uuid}.{ext}`, generates thumb, inserts row. Attaches to active note if note editor is open; otherwise standalone.
- **Drag-drop** — panel accepts dragged files (local), dragged URLs to web images (we download), and cross-app drags from Preview / Photos. Same save path.
- **Screenshot** (optional, v1 stretch) — register `Option+Shift+4` to invoke `screencapture -i -c`, then auto-paste. User selects area, image lands in Notetaker. If stretch is descoped, user manually uses `Cmd+Shift+4` then pastes.

### F5 · Retrieve and copy out

- **Search** — top bar does `LIKE '%query%'` on `notes.title + notes.body` for Notes tab, on `images.source + images.note.title` for Images tab.
- **Text note copy** — click row or press `⌘C` on focused row. Writes `NSString` + RTF to pasteboard. Toast: "Copied".
- **Single image copy** — click to select, `⌘C`. Writes `NSImage` (TIFF + PNG multi-rep) so it pastes correctly in Claude Code, Slack, browsers.
- **Multi-image copy** — `⌘`-click to toggle selection, `⇧`-click for range. `⌘C` writes multi-item pasteboard with both image data and file-URLs. Most apps take the first image; Finder pastes all.
- **Copy note + attachments** — `⌘⇧C` on a note. Writes note text plus file-URLs of attached images. Pasting into Claude Code yields text + images together.

### F6 · Auto-recycle

1. `RetentionService` timer fires every 30 minutes (and on app launch).
2. **Pass 1:** `UPDATE ... SET status='trashed', trashed_at=now WHERE status='active' AND updated_at < now - retention_seconds`.
3. **Pass 2:** For each row where `status='trashed' AND trashed_at < now - trash_retention_seconds`, delete the row; ON DELETE CASCADE handles `images` and `audio_recordings`; we also delete the corresponding files from disk in the same transaction.
4. **UI:** Bottom of each tab shows a "Recently Deleted (N)" collapsible. Expand to see trashed entries. Each has Restore (back to `active`, clear `trashed_at`) and Permanent Delete (hard-delete immediately).

---

## 7. Defaults and configuration

### 7.1 Hotkeys (all rebindable in Settings)

- `Option+Space` — toggle panel.
- `Option+V` — push-to-talk voice capture (toggle, not hold). Avoids `Fn` because Wispr Flow already binds it.
- `⌘N` (panel open) — new note.
- `⌘C` (focused row or selection) — copy content.
- `⌘⇧C` (focused note) — copy note + attached images.
- `Esc` — close panel.
- `⌘,` (panel open) — open Settings.

### 7.2 Retention

- Active retention (default): **2 days**. Options: 1 / 2 / 7 / 14 / 30 days / Never.
- Trash retention (default): **7 days**. Options: Immediate / 7 / 14 / 30 days.

### 7.3 Launch

- Launch at login: on by default (user can disable).
- No Dock icon; menu bar only (`LSUIElement = true` in Info.plist).
- Panel dismisses on click-outside.

### 7.4 Storage location

- `~/Library/Application Support/Notetaker/` for all data. Not encrypted at rest in v1.

---

## 8. Tech stack specifics

### 8.1 Toolchain

- Xcode 15+ (recommended: latest stable).
- Swift 5.9+.
- Deployment target: **macOS 13 (Ventura)**. If we add ScreenCaptureKit in v1.1, bumps to 13.3.
- Apple Silicon primary (Core ML encoder is Apple Silicon only; app still runs on Intel with pure-CPU whisper.cpp).

### 8.2 Project layout

```
Notetaker.xcodeproj
  Notetaker/
    App/
      NotetakerApp.swift          @main
      AppDelegate.swift
      MenuBarController.swift
    Panel/
      PanelWindowController.swift
      PanelRootView.swift
      NotesListView.swift
      NoteEditorView.swift
      ImagesGridView.swift
      RecordingPillView.swift
    Services/
      NoteStore.swift
      Database.swift
      ImageStore.swift
      AudioRecorder.swift
      WhisperService.swift
      HotkeyService.swift
      ClipboardService.swift
      RetentionService.swift
    DesignSystem/
      DesignTokens.swift
      Animations.swift
      Typography.swift
    Resources/
      ggml-small.en.bin
      ggml-small.en-encoder.mlmodelc
      AppIcon.xcassets
  NotetakerTests/
  NotetakerUITests/
```

### 8.3 Whisper integration specifics

- `whisper.cpp` as SwiftPM dependency.
- Bundle both `ggml-small.en.bin` (GGML model) and `ggml-small.en-encoder.mlmodelc` (Core ML-compiled encoder). Encoder runs on the Neural Engine; decoder runs on CPU via GGML.
- Performance target on Apple Silicon: 10s audio → <1s total transcription.
- Lazy-load on first voice capture, keep resident in memory (~500MB) until app terminates. Cold-start cost is acceptable given usage pattern.
- All transcription work runs on `DispatchQueue(qos: .userInitiated)`. UI never blocks.

### 8.4 Permissions

`Info.plist` keys:

- `NSMicrophoneUsageDescription`: "Notetaker transcribes your voice offline to create notes. Audio never leaves your Mac."

Runtime:

- **Accessibility** — required for global hotkeys when other apps have focus. We prompt on first launch with a clear explanation modal, then open System Settings at `x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility`.

No other permissions required. No camera, no contacts, no location, no network.

### 8.5 Clipboard behavior for Claude Code compatibility

- Text: `NSPasteboard.general.writeObjects([NSString])` — plain text + RTF (via `NSAttributedString`).
- Single image: `NSPasteboard.general.writeObjects([NSImage])` — yields both TIFF and PNG representations on the pasteboard. Claude Code reads TIFF correctly.
- Multiple images: write as individual pasteboard items, each with `NSImage` data plus a `public.file-url` item pointing to the on-disk file. This supports both in-place paste and drag-to-Finder scenarios.

### 8.6 Packaging

- Codesign with Developer ID certificate (stored in Keychain).
- Notarize via `xcrun notarytool` on CI or manually.
- Distribute as `.dmg` with drag-to-Applications window.
- Sparkle for auto-updates: **v1.1 scope**, not v1.

---

## 9. Testing strategy

### 9.1 Automated (XCTest)

- **Database layer** — migrations run cleanly; CRUD round-trips for notes/images/audio; retention queries return the right rows given controlled timestamps; cascade deletes work.
- **RetentionService** — given rows of varying ages, sweeps mark/delete the correct rows. Uses injectable `now` timestamp.
- **ClipboardService** — round-trip test: `NSImage → pasteboard → NSImage`, assert TIFF representation is lossless. Critical for Claude Code paste fidelity.
- **WhisperService wrapper** — not the model; the plumbing. Bundled short test WAV, assert non-empty transcription and correct threading.
- **ImageStore** — file writes go to expected paths; thumbnails are generated at 256px; cleanup on row delete removes files.
- **Integration test** — spin up full `NoteStore + Database + ImageStore` against in-memory SQLite, drive 50 user-like operations, assert final state.

### 9.2 Manual checklist

- Panel open/close animation feel.
- Drag-drop from Chrome, Safari, Finder, Preview.
- Global hotkey collision in VS Code, Chrome, full-screen apps.
- Whisper accuracy on user's voice in user's environment.
- Light mode sanity (functional, not polished).

### 9.3 Performance budgets (asserted, measured with Instruments for manual)

- Panel first paint: within **120ms** of hotkey press.
- Notes list with 500 rows: 60fps scroll, no dropped frames.
- Whisper `small.en` on 15s clip: under **2s** end-to-end on Apple Silicon.
- Single note insert + fsync: under **5ms**.

### 9.4 Development aids

- `DEBUG_SEED=1` env var seeds DB with 40 mixed-age notes and 20 images on launch.
- Aggressive use of Xcode Preview for visual iteration on panel, rows, grid, recording pill.

### 9.5 Explicitly not tested

- SwiftUI snapshot tests (too brittle).
- Accessibility tree in v1.
- Whisper model accuracy (OpenAI's responsibility).

---

## 10. Open questions / future considerations

- **Video links:** user mentioned "video links" in initial conversation. v1 treats these as plain text URLs inside notes (no preview fetching). v1.1 could add inline OG-tag previews.
- **Screen recording via Slate:** planned for v1.1 as watched-folder handoff. Slate saves recordings to a known directory; Notetaker watches and imports new files as attached "recordings" to a new note type.
- **Encryption at rest:** v1.1 — derive key from Keychain-stored secret, use SQLCipher or GRDB's built-in encryption.
- **iCloud sync:** not planned. Could revisit if user wants cross-device after going to market.
- **Public distribution:** only relevant if user decides to ship commercially. Would add Stripe + licensing + proper onboarding.
- **Larger Whisper models:** model picker UI could allow `medium` / `large` for users who want better accent handling. Adds ~1-2GB to bundle.

---

## 11. Success criteria for v1

- User can press `⌥Space` and capture a text thought in under 2 seconds.
- User can push-to-talk a thought and have accurate transcription in under 3 seconds total (record + transcribe).
- User can drag a screenshot from Chrome into the panel and it persists correctly.
- User can `⌘C` a note's content, paste into Claude Code, and the full text arrives intact.
- User can `⌘C` selected images, paste into Claude Code, and images arrive viewable.
- Notes older than 2 days automatically move to trash; notes older than 9 days (2+7) are permanently deleted from disk with files cleaned up.
- App feels indistinguishable from a first-party Apple utility in look, feel, and animation quality.
