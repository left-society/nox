# ClipBook Feature Findings → Notetaker Roadmap

**Date:** 2026-04-25
**Source:** `/Applications/ClipBook.app/Contents/Resources/locales/en/translation.json` (ClipBook v1.34.0)
**Purpose:** Mined ClipBook's full feature surface from its i18n bundle and triaged what fits Notetaker's "premium curated panel" ethos vs. what's redundant or off-brand.

## Differentiator Refresh

ClipBook is a **firehose** clipboard manager — it sweeps every copy into a sortable, taggable, searchable history. Notetaker is a **curated** clipboard panel — copies route into typed buckets (Notes/Images/Videos/Files), each with its own affordances, and Notes are the long-lived first-class object. So we don't want to graft a generic history list onto Notetaker. We want to absorb the things ClipBook does that **make individual paste interactions richer**, and skip the things that turn the panel into a database explorer.

## ClipBook's Full Feature Surface

(every distinct user-visible feature extracted from ClipBook's `commands.*`, `historyItemContextMenu.*`, `preview.toolbar.*`, `settings.*` keys)

### Core history model
- All clipboard activity persisted (text/image/link/file/color/email — typed sidebar)
- Sort by: lastCopyTime / firstCopyTime / numberOfCopies / size / copySequence (insertion) / reverseOrder
- "Number of copies" counter — re-copying the same thing increments rather than duplicates
- Favorites + user-defined tags
- Rename items
- Edit content (text only)
- Merge multiple selected items into one paste
- Split a multi-line item into separate items
- Quick Look (⌘Y)
- Show in Finder
- Open With… picker (file/link routing)

### Smart type detection ClipBook does that Notetaker doesn't
- **Color detection** — `#FF6F61`, `rgb(255,111,97)`, hex literals → swatch in Colors bucket
- **Email detection** — bare `foo@bar.com` → Email bucket
- **Link previews** — fetches favicon + page title + meta description + og-image card
- **OCR ("Copy Text from Image")** — Vision-framework-based text extraction from any image item

### Power features
- **Copy-and-merge** — `⌘C ⌘C` (double-tap) appends current selection to previous clipboard text. Separator is configurable: newline or space.
- **Quick paste ⌘1–⌘9** — when panel open, ⌘N pastes the Nth visible item
- **Paste with formatting transformations** — when pasting, optionally apply: lower-case / UPPER-CASE / Capitalize / sentence case / strip-all-whitespace / trim / remove-empty-lines
- **Paste with Return / with Tab** — paste then immediately press enter / tab (form-fill UX)
- **Pause/Resume** clipboard observation

### Window placement strategies
ClipBook lets the user pick where the window opens:
- Last location on active screen
- Center of active screen
- Center of active window
- Screen with mouse pointer
- Mouse pointer location
- **Text caret location** ← this one is the killer

### Privacy
- **Ignore confidential content** — respects `org.nspasteboard.ConcealedType` (1Password, Keychain, etc.)
- **Ignore transient content** — respects `org.nspasteboard.TransientType`
- **Ignore from specific apps** — user-configurable app blocklist

### Storage
- Per-type retention period (1 day → unlimited per text/image/file/link/email/color)
- Clear all on quit / on Mac shutdown
- Always keep favorites + tagged items
- Pin favorites on top
- Warn before clear-all

## Triage Against Notetaker

Each feature: keep / adapt / skip, with reasoning.

| Feature | Decision | Why |
|---|---|---|
| Generic timestamped history list | **skip** | Off-brand — Notetaker is curated, not a firehose |
| Sort menu (lastCopyTime / numberOfCopies / size / ...) | **skip** | Notes already sort by recency; no demand to surface other axes |
| Per-type sidebar filter (All / Text / Images / Links / ...) | **skip** | We already have typed tabs |
| Favorites + Tags | **adapt** (sub-project #2.5) | Strong UX. Favorites = pin a note/image/video. Tags = color-coded chips on cards. |
| Rename items | **adapt** | Already partial — note titles auto-derive from first line. Could expose explicit rename for images/videos. |
| Edit text content | **already exists** | NoteEditor handles this. |
| **Quick paste ⌘1–⌘9** | **keep** (ship next) | Tiny scope, universal value. Works on every tab. Pure win. |
| Merge items (⌘C ⌘C copy-append) | **adapt** (sub-project #3) | Notes-only — rebind ⌘C ⌘C to "append clipboard to active note". |
| Split item | **skip** | Not a meaningful op for our content types |
| Paste with Return / with Tab | **adapt** (sub-project #3) | Form-fill UX is real. Add as keyboard shortcuts in the Files tab specifically (paste path with Return/Tab). |
| Paste-text transformations (lower/UPPER/etc.) | **adapt** (sub-project #3) | Add to NoteEditor as a "Paste as…" submenu and standalone toolbar buttons. |
| **Color detection** | **keep** (sub-project #2.5) | Hex string → swatch card in Notes; copy bumps it back to clipboard as raw hex |
| **Email detection** | **adapt** | Show a 'mailto:' open-button on note cards that contain an email address |
| **Link previews** | **keep** (sub-project #2 must-have) | Fetched favicon + title + og-image rendered inline next to a Note that contains a URL. Uses `LPLinkMetadata` (LinkPresentation framework) — Apple ships this for free. Massive aesthetic upgrade. |
| **OCR (Copy Text from Image)** | **keep** (sub-project #2 must-have) | Right-click image → "Copy Text from Image" → uses `VNRecognizeTextRequest`. Native, no deps. |
| Quick Look | **keep** (sub-project #2.5) | Spacebar on a card → QLPreviewPanel. Free system feature. |
| Show in Finder | **keep** (sub-project #2.5) | Already half-there for images; expose as right-click for files/videos too. |
| Open With… | **adapt** | For Files tab cards — right-click → app picker. |
| Window placement: text caret location | **keep** (sub-project #4) | Killer feature — open the panel right where the user is typing. Requires AX inspection (`AXUIElementCopyAttributeValue` on focused element). Trickier — own sub-project. |
| Pause/Resume | **skip** | We don't observe clipboard continuously — we only read on panel open. So already implicitly paused. |
| Confidential content filter | **keep** (sub-project #2) | Read `org.nspasteboard.ConcealedType` and skip auto-routing. Trivial code, real privacy upgrade. |
| Transient content filter | **keep** (sub-project #2) | Same, for `org.nspasteboard.TransientType`. |
| App blocklist | **adapt** (sub-project #4) | "Don't auto-route from these apps" — needs `NSWorkspace.frontmostApplication` snapshot at copy time. |
| Per-type retention | **skip** | Existing global retention is enough — we don't have ClipBook's volume problem. |
| Pin favorites on top | **adapt** | Once Favorites lands, this comes for free. |
| Warn before clear-all | **adapt** | NoteStore.empty-trash already has this; extend to other clear ops. |

## Carved-Out Sub-Projects

Updating the roadmap. Each gets its own design doc + plan when picked up.

### Sub-project #2 (next): Power-user clipboard upgrades
**Theme:** Land the four highest-leverage ClipBook-style features. None require new tabs — they enhance the existing tabs.

1. **Quick paste ⌘1–⌘9** — ⌘N pastes the Nth item from the active tab
2. **Link preview cards** in Notes — `LPLinkMetadata`-driven preview alongside notes containing URLs
3. **OCR "Copy Text from Image"** — Vision framework, right-click on image cards
4. **Privacy: Concealed/Transient pasteboard types** — auto-routing skips items marked confidential/transient

Estimated 4 tasks, ~3-4 hours TDD.

### Sub-project #2.5: Curation upgrades
1. Favorites system (pin a card to top, survives retention sweep)
2. Tags (user-defined chips, filterable)
3. Color swatch detection (hex → swatch card in Notes)
4. Quick Look on selected card (spacebar)
5. Show-in-Finder for file/video/image cards
6. Email detection → mailto-button on note cards

### Sub-project #3 (later): Premium polish refresh
**Original sub-project #2 unchanged** — universal visual polish across all tabs (now sub-project #3).

### Sub-project #4 (later): Notes power-paste
1. ⌘C ⌘C copy-and-append (merge into active note)
2. "Paste as…" text transformations (lower / UPPER / Cap / sentence / trim / strip / remove-empty)
3. Paste-with-Return and Paste-with-Tab for Files tab

### Sub-project #5 (later): Caret-anchored panel + app blocklist
1. Window placement strategies including "open near text caret" (AX-based)
2. Per-app auto-route blocklist (`NSWorkspace.frontmostApplication`)

### Existing later items (unchanged)
- Sub-project #6: Now-playing widget (Alcove-style)
- Sub-project #7: System HUD replacement (volume/brightness)
- Sub-project #8: AirPods/Bluetooth visualizer
- Sub-project #9: Calendar/Battery/Focus surfacing

## Recommendation

Ship sub-project #2 next. The four features are independent (each can ship as its own commit), all are tight in scope, and each is a visible "wow" the user feels every time they paste. Quick paste is the pure crowd-pleaser, link previews and OCR are the aesthetic differentiators, and the privacy filter is the "feels professional" touch.
