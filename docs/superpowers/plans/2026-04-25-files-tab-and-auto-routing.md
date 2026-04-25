# Files Tab + Smart Auto-Routing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a fourth `.files` tab that holds in-memory clipboard staging items (no disk persistence), and auto-route the active tab on panel-open based on what's currently on the system pasteboard (text→Notes, image→Images, video→Videos, plain file→Files).

**Architecture:** Three new files (`FileStore`, `ClipboardRouter`, `FilesGridView`) plus four touched files (`PanelTab` enum, `AppEnvironment`, `PanelWindowController`, `PanelDropContainer`, `ClipboardService`). The router is a single pure function over `NSPasteboard` that returns a `RoutingDecision` enum, called once on every `show()` if `changeCount` advanced since last `hide()`. The store is a plain `@MainActor ObservableObject` holding an array of bookmark-resolvable `URL`s. The UI mirrors the existing `ImagesGridView` card aesthetic so polish is consistent across tabs.

**Tech Stack:** SwiftUI, AppKit (`NSPasteboard`, `NSWorkspace.icon(forFile:)`, `NSURL` bookmark data, `NSHapticFeedbackManager`), GRDB (untouched — Files tab does not persist), XCTest.

**Spec:** `docs/superpowers/specs/2026-04-25-files-tab-and-auto-routing-design.md`

---

## File Structure

**Create:**
- `Notetaker/Services/FileStore.swift` — `@MainActor ObservableObject` holding `[StagedFile]` in memory. API: `stage(urls:)`, `remove(id:)`, `clearAll()`, `isStillResolvable(_:)`.
- `Notetaker/Services/ClipboardRouter.swift` — `enum ClipboardRouter` with `static func decide(pasteboard:) -> RoutingDecision`. Pure, no side effects.
- `Notetaker/Panel/FilesGridView.swift` — SwiftUI view with `@EnvironmentObject var fileStore`. Empty state + scroll list of `FileRow` cards. "Copy all" / "Clear" toolbar.

**Modify:**
- `Notetaker/Panel/PanelRootView.swift:204-216` — add `.files` to `PanelTab` enum + dispatch `FilesGridView()` in `content`.
- `Notetaker/App/AppEnvironment.swift` — add `let fileStore: FileStore` and instantiate it in `init()`.
- `Notetaker/Panel/PanelWindowController.swift` — inject `fileStore` as env-object; add `lastSeenChangeCount: Int` field; in `show()` call `ClipboardRouter.decide()` and switch tabs/inject content; in `hide()` capture `NSPasteboard.general.changeCount`. Also extend `PanelDropContainer` init with `onFile` callback.
- `Notetaker/Panel/VideoDropCatcher.swift` — add `onFile: ([URL]) -> Void` param to `PanelDropContainer.init`; insert generic-file path into `performDragOperation` between image-extract and reject.
- `Notetaker/Services/ClipboardService.swift` — add `static func copy(fileURLs: [URL])` for the "Copy all" button.

**Tests (create):**
- `NotetakerTests/ClipboardRouterTests.swift` — 9 cases covering each routing branch.
- `NotetakerTests/FileStoreTests.swift` — 6 cases covering stage/dedup/remove/clear/resolvable.

---

## Polish Baseline (used across all UI tasks below)

These tokens establish the "Alcove-bar" feel and apply to every tab going forward:

- **Spring curve:** `.spring(response: 0.32, dampingFraction: 0.74)` for tab-switch glow, card hover lift, drag pulse. Existing `Animation.selection` and `.rowHover` stay for tap feedback only.
- **Haptic:** `NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)` on tab change; `.levelChange` on stage/remove file. Fire from main actor.
- **Card style:** `RoundedRectangle(cornerRadius: 14, style: .continuous)` filled with `Color.white.opacity(0.05)`, `strokeBorder` LinearGradient `(white 0.18 → white 0.04, top → bottom, lineWidth: 0.6)`, double shadow `(black 0.45, radius 8, y 4)` + `(black 0.18, radius 1, y 1)`. Hover lift `-2pt` y-offset + shadow radius bump to 12.
- **Type:** Title `.nkTitle`, primary text `.nkBody`, meta `.nkMeta`. All from `DesignSystem/Typography.swift` (no new tokens required for this sub-project).

---

### Task 1: Add `.files` tab + FileStore stub + AppEnvironment wiring

Goal: get the new tab visible (empty placeholder) so subsequent tasks can focus on logic without compile errors. **No tests in this task** — it's pure scaffolding.

**Files:**
- Create: `Notetaker/Services/FileStore.swift`
- Create: `Notetaker/Panel/FilesGridView.swift`
- Modify: `Notetaker/Panel/PanelRootView.swift:204-216` (PanelTab enum) and `~485-493` (content switch)
- Modify: `Notetaker/App/AppEnvironment.swift` (add fileStore)
- Modify: `Notetaker/Panel/PanelWindowController.swift` (inject env-object)

- [ ] **Step 1: Create stub FileStore**

Write `Notetaker/Services/FileStore.swift`:

```swift
import Foundation
import Combine

@MainActor
final class FileStore: ObservableObject {
    struct StagedFile: Identifiable, Equatable {
        let id: String
        let url: URL
        let displayName: String
        let sizeBytes: Int64?
        let stagedAt: Date

        static func == (lhs: StagedFile, rhs: StagedFile) -> Bool {
            lhs.id == rhs.id
        }
    }

    @Published private(set) var files: [StagedFile] = []

    /// Real impl arrives in Task 3.
    func stage(urls: [URL]) {}
    func remove(id: String) {}
    func clearAll() {}
    func isStillResolvable(_ file: StagedFile) -> Bool { true }
}
```

- [ ] **Step 2: Add .files to PanelTab enum**

In `Notetaker/Panel/PanelRootView.swift`, replace the PanelTab enum (currently lines 204-216):

```swift
enum PanelTab: String, CaseIterable, Identifiable {
    case notes, images, videos, files

    var id: String { rawValue }

    var title: String {
        switch self {
        case .notes: return "Notes"
        case .images: return "Images"
        case .videos: return "Videos"
        case .files: return "Files"
        }
    }
}
```

- [ ] **Step 3: Create stub FilesGridView**

Write `Notetaker/Panel/FilesGridView.swift`:

```swift
import SwiftUI

struct FilesGridView: View {
    @EnvironmentObject var fileStore: FileStore

    var body: some View {
        // Real UI lands in Task 5.
        VStack {
            Text("Files")
                .font(.nkBody)
                .foregroundStyle(DS.Color.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
```

- [ ] **Step 4: Dispatch FilesGridView in content switch**

In `Notetaker/Panel/PanelRootView.swift`, the `content` view (currently lines 484-493) becomes:

```swift
@ViewBuilder
private var content: some View {
    switch presenter.activeTab {
    case .notes:
        NotesListView()
    case .images:
        ImagesGridView()
    case .videos:
        VideosGridView()
    case .files:
        FilesGridView()
    }
}
```

- [ ] **Step 5: Add FileStore to AppEnvironment**

Edit `Notetaker/App/AppEnvironment.swift`:

```swift
import Foundation

@MainActor
final class AppEnvironment: ObservableObject {
    let database: Database
    let noteStore: NoteStore
    let imageStore: ImageStore
    let videoStore: VideoStore
    let fileStore: FileStore
    let retentionService: RetentionService

    init() throws {
        self.database = try Database()
        self.noteStore = NoteStore(db: database)
        self.imageStore = try ImageStore(db: database)
        self.videoStore = try VideoStore(db: database)
        self.fileStore = FileStore()
        let imageRoot = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("Notetaker", isDirectory: true)
        self.retentionService = RetentionService(db: database, imageRoot: imageRoot)
    }
}
```

- [ ] **Step 6: Inject fileStore in PanelWindowController**

In `Notetaker/Panel/PanelWindowController.swift`, find the `NSHostingView` block (currently around lines 99-106) and add `.environmentObject(environment.fileStore)`:

```swift
let host = NSHostingView(
    rootView: PanelRootView()
        .environmentObject(environment)
        .environmentObject(environment.noteStore)
        .environmentObject(environment.imageStore)
        .environmentObject(environment.videoStore)
        .environmentObject(environment.fileStore)
        .environmentObject(presenter)
)
```

- [ ] **Step 7: Build & visually confirm**

Run:
```bash
cd "/Users/apple/Note taker app" && xcodebuild -project Notetaker.xcodeproj -scheme Notetaker -configuration Debug build 2>&1 | tail -40
```
Expected: `** BUILD SUCCEEDED **`. The 4-segment pill (Notes / Images / Videos / Files) should now render. Tap "Files" → "Files" placeholder text appears.

- [ ] **Step 8: Commit scaffolding**

```bash
cd "/Users/apple/Note taker app" && git add Notetaker/Services/FileStore.swift Notetaker/Panel/FilesGridView.swift Notetaker/Panel/PanelRootView.swift Notetaker/App/AppEnvironment.swift Notetaker/Panel/PanelWindowController.swift && git commit -m "$(cat <<'EOF'
feat: scaffold .files tab + FileStore stub

Adds Files as a fourth tab (between Videos and the existing trio's
end), wires an empty FileStore through AppEnvironment as its own
EnvironmentObject, and stubs FilesGridView so the segmented pill
shows four equal segments. No logic yet — that arrives in the next
tasks.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: ClipboardRouter (TDD)

Goal: pure decision function. Inputs: `NSPasteboard`. Output: a `RoutingDecision` enum. No side effects, no environment access. Easy to test by stuffing a fresh `NSPasteboard.withUniqueName()` and asserting.

**Files:**
- Create: `Notetaker/Services/ClipboardRouter.swift`
- Test: `NotetakerTests/ClipboardRouterTests.swift`

- [ ] **Step 1: Write failing test file**

Create `NotetakerTests/ClipboardRouterTests.swift`:

```swift
import XCTest
import AppKit
@testable import Notetaker

final class ClipboardRouterTests: XCTestCase {
    private func freshPasteboard() -> NSPasteboard {
        let pb = NSPasteboard(name: NSPasteboard.Name(rawValue: "Notetaker.RouterTest.\(UUID().uuidString)"))
        pb.clearContents()
        return pb
    }

    func test_emptyPasteboard_returnsNone() {
        let pb = freshPasteboard()
        XCTAssertEqual(ClipboardRouter.decide(pasteboard: pb), .none)
    }

    func test_plainText_routesToNotes() {
        let pb = freshPasteboard()
        pb.setString("hello clipboard", forType: .string)

        if case .notes(let text) = ClipboardRouter.decide(pasteboard: pb) {
            XCTAssertEqual(text, "hello clipboard")
        } else {
            XCTFail("expected .notes")
        }
    }

    func test_whitespaceOnlyText_returnsNone() {
        let pb = freshPasteboard()
        pb.setString("   \n\t  ", forType: .string)
        XCTAssertEqual(ClipboardRouter.decide(pasteboard: pb), .none)
    }

    func test_youtubeURL_routesToVideos() {
        let pb = freshPasteboard()
        pb.setString("https://www.youtube.com/watch?v=dQw4w9WgXcQ", forType: .string)

        if case .videos(let url) = ClipboardRouter.decide(pasteboard: pb) {
            XCTAssertEqual(url.absoluteString, "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
        } else {
            XCTFail("expected .videos")
        }
    }

    func test_pngData_routesToImages() {
        let pb = freshPasteboard()
        let png = Self.makeTinyPNG()
        pb.setData(png, forType: .png)

        if case .images(let data, let mime) = ClipboardRouter.decide(pasteboard: pb) {
            XCTAssertGreaterThan(data.count, 0)
            XCTAssertEqual(mime, "image/png")
        } else {
            XCTFail("expected .images")
        }
    }

    func test_imageFileURL_routesToImages() throws {
        let tmp = try Self.writeTempFile(name: "pic.png", data: Self.makeTinyPNG())
        defer { try? FileManager.default.removeItem(at: tmp) }
        let pb = freshPasteboard()
        pb.writeObjects([tmp as NSURL])

        if case .images = ClipboardRouter.decide(pasteboard: pb) {
            // pass
        } else {
            XCTFail("expected .images for image file URL")
        }
    }

    func test_videoFileURL_routesToVideos() throws {
        let tmp = try Self.writeTempFile(name: "clip.mp4", data: Data([0x00, 0x00, 0x00]))
        defer { try? FileManager.default.removeItem(at: tmp) }
        let pb = freshPasteboard()
        pb.writeObjects([tmp as NSURL])

        if case .videos(let url) = ClipboardRouter.decide(pasteboard: pb) {
            XCTAssertEqual(url.lastPathComponent, "clip.mp4")
        } else {
            XCTFail("expected .videos for video file URL")
        }
    }

    func test_genericFileURL_routesToFiles() throws {
        let tmp = try Self.writeTempFile(name: "doc.pdf", data: Data([0x25, 0x50, 0x44, 0x46]))
        defer { try? FileManager.default.removeItem(at: tmp) }
        let pb = freshPasteboard()
        pb.writeObjects([tmp as NSURL])

        if case .files(let urls) = ClipboardRouter.decide(pasteboard: pb) {
            XCTAssertEqual(urls.first?.lastPathComponent, "doc.pdf")
        } else {
            XCTFail("expected .files for pdf URL")
        }
    }

    func test_multipleFileURLs_routesToFilesWithAll() throws {
        let a = try Self.writeTempFile(name: "a.pdf", data: Data([0x25, 0x50]))
        let b = try Self.writeTempFile(name: "b.zip", data: Data([0x50, 0x4B]))
        defer {
            try? FileManager.default.removeItem(at: a)
            try? FileManager.default.removeItem(at: b)
        }
        let pb = freshPasteboard()
        pb.writeObjects([a as NSURL, b as NSURL])

        if case .files(let urls) = ClipboardRouter.decide(pasteboard: pb) {
            XCTAssertEqual(urls.count, 2)
        } else {
            XCTFail("expected .files for multiple URLs")
        }
    }

    // MARK: - Helpers

    private static func makeTinyPNG() -> Data {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 4, pixelsHigh: 4,
            bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 16, bitsPerPixel: 32
        )!
        return rep.representation(using: .png, properties: [:]) ?? Data()
    }

    private static func writeTempFile(name: String, data: Data) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:
```bash
cd "/Users/apple/Note taker app" && xcodebuild -project Notetaker.xcodeproj -scheme Notetaker -destination 'platform=macOS' test -only-testing:NotetakerTests/ClipboardRouterTests 2>&1 | tail -30
```
Expected: BUILD FAILS with "Cannot find 'ClipboardRouter' in scope" — that's the green-light to write the implementation.

- [ ] **Step 3: Write minimal ClipboardRouter implementation**

Create `Notetaker/Services/ClipboardRouter.swift`:

```swift
import AppKit
import Foundation

/// Pure decision over the clipboard. The `show()` handler in
/// `PanelWindowController` calls this once on every panel open
/// (when `changeCount` advanced) and switches tabs / dispatches
/// content based on what it returns.
///
/// Priority order — most specific signal wins:
///   1. Text — only when the pasteboard has plain text and NO
///      file URLs and NO image data. Routes to Notes (or Videos
///      if the text is a recognized video-host link).
///   2. Image bytes — png/tiff/etc directly on the pasteboard.
///      Browser screenshot → Images.
///   3. File URLs — peek at the extension. Image ext → Images,
///      video ext → Videos, anything else → Files.
///   4. Otherwise → no routing change.
enum RoutingDecision: Equatable {
    case notes(text: String)
    case images(data: Data, mime: String)
    case videos(url: URL)
    case files(urls: [URL])
    case none
}

enum ClipboardRouter {
    static func decide(pasteboard pb: NSPasteboard = .general) -> RoutingDecision {
        // Video-host text first — yt-dlp-able links pasted as plain
        // text should land in Videos, not Notes.
        if let candidate = VideoDropScanner.findCandidate(in: pb) {
            switch candidate {
            case .localFile(let url):
                return .videos(url: url)
            case .remoteURL(let s):
                if let url = URL(string: s) {
                    return .videos(url: url)
                }
            }
        }

        // Image bytes on the pasteboard — screenshot copies, browser
        // image-copies. Goes to Images.
        if let (data, mime) = ImageDropExtractor.extract(from: pb) {
            return .images(data: data, mime: mime)
        }

        // File URLs — split by extension. Image-ext → Images (covered
        // above by ImageDropExtractor), video-ext → Videos (covered
        // above by VideoDropScanner.localFile path). Anything left
        // → Files.
        if let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL],
           !urls.isEmpty,
           urls.allSatisfy({ $0.isFileURL }) {
            return .files(urls: urls)
        }

        // Plain text last — only fires if no file URLs were on the
        // pasteboard above. Whitespace-only strings don't count.
        if let text = pb.string(forType: .string) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return .notes(text: text)
            }
        }

        return .none
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd "/Users/apple/Note taker app" && xcodebuild -project Notetaker.xcodeproj -scheme Notetaker -destination 'platform=macOS' test -only-testing:NotetakerTests/ClipboardRouterTests 2>&1 | tail -30
```
Expected: `Test Suite 'ClipboardRouterTests' passed`. All 9 tests green.

- [ ] **Step 5: Commit**

```bash
cd "/Users/apple/Note taker app" && git add Notetaker/Services/ClipboardRouter.swift NotetakerTests/ClipboardRouterTests.swift && git commit -m "$(cat <<'EOF'
feat: ClipboardRouter — pure pasteboard → tab decision

Single static function that inspects an NSPasteboard and returns
which tab the panel should switch to on open. Reuses the existing
VideoDropScanner (so YouTube/TikTok/etc URLs route to Videos) and
ImageDropExtractor (so PNG/TIFF/etc bytes route to Images). File
URLs that aren't recognized as image or video fall through to the
new .files case. Pure / no side effects so the 9-case test suite
runs in a couple of milliseconds.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: FileStore real implementation (TDD)

Goal: replace the stub with a real in-memory store. Dedup by file URL standardised path so re-staging the same file is a no-op.

**Files:**
- Modify: `Notetaker/Services/FileStore.swift`
- Test: `NotetakerTests/FileStoreTests.swift`

- [ ] **Step 1: Write failing tests**

Create `NotetakerTests/FileStoreTests.swift`:

```swift
import XCTest
@testable import Notetaker

@MainActor
final class FileStoreTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func writeFile(name: String, bytes: Int = 64) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try Data(repeating: 0xAB, count: bytes).write(to: url)
        return url
    }

    func test_initiallyEmpty() {
        let store = FileStore()
        XCTAssertTrue(store.files.isEmpty)
    }

    func test_stage_appendsOne() throws {
        let store = FileStore()
        let url = try writeFile(name: "alpha.pdf")
        store.stage(urls: [url])
        XCTAssertEqual(store.files.count, 1)
        XCTAssertEqual(store.files.first?.displayName, "alpha.pdf")
        XCTAssertEqual(store.files.first?.sizeBytes, 64)
    }

    func test_stage_dedupesByPath() throws {
        let store = FileStore()
        let url = try writeFile(name: "beta.zip")
        store.stage(urls: [url])
        store.stage(urls: [url])
        XCTAssertEqual(store.files.count, 1)
    }

    func test_stage_acceptsMultipleAtOnce() throws {
        let store = FileStore()
        let a = try writeFile(name: "a.txt")
        let b = try writeFile(name: "b.txt")
        store.stage(urls: [a, b])
        XCTAssertEqual(store.files.count, 2)
    }

    func test_remove_dropsById() throws {
        let store = FileStore()
        let url = try writeFile(name: "c.csv")
        store.stage(urls: [url])
        let id = store.files[0].id
        store.remove(id: id)
        XCTAssertTrue(store.files.isEmpty)
    }

    func test_clearAll_emptiesEverything() throws {
        let store = FileStore()
        let a = try writeFile(name: "x.dat")
        let b = try writeFile(name: "y.dat")
        store.stage(urls: [a, b])
        store.clearAll()
        XCTAssertTrue(store.files.isEmpty)
    }

    func test_isStillResolvable_falseAfterFileDeleted() throws {
        let store = FileStore()
        let url = try writeFile(name: "ghost.tmp")
        store.stage(urls: [url])
        let staged = store.files[0]
        try FileManager.default.removeItem(at: url)
        XCTAssertFalse(store.isStillResolvable(staged))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd "/Users/apple/Note taker app" && xcodebuild -project Notetaker.xcodeproj -scheme Notetaker -destination 'platform=macOS' test -only-testing:NotetakerTests/FileStoreTests 2>&1 | tail -30
```
Expected: 6 tests FAIL — stage/remove/clearAll are no-ops in the stub from Task 1.

- [ ] **Step 3: Replace FileStore stub with real implementation**

Overwrite `Notetaker/Services/FileStore.swift`:

```swift
import AppKit
import Combine
import Foundation

/// In-memory clipboard staging. The Files tab is a "scratch pad" —
/// nothing is persisted to disk, nothing is moved or copied on the
/// filesystem. We just hold the user's URLs so they can pile a few
/// items up and copy them all out later. When the panel app quits,
/// the list is gone.
///
/// Dedup uses standardisedFileURL.path so re-staging the same file
/// (drop twice in a row, or paste the same URL twice) is a no-op
/// rather than producing duplicate cards.
@MainActor
final class FileStore: ObservableObject {
    struct StagedFile: Identifiable, Equatable {
        let id: String
        let url: URL
        let displayName: String
        let sizeBytes: Int64?
        let stagedAt: Date

        static func == (lhs: StagedFile, rhs: StagedFile) -> Bool {
            lhs.id == rhs.id
        }
    }

    @Published private(set) var files: [StagedFile] = []

    func stage(urls: [URL]) {
        var existingPaths = Set(files.map { $0.url.standardizedFileURL.path })
        var changed = false
        for url in urls {
            let path = url.standardizedFileURL.path
            guard !existingPaths.contains(path) else { continue }
            existingPaths.insert(path)
            let attrs = try? FileManager.default.attributesOfItem(atPath: path)
            let size = (attrs?[.size] as? NSNumber)?.int64Value
            let staged = StagedFile(
                id: UUID().uuidString,
                url: url.standardizedFileURL,
                displayName: url.lastPathComponent,
                sizeBytes: size,
                stagedAt: Date()
            )
            files.append(staged)
            changed = true
        }
        if changed {
            // Newest at top — feels right for a scratch-pad list.
            files.sort { $0.stagedAt > $1.stagedAt }
        }
    }

    func remove(id: String) {
        files.removeAll { $0.id == id }
    }

    func clearAll() {
        files.removeAll()
    }

    /// Cheap existence check used by the UI to fade out cards whose
    /// underlying file was deleted/moved while staged.
    func isStillResolvable(_ file: StagedFile) -> Bool {
        FileManager.default.fileExists(atPath: file.url.standardizedFileURL.path)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd "/Users/apple/Note taker app" && xcodebuild -project Notetaker.xcodeproj -scheme Notetaker -destination 'platform=macOS' test -only-testing:NotetakerTests/FileStoreTests 2>&1 | tail -30
```
Expected: 6 tests PASS.

- [ ] **Step 5: Commit**

```bash
cd "/Users/apple/Note taker app" && git add Notetaker/Services/FileStore.swift NotetakerTests/FileStoreTests.swift && git commit -m "$(cat <<'EOF'
feat: FileStore — in-memory staging with path-dedup

Replaces the Task-1 stub with a real ObservableObject. Stage by
URL, dedup by standardisedFileURL.path so the same file dropped
twice doesn't produce two cards, sort newest-first. No disk
persistence, no copying — just URL bookkeeping. isStillResolvable
lets the UI fade out cards whose underlying file was deleted.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: ClipboardService.copy(fileURLs:) (TDD)

Goal: a "Copy all" button on the Files tab needs a way to dump multiple file URLs back onto the system pasteboard. Existing `copy(images:fileURLs:)` requires images alongside, so we need a files-only path.

**Files:**
- Modify: `Notetaker/Services/ClipboardService.swift`
- Modify: `NotetakerTests/ClipboardServiceTests.swift` (add one test)

- [ ] **Step 1: Write failing test**

Append to `NotetakerTests/ClipboardServiceTests.swift` inside the existing `final class ClipboardServiceTests: XCTestCase`:

```swift
    func test_copyFileURLs_writesURLsToPasteboard() {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("CopyTest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let a = tmp.appendingPathComponent("one.pdf")
        let b = tmp.appendingPathComponent("two.zip")
        try? Data([0x25, 0x50]).write(to: a)
        try? Data([0x50, 0x4B]).write(to: b)
        defer { try? FileManager.default.removeItem(at: tmp) }

        ClipboardService.copy(fileURLs: [a, b])

        let urls = NSPasteboard.general.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []
        XCTAssertEqual(urls.count, 2)
        XCTAssertEqual(urls.map { $0.lastPathComponent }, ["one.pdf", "two.zip"])
    }
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd "/Users/apple/Note taker app" && xcodebuild -project Notetaker.xcodeproj -scheme Notetaker -destination 'platform=macOS' test -only-testing:NotetakerTests/ClipboardServiceTests/test_copyFileURLs_writesURLsToPasteboard 2>&1 | tail -20
```
Expected: BUILD FAILS with "no exact matches in call to static method 'copy'" or similar.

- [ ] **Step 3: Add copy(fileURLs:) to ClipboardService**

In `Notetaker/Services/ClipboardService.swift`, after the existing `copy(note:attachedImages:)` method (around line 57) and before `// MARK: - Drag Monitor`, add:

```swift
    /// Files-only paste payload. Used by the Files-tab "Copy all"
    /// button. NSPasteboard.writeObjects with NSURLs round-trips
    /// cleanly to Finder, browser file inputs, and other apps that
    /// accept file URLs.
    static func copy(fileURLs: [URL]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(fileURLs.map { $0 as NSURL })
        ClipboardMonitor.shared?.acknowledge()
    }
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd "/Users/apple/Note taker app" && xcodebuild -project Notetaker.xcodeproj -scheme Notetaker -destination 'platform=macOS' test -only-testing:NotetakerTests/ClipboardServiceTests 2>&1 | tail -20
```
Expected: all ClipboardServiceTests pass (3 tests).

- [ ] **Step 5: Commit**

```bash
cd "/Users/apple/Note taker app" && git add Notetaker/Services/ClipboardService.swift NotetakerTests/ClipboardServiceTests.swift && git commit -m "$(cat <<'EOF'
feat: ClipboardService.copy(fileURLs:) for files-only payloads

Existing copy(images:fileURLs:) ties URLs to images by index — no
good for the Files tab's "Copy all" button where there are no
images. New overload writes plain NSURLs via writeObjects so Finder
and browser file inputs accept the paste cleanly.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: FilesGridView + FileRow UI

Goal: the actual Files tab UI. Empty state, scrolling list of card rows showing icon + filename + size, hover/remove affordances, "Copy all" + "Clear" toolbar.

**Files:**
- Modify: `Notetaker/Panel/FilesGridView.swift` (replace stub)

No tests — this is pure UI.

- [ ] **Step 1: Replace FilesGridView stub with full UI**

Overwrite `Notetaker/Panel/FilesGridView.swift`:

```swift
import SwiftUI
import AppKit

struct FilesGridView: View {
    @EnvironmentObject var fileStore: FileStore

    var body: some View {
        VStack(spacing: 0) {
            if fileStore.files.isEmpty {
                emptyState
            } else {
                toolbar
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: DS.Spacing.sm) {
                        ForEach(fileStore.files) { file in
                            FileRow(file: file) {
                                fileStore.remove(id: file.id)
                                NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
                            }
                            .transition(.asymmetric(
                                insertion: .scale(scale: 0.92).combined(with: .opacity),
                                removal: .opacity.combined(with: .scale(scale: 0.96))
                            ))
                        }
                    }
                    .padding(.horizontal, DS.Spacing.md)
                    .padding(.vertical, DS.Spacing.sm)
                    .animation(.spring(response: 0.32, dampingFraction: 0.74), value: fileStore.files.map(\.id))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: DS.Spacing.md) {
            ZStack {
                RadialGradient(
                    colors: [
                        DS.Color.accent.opacity(0.18),
                        DS.Color.accent.opacity(0.02),
                        Color.clear
                    ],
                    center: .center,
                    startRadius: 0,
                    endRadius: 70
                )
                .frame(width: 140, height: 140)
                Image(systemName: "tray.full")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(DS.Color.textSecondary)
            }
            Text("Drop files here")
                .font(.nkBody)
                .foregroundStyle(DS.Color.textSecondary)
            Text("Stage anything you need to paste later — nothing is saved.")
                .font(.nkMeta)
                .foregroundStyle(DS.Color.textTertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, DS.Spacing.xl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var toolbar: some View {
        HStack(spacing: DS.Spacing.sm) {
            Text("\(fileStore.files.count) staged")
                .font(.nkMeta)
                .foregroundStyle(DS.Color.textTertiary)
            Spacer()
            Button {
                ClipboardService.copy(fileURLs: fileStore.files.map(\.url))
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            } label: {
                Label("Copy all", systemImage: "doc.on.doc")
                    .font(.nkMeta.weight(.medium))
                    .foregroundStyle(DS.Color.textPrimary)
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.plain)
            Button {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.74)) {
                    fileStore.clearAll()
                }
                NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
            } label: {
                Label("Clear", systemImage: "xmark.circle")
                    .font(.nkMeta.weight(.medium))
                    .foregroundStyle(DS.Color.textSecondary)
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, DS.Spacing.md)
        .padding(.top, DS.Spacing.sm)
        .padding(.bottom, DS.Spacing.xs)
    }
}

private struct FileRow: View {
    let file: FileStore.StagedFile
    let onRemove: () -> Void

    @State private var hovered = false

    var body: some View {
        HStack(spacing: DS.Spacing.md) {
            // Finder icon — exact same Quick Look icon the user sees
            // when looking at the file in Finder. Cheap to fetch
            // and keeps the row instantly recognisable.
            Image(nsImage: NSWorkspace.shared.icon(forFile: file.url.path))
                .resizable()
                .interpolation(.high)
                .frame(width: 28, height: 28)
                .shadow(color: .black.opacity(0.25), radius: 1.5, y: 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(file.displayName)
                    .font(.nkBody.weight(.medium))
                    .foregroundStyle(DS.Color.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(meta)
                    .font(.nkMeta)
                    .foregroundStyle(DS.Color.textTertiary)
            }
            Spacer(minLength: 0)
            if hovered {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(DS.Color.textSecondary)
                }
                .buttonStyle(.plain)
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .padding(.horizontal, DS.Spacing.md)
        .padding(.vertical, DS.Spacing.sm)
        .frame(minHeight: 56)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(hovered ? 0.07 : 0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(0.18), Color.white.opacity(0.04)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 0.6
                )
        )
        .shadow(color: .black.opacity(0.45), radius: hovered ? 12 : 8, x: 0, y: hovered ? 6 : 4)
        .shadow(color: .black.opacity(0.18), radius: 1, x: 0, y: 1)
        .offset(y: hovered ? -2 : 0)
        .onHover { isHovering in
            withAnimation(.spring(response: 0.32, dampingFraction: 0.74)) {
                hovered = isHovering
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onDrag {
            // Lets the user pick a card up and drag it back out into
            // Finder, an upload field, etc. — the whole point of the
            // tab is to be a re-paste source.
            NSItemProvider(contentsOf: file.url) ?? NSItemProvider()
        }
    }

    private var meta: String {
        var bits: [String] = [file.url.pathExtension.uppercased()]
            .filter { !$0.isEmpty }
        if let bytes = file.sizeBytes {
            bits.append(Self.formatSize(bytes))
        }
        return bits.joined(separator: " · ")
    }

    private static func formatSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

```bash
cd "/Users/apple/Note taker app" && xcodebuild -project Notetaker.xcodeproj -scheme Notetaker -configuration Debug build 2>&1 | tail -25
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
cd "/Users/apple/Note taker app" && git add Notetaker/Panel/FilesGridView.swift && git commit -m "$(cat <<'EOF'
feat: FilesGridView UI — empty state, cards, copy/clear toolbar

Premium card aesthetic matching the photo grid (14pt pillows,
double shadow, gradient stroke, hover lift, levelChange haptic on
remove). Empty state uses the accent radial blob + tray icon. Each
row shows the real Finder icon for instant recognition, drag-out
support so the user can pull cards back into other apps, hover
reveals an X to remove. Toolbar exposes "Copy all" (haptic
.alignment) and "Clear" (haptic .levelChange).

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: PanelDropContainer onFile hook

Goal: extend the panel-level NSView drop catcher so a generic-file drop (anything that wasn't recognized as a video or an image) lands in the Files tab.

**Files:**
- Modify: `Notetaker/Panel/VideoDropCatcher.swift` (PanelDropContainer struct)

No new tests — drop routing is exercised manually below.

- [ ] **Step 1: Add onFile callback to PanelDropContainer**

In `Notetaker/Panel/VideoDropCatcher.swift`, replace the PanelDropContainer init (currently lines 17-37) and performDragOperation method (lines 54-75):

```swift
final class PanelDropContainer: NSView {
    let onVideo: (VideoDropScanner.Candidate) -> Void
    let onImage: (Data, String) -> Void
    let onFile: ([URL]) -> Void
    let onTargeted: (Bool) -> Void

    init(
        hosting: NSView,
        onVideo: @escaping (VideoDropScanner.Candidate) -> Void,
        onImage: @escaping (Data, String) -> Void,
        onFile: @escaping ([URL]) -> Void,
        onTargeted: @escaping (Bool) -> Void
    ) {
        self.onVideo = onVideo
        self.onImage = onImage
        self.onFile = onFile
        self.onTargeted = onTargeted
        super.init(frame: .zero)
        autoresizesSubviews = true
        addSubview(hosting)
        hosting.autoresizingMask = [.width, .height]
        hosting.frame = bounds
        registerForDraggedTypes(Self.allTypes)
    }

    required init?(coder: NSCoder) { fatalError() }
```

And update `performDragOperation` to insert a generic-file branch BEFORE the reject:

```swift
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        DispatchQueue.main.async { [weak self] in self?.onTargeted(false) }
        let pb = sender.draggingPasteboard

        // Video first — it's the most specific signal. A YouTube link
        // pasted as plain text would also match the image-data path
        // below if we didn't lead with the video scanner.
        if let candidate = VideoDropScanner.findCandidate(in: pb) {
            NSLog("Notetaker: drop → video candidate")
            DispatchQueue.main.async { [weak self] in self?.onVideo(candidate) }
            return true
        }
        // Image next — png/tiff/jpeg directly on the pasteboard, or a
        // file URL pointing at an image extension.
        if let (data, mime) = ImageDropExtractor.extract(from: pb) {
            NSLog("Notetaker: drop → image (\(mime), \(data.count) bytes)")
            DispatchQueue.main.async { [weak self] in self?.onImage(data, mime) }
            return true
        }
        // Generic file URLs — falls through to the Files tab as a
        // pure staging operation (we never copy the file, just hold
        // the URL). Anything that wasn't a video or image goes here.
        if let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL] {
            let fileUrls = urls.filter { $0.isFileURL }
            if !fileUrls.isEmpty {
                NSLog("Notetaker: drop → \(fileUrls.count) file(s)")
                DispatchQueue.main.async { [weak self] in self?.onFile(fileUrls) }
                return true
            }
        }
        NSLog("Notetaker: drop → no candidate, rejecting; types=\(pb.types ?? [])")
        return false
    }
```

- [ ] **Step 2: Update PanelWindowController call site**

In `Notetaker/Panel/PanelWindowController.swift`, find the `PanelDropContainer(...)` construction (around line 114-144). Add the `onFile` closure and update `presenter.activeTab` accordingly:

```swift
        let container = PanelDropContainer(
            hosting: host,
            onVideo: { [weak presenter, weak environment] candidate in
                guard let presenter, let environment else { return }
                switch candidate {
                case .localFile(let url):
                    _ = try? environment.videoStore.saveLocalFile(url)
                case .remoteURL(let s):
                    _ = environment.videoStore.startDownload(url: s)
                }
                presenter.activeTab = .videos
            },
            onImage: { [weak presenter, weak environment] data, mime in
                guard let presenter, let environment else { return }
                environment.imageStore.saveImageDeferred(
                    data: data,
                    mimeType: mime,
                    noteId: nil,
                    source: "drop"
                )
                presenter.activeTab = .images
            },
            onFile: { [weak presenter, weak environment] urls in
                guard let presenter, let environment else { return }
                environment.fileStore.stage(urls: urls)
                presenter.activeTab = .files
                NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
            },
            onTargeted: { [weak presenter] flag in
                presenter?.isDropTargeted = flag
            }
        )
```

- [ ] **Step 3: Build to verify**

```bash
cd "/Users/apple/Note taker app" && xcodebuild -project Notetaker.xcodeproj -scheme Notetaker -configuration Debug build 2>&1 | tail -20
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
cd "/Users/apple/Note taker app" && git add Notetaker/Panel/VideoDropCatcher.swift Notetaker/Panel/PanelWindowController.swift && git commit -m "$(cat <<'EOF'
feat: PanelDropContainer onFile — drop generic files into Files tab

Adds a fourth callback to the panel-level drop catcher. Anything
that isn't a recognized video (yt-dlp candidate or local mp4/mov/etc)
or image (png/tiff bytes or image-extension file URL) but is still
a file URL now stages into FileStore and switches to the Files tab,
with a levelChange haptic. Files are never copied — we hold URLs
only, matching the "no save" contract.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: Smart auto-routing in show()

Goal: when the panel opens, peek at the system clipboard. If the user copied something since the last hide(), route the active tab automatically.

**Files:**
- Modify: `Notetaker/Panel/PanelWindowController.swift`
- Modify: `Notetaker/Services/NoteStore.swift` — read-only check, no edit needed (uses existing createNote + updateBody)

- [ ] **Step 1: Add lastSeenChangeCount field + auto-route in show()**

In `Notetaker/Panel/PanelWindowController.swift`, add a property near the other state fields (around line 58):

```swift
    private var hideWorkItem: DispatchWorkItem?
    /// `NSPasteboard.general.changeCount` captured at the last hide().
    /// Initialized to -1 so the very first show() always evaluates the
    /// clipboard. Updated on every hide() so we only re-route when
    /// the user has actually copied something new in between.
    private var lastSeenChangeCount: Int = -1
```

Then, near the top of `show()` (right after `hideWorkItem?.cancel(); hideWorkItem = nil`), add the routing dispatch:

```swift
    func show() {
        hideWorkItem?.cancel()
        hideWorkItem = nil

        // Smart auto-routing — only fires if the clipboard has
        // changed since the last hide(). Avoids the annoying case
        // where the user closes the panel on Notes, switches apps,
        // and reopens the panel only to be teleported off Notes
        // because there's still a stale text payload on the clipboard.
        let currentCount = NSPasteboard.general.changeCount
        if currentCount != lastSeenChangeCount {
            applyAutoRouting()
        }
        lastSeenChangeCount = currentCount

        let size = PanelWindowController.panelSize(for: NSScreen.main)
        // ... rest of show() unchanged ...
```

And in `hide()`, capture changeCount right after the `guard isVisible else { return }`:

```swift
    func hide() {
        NSLog("Notetaker: hide() called, isVisible=\(isVisible)")
        guard isVisible else { return }
        // Snapshot the clipboard so the next show() can tell whether
        // the user copied something new in between.
        lastSeenChangeCount = NSPasteboard.general.changeCount
        removeMonitors()
        // ... rest unchanged ...
```

- [ ] **Step 2: Add applyAutoRouting method**

Add this method to `PanelWindowController` (near the other private helpers, e.g. just before `removeMonitors()`):

```swift
    /// Calls into ClipboardRouter and reacts to its decision. Only
    /// invoked when changeCount has advanced since the last hide().
    private func applyAutoRouting() {
        let decision = ClipboardRouter.decide()
        NSLog("Notetaker: auto-route decision = \(decision)")
        switch decision {
        case .none:
            return
        case .notes(let text):
            do {
                let note = try environment.noteStore.createNote()
                try environment.noteStore.updateBody(id: note.id, body: text)
                presenter.activeTab = .notes
            } catch {
                NSLog("Notetaker: auto-route notes failed: \(error)")
            }
        case .images(let data, let mime):
            environment.imageStore.saveImageDeferred(
                data: data,
                mimeType: mime,
                noteId: nil,
                source: "clipboard"
            )
            presenter.activeTab = .images
        case .videos(let url):
            if url.isFileURL {
                _ = try? environment.videoStore.saveLocalFile(url)
            } else {
                _ = environment.videoStore.startDownload(url: url.absoluteString)
            }
            presenter.activeTab = .videos
        case .files(let urls):
            environment.fileStore.stage(urls: urls)
            presenter.activeTab = .files
        }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }
```

- [ ] **Step 3: Build to verify**

```bash
cd "/Users/apple/Note taker app" && xcodebuild -project Notetaker.xcodeproj -scheme Notetaker -configuration Debug build 2>&1 | tail -25
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
cd "/Users/apple/Note taker app" && git add Notetaker/Panel/PanelWindowController.swift && git commit -m "$(cat <<'EOF'
feat: smart auto-routing on panel open

show() now peeks at the system clipboard via ClipboardRouter and
switches to the matching tab — text → Notes (creates a new note
pre-filled with the clipboard contents), image bytes → Images,
video link or local mp4 → Videos, generic file URL → Files.
Only fires when NSPasteboard.changeCount has advanced since the
last hide() so reopening on the same content doesn't bounce the
user out of whatever tab they were on. Alignment haptic on every
auto-route so the routing feels intentional.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

### Task 8: Full build, test sweep, manual smoke, ship commit

Goal: prove the whole stack works end-to-end and lock the sub-project.

- [ ] **Step 1: Full build**

```bash
cd "/Users/apple/Note taker app" && xcodebuild -project Notetaker.xcodeproj -scheme Notetaker -configuration Debug build 2>&1 | tail -20
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 2: Full test sweep**

```bash
cd "/Users/apple/Note taker app" && xcodebuild -project Notetaker.xcodeproj -scheme Notetaker -destination 'platform=macOS' test 2>&1 | tail -40
```
Expected: ALL tests pass — pre-existing suites (NoteStore, Database, Retention, Image, Clipboard) plus the two new ones (ClipboardRouter, FileStore). Failure here means Task 7 broke a regression — fix before shipping.

- [ ] **Step 3: Manual smoke — auto-routing**

Launch the app, open the panel with ⌥Space.

1. Switch focus to a text editor, copy "hello", reopen the panel → lands on Notes with a new note containing "hello". ✅
2. Open Finder, copy a `.png` (cmd-C on a Finder file is a file URL copy), reopen the panel → lands on Images, screenshot fades in. ✅
3. Copy a YouTube URL from Safari, reopen the panel → lands on Videos, download starts. ✅
4. Copy a `.pdf` from Finder, reopen the panel → lands on Files, the staged card shows. ✅
5. Reopen the panel without copying anything new → stays on whatever tab you closed on. ✅

- [ ] **Step 4: Manual smoke — Files tab interactions**

1. Drag a Finder file onto the panel → Files tab activates, card slides in, levelChange haptic fires. ✅
2. Drag a second different file → second card stacks on top, newest first. ✅
3. Drag the same file again → no duplicate card (dedup works). ✅
4. Hover a card → X appears, card lifts 2pt. ✅
5. Click X → card slides/scales out. ✅
6. Click "Copy all" → switch to Finder, Cmd-V into a folder → both files paste in (or cmd-tab to TextEdit and the file paths show up). ✅
7. Click "Clear" → list empties with a spring fade. ✅
8. Drag a card OUT of the panel into Finder → a copy/move offers (drag-back-out works). ✅
9. Quit and relaunch the app → Files list is empty (no persistence, as designed). ✅

- [ ] **Step 5: Final ship commit**

If anything tweaked during smoke, commit it. Otherwise tag the milestone:

```bash
cd "/Users/apple/Note taker app" && git log --oneline -10
```
Confirm the chain of commits from Task 1 → Task 7 is intact, then move on. No additional ship commit needed — the per-task commits are the trail.

---

## Done Criteria

- 4-segment pill renders Notes / Images / Videos / Files.
- All test suites pass.
- Auto-routing fires on panel open when clipboard advanced.
- Drag-into-panel of a generic file lands in Files tab.
- Files tab supports stage / dedup / remove / clear / copy-all / drag-out.
- Files tab is empty after relaunch (no persistence).
- No regressions in Notes / Images / Videos behavior.
- Commits land sequentially without amends.
