import Foundation

/// Three-layer vocabulary biasing system for local Whisper
/// transcription. Combined into a single `prompt` string that
/// gets encoded as Whisper prompt tokens, biasing the decoder
/// toward the user's domain-specific terms.
///
/// Layers (in priority order, joined with commas):
///   1. **App vocabulary** — Notetaker-specific jargon hardcoded
///      so the app can spell its own name + features correctly
///      ("Notetaker", "MediaRemote", "AppleScript")
///   2. **Personal vocabulary** — comma-separated list the user
///      types into Settings. Names, places, project terms.
///   3. **Auto-learned vocabulary** — words that the user has
///      manually typed or corrected enough times that Notetaker
///      decides they should be in the prompt automatically.
///   4. **Recent notes context** — content of the last 3 notes
///      truncated to fit Whisper's ~224-token prompt budget.
///      Lets the model continue in the same vocabulary as
///      yesterday's note.
///
/// Why all four: each catches a different failure mode of frozen
/// Whisper — hardcoded terms catch app-name spellings, personal
/// vocab catches names the user explicitly wants, auto-learn
/// catches everything else through corrections, and recent
/// context catches "I was just talking about X yesterday."
@MainActor
final class DictationVocabulary {
    static let shared = DictationVocabulary()

    // MARK: - Layer 1: App vocabulary
    //
    // Notetaker-specific terms that should always be biased,
    // even on a fresh install before the user has typed anything.

    private let appTerms: [String] = [
        "nox", "Alcove", "Tahoe",
        "MediaRemote", "AppleScript", "Spotify", "Apple Music",
        "AirPods", "AirDrop", "Whisper",
        "macOS", "Sonoma", "Ventura"
    ]

    // MARK: - Layer 2: Personal vocabulary (user-managed)

    private let personalKey = "Notetaker.dictationPersonalVocabulary"

    /// User's personal vocabulary — comma-separated terms typed
    /// into Settings. Empty by default. Stored in UserDefaults
    /// so it survives relaunch and syncs via iCloud-Documents
    /// when the user has it on.
    var personal: String {
        get { UserDefaults.standard.string(forKey: personalKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: personalKey) }
    }

    private var personalTerms: [String] {
        personal.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Layer 3: Auto-learned vocabulary
    //
    // Each correction the user makes gets observed and the
    // "correct" version is added here. Limited to ~50 entries
    // so the prompt doesn't grow unbounded. Older entries get
    // evicted FIFO when the cap is reached.

    private let learnedKey = "Notetaker.dictationLearnedVocabulary"
    private let learnedCap = 50

    private var learnedTerms: [String] {
        get { UserDefaults.standard.stringArray(forKey: learnedKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: learnedKey) }
    }

    /// Record a term the user typed/corrected. Promotes existing
    /// entries to the front (LRU); evicts oldest when over cap.
    /// Filters out common words so the prompt stays signal-dense.
    func recordLearnedTerm(_ term: String) {
        let cleaned = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count >= 3 else { return }
        // Skip obvious common words — they don't help bias the
        // decoder and just eat prompt tokens.
        let lowercased = cleaned.lowercased()
        if Self.commonWords.contains(lowercased) { return }

        var current = learnedTerms
        // Promote-to-front if exists.
        current.removeAll { $0.caseInsensitiveCompare(cleaned) == .orderedSame }
        current.insert(cleaned, at: 0)
        // Cap.
        if current.count > learnedCap {
            current = Array(current.prefix(learnedCap))
        }
        learnedTerms = current
    }

    /// Skip-list of high-frequency English words. Whisper already
    /// knows these — wasting prompt tokens on them just shrinks
    /// the budget for actually-useful terms.
    private static let commonWords: Set<String> = [
        "the", "and", "for", "are", "but", "not", "you", "all", "can",
        "had", "her", "was", "one", "our", "out", "day", "get", "has",
        "him", "his", "how", "man", "new", "now", "old", "see", "two",
        "way", "who", "boy", "did", "its", "let", "put", "say", "she",
        "too", "use", "this", "that", "with", "have", "from", "they",
        "know", "want", "been", "good", "much", "some", "time", "very",
        "when", "come", "here", "just", "like", "long", "make", "many",
        "over", "such", "take", "than", "them", "well", "were"
    ]

    // MARK: - Layer 4: Recent notes context

    /// Snapshot of recent note bodies, set by NotesListView on
    /// every change. Used as rolling context — the last 3
    /// notes' first ~80 chars each get appended to the prompt.
    /// Limits keep the prompt under Whisper's ~224-token cap.
    private var recentNotesSnippets: [String] = []

    func updateRecentNotes(_ noteBodies: [String]) {
        // Take the first 80 chars of each of the most recent 3.
        // Trim newlines and excessive whitespace so the prompt
        // reads as continuous text (which is how Whisper
        // expects prompts to look).
        let snippets = noteBodies.prefix(3).map { body in
            let oneLine = body
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
            let collapsed = oneLine.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
            return String(collapsed.prefix(80))
        }
        recentNotesSnippets = snippets
    }

    // MARK: - Compose the final prompt

    /// Build the Whisper-style prompt string by concatenating
    /// all four layers. Format is plain comma-separated text,
    /// matching how Whisper's decoder expects prompt tokens.
    /// Truncated to ~700 chars (≈ 200 tokens, leaving headroom
    /// under the 224 cap for safety).
    var composedPrompt: String {
        var parts: [String] = []
        parts.append(contentsOf: appTerms)
        parts.append(contentsOf: personalTerms)
        parts.append(contentsOf: learnedTerms)
        let head = parts.joined(separator: ", ")

        // Append recent-notes context as a separate sentence so
        // the model treats it as continuation context rather
        // than vocabulary.
        let context = recentNotesSnippets.joined(separator: ". ")
        let combined = context.isEmpty ? head : "\(head). \(context)"
        // Hard cap at 700 chars.
        if combined.count > 700 {
            return String(combined.prefix(700))
        }
        return combined
    }

    private init() {}
}
