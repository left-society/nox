import SwiftUI
import AppKit

/// NSTextView wrapper that renders markdown LIVE while still letting
/// the user type plain text. Stores body as plain markdown (so the
/// data model stays simple — the row preview, Gemini summary, and
/// clipboard copy all work on the raw string), but visually styles
/// each line based on its prefix:
///   - `# heading`   → 18pt semibold, dimmed `# ` marker
///   - `## subhead`  → 15pt semibold, dimmed `## ` marker
///   - `- [ ] todo`  → checkbox glyph + dimmed marker; `[x]` adds strikethrough
///   - `- bullet`    → bullet glyph + dimmed marker
///   - `> quote`     → italic + dimmed `> ` marker, left rule
///   - `---`         → horizontal rule
///
/// User: "The buttons are not applying properly" — the previous
/// implementation just dumped raw `- [ ]` text and trusted the user
/// to read it as markdown. This editor renders the formatting inline
/// so the editor feels like a proper note canvas, not a markdown
/// terminal.
///
/// Toolbar insertion is cursor-aware: clicking "Heading" prefixes
/// `# ` to the current line where the caret sits and re-positions
/// the caret AFTER the marker so the user can immediately type
/// the heading content. Notion-equivalent.
struct MarkdownTextEditor: NSViewRepresentable {
    @Binding var text: String
    /// Action callbacks invoked from the toolbar — we expose them
    /// so the parent view can route toolbar taps directly into the
    /// text view's cursor-aware insertion logic.
    let coordinatorRef: CoordinatorRef

    final class CoordinatorRef {
        var insertHeading: (() -> Void)?
        var insertBullet: (() -> Void)?
        var insertTodo: (() -> Void)?
        var insertQuote: (() -> Void)?
        var insertDivider: (() -> Void)?
        /// Insert arbitrary text at the current caret position.
        /// Used by the dictation mic button to drop the
        /// transcribed text right where the user was typing,
        /// without going through the system-wide auto-type path.
        var insertText: ((String) -> Void)?
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true

        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.drawsBackground = false
        textView.textColor = NSColor(DS.Color.textPrimary)
        textView.insertionPointColor = NSColor(DS.Color.accent)
        textView.font = .systemFont(ofSize: 14)
        textView.textContainerInset = NSSize(width: 12, height: 8)
        textView.string = text
        context.coordinator.textView = textView
        context.coordinator.applyStyling()

        // Wire the coordinator-ref so the parent toolbar can call
        // these closures to insert markdown at the cursor.
        coordinatorRef.insertHeading = { context.coordinator.insertLinePrefix("# ") }
        coordinatorRef.insertBullet = { context.coordinator.insertLinePrefix("- ") }
        coordinatorRef.insertTodo = { context.coordinator.insertLinePrefix("- [ ] ") }
        coordinatorRef.insertQuote = { context.coordinator.insertLinePrefix("> ") }
        coordinatorRef.insertDivider = { context.coordinator.insertDivider() }
        coordinatorRef.insertText = { text in context.coordinator.insertText(text) }

        scroll.documentView = textView
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        // Avoid clobbering the live editing buffer when the binding
        // is updated externally (e.g. from a parent view re-render
        // for an unrelated reason). Only sync if the strings actually
        // differ.
        if textView.string != text {
            let selected = textView.selectedRange()
            textView.string = text
            // Restore selection if still valid; otherwise place
            // the caret at the end.
            let safeMax = (text as NSString).length
            let restored = NSRange(
                location: min(selected.location, safeMax),
                length: 0
            )
            textView.setSelectedRange(restored)
            context.coordinator.applyStyling()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String
        weak var textView: NSTextView?

        init(text: Binding<String>) {
            self._text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            text = tv.string
            // Per BUG-036 fix: restyle ONLY the edited line(s),
            // not the entire document. The old `applyStyling()`
            // iterated every line in the storage on every
            // keystroke — fine for short notes, but on a
            // 5000-line note that's 5000 lineRange/applyLineStyle
            // round-trips per keystroke, which the user reported
            // as visible jank. Localized restyle is O(1) in
            // typing cost regardless of document length. We
            // include one line above and one below the caret in
            // the restyle window so multi-line edits (paste,
            // cross-line delete, return-key) still get re-styled
            // correctly without needing a full pass.
            applyStylingNearCaret(tv: tv)
        }

        // MARK: Cursor-aware insertion

        /// Insert `prefix` at the START of the line the caret currently
        /// sits on. If the line already starts with the same prefix,
        /// REMOVE it (toggle behavior — same as Notion). Caret lands
        /// after the prefix so the user can immediately type content.
        func insertLinePrefix(_ prefix: String) {
            guard let tv = textView else { return }
            let ns = tv.string as NSString
            let sel = tv.selectedRange()
            let lineRange = ns.lineRange(for: NSRange(location: sel.location, length: 0))
            let line = ns.substring(with: lineRange)

            // Strip any existing structural prefix on this line so we
            // don't end up with `- [ ] # heading`. Prefixes we'll
            // toggle / replace: `# `, `## `, `### `, `- [ ] `, `- [x] `,
            // `- `, `* `, `> `.
            let stripped = stripStructuralPrefix(line)

            let isToggleOff = line.hasPrefix(prefix)
            let newLine: String
            if isToggleOff {
                newLine = stripped
            } else {
                newLine = prefix + stripped
            }

            tv.shouldChangeText(in: lineRange, replacementString: newLine)
            tv.replaceCharacters(in: lineRange, with: newLine)
            tv.didChangeText()

            // Re-position caret: if we just added a prefix, place the
            // caret after the prefix on the same line; if we removed
            // one, leave it at the start of the line.
            let newCaret: Int
            if isToggleOff {
                newCaret = lineRange.location
            } else {
                newCaret = lineRange.location + (prefix as NSString).length
                    + (stripped as NSString).length
            }
            let safeMax = (tv.string as NSString).length
            tv.setSelectedRange(NSRange(location: min(newCaret, safeMax), length: 0))
            text = tv.string
            applyStyling()
        }

        /// Strip any markdown line-prefix (heading, todo, bullet, quote)
        /// from the start of `line`. Used by `insertLinePrefix` so
        /// toggling a different format on the same line replaces
        /// rather than nests.
        private func stripStructuralPrefix(_ line: String) -> String {
            let prefixes = ["# ", "## ", "### ", "- [ ] ", "- [x] ", "- [X] ", "- ", "* ", "> "]
            for p in prefixes {
                if line.hasPrefix(p) {
                    return String(line.dropFirst(p.count))
                }
            }
            return line
        }

        /// Insert arbitrary text at the current caret position.
        /// Replaces any current selection. Used by the dictation
        /// mic button to drop transcribed text right where the
        /// user was typing.
        ///
        /// Adds a leading space if the character before the caret
        /// isn't whitespace and the inserted text doesn't start
        /// with one — so dictating mid-sentence reads as "old text
        /// new text" rather than "old textnew text."
        func insertText(_ insertion: String) {
            guard let tv = textView, !insertion.isEmpty else { return }
            let sel = tv.selectedRange()
            let ns = tv.string as NSString

            var toInsert = insertion
            // Leading-space heuristic: if caret is mid-sentence and
            // the inserted text doesn't start with whitespace, add
            // one. Skip when caret is at line start, document start,
            // or right after whitespace.
            if sel.location > 0 && sel.length == 0 && !insertion.first!.isWhitespace {
                let prevChar = ns.substring(with: NSRange(location: sel.location - 1, length: 1))
                if let prev = prevChar.first, !prev.isWhitespace {
                    toInsert = " " + insertion
                }
            }

            tv.shouldChangeText(in: sel, replacementString: toInsert)
            tv.replaceCharacters(in: sel, with: toInsert)
            tv.didChangeText()

            // Move caret to end of inserted text.
            let newCaret = sel.location + (toInsert as NSString).length
            let safeMax = (tv.string as NSString).length
            tv.setSelectedRange(NSRange(location: min(newCaret, safeMax), length: 0))
            text = tv.string
            applyStylingNearCaret(tv: tv)
        }

        func insertDivider() {
            guard let tv = textView else { return }
            let ns = tv.string as NSString
            let sel = tv.selectedRange()
            let lineRange = ns.lineRange(for: NSRange(location: sel.location, length: 0))

            // Insert a standalone divider line BELOW the current line
            // (so the user's current content isn't disturbed).
            let insertion = ns.substring(with: lineRange).hasSuffix("\n")
                ? "---\n"
                : "\n---\n"
            let insertLoc = lineRange.location + lineRange.length
            tv.shouldChangeText(in: NSRange(location: insertLoc, length: 0), replacementString: insertion)
            tv.replaceCharacters(in: NSRange(location: insertLoc, length: 0), with: insertion)
            tv.didChangeText()
            let newCaret = insertLoc + (insertion as NSString).length
            let safeMax = (tv.string as NSString).length
            tv.setSelectedRange(NSRange(location: min(newCaret, safeMax), length: 0))
            text = tv.string
            applyStyling()
        }

        // MARK: Live styling

        /// Walk the text storage line-by-line and apply per-line
        /// attributes based on markdown prefixes. This is the trick
        /// that gives the editor its WYSIWYG feel without us having
        /// to actually modify the underlying text — the data stays
        /// as plain markdown (good for the row preview, Gemini
        /// summary, clipboard copy), but the visible rendering is
        /// styled inline.
        ///
        /// The marker prefix itself (e.g. `# `, `- [ ] `) is given a
        /// dimmed color so it's still legible (the user knows they
        /// have a heading) but recedes visually next to the actual
        /// content.
        /// Per BUG-036 fix: localized restyling around the caret.
        /// Used by `textDidChange` instead of the full-document
        /// pass below, so per-keystroke cost is O(1) in document
        /// size. Includes one line above and below the caret so
        /// multi-line edits (paste, return key, cross-line
        /// delete) still get restyled.
        func applyStylingNearCaret(tv: NSTextView) {
            guard let storage = tv.textStorage else { return }
            let ns = storage.string as NSString
            guard ns.length > 0 else { return }
            let bodyFont = NSFont.systemFont(ofSize: 14)
            let headingFont = NSFont.systemFont(ofSize: 18, weight: .semibold)
            let subheadFont = NSFont.systemFont(ofSize: 16, weight: .semibold)
            let primary = NSColor(DS.Color.textPrimary)
            let secondary = NSColor(DS.Color.textSecondary)
            let dim = NSColor(DS.Color.textTertiary).withAlphaComponent(0.55)

            let caret = min(tv.selectedRange().location, ns.length)
            // Anchor line: where the caret currently sits.
            let anchorLine = ns.lineRange(for: NSRange(location: caret, length: 0))
            // Expand by one line above and one below.
            var startLoc = anchorLine.location
            var endLoc = anchorLine.location + anchorLine.length
            if startLoc > 0 {
                let above = ns.lineRange(for: NSRange(location: startLoc - 1, length: 0))
                startLoc = above.location
            }
            if endLoc < ns.length {
                let below = ns.lineRange(for: NSRange(location: endLoc, length: 0))
                endLoc = below.location + below.length
            }
            let restyleRange = NSRange(location: startLoc, length: endLoc - startLoc)

            storage.beginEditing()
            // Reset attributes within the restyle window only.
            storage.setAttributes([
                .font: bodyFont,
                .foregroundColor: primary
            ], range: restyleRange)
            // Re-style each line within the window.
            var lineLoc = restyleRange.location
            while lineLoc < restyleRange.location + restyleRange.length {
                let lr = ns.lineRange(for: NSRange(location: lineLoc, length: 0))
                let lt = ns.substring(with: lr)
                applyLineStyle(
                    storage: storage,
                    lineRange: lr,
                    lineText: lt,
                    bodyFont: bodyFont,
                    headingFont: headingFont,
                    subheadFont: subheadFont,
                    primary: primary,
                    secondary: secondary,
                    dim: dim
                )
                lineLoc = lr.location + lr.length
            }
            storage.endEditing()
        }

        /// Full-document restyle. Used on initial mount + when the
        /// binding rebinds to a different note. Per BUG-036 fix:
        /// no longer called from `textDidChange` — that path uses
        /// `applyStylingNearCaret` instead so typing on long notes
        /// stays smooth.
        func applyStyling() {
            guard let tv = textView, let storage = tv.textStorage else { return }
            let full = NSRange(location: 0, length: storage.length)
            let bodyFont = NSFont.systemFont(ofSize: 14)
            let headingFont = NSFont.systemFont(ofSize: 18, weight: .semibold)
            let subheadFont = NSFont.systemFont(ofSize: 16, weight: .semibold)
            let primary = NSColor(DS.Color.textPrimary)
            let secondary = NSColor(DS.Color.textSecondary)
            let dim = NSColor(DS.Color.textTertiary).withAlphaComponent(0.55)

            storage.beginEditing()
            // Reset everything to defaults first so an edit that
            // demoted a heading back to a plain line doesn't leave
            // stale large-font glyphs on it.
            storage.setAttributes([
                .font: bodyFont,
                .foregroundColor: primary
            ], range: full)

            let ns = storage.string as NSString
            var lineLoc = 0
            while lineLoc < ns.length {
                let lineRange = ns.lineRange(for: NSRange(location: lineLoc, length: 0))
                let lineText = ns.substring(with: lineRange)
                applyLineStyle(
                    storage: storage,
                    lineRange: lineRange,
                    lineText: lineText,
                    bodyFont: bodyFont,
                    headingFont: headingFont,
                    subheadFont: subheadFont,
                    primary: primary,
                    secondary: secondary,
                    dim: dim
                )
                lineLoc = lineRange.location + lineRange.length
            }
            storage.endEditing()
        }

        private func applyLineStyle(
            storage: NSTextStorage,
            lineRange: NSRange,
            lineText: String,
            bodyFont: NSFont,
            headingFont: NSFont,
            subheadFont: NSFont,
            primary: NSColor,
            secondary: NSColor,
            dim: NSColor
        ) {
            let trimmed = lineText.trimmingCharacters(in: .newlines)

            // # Heading — 18pt semibold for the whole line, dim the marker
            if trimmed.hasPrefix("# ") {
                storage.addAttributes([.font: headingFont, .foregroundColor: primary], range: lineRange)
                storage.addAttribute(.foregroundColor, value: dim,
                                     range: NSRange(location: lineRange.location, length: 2))
                return
            }
            // ## Subheading
            if trimmed.hasPrefix("## ") {
                storage.addAttributes([.font: subheadFont, .foregroundColor: primary], range: lineRange)
                storage.addAttribute(.foregroundColor, value: dim,
                                     range: NSRange(location: lineRange.location, length: 3))
                return
            }
            // - [x] checked todo — strikethrough body, dim marker
            if trimmed.hasPrefix("- [x] ") || trimmed.hasPrefix("- [X] ")
                || trimmed.hasPrefix("* [x] ") || trimmed.hasPrefix("* [X] ") {
                storage.addAttributes([
                    .font: bodyFont,
                    .foregroundColor: secondary,
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                    .strikethroughColor: NSColor(DS.Color.textTertiary)
                ], range: lineRange)
                storage.addAttribute(.foregroundColor, value: dim,
                                     range: NSRange(location: lineRange.location, length: 6))
                return
            }
            // - [ ] unchecked todo — dim marker, body in primary
            if trimmed.hasPrefix("- [ ] ") || trimmed.hasPrefix("* [ ] ") {
                storage.addAttribute(.foregroundColor, value: dim,
                                     range: NSRange(location: lineRange.location, length: 6))
                return
            }
            // - bullet
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                storage.addAttribute(.foregroundColor, value: dim,
                                     range: NSRange(location: lineRange.location, length: 2))
                return
            }
            // > quote — italicize the line, dim the marker
            if trimmed.hasPrefix("> ") {
                let italicFont = NSFontManager.shared.convert(bodyFont, toHaveTrait: .italicFontMask)
                storage.addAttributes([.font: italicFont, .foregroundColor: secondary], range: lineRange)
                storage.addAttribute(.foregroundColor, value: dim,
                                     range: NSRange(location: lineRange.location, length: 2))
                return
            }
            // --- divider — dim the line, render as separator
            if trimmed == "---" {
                storage.addAttribute(.foregroundColor, value: dim, range: lineRange)
                return
            }
        }
    }
}
