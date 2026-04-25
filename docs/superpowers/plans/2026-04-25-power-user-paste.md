# Power-User Paste Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land four ClipBook-inspired upgrades to Notetaker — privacy filter, ⌘1–⌘9 quick paste, OCR, and link previews — each as an independent commit, with TDD coverage.

**Architecture:** Each feature is independent and shares no state with the others. Privacy filter sits at the top of `ClipboardRouter.decide()`. Quick paste extracts a pure helper (`QuickPasteRouter`) for testability and wires a local `NSEvent` monitor in `PanelWindowController`. OCR adds a `Services/ImageOCRService.swift` invoked from `ImagesGridView`'s context menu. Link previews add a `Services/LinkPreviewService.swift` (LPMetadataProvider-backed, NSCache-memoized) plus a `Utils/URLExtractor.swift` (NSDataDetector-backed), surfaced in the existing `NoteRow`.

**Tech Stack:** Swift 5, AppKit, SwiftUI, XCTest, Vision, LinkPresentation, NSDataDetector.

---

## File Structure

**New files:**
- `Notetaker/Services/QuickPasteRouter.swift` — pure helper that decides what the Nth item of the active tab is.
- `Notetaker/Services/ImageOCRService.swift` — Vision-backed text extraction.
- `Notetaker/Services/LinkPreviewService.swift` — `LPMetadataProvider` wrapper with `NSCache` memo.
- `Notetaker/Utils/URLExtractor.swift` — `NSDataDetector`-backed URL finder.
- `NotetakerTests/QuickPasteRouterTests.swift`
- `NotetakerTests/ImageOCRServiceTests.swift`
- `NotetakerTests/URLExtractorTests.swift`

**Modified files:**
- `Notetaker/Services/ClipboardRouter.swift` — privacy guard at top of `decide()`.
- `NotetakerTests/ClipboardRouterTests.swift` — two new privacy cases.
- `Notetaker/App/AppEnvironment.swift` — wire `LinkPreviewService` into env.
- `Notetaker/Panel/PanelWindowController.swift` — local NSEvent monitor for ⌘1–⌘9; inject `linkPreviewService` into hosting view.
- `Notetaker/Panel/ImagesGridView.swift` — context menu `Copy text from image`.
- `Notetaker/Panel/NotesListView.swift` — `NoteRow` shows `[favicon] host · time` chip when body has a URL.

---

### Task 1: Privacy filter — Concealed/Transient pasteboard types

**Files:**
- Modify: `Notetaker/Services/ClipboardRouter.swift`
- Modify: `NotetakerTests/ClipboardRouterTests.swift`

- [ ] **Step 1: Write the two failing tests**

Add to `ClipboardRouterTests`:

```swift
func test_concealedType_returnsNone() {
    let pb = freshPasteboard()
    let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    pb.declareTypes([.string, concealed], owner: nil)
    pb.setString("supersecret", forType: .string)
    pb.setData(Data([0x01]), forType: concealed)
    XCTAssertEqual(ClipboardRouter.decide(pasteboard: pb), .none)
}

func test_transientType_returnsNone() {
    let pb = freshPasteboard()
    let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    pb.declareTypes([.string, transient], owner: nil)
    pb.setString("ephemeral", forType: .string)
    pb.setData(Data([0x01]), forType: transient)
    XCTAssertEqual(ClipboardRouter.decide(pasteboard: pb), .none)
}
```

- [ ] **Step 2: Run the new tests to verify RED**

Run: `xcodebuild test -scheme Notetaker -only-testing:NotetakerTests/ClipboardRouterTests/test_concealedType_returnsNone -only-testing:NotetakerTests/ClipboardRouterTests/test_transientType_returnsNone`
Expected: both fail (router currently returns `.notes(...)`).

- [ ] **Step 3: Add the privacy guard to `ClipboardRouter.decide()`**

Insert at the very top of `ClipboardRouter.decide(pasteboard:)`:

```swift
let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
if let types = pb.types, types.contains(concealed) || types.contains(transient) {
    return .none
}
```

- [ ] **Step 4: Run all router tests to confirm GREEN**

Run: `xcodebuild test -scheme Notetaker -only-testing:NotetakerTests/ClipboardRouterTests`
Expected: all pass (the two new + every existing case).

- [ ] **Step 5: Commit**

```bash
git add Notetaker/Services/ClipboardRouter.swift NotetakerTests/ClipboardRouterTests.swift
git commit -m "feat: ClipboardRouter honors Concealed/Transient pasteboard types"
```

---

### Task 2: Quick paste ⌘1–⌘9

**Files:**
- Create: `Notetaker/Services/QuickPasteRouter.swift`
- Create: `NotetakerTests/QuickPasteRouterTests.swift`
- Modify: `Notetaker/Panel/PanelWindowController.swift`

- [ ] **Step 1: Write the failing test for `QuickPasteRouter`**

Create `NotetakerTests/QuickPasteRouterTests.swift`:

```swift
import XCTest
@testable import Notetaker

final class QuickPasteRouterTests: XCTestCase {
    func test_files_returnsNthURL() throws {
        let urls = try (0..<3).map { i -> URL in
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("f\(i).txt")
            try Data("hi".utf8).write(to: url)
            return url
        }
        defer { urls.forEach { try? FileManager.default.removeItem(at: $0.deletingLastPathComponent()) } }

        let result = QuickPasteRouter.itemAt(index: 1, urls: urls)
        if case .fileURL(let u) = result {
            XCTAssertEqual(u.lastPathComponent, "f1.txt")
        } else { XCTFail("expected .fileURL") }
    }

    func test_outOfRange_returnsNone() {
        XCTAssertEqual(QuickPasteRouter.itemAt(index: 5, urls: []), .none)
    }

    func test_text_returnsNthString() {
        let result = QuickPasteRouter.itemAt(index: 0, texts: ["alpha", "beta"])
        if case .text(let s) = result {
            XCTAssertEqual(s, "alpha")
        } else { XCTFail("expected .text") }
    }
}
```

- [ ] **Step 2: Run to verify RED**

Run: `xcodebuild test -scheme Notetaker -only-testing:NotetakerTests/QuickPasteRouterTests`
Expected: compile error — `QuickPasteRouter` not defined.

- [ ] **Step 3: Implement `QuickPasteRouter`**

Create `Notetaker/Services/QuickPasteRouter.swift`:

```swift
import Foundation

/// Pure helper for ⌘1–⌘9 quick paste. Given an index and a per-tab
/// payload, returns what should be re-copied to the system clipboard.
/// Kept pure so it can be unit-tested without spinning up stores or
/// the panel window.
enum QuickPasteRouter {
    enum Item: Equatable {
        case text(String)
        case fileURL(URL)
        case none
    }

    static func itemAt(index: Int, texts: [String]) -> Item {
        guard index >= 0, index < texts.count else { return .none }
        return .text(texts[index])
    }

    static func itemAt(index: Int, urls: [URL]) -> Item {
        guard index >= 0, index < urls.count else { return .none }
        return .fileURL(urls[index])
    }
}
```

- [ ] **Step 4: Run to verify GREEN**

Run: `xcodebuild test -scheme Notetaker -only-testing:NotetakerTests/QuickPasteRouterTests`
Expected: 3/3 pass.

- [ ] **Step 5: Wire ⌘1–⌘9 NSEvent monitor in `PanelWindowController`**

In `PanelWindowController`, add a private property:

```swift
private var quickPasteMonitor: Any?
```

In `show()`, just before the existing `keyMonitor = NSEvent.addLocalMonitorForEvents...`, install:

```swift
quickPasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
    guard let self else { return event }
    guard event.modifierFlags.intersection([.command, .control, .option]) == .command else { return event }
    let chars = event.charactersIgnoringModifiers ?? ""
    guard chars.count == 1, let digit = chars.first?.wholeNumberValue, (1...9).contains(digit) else {
        return event
    }
    if self.handleQuickPaste(index: digit - 1) {
        return nil
    }
    return event
}
```

Add the handler method:

```swift
@discardableResult
private func handleQuickPaste(index: Int) -> Bool {
    switch presenter.activeTab {
    case .notes:
        let texts = environment.noteStore.notes.prefix(9).map(\.body)
        if case .text(let s) = QuickPasteRouter.itemAt(index: index, texts: Array(texts)) {
            ClipboardService.copy(text: s)
            quickPasteFeedback()
            return true
        }
    case .images:
        let urls = environment.imageStore.images.prefix(9).map { environment.imageStore.fullURL(for: $0) }
        if case .fileURL(let u) = QuickPasteRouter.itemAt(index: index, urls: Array(urls)) {
            if let img = NSImage(contentsOf: u) {
                ClipboardService.copy(images: [img], fileURLs: [u])
                quickPasteFeedback()
                return true
            }
        }
    case .videos:
        let urls = environment.videoStore.videos.prefix(9).compactMap { rec -> URL? in
            guard let path = rec.localPath else { return nil }
            return URL(fileURLWithPath: path)
        }
        if case .fileURL(let u) = QuickPasteRouter.itemAt(index: index, urls: Array(urls)) {
            ClipboardService.copy(fileURLs: [u])
            quickPasteFeedback()
            return true
        }
    case .files:
        let urls = environment.fileStore.files.prefix(9).map(\.url)
        if case .fileURL(let u) = QuickPasteRouter.itemAt(index: index, urls: Array(urls)) {
            ClipboardService.copy(fileURLs: [u])
            quickPasteFeedback()
            return true
        }
    }
    return false
}

private func quickPasteFeedback() {
    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
        self?.hide()
    }
}
```

In `removeMonitors()`, add:

```swift
if let monitor = quickPasteMonitor {
    NSEvent.removeMonitor(monitor)
    quickPasteMonitor = nil
}
```

NOTE: `videoStore.videos` may not be the exact accessor — read VideoStore.swift in the implementation step and substitute the right `[VideoRecord]` accessor (likely `completedVideos` or `videos`). If the videos accessor uses a different shape (e.g. only-completed vs in-flight jobs), filter to terminal/completed ones before mapping.

- [ ] **Step 6: Build and smoke test**

Run: `xcodebuild build -scheme Notetaker`
Expected: no compile errors.

Manual: open the panel via ⌥Space with at least 1 note and 1 file. Press ⌘1 — clipboard should now hold the first item; the panel should hide ~180ms later.

- [ ] **Step 7: Commit**

```bash
git add Notetaker/Services/QuickPasteRouter.swift NotetakerTests/QuickPasteRouterTests.swift Notetaker/Panel/PanelWindowController.swift
git commit -m "feat: ⌘1–⌘9 quick paste routes Nth item of active tab"
```

---

### Task 3: OCR — Copy Text from Image

**Files:**
- Create: `Notetaker/Services/ImageOCRService.swift`
- Create: `NotetakerTests/ImageOCRServiceTests.swift`
- Modify: `Notetaker/Panel/ImagesGridView.swift`

- [ ] **Step 1: Write the failing test**

Create `NotetakerTests/ImageOCRServiceTests.swift`:

```swift
import XCTest
import AppKit
@testable import Notetaker

final class ImageOCRServiceTests: XCTestCase {
    func test_extractsRenderedText() async throws {
        let url = try Self.renderTestImage(text: "Hello Notetaker")
        defer { try? FileManager.default.removeItem(at: url) }

        let result = await ImageOCRService.extractText(from: url)
        let extracted = try XCTUnwrap(result)
        XCTAssertTrue(extracted.localizedCaseInsensitiveContains("hello"),
                      "expected 'hello' in OCR output, got: \(extracted)")
    }

    private static func renderTestImage(text: String) throws -> URL {
        let size = NSSize(width: 480, height: 120)
        let img = NSImage(size: size)
        img.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 48, weight: .semibold),
            .foregroundColor: NSColor.black
        ]
        NSAttributedString(string: text, attributes: attrs)
            .draw(at: NSPoint(x: 20, y: 30))
        img.unlockFocus()

        let tiff = try XCTUnwrap(img.tiffRepresentation)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("ocr.png")
        try png.write(to: url)
        return url
    }
}
```

- [ ] **Step 2: Run to verify RED**

Run: `xcodebuild test -scheme Notetaker -only-testing:NotetakerTests/ImageOCRServiceTests`
Expected: compile error — `ImageOCRService` undefined.

- [ ] **Step 3: Implement `ImageOCRService`**

Create `Notetaker/Services/ImageOCRService.swift`:

```swift
import Vision
import AppKit

/// Vision-backed text extraction. Async because Vision gates a
/// real ML model load that can take ~hundreds of milliseconds the
/// first time the recognizer runs.
enum ImageOCRService {
    /// Runs Vision text recognition on the image at the given URL.
    /// Returns a single concatenated string (joined by newlines)
    /// of all recognized observations, or nil if no text was found.
    static func extractText(from url: URL) async -> String? {
        guard let cgImage = loadCGImage(at: url) else { return nil }
        return await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            let request = VNRecognizeTextRequest { req, _ in
                guard let results = req.results as? [VNRecognizedTextObservation] else {
                    cont.resume(returning: nil); return
                }
                let lines = results.compactMap { $0.topCandidates(1).first?.string }
                cont.resume(returning: lines.isEmpty ? nil : lines.joined(separator: "\n"))
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            let handler = VNImageRequestHandler(cgImage: cgImage)
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try handler.perform([request])
                } catch {
                    cont.resume(returning: nil)
                }
            }
        }
    }

    private static func loadCGImage(at url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }
}
```

- [ ] **Step 4: Run to verify GREEN**

Run: `xcodebuild test -scheme Notetaker -only-testing:NotetakerTests/ImageOCRServiceTests`
Expected: passes (Vision warmup may take ~1s).

- [ ] **Step 5: Wire context menu in `ImagesGridView`**

In `ImageCell.body`, add a `.contextMenu` after the `.contentShape(shape)` line:

```swift
.contextMenu {
    Button("Copy text from image") {
        let url = imageStore.fullURL(for: record)
        Task {
            if let text = await ImageOCRService.extractText(from: url) {
                ClipboardService.copy(text: text)
                await MainActor.run {
                    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                }
            }
        }
    }
}
```

- [ ] **Step 6: Build**

Run: `xcodebuild build -scheme Notetaker`
Expected: succeeds.

- [ ] **Step 7: Commit**

```bash
git add Notetaker/Services/ImageOCRService.swift NotetakerTests/ImageOCRServiceTests.swift Notetaker/Panel/ImagesGridView.swift
git commit -m "feat: OCR — Copy Text from Image via Vision"
```

---

### Task 4: Link preview cards in Notes

**Files:**
- Create: `Notetaker/Utils/URLExtractor.swift`
- Create: `Notetaker/Services/LinkPreviewService.swift`
- Create: `NotetakerTests/URLExtractorTests.swift`
- Modify: `Notetaker/App/AppEnvironment.swift`
- Modify: `Notetaker/Panel/PanelWindowController.swift`
- Modify: `Notetaker/Panel/NotesListView.swift`

- [ ] **Step 1: Write `URLExtractorTests`**

Create `NotetakerTests/URLExtractorTests.swift`:

```swift
import XCTest
@testable import Notetaker

final class URLExtractorTests: XCTestCase {
    func test_plainHTTPURL() {
        XCTAssertEqual(
            URLExtractor.firstHTTPURL(in: "https://github.com")?.absoluteString,
            "https://github.com"
        )
    }
    func test_urlInsideText() {
        XCTAssertEqual(
            URLExtractor.firstHTTPURL(in: "see https://example.com please")?.host,
            "example.com"
        )
    }
    func test_noURL() {
        XCTAssertNil(URLExtractor.firstHTTPURL(in: "no link here"))
    }
    func test_multipleURLs_returnsFirst() {
        XCTAssertEqual(
            URLExtractor.firstHTTPURL(in: "https://a.com and https://b.com")?.host,
            "a.com"
        )
    }
    func test_fileURL_ignored() {
        XCTAssertNil(URLExtractor.firstHTTPURL(in: "file:///tmp/x.txt"))
    }
    func test_mailto_ignored() {
        XCTAssertNil(URLExtractor.firstHTTPURL(in: "mailto:foo@bar.com"))
    }
    func test_emptyString() {
        XCTAssertNil(URLExtractor.firstHTTPURL(in: ""))
    }
}
```

- [ ] **Step 2: Run to verify RED**

Run: `xcodebuild test -scheme Notetaker -only-testing:NotetakerTests/URLExtractorTests`
Expected: compile error — `URLExtractor` undefined.

- [ ] **Step 3: Implement `URLExtractor`**

Create `Notetaker/Utils/URLExtractor.swift`:

```swift
import Foundation

/// Pulls the first http/https URL out of a string. Used by the
/// notes list to decide whether to render a link preview chip.
/// Backed by NSDataDetector so it handles the same surface as
/// Apple's own text-recognition stack (smart quotes, trailing
/// punctuation, etc.).
enum URLExtractor {
    static func firstHTTPURL(in text: String) -> URL? {
        guard !text.isEmpty else { return nil }
        let detector = try? NSDataDetector(
            types: NSTextCheckingResult.CheckingType.link.rawValue
        )
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = detector?.firstMatch(in: text, options: [], range: range),
              let url = match.url else { return nil }
        guard url.scheme == "http" || url.scheme == "https" else { return nil }
        return url
    }
}
```

- [ ] **Step 4: Run to verify GREEN**

Run: `xcodebuild test -scheme Notetaker -only-testing:NotetakerTests/URLExtractorTests`
Expected: 7/7 pass.

- [ ] **Step 5: Implement `LinkPreviewService`**

Create `Notetaker/Services/LinkPreviewService.swift`:

```swift
import LinkPresentation
import Foundation

/// Memoizing wrapper around `LPMetadataProvider`. Calls into the
/// LinkPresentation framework (the same machinery Messages and Notes
/// use) and publishes the resulting `LPLinkMetadata` keyed by URL.
/// SwiftUI views observe `previews[url]` and re-render when an
/// async fetch lands. NSCache survives clear-metadata events; the
/// in-memory `previews` map keeps SwiftUI in the loop.
@MainActor
final class LinkPreviewService: ObservableObject {
    @Published private(set) var previews: [URL: LPLinkMetadata] = [:]
    private var inflight: Set<URL> = []
    private let cache = NSCache<NSURL, LPLinkMetadata>()

    func ensure(for url: URL) {
        if previews[url] != nil { return }
        if let cached = cache.object(forKey: url as NSURL) {
            previews[url] = cached
            return
        }
        guard !inflight.contains(url) else { return }
        inflight.insert(url)

        let provider = LPMetadataProvider()
        provider.startFetchingMetadata(for: url) { [weak self] meta, _ in
            guard let self, let meta else {
                Task { @MainActor [weak self] in
                    self?.inflight.remove(url)
                }
                return
            }
            Task { @MainActor in
                self.cache.setObject(meta, forKey: url as NSURL)
                self.previews[url] = meta
                self.inflight.remove(url)
            }
        }
    }
}
```

- [ ] **Step 6: Wire into `AppEnvironment`**

Add a property and instantiate in `init()`:

```swift
let linkPreviewService: LinkPreviewService

init() throws {
    self.database = try Database()
    self.noteStore = NoteStore(db: database)
    self.imageStore = try ImageStore(db: database)
    self.videoStore = try VideoStore(db: database)
    self.fileStore = FileStore()
    self.linkPreviewService = LinkPreviewService()
    // ... existing imageRoot/retentionService setup unchanged
}
```

- [ ] **Step 7: Inject the service into the SwiftUI tree**

In `PanelWindowController.init`, add after the other `.environmentObject(...)` calls:

```swift
.environmentObject(environment.linkPreviewService)
```

- [ ] **Step 8: Surface it in `NoteRow`**

Replace the `Text(Self.relativeTime(from: note.updatedAt))` line in `displayView` with a call to a small helper view that renders either the chip or the time. Add to `NoteRow`:

```swift
@EnvironmentObject private var linkPreviewService: LinkPreviewService

@ViewBuilder
private var metaLine: some View {
    if let url = URLExtractor.firstHTTPURL(in: note.body) {
        HStack(spacing: 5) {
            faviconView(for: url)
            Text(url.host ?? url.absoluteString)
                .font(.nkLabel)
                .foregroundStyle(DS.Color.textTertiary)
                .lineLimit(1)
            Text("·")
                .font(.nkLabel)
                .foregroundStyle(DS.Color.textTertiary)
            Text(Self.relativeTime(from: note.updatedAt))
                .font(.nkLabel)
                .foregroundStyle(DS.Color.textTertiary)
        }
        .onAppear { linkPreviewService.ensure(for: url) }
    } else {
        Text(Self.relativeTime(from: note.updatedAt))
            .font(.nkLabel)
            .foregroundStyle(DS.Color.textTertiary)
    }
}

@ViewBuilder
private func faviconView(for url: URL) -> some View {
    if let icon = linkPreviewService.previews[url]?.iconProvider {
        FaviconLoader(provider: icon)
    } else {
        Image(systemName: "globe")
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(DS.Color.textTertiary)
            .frame(width: 12, height: 12)
    }
}
```

Add a tiny `FaviconLoader` view (also in `NotesListView.swift`):

```swift
private struct FaviconLoader: View {
    let provider: NSItemProvider
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 12, height: 12)
                    .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
            } else {
                Image(systemName: "globe")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(DS.Color.textTertiary)
                    .frame(width: 12, height: 12)
            }
        }
        .onAppear(perform: load)
    }

    private func load() {
        provider.loadObject(ofClass: NSImage.self) { obj, _ in
            if let nsImage = obj as? NSImage {
                Task { @MainActor in self.image = nsImage }
            }
        }
    }
}
```

In `displayView`, replace `Text(Self.relativeTime(from: note.updatedAt))` with `metaLine`.

- [ ] **Step 9: Build**

Run: `xcodebuild build -scheme Notetaker`
Expected: succeeds.

- [ ] **Step 10: Commit**

```bash
git add Notetaker/Utils/URLExtractor.swift Notetaker/Services/LinkPreviewService.swift NotetakerTests/URLExtractorTests.swift Notetaker/App/AppEnvironment.swift Notetaker/Panel/PanelWindowController.swift Notetaker/Panel/NotesListView.swift
git commit -m "feat: link preview chips on notes containing URLs"
```

---

### Task 5: Final sanity pass

- [ ] **Step 1: Run the full test suite**

Run: `xcodebuild test -scheme Notetaker`
Expected: every prior test still green plus all new tests.

- [ ] **Step 2: Build a release configuration**

Run: `xcodebuild build -scheme Notetaker -configuration Release`
Expected: succeeds with no warnings introduced by this branch.

---

## Done Criteria

- 4 feature commits, plus the existing design+plan commits
- All new tests pass; no regressions in existing tests
- Privacy filter blocks ConcealedType/TransientType auto-routing
- ⌘1 in any tab copies the first visible item and dismisses the panel
- Right-click on an image card shows "Copy text from image" → text on clipboard
- A note containing `https://github.com` shows `[favicon] github.com · time` after ~1–2s
