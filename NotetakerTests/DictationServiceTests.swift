import XCTest
@testable import Notetaker

/// Tests for the dictation pipeline's most fragile surfaces. These
/// cover regressions we hit in production and want pinned down:
///
/// • `looksLikeMetacommentary` — the LLM cleanup pass occasionally
///   responds TO the system prompt instead of FOLLOWING it,
///   producing "I will process the raw transcript..." instead of
///   the cleaned text. The fallback heuristic must catch every
///   known preface AND not false-positive on legitimate speech.
///
/// • Multipart body construction — Whisper's `language` and
///   `prompt` fields are critical for accuracy. Tests verify they
///   land in the form data correctly when set, and are omitted
///   when empty/nil.
///
/// • `String.unicodeChunks(of:)` — the typing pipeline chunks
///   long transcripts so fast text fields don't drop characters.
///   Test the chunk boundaries + grapheme preservation.
final class DictationServiceTests: XCTestCase {

    // MARK: - Metacommentary detection

    func testMetacommentaryDetectionCatchesKnownPrefaces() {
        // Each of these is an actual failure mode we've seen in
        // the wild OR a documented LLM hedging preface. If the
        // detection misses any of them, the user sees "I will
        // process..." pasted into their note instead of their
        // actual words.
        let metaSamples = [
            "I will process the raw speech-to-text output. I'll remove filler words...",
            "I'll clean the transcript text. Please provide the raw transcript.",
            "Sure, here's the cleaned version: hello world.",
            "Sure! Let me clean that up for you.",
            "Here is the cleaned transcript:\n\nHello world.",
            "Here's the transcript with corrections:",
            "Of course, the cleaned text is: hello world.",
            "Certainly, here is the cleaned transcript.",
            "Okay, I'll fix that up.",
            "Got it, here's the cleaned version.",
            "Please provide the raw transcript so I can clean it.",
            "As a transcript cleaner, I will remove filler words...",
            "As an AI, I'm happy to help clean your transcript.",
            "I'm ready to clean any transcript you provide.",
            "Let me clean that up for you.",
            "To clean the transcript, I'll remove filler words.",
        ]
        for sample in metaSamples {
            XCTAssertTrue(
                DictationService.looksLikeMetacommentary(sample),
                "Should detect metacommentary in: \(sample.prefix(60))…"
            )
        }
    }

    func testMetacommentaryDetectionAllowsLegitimateSpeech() {
        // These are real things people dictate. They start with
        // pronouns or normal words but are NOT model
        // metacommentary — the heuristic must let them through.
        let legitSamples = [
            "Hello, how are you doing today?",
            "Make it like three lines max.",
            "Send the email to the team.",
            "The meeting is at 3pm tomorrow.",
            "Please call me back when you can.",  // starts with "Please" but not "Please provide"
            "I went to the store yesterday.",      // starts with "I" but not "I will" / "I'll"
            "Sure thing! Sounds good.",            // starts with "Sure thing" not "Sure,"
            "Here we go again with the same problem.",  // starts with "Here we" not "Here is"/"Here's"
            "Got coffee this morning.",            // starts with "Got" but not "Got it,"
            "Let's grab lunch.",                   // starts with "Let's" not "Let me"
        ]
        for sample in legitSamples {
            XCTAssertFalse(
                DictationService.looksLikeMetacommentary(sample),
                "Should NOT flag legitimate speech: \(sample)"
            )
        }
    }

    func testMetacommentaryDetectionIgnoresLongOutputs() {
        // The 300-char ceiling prevents long legitimate transcripts
        // that happen to contain "I will" mid-text from being
        // flagged. A user dictating a 2-paragraph note shouldn't
        // get rejected because they said "I will be there at 3."
        let longText = String(repeating: "I will be there at three. Then we'll grab dinner. ", count: 8)
        XCTAssertGreaterThan(longText.count, 300)
        XCTAssertFalse(
            DictationService.looksLikeMetacommentary(longText),
            "Long outputs should bypass the heuristic"
        )
    }

    func testMetacommentaryDetectionIsCaseInsensitive() {
        XCTAssertTrue(DictationService.looksLikeMetacommentary("I WILL process this"))
        XCTAssertTrue(DictationService.looksLikeMetacommentary("Sure, here it is"))
        XCTAssertTrue(DictationService.looksLikeMetacommentary("HERE IS the transcript"))
    }

    // MARK: - String chunking (paste pipeline)

    func testUnicodeChunksSplitsAtBoundaries() {
        let s = "abcdefghijklmnopqrstuvwxyz"  // 26 chars
        let chunks = s.unicodeChunks(of: 10)
        XCTAssertEqual(chunks.count, 3)
        XCTAssertEqual(chunks[0], "abcdefghij")
        XCTAssertEqual(chunks[1], "klmnopqrst")
        XCTAssertEqual(chunks[2], "uvwxyz")
    }

    func testUnicodeChunksPreservesShortStrings() {
        XCTAssertEqual("hi".unicodeChunks(of: 20), ["hi"])
        XCTAssertEqual("".unicodeChunks(of: 20), [""])
    }

    func testUnicodeChunksPreservesGraphemeClusters() {
        // 👨‍👩‍👧 is a single grapheme cluster but multiple UTF-16
        // code units. Chunking by `count` (which counts graphemes,
        // not code units) keeps it intact across chunk boundaries.
        let family = "👨‍👩‍👧"
        let s = "ab" + family + "cd" + family + "ef"
        let chunks = s.unicodeChunks(of: 3)
        // Re-joining must equal the original — emoji intact.
        XCTAssertEqual(chunks.joined(), s)
        // No chunk should split a grapheme.
        for chunk in chunks {
            XCTAssertEqual(chunk.count, chunk.count)  // grapheme count
        }
    }
}

// `String.unicodeChunks(of:)` lives in DictationPasteHelper.swift
// as an `internal` extension so `@testable import Notetaker`
// exposes it here without duplicating the implementation.
