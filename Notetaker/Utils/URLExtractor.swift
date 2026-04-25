import Foundation

/// Pulls the first http/https URL out of a string. Used by the
/// notes list to decide whether to render a link-preview chip on
/// a note row.
///
/// Backed by `NSDataDetector` so it handles the same surface as
/// Apple's own text-recognition stack — smart quotes, trailing
/// punctuation, surrounding markdown, etc. We deliberately filter
/// out non-web schemes (file://, mailto:, tel:, message:) since
/// LinkPresentation only fetches metadata for HTTP(S).
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
