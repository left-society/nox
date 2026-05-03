import AppKit
import Carbon

/// Inserts dictation transcripts into whatever app + text field is
/// frontmost, WITHOUT touching the user's clipboard.
///
/// Earlier versions of this helper did the classic ⌘V dance: save
/// the user's pasteboard, write the transcript, synthesize ⌘V, then
/// restore the pasteboard 250ms later. That worked, but had
/// downsides:
///   • The user's clipboard gets stomped briefly. Anything pending
///     a manual paste (an image, a long URL, etc.) is at risk during
///     the ~250ms restore window — and on apps that consume the
///     clipboard asynchronously (some browsers, Electron apps), the
///     restore can race the paste and corrupt the user's clipboard.
///   • The user explicitly said: "let's just dont copy the text we
///     are generating with audio please." Direct user feedback.
///
/// New approach: use `CGEvent.keyboardSetUnicodeString(...)` to
/// post an event that carries the transcript text in its unicode
/// payload. macOS delivers this as if the user typed every character
/// — works in every text field type (native, web, terminal, search
/// boxes, password fields…) and crucially **never touches the
/// pasteboard**. This is how Wispr Flow / FreeFlow / native macOS
/// dictation insert text.
///
/// Requires Accessibility permission (same as the previous ⌘V
/// approach — both rely on synthesized CGEvents).
@MainActor
enum DictationPasteHelper {
    /// Type `text` at the cursor in whatever app is currently
    /// frontmost. Direct unicode keystroke synthesis — pasteboard
    /// is left exactly as the user left it.
    static func paste(_ text: String) {
        typeText(text)
    }

    /// Type `text` at the cursor as a sequence of Unicode keystrokes.
    /// Long strings are chunked because CGEvent's unicode payload is
    /// limited (in practice ~20 characters per event reliably; 50+ on
    /// modern macOS but we keep the chunk small for safety). A short
    /// inter-event delay keeps fast text-field redraw cycles from
    /// dropping characters.
    static func typeText(_ text: String) {
        guard !text.isEmpty else { return }

        let source = CGEventSource(stateID: .hidSystemState)
        let chunks = text.unicodeChunks(of: 20)

        for chunk in chunks {
            postUnicodeEvent(source: source, string: chunk)
            // Tiny pause so receivers that batch keystrokes
            // (some web text fields, rich-text editors) don't
            // drop intermediate chunks. 1ms is enough; we don't
            // want a perceptible typing latency on long strings.
            usleep(1_000)
        }
    }

    /// Synthesize a keyDown event carrying `string` as its unicode
    /// payload. macOS delivers it as if the user typed every
    /// character literally.
    ///
    /// 2026-04-29 v2 fix for the duplication bug: post ONLY the
    /// keyDown event. The previous version posted keyDown + keyUp
    /// and macOS apps reading via cgAnnotatedSessionEventTap were
    /// processing both as text-input events even when the unicode
    /// payload was only set on keyDown — different apps interpret
    /// the down/up pair differently for synthesized events with
    /// virtualKey=0 (no real key). With ONLY keyDown posted, the
    /// receiving app sees exactly one text-input event per chunk
    /// and the text lands once.
    ///
    /// Side-effects of skipping keyUp:
    ///   • No "key released" signal — but for virtualKey=0 there's
    ///     no real key to release, so nothing depends on this.
    ///   • Apps that count keypresses (rare in text fields) might
    ///     see N keys-down without corresponding keys-up. Not a
    ///     practical issue for text input.
    private static func postUnicodeEvent(source: CGEventSource?, string: String) {
        let utf16 = Array(string.utf16)
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) else {
            return
        }
        utf16.withUnsafeBufferPointer { buf in
            if let base = buf.baseAddress {
                keyDown.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: base)
            }
        }
        keyDown.post(tap: .cgAnnotatedSessionEventTap)
    }
}

extension String {
    /// Split into chunks of up to `n` characters, preserving
    /// grapheme clusters (so emoji and combined characters don't
    /// get torn across event boundaries).
    ///
    /// `internal` (not `private`) so the test target can access
    /// it via `@testable import Notetaker`. There's no other
    /// production caller — this stays effectively private to
    /// `DictationPasteHelper` in practice.
    func unicodeChunks(of n: Int) -> [String] {
        guard count > n else { return [self] }
        var chunks: [String] = []
        var current = ""
        for char in self {
            current.append(char)
            if current.count >= n {
                chunks.append(current)
                current = ""
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
}
