# Files tab + Smart auto-routing — design

**Sub-project #1 of the Alcove-grade Notetaker redesign.** Establishes the
clipboard-staging tab and the smart-routing fabric that decides which tab
the panel opens to based on what's on the system clipboard. Also sets
the haptic + animation vocabulary the later sub-projects (polish refresh,
now-playing widget, HUDs, etc.) will plug into.

## Goal

1. A new **Files** tab that acts as an in-memory clipboard scratch-pad for
   any file type the existing tabs don't already claim (PDFs, archives,
   docs, generic file URLs, folders).
2. **Smart auto-routing on panel open**: inspect `NSPasteboard.general`
   when the panel shows; if the clipboard changed since the last close,
   switch to the matching tab and auto-stage the content.

## Non-goals

- No on-disk persistence of staged files. Quit Notetaker → staging
  clears. The whole point of the scratch-pad is "set things aside, paste
  later, no clutter accumulates."
- No real-time clipboard mirroring while the panel is open. Auto-routing
  fires on the show edge only; existing per-tab Cmd+V still works.
- No undo / cleared-history. Trash a row → it's gone.
- No drag-reorder of staged files. The order is recency, top = newest.
- No video-thumbnail generation for files. SF Symbol + filename + size
  is the row layout. (Image previews for image *files* are nice-to-have
  but routed to the Images tab, not Files.)

## Architecture

Three new files, three modified.

### New units

#### `Notetaker/Services/FileStore.swift`

```swift
@MainActor
final class FileStore: ObservableObject {
    struct StagedFile: Identifiable, Equatable {
        let id: String           // UUID, opaque
        let url: URL             // source URL (may go stale)
        let displayName: String  // url.lastPathComponent at stage time
        let sizeBytes: Int64?    // url file size at stage time, nil if unreadable
        let stagedAt: Date
    }

    @Published private(set) var files: [StagedFile] = []

    func stage(urls: [URL])
    func remove(id: String)
    func clearAll()
    /// True if `url`'s file still exists with the same byte count we saw at stage time.
    func isStillResolvable(_ file: StagedFile) -> Bool
}
```

**Responsibility:** in-memory list of staged files. Pure value semantics
— no DB, no GRDB, no filesystem ownership. Lives for the app's lifetime
and dies on quit.

**Why not a Database table:** the requirement is explicit — "don't make
or save anything." A scratch-pad with persistence would be a different
feature.

#### `Notetaker/Services/ClipboardRouter.swift`

```swift
enum RoutingDecision: Equatable {
    case notes(text: String)
    case images(data: Data, mime: String)
    case videos(url: URL)
    case files(urls: [URL])
    case none
}

enum ClipboardRouter {
    /// Inspects `NSPasteboard.general` and returns the best routing for
    /// what's on it RIGHT NOW. Pure: no side effects.
    static func decide(pasteboard: NSPasteboard = .general) -> RoutingDecision
}
```

**Decision priority** (first match wins):

1. **Plain text** with no file URL → `.notes`. Includes URLs typed as
   strings, RTF stripped to plain.
2. **Image bytes** (`.png` / `.tiff` / `public.jpeg` data on the
   pasteboard, no `fileURL`) → `.images`.
3. **Single file URL** whose extension is image (`jpg/png/heic/tiff/gif/
   webp/heif`) → `.images`.
4. **Single file URL** whose extension is video (`mp4/mov/m4v/webm/mkv`)
   → `.videos`.
5. **One or more file URLs** that aren't image/video → `.files`.
6. **Anything else** → `.none`.

Reuses existing detection logic where possible: `VideoDropScanner.looks
LikeVideo(in:)` already exists and handles drag-pasteboard video
detection — we'll mirror its extension list for the regular pasteboard
path.

#### `Notetaker/Panel/FilesGridView.swift`

```swift
struct FilesGridView: View {
    @EnvironmentObject var fileStore: FileStore
    // ...
}
```

**Layout:**
- Toolbar (mirrors Images tab): `"N files"` count, `"Saving 0…"` chip
  (always 0 — the scratchpad doesn't save, but the slot is there for
  visual parity with Images), Clear button.
- Scroll-able **stack of file rows**. Each row:
  - `NSWorkspace.shared.icon(forFile:)` rendered at 28×28 with the
    14pt-pillow card treatment we just shipped on Images.
  - Filename (truncated middle), file size formatted via
    `ByteCountFormatter`.
  - Per-row Copy button (puts that file URL on the clipboard).
  - Per-row Trash.
  - "Missing" badge if `fileStore.isStillResolvable` is false.
- Bottom-pinned **"Copy all" pill** when `files.count >= 2`.
- Empty state mirrors the Images empty-state radial-blob aesthetic:
  SF Symbol `tray.full` + accent radial gradient + caption "Drop files,
  paste with ⌘V — held here for later pasting."

**Drag in:** uses the same `PanelDropContainer` plumbing the existing
tabs use (handled at the contentView level — see below).

**Drag out:** `NSItemProvider(contentsOf: url)` for the row, or
`MultiFileDragSource` for the whole stack — the existing helper used by
Images' stack-hero already does multi-file drag.

#### `Notetaker/Panel/FilesGridView.swift` — `FileRow`

```swift
private struct FileRow: View {
    let file: FileStore.StagedFile
    let isResolvable: Bool
    let onCopy: () -> Void
    let onTrash: () -> Void
}
```

96pt height, 14pt pillow corners, double-shadow language matching the
just-shipped `ImageCell`.

### Modified units

#### `Notetaker/Panel/PanelRootView.swift`

```swift
enum PanelTab: String, CaseIterable, Identifiable {
    case notes, images, videos, files   // ← add .files
    // title: "Files"
}

@ViewBuilder
private var content: some View {
    switch presenter.activeTab {
    case .notes:  NotesListView()
    case .images: ImagesGridView()
    case .videos: VideosGridView()
    case .files:  FilesGridView()      // ← new
    }
}
```

#### `Notetaker/App/AppEnvironment.swift`

Add `let fileStore: FileStore` initialized in `init()`. No DB
parameter — it's pure in-memory.

#### `Notetaker/Panel/PanelWindowController.swift`

In `init`, inject `fileStore` as another EnvironmentObject:

```swift
.environmentObject(environment.fileStore)
```

In `show()`, before the spring animation kicks off, run the auto-router
**only if the clipboard's `changeCount` differs from the value we
recorded on the previous `hide()`**. If routed, set
`presenter.activeTab` and dispatch the corresponding stage action:

| RoutingDecision | Action |
|---|---|
| `.notes(text)` | `activeTab = .notes` + `noteStore.createNote()` then `noteStore.updateBody(id: newId, body: text)` |
| `.images(data, mime)` | `activeTab = .images` + `imageStore.saveImageDeferred` |
| `.videos(url)` | `activeTab = .videos` + `videoStore.saveLocalFile(url)` |
| `.files(urls)` | `activeTab = .files` + `fileStore.stage(urls: urls)` |
| `.none` | leave `activeTab` at its last value, no stage |

Stored on the controller: `private var lastSeenChangeCount: Int = NSPasteboard.general.changeCount`.
Updated in `hide()` so the next `show()` knows what "new" means.

#### `Notetaker/Panel/PanelWindowController.swift` — `PanelDropContainer`

The existing `PanelDropContainer` has `onVideo` and `onImage` handlers
that fire when a drag is identified as one or the other. Add a third
handler `onFile([URL])` for any drag that's neither image nor video but
contains file URLs. Wire it to:

```swift
onFile: { [weak presenter, weak environment] urls in
    guard let presenter, let environment else { return }
    environment.fileStore.stage(urls: urls)
    presenter.activeTab = .files
}
```

The dispatch logic inside `PanelDropContainer.draggingEnded` becomes:

1. `VideoDropScanner.looksLikeVideo` → onVideo (existing)
2. Image type available → onImage (existing)
3. Has file URLs → onFile (new)
4. Otherwise drop ignored

## Data flow

### Auto-routing on panel show

```
[user hits Option+Space]
       │
       ▼
HotkeyService → PanelWindowController.show()
       │
       ▼
ClipboardRouter.decide()  ◄── reads NSPasteboard.general
       │
       ├─ .notes(text)        → activeTab = .notes ; NoteStore inserts
       ├─ .images(data, mime) → activeTab = .images ; imageStore.saveImageDeferred
       ├─ .videos(url)        → activeTab = .videos ; videoStore.saveLocalFile
       ├─ .files(urls)        → activeTab = .files  ; fileStore.stage
       └─ .none               → no-op
       │
       ▼
panel orderFront, spring-in
```

### Drop-onto-panel

```
[user drags files over panel]
       │
       ▼
PanelDropContainer.draggingEntered/Updated  → presenter.isDropTargeted = true
       │
[user releases]
       │
       ▼
PanelDropContainer.performDragOperation:
   ├─ video?     → onVideo
   ├─ image?     → onImage
   ├─ file URLs? → onFile  → fileStore.stage(urls) ; activeTab = .files
   └─ none       → ignore
```

### Stage → Copy → Paste

```
[file in FileStore.files]
       │
[user clicks per-row Copy]
       │
       ▼
ClipboardService.copy(fileURLs: [url])
       │
[user pastes in Finder/wherever]
       │
       ▼
NSPasteboard.fileURL → recipient app reads from disk at original location
```

If the original file moved/deleted, the recipient app's paste fails.
We don't pre-validate (the URL might still be readable in 0.05s but not
the moment we copied). We do show a "Missing" badge in the Files tab
when the row is rendered, based on `fileStore.isStillResolvable`.

## Polish — Alcove-bar baseline

This sub-project also ships the haptic + animation vocabulary later
sub-projects will reuse:

- **Haptic on:** stage, copy row, copy all, clear, tab auto-switch.
  `NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)`
  for general feedback; `.levelChange` for tab-switches (slightly
  weightier, sells the "section change" beat).
- **Spring in/out** when a file lands or leaves: `.spring(response:
  0.32, dampingFraction: 0.74)`. Same curve we'll reuse for music
  widget transitions later.
- **Tab auto-switch transition**: when the auto-router switches tabs,
  the segmented pill `matchedGeometryEffect` already animates — we just
  let it play. No extra work.
- **Card style**: matches the Images-tab redesign (14pt pillow corners,
  double-shadow, 0.32→0.06 white-gradient strokeBorder).

## Testing

Unit tests (XCTest, `NotetakerTests/`):

### `ClipboardRouterTests.swift`

- `test_decide_plainTextOnPasteboard_returnsNotes`
- `test_decide_pngDataOnPasteboard_returnsImages`
- `test_decide_imageFileURL_returnsImages`
- `test_decide_videoFileURL_returnsVideos`
- `test_decide_pdfFileURL_returnsFiles`
- `test_decide_zipFileURL_returnsFiles`
- `test_decide_multipleFileURLs_returnsFiles`
- `test_decide_emptyPasteboard_returnsNone`
- `test_decide_textWithFileURL_prefersFileTypeOverText`
  (a copied file from Finder has both — file URL must win)

Tests use a freshly-allocated `NSPasteboard(name: .init("test-router-\(UUID())"))`
or unique-named pasteboard per test to avoid cross-test contamination.

### `FileStoreTests.swift`

- `test_stage_addsFiles`
- `test_stage_dedupesByURL` (staging the same file twice → one row)
- `test_remove_removesById`
- `test_clearAll_emptiesList`
- `test_isStillResolvable_trueForExtantFile`
- `test_isStillResolvable_falseAfterDelete`

Uses a temp directory + dummy files for `isStillResolvable` paths.

### Manual smoke (no xctest)

After build:
1. Cmd+C random text → Option+Space → panel opens on Notes tab, text
   pasted as new note.
2. Cmd+Shift+4 region screenshot → Option+Space → panel opens on
   Images tab, screenshot in.
3. Right-click file in Finder → Copy → Option+Space → panel opens on
   Files tab, file row visible.
4. Drag PDF onto panel → Files tab activates, row appears.
5. Click per-row Copy on a Files row → Cmd+V into Finder → file
   pastes successfully.
6. Restart app → Files tab is empty (verifies no persistence).

## File list summary

**Created:**
- `Notetaker/Services/FileStore.swift`
- `Notetaker/Services/ClipboardRouter.swift`
- `Notetaker/Panel/FilesGridView.swift`
- `NotetakerTests/ClipboardRouterTests.swift`
- `NotetakerTests/FileStoreTests.swift`

**Modified:**
- `Notetaker/Panel/PanelRootView.swift` (add `.files` to `PanelTab`,
  switch case)
- `Notetaker/App/AppEnvironment.swift` (add `fileStore`)
- `Notetaker/Panel/PanelWindowController.swift` (auto-router on show,
  EnvironmentObject injection, onFile drop handler, `lastSeenChangeCount`
  bookkeeping in `hide()`)
- `Notetaker/Services/ClipboardService.swift` (add `copy(fileURLs:[URL])`
  static method — the existing `copy(images:fileURLs:)` requires images,
  so a files-only path doesn't exist yet)
