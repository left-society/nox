import AppKit
import Foundation

/// Pure decision over the clipboard. The `show()` handler in
/// `PanelWindowController` calls this once on every panel open
/// (when `changeCount` advanced) and switches tabs / dispatches
/// content based on what it returns.
///
/// Priority order — most specific signal wins:
///   1. Video — yt-dlp-able link in any pasteboard type, or a
///      local mp4/mov/etc file URL.
///   2. Image — png/tiff/etc bytes directly on the pasteboard,
///      OR a file URL pointing at an image extension.
///   3. File URLs — anything left that's still a file URL goes
///      to Files (the staging tab).
///   4. Plain text — only fires if no file URLs were on the
///      pasteboard. Routes to Notes.
///   5. Otherwise → no routing change.
enum RoutingDecision: Equatable {
    case notes(text: String)
    case images(data: Data, mime: String)
    case videos(url: URL)
    case files(urls: [URL])
    case none
}

enum ClipboardRouter {
    static func decide(pasteboard pb: NSPasteboard = .general) -> RoutingDecision {
        // Video first — yt-dlp-able links pasted as plain text or
        // local mp4/mov file URLs.
        if let candidate = VideoDropScanner.findCandidate(in: pb) {
            switch candidate {
            case .localFile(let url):
                return .videos(url: url)
            case .remoteURL(let s):
                if let url = URL(string: s) {
                    return .videos(url: url)
                }
            }
        }

        // Image bytes on the pasteboard — screenshot copies, browser
        // image-copies, or image-extension file URLs.
        if let (data, mime) = ImageDropExtractor.extract(from: pb) {
            return .images(data: data, mime: mime)
        }

        // File URLs that weren't claimed as image or video go to Files.
        if let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL],
           !urls.isEmpty {
            let fileUrls = urls.filter { $0.isFileURL }
            if !fileUrls.isEmpty {
                return .files(urls: fileUrls)
            }
        }

        // Plain text last — only fires if no file URLs were on the
        // pasteboard above. Whitespace-only strings don't count.
        if let text = pb.string(forType: .string) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return .notes(text: text)
            }
        }

        return .none
    }
}
