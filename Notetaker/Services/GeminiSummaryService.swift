import Foundation

/// Gemini-backed one-line summarization for note bodies. Companion to
/// `GeminiOCRService` — same API key, same Gemini 2.0 Flash model,
/// different prompt: instead of "extract chat messages from this
/// screenshot," this prompt is "give me a 6-10 word summary of this
/// note that fits in a list row."
///
/// User: "Every note will get sumaraize by gemini since we already
/// connected the key? So it's easy to understand and cheak or copy
/// later." Replaces the previous "first line of body" title in the
/// list view, so the row reads as "what was this note about?" rather
/// than "what were the first 5 words?".
///
/// Network: single POST, 30-second timeout. Cheap — ~50 input tokens
/// for a typical note, ~10 output tokens for the summary. Runs
/// asynchronously after the note is saved; the user's save is never
/// blocked on the round-trip. The summary is persisted in the notes
/// table (added in v5_note_summary migration), so it survives app
/// restarts and we don't repeatedly bill the same content.
enum GeminiSummaryService {

    enum Result {
        case missingAPIKey
        case success(String)
        case failure(String)
    }

    /// Reuse the same API-key default as the OCR service — one key
    /// powers both features, so the user only configures it once.
    static var apiKeyDefaultsKey: String { GeminiOCRService.apiKeyDefaultsKey }

    /// Summarize `body` into a 6-10 word phrase suitable for a list row.
    /// Returns `.missingAPIKey` (caller surfaces a settings prompt),
    /// `.success` with the summary, or `.failure` with a short reason.
    static func summarize(body: String) async -> Result {
        // Keychain-backed read — see GeminiOCRService for the full
        // rationale (security audit, May 2026).
        let stored = await MainActor.run { SecureKeyStore.shared.load(.geminiApiKey) }
        let key = (stored ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return .missingAPIKey }

        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure("Empty note") }

        // Cap input at ~4000 chars. Most notes are far shorter; very
        // long inputs would just waste tokens since we want a concise
        // output anyway.
        let capped = String(trimmed.prefix(4000))

        // Prompt is structured to give the model a narrow job and a
        // strict output format. "Output only the summary, nothing
        // else" prevents Gemini from prepending "Here's a summary:"
        // which would break the one-line list display.
        let prompt = """
        You are a notes app summarizer. Given the note text below, output a single concise summary in 6 to 10 words. The summary should describe what the note is about, not paraphrase its first sentence. Output ONLY the summary text — no quotes, no prefix, no explanation.

        Note text:
        \(capped)
        """

        // Per BUG-007 fix: API key moved out of URL query into
        // the `x-goog-api-key` header. See GeminiOCRService for
        // the rationale.
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent") else {
            return .failure("Bad URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        request.timeoutInterval = 30

        let payload: [String: Any] = [
            "contents": [
                [
                    "parts": [["text": prompt]]
                ]
            ],
            "generationConfig": [
                // Low temperature for deterministic, factual summaries
                // (high temp would invite creative paraphrasing the
                // user didn't ask for).
                "temperature": 0.2,
                // Per BUG-073 fix: bumped from 40 to 80. 40 tokens
                // covered ~25 words but Gemini sometimes added an
                // explanatory clause and got truncated MID-WORD,
                // landing things like "This note discusses the
                // implementation of a new" in the DB. 80 tokens
                // gives generous headroom for a complete sentence
                // while still capping runaway generations. The
                // model still self-stops at 6-10 words in the
                // common case so cost-per-call doesn't change.
                "maxOutputTokens": 80
            ]
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        } catch {
            return .failure("Encode failed")
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failure("No response")
            }
            guard http.statusCode == 200 else {
                return .failure("HTTP \(http.statusCode)")
            }
            guard
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let candidates = json["candidates"] as? [[String: Any]],
                let first = candidates.first,
                let content = first["content"] as? [String: Any],
                let parts = content["parts"] as? [[String: Any]],
                let firstPart = parts.first,
                let text = firstPart["text"] as? String
            else {
                return .failure("Bad shape")
            }

            // Sanitize: trim whitespace, strip surrounding quotes the
            // model sometimes emits despite "no quotes" instruction,
            // collapse internal newlines (the row shows one line).
            var summary = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if summary.hasPrefix("\"") && summary.hasSuffix("\"") {
                summary = String(summary.dropFirst().dropLast())
            }
            summary = summary.replacingOccurrences(of: "\n", with: " ")
            summary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !summary.isEmpty else { return .failure("Empty result") }
            return .success(summary)
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    /// Longer, in-editor summary for the popout note window. Returns
    /// a one-sentence overview followed by 3-6 markdown bullet points
    /// — designed to be PREPENDED to a note (the user is watching a
    /// video and wants their captured-as-they-typed notes condensed
    /// into a study-ready block at the top).
    ///
    /// Same key, same model, same cap as `summarize` — just a fuller
    /// prompt and a higher token ceiling. The popout's "AI Summarize"
    /// button calls this; the auto-summary on save still uses the
    /// short variant for the list-row preview.
    static func summarizeDetail(body: String) async -> Result {
        let stored = await MainActor.run { SecureKeyStore.shared.load(.geminiApiKey) }
        let key = (stored ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return .missingAPIKey }

        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure("Empty note") }
        let capped = String(trimmed.prefix(8000))

        let prompt = """
        You are a study-notes assistant. The user is taking notes while watching a video. Read their note and produce a concise review block:

        - Open with ONE sentence summarizing what the note covers (no preamble like "This note discusses…").
        - Then list 3 to 6 bullet points capturing the key takeaways.
        - Use markdown: hyphens for bullets, **bold** sparingly for true emphasis only.
        - Output ONLY the summary block. No headers, no quotes, no commentary.

        Note text:
        \(capped)
        """

        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent") else {
            return .failure("Bad URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        request.timeoutInterval = 60

        let payload: [String: Any] = [
            "contents": [["parts": [["text": prompt]]]],
            "generationConfig": [
                "temperature": 0.3,
                // ~600 tokens ≈ 450 words: comfortable headroom for
                // 1 sentence + 6 bullet points without truncation.
                "maxOutputTokens": 600
            ]
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        } catch {
            return .failure("Encode failed")
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failure("No response")
            }
            guard http.statusCode == 200 else {
                return .failure("HTTP \(http.statusCode)")
            }
            guard
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let candidates = json["candidates"] as? [[String: Any]],
                let first = candidates.first,
                let content = first["content"] as? [String: Any],
                let parts = content["parts"] as? [[String: Any]],
                let firstPart = parts.first,
                let text = firstPart["text"] as? String
            else {
                return .failure("Bad shape")
            }
            let summary = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !summary.isEmpty else { return .failure("Empty result") }
            return .success(summary)
        } catch {
            return .failure(error.localizedDescription)
        }
    }
}
