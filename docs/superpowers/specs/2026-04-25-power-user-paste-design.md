# Power-User Paste Upgrades — Design

**Date:** 2026-04-25
**Sub-project:** #2 of the post-Files-tab roadmap (see `2026-04-25-clipbook-feature-findings.md`)
**Goal:** Land four ClipBook-inspired features that make every individual paste interaction richer, without compromising Notetaker's curated-panel ethos.

## Summary

Four discrete features, each shippable as its own commit:

1. **Privacy filter** — `ClipboardRouter` honors `org.nspasteboard.ConcealedType` and `org.nspasteboard.TransientType`, returning `.none` so we don't auto-route 1Password/Keychain/etc. content.
2. **Quick paste ⌘1–⌘9** — when the panel is open, ⌘1 through ⌘9 dispatch a "copy item N from the active tab to the clipboard" action that maps to whatever the active tab considers its top-9 items.
3. **OCR "Copy Text from Image"** — context-menu (right-click) on any image card → `VNRecognizeTextRequest` → puts extracted text on the system clipboard.
4. **Link preview cards** — when a Note's body contains a URL, render an `LPLinkView`-style preview card inline at the top of the note editor and as a thumbnail on the note's row in the list.

All four are independent — they can ship in any order, but the order above is by ascending complexity.

## Feature 1 — Privacy filter

### Problem
ClipBook's `ignoreConfidentialContent` and `ignoreTransientContent` settings respect two well-established `NSPasteboardType` markers:

- `org.nspasteboard.ConcealedType` — set by 1Password, Keychain, password managers
- `org.nspasteboard.TransientType` — set when a copy is intentionally short-lived (e.g. a colour-picker "current color" preview)

Today, Notetaker's `ClipboardRouter.decide()` happily auto-routes a 1Password password-copy onto Notes because it's just text. That's a privacy bug.

### Design
Add a single guard at the top of `ClipboardRouter.decide()`:

```swift
let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
if pb.types?.contains(concealed) == true || pb.types?.contains(transient) == true {
    return .none
}
```

Returning `.none` means `applyAutoRouting` exits early. The user opening the panel after copying a password just lands on whatever tab they were on — Notetaker is invisible to the operation.

No UI surface needed. No setting to toggle. We always honor the marker.

### Tests
Two new cases in `ClipboardRouterTests`:
- `test_concealedType_returnsNone` — write text + `ConcealedType` marker → `.none`
- `test_transientType_returnsNone` — write text + `TransientType` marker → `.none`

## Feature 2 — Quick paste ⌘1–⌘9

### Problem
ClipBook's `⌘N` quick-paste shortcut is a universal "the user already knows what they want, get out of the way" affordance. Notetaker requires the user to mouse-click a card today.

### Design

When the panel is **key**, install a local `NSEvent` monitor inside `PanelWindowController.show()` that handles `.keyDown` with `.command` modifier and keyCodes 18–26 (⌘1–⌘9). Map each keystroke to:

1. Read the active tab from `PanelPresenter.activeTab`
2. Ask the active tab's store for its first-9 visible items (`environment.noteStore.notes`, `environment.imageStore.images`, `environment.videoStore.completedVideos`, `environment.fileStore.files`)
3. The Nth item gets re-copied to the system pasteboard via the existing `ClipboardService` paths (`copy(text:)` for notes, `copy(images:fileURLs:)` for images, `copy(fileURLs:)` for videos/files)
4. Haptic `.alignment` + brief flash on the visual card so the user gets feedback
5. Auto-hide the panel after 200ms (the ClipBook UX — once you've quick-pasted, the panel gets out of your way)

Quick-paste is **non-key-stealing**: because the panel only opens via ⌥Space and the local monitor only fires when the panel is key (the user actively focused it), this doesn't interfere with anyone typing in another app.

The implementation lives in `PanelWindowController` next to the existing ESC monitor.

### Tests
A new `QuickPasteTests` suite that builds the dispatch logic into a pure function `QuickPasteRouter.itemAt(index:tab:environment:)` returning a `RoutingDecision`-like enum (`.text(String)`, `.image(NSImage, URL?)`, `.fileURL(URL)`, `.none`). Tests verify each tab's first-9 mapping. The `PanelWindowController` keystroke wiring is exercised manually.

### Visual feedback (deferred to polish pass)
A brief `0.18s` ease-out scale-pulse on the targeted card. Implemented as a `@State pulseId` in each grid view that the QuickPasteRouter sets via a published `lastQuickPastedId`.

## Feature 3 — OCR "Copy Text from Image"

### Problem
Notetaker's Images tab holds screenshots and pasted images, but the user can't extract text from them without leaving the app and dragging into Preview/Live Text. ClipBook bundles this as a context-menu item.

### Design

Add a `Services/ImageOCRService.swift`:

```swift
import Vision
import AppKit

enum ImageOCRService {
    /// Runs Vision text recognition on the image at the given URL.
    /// Returns a single concatenated string (joined by newlines) of
    /// all recognized observations, or nil if no text was found.
    static func extractText(from url: URL) async -> String? {
        guard let cgImage = loadCGImage(at: url) else { return nil }
        return await withCheckedContinuation { cont in
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
            try? handler.perform([request])
        }
    }
}
```

Wire it into `ImagesGridView`'s context menu:

```swift
.contextMenu {
    Button("Copy text from image") {
        Task {
            if let text = await ImageOCRService.extractText(from: image.fileURL) {
                ClipboardService.copy(text: text)
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            }
        }
    }
    // existing context menu items unchanged
}
```

### Tests
A new `ImageOCRServiceTests` that ships a checked-in test PNG containing the literal text "Hello Notetaker" rendered with `NSAttributedString.draw`, then asserts the extraction returns a string containing "Hello Notetaker". (Vision is async and gates a real ML model load, so the test is async and may have a ~1s warmup.)

## Feature 4 — Link preview cards

### Problem
Notes that contain URLs render as plain text. ClipBook fetches favicon + title + description + og-image. Apple ships exactly this as `LinkPresentation.LPMetadataProvider` + `LPLinkView`. We can have it for free.

### Design

#### Service layer
Add `Services/LinkPreviewService.swift`:

```swift
import LinkPresentation

@MainActor
final class LinkPreviewService: ObservableObject {
    @Published private(set) var previews: [URL: LPLinkMetadata] = [:]
    private var inflight: Set<URL> = []
    private let cache = NSCache<NSURL, LPLinkMetadata>()

    /// Fire-and-forget fetch. UI binds to `previews[url]` and gets
    /// re-rendered when the metadata arrives. No-op if already cached
    /// or currently fetching.
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
            guard let self, let meta else { return }
            Task { @MainActor in
                self.cache.setObject(meta, forKey: url as NSURL)
                self.previews[url] = meta
                self.inflight.remove(url)
            }
        }
    }
}
```

Wire it into `AppEnvironment` alongside the other stores.

#### URL extraction
Add `Notetaker/Utils/URLExtractor.swift`:

```swift
enum URLExtractor {
    /// Returns the first http/https URL found in the given string,
    /// or nil. Used to decide whether to render a link preview for
    /// a note. Avoids over-eager matching on file:// or mailto:.
    static func firstHTTPURL(in text: String) -> URL? {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = detector?.firstMatch(in: text, range: range),
              let url = match.url,
              url.scheme == "http" || url.scheme == "https" else { return nil }
        return url
    }
}
```

#### UI surface
Two places render link previews:

1. **Note row in the list** — when a note's body contains a URL, replace the meta text "X chars" with a tiny 18×18 favicon thumbnail + URL host, e.g. `[favicon] github.com`. Falls back to a system globe icon while the metadata loads.
2. **Note editor** — at the top of the editor, above the body text editor, render a 60pt-tall horizontal card: favicon + title + description, with a `tap → open in browser` affordance. Only when the body contains a URL.

Implementation uses a `NSViewRepresentable` wrapper around `LPLinkView` for the editor card, and a custom `LinkChipView` SwiftUI view for the row chip (since `LPLinkView` is too heavy for a row).

### Tests
- `URLExtractorTests` (pure, fast) — cases for plain URL, URL inside text, no URL, multiple URLs (returns first), file://, mailto://, malformed.
- `LinkPreviewServiceTests` — networked, marked as integration tests. Single test fetches `https://github.com` and asserts metadata.title is non-nil after a 5s timeout. (Skipped if `XCTEST_SKIP_NETWORK=1` env var set.)

## Architecture considerations

Each feature is independent — they share no state. The Privacy filter touches `ClipboardRouter`. Quick paste touches `PanelWindowController` and adds a new pure helper. OCR adds one service + one menu item. Link previews add one service, one extractor, and surfaces in two existing views.

No new tabs, no new persistence layer, no GRDB migration. Files tab is unaffected.

## Polish baseline reminder

Carry the baseline forward (from sub-project #1's plan):
- Spring `.spring(response: 0.32, dampingFraction: 0.74)`
- Haptic `.alignment` for confirmations, `.levelChange` for state transitions
- Card style 14pt corner / `Color.white.opacity(0.05)` fill / gradient stroke / double shadow

Quick-paste's pulse animation, the OCR success feedback, and link-card hover-lift all use this baseline.

## Out of scope (deferred)

- Favorites + Tags (sub-project #2.5)
- Color/email detection (sub-project #2.5)
- Quick Look (sub-project #2.5)
- ⌘C ⌘C copy-and-merge (sub-project #4)
- Paste-text transformations (sub-project #4)
- Caret-anchored panel placement (sub-project #5)
- Per-app blocklist (sub-project #5)

## Done criteria

- 4 commits, one per feature, each green on its own
- All existing tests still pass
- New tests added for each feature
- Privacy filter: copying a password from 1Password does not auto-route to Notes
- Quick paste: ⌘1 in any tab copies the first item to clipboard and dismisses the panel
- OCR: right-click on an image card with text → "Copy Text from Image" → text on clipboard
- Link previews: paste a URL into a note → editor shows the preview card after ~1-2s
