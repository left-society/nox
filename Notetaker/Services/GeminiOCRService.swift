import Foundation
import AppKit

/// Gemini-backed text extraction tuned for chat screenshots.
///
/// Vision (`ImageOCRService`) is fast and offline but brittle for the
/// specific use case the user asked for — pulling clean message text
/// out of an Instagram / Messages / WhatsApp screenshot. Vision returns
/// every recognized line in geometric reading order, which means
/// timestamps, reaction overlays, sender headers, and the "typing…"
/// indicator all land in the output too. The user wanted the kind of
/// summary they could paste straight into a note: just the messages,
/// in chronological order, attributed if multiple senders show up.
///
/// Gemini 2.0 Flash hits that sweet spot — it's cheap, fast (~1-2s
/// round-trip on a typical screenshot), and the structured prompt
/// below reliably collapses chat UI noise into clean text. The user
/// supplies their own API key in Settings; the service does nothing
/// until a key exists.
///
/// Network behavior: a single POST to the Gemini REST endpoint with
/// the image inlined as base64 and the prompt as a sibling text part.
/// Uses `URLSession.shared` — no custom session config needed since
/// Gemini's CDN handles TLS/HTTP2 fine, and a per-call session would
/// just leak resources. 30-second timeout because chat screenshots
/// are small and a slow response usually means the user's connection
/// dropped, not that Gemini is genuinely thinking hard about it.
enum GeminiOCRService {

    /// Result of an extraction attempt — separates "no API key" from
    /// "API said no" from "extracted text" so the caller (a context
    /// menu handler) can give the user the right next step.
    enum Result {
        case missingAPIKey
        /// Gemini returned text. May be empty if the screenshot
        /// didn't contain anything that looked like chat messages.
        case success(String)
        /// Network or parse failure. The string is suitable for
        /// surfacing to the user verbatim — kept short so it can ride
        /// in a haptic-paired notification.
        case failure(String)
    }

    /// Default key for `@AppStorage` so the SettingsView and this
    /// service stay in sync without a magic-string typo. Kept here
    /// (not in some shared constants module) because the service is
    /// the only consumer outside Settings, and putting it next to
    /// the call site is easier to audit than chasing a constant.
    static let apiKeyDefaultsKey = "geminiApiKey"

    /// Pull a clean chat-message transcript out of `url`. Returns the
    /// text on success — the caller is responsible for routing it
    /// (typically straight to the system clipboard).
    static func extractMessages(from url: URL) async -> Result {
        let key = (UserDefaults.standard.string(forKey: apiKeyDefaultsKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return .missingAPIKey }

        guard let imageData = try? Data(contentsOf: url) else {
            return .failure("Couldn't read image")
        }

        // Gemini wants images inlined as base64 in the request body.
        // For a typical 4MB screenshot the encoded payload is ~5.4MB,
        // well under the model's per-request limit. We could detour
        // through the Files API for huge captures, but chat
        // screenshots virtually never approach that size.
        let base64 = imageData.base64EncodedString()
        let mime = mimeType(for: url)

        // Prompt is structured to give the model a clear, narrow job:
        // emit messages in chronological order, attribute when there
        // are multiple senders, drop everything else (timestamps,
        // status indicators, reactions, UI chrome). Asking for "no
        // commentary" up front prevents Gemini from prepending
        // "Here are the messages from the screenshot:" which the
        // user would then have to manually trim out of their note.
        let prompt = """
        You are extracting chat messages from a screenshot for a notes app. Output ONLY the messages, in the order they appear (oldest at top, newest at bottom).

        Rules:
        - One message per line.
        - If there are multiple participants, prefix each line with the sender's name and a colon (e.g., "Alex: hey what's up"). If there's only one sender visible, don't include a name.
        - Drop timestamps, read receipts, reactions, "typing…" indicators, and any UI chrome.
        - Preserve emoji and punctuation as written.
        - Do NOT add commentary, headers, or explanation. Just the messages.

        If the image doesn't contain chat messages, output the literal string: NO_MESSAGES
        """

        let endpoint = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent?key=\(key)")!

        let body: [String: Any] = [
            "contents": [
                [
                    "parts": [
                        ["text": prompt],
                        [
                            "inline_data": [
                                "mime_type": mime,
                                "data": base64
                            ]
                        ]
                    ]
                ]
            ],
            // Lower temperature pushes the model toward the literal
            // transcript and away from creative paraphrasing — we want
            // the user's own words back, not Gemini's interpretation.
            "generationConfig": [
                "temperature": 0.2,
                "maxOutputTokens": 2048
            ]
        ]

        guard let payload = try? JSONSerialization.data(withJSONObject: body) else {
            return .failure("Couldn't encode request")
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = payload
        request.timeoutInterval = 30

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failure("No response")
            }
            guard (200..<300).contains(http.statusCode) else {
                // Surface the most actionable hint we can. 400/403 are
                // almost always "bad API key" or "key without Gemini
                // enabled"; 429 is rate limiting; everything else
                // collapses to a generic message.
                let hint: String
                switch http.statusCode {
                case 400, 401, 403: hint = "Check your Gemini API key in Settings"
                case 429: hint = "Gemini rate limit hit — try again shortly"
                default: hint = "Gemini error \(http.statusCode)"
                }
                return .failure(hint)
            }

            guard let text = parseGeminiText(data) else {
                return .failure("Gemini returned no text")
            }

            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == "NO_MESSAGES" || trimmed.isEmpty {
                // The model gave us its sentinel — bubble up an empty
                // success so the caller can decide whether to fall back
                // to plain Vision OCR or just play a "nothing here"
                // haptic.
                return .success("")
            }
            return .success(trimmed)
        } catch {
            return .failure("Network: \(error.localizedDescription)")
        }
    }

    // MARK: - Helpers

    /// Walk the Gemini response shape down to the first text part.
    /// Hand-rolled rather than using Codable because the only field we
    /// need is `candidates[0].content.parts[0].text` — modeling the
    /// whole response struct would be three nested types of overhead
    /// for one string. If Gemini's schema ever changes, this is also
    /// trivially diagnosable from a single line in the debugger.
    private static func parseGeminiText(_ data: Data) -> String? {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let candidates = json["candidates"] as? [[String: Any]],
            let first = candidates.first,
            let content = first["content"] as? [String: Any],
            let parts = content["parts"] as? [[String: Any]],
            let firstPart = parts.first,
            let text = firstPart["text"] as? String
        else { return nil }
        return text
    }

    private static func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "heic": return "image/heic"
        default: return "image/png"
        }
    }
}
