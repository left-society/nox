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
        let key = (UserDefaults.standard.string(forKey: apiKeyDefaultsKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
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

        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent?key=\(key)") else {
            return .failure("Bad URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
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
                // Cap output tokens to ~30 — comfortably above the
                // 6-10 word target. The model usually self-stops
                // after the summary, but the cap is a safety net
                // against runaway generations.
                "maxOutputTokens": 40
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
}
