import AppKit
import Foundation

/// Pulls a video-downloader-friendly URL (or local file) out of a drag pasteboard.
///
/// Browsers stash the source page URL in non-standard pasteboard types when you
/// drag a media element. This scanner walks those types in priority order so
/// that dragging a `<video>`, a thumbnail, or a link all resolve to the post
/// page URL yt-dlp can actually process.
enum VideoDropScanner {
    enum Candidate {
        case localFile(URL)
        case remoteURL(String)
    }

    static let videoExts: Set<String> = [
        "mp4", "m4v", "mov", "webm", "mkv", "avi", "flv", "wmv", "mpg", "mpeg"
    ]

    static let videoHosts: Set<String> = [
        "youtube.com", "www.youtube.com", "m.youtube.com", "youtu.be", "music.youtube.com",
        "instagram.com", "www.instagram.com",
        "tiktok.com", "www.tiktok.com", "vm.tiktok.com", "m.tiktok.com",
        "twitter.com", "x.com", "mobile.twitter.com",
        "vimeo.com", "www.vimeo.com", "player.vimeo.com",
        "reddit.com", "www.reddit.com", "v.redd.it", "old.reddit.com",
        "facebook.com", "www.facebook.com", "fb.watch", "m.facebook.com",
        "twitch.tv", "www.twitch.tv", "clips.twitch.tv", "m.twitch.tv",
        "dailymotion.com", "www.dailymotion.com",
        "streamable.com",
        "soundcloud.com"
    ]

    static let chromeSourceURL = NSPasteboard.PasteboardType("org.chromium.source-url")
    static let webURLsWithTitles = NSPasteboard.PasteboardType("WebURLsWithTitlesPboardType")
    static let htmlType = NSPasteboard.PasteboardType("public.html")
    static let urlType = NSPasteboard.PasteboardType("public.url")

    static let movieTypes: [NSPasteboard.PasteboardType] = [
        NSPasteboard.PasteboardType("public.movie"),
        NSPasteboard.PasteboardType("public.video"),
        NSPasteboard.PasteboardType("public.mpeg-4"),
        NSPasteboard.PasteboardType("com.apple.quicktime-movie"),
        NSPasteboard.PasteboardType("public.avi"),
        NSPasteboard.PasteboardType("org.matroska.mkv")
    ]

    static func findCandidate(in pb: NSPasteboard) -> Candidate? {
        if let src = pb.string(forType: chromeSourceURL),
           let url = URL(string: src),
           let host = url.host?.lowercased(),
           videoHosts.contains(host) {
            return .remoteURL(url.absoluteString)
        }

        if let data = pb.data(forType: webURLsWithTitles),
           let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
           let pair = plist as? [[String]],
           let urls = pair.first {
            for s in urls {
                guard let url = URL(string: s),
                      (url.scheme == "http" || url.scheme == "https"),
                      let host = url.host?.lowercased() else { continue }
                if videoHosts.contains(host) { return .remoteURL(url.absoluteString) }
            }
        }

        if let html = pb.string(forType: htmlType),
           let u = extractVideoHostURL(from: html) {
            return .remoteURL(u)
        }

        if let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL] {
            for url in urls {
                guard !url.isFileURL,
                      (url.scheme == "http" || url.scheme == "https"),
                      let host = url.host?.lowercased() else { continue }
                if videoHosts.contains(host) { return .remoteURL(url.absoluteString) }
            }
            for url in urls where url.isFileURL {
                if videoExts.contains(url.pathExtension.lowercased()) {
                    return .localFile(url)
                }
            }
        }

        if let text = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) {
            if let u = URL(string: text),
               (u.scheme == "http" || u.scheme == "https"),
               let host = u.host?.lowercased(),
               videoHosts.contains(host) {
                return .remoteURL(u.absoluteString)
            }
            if let u = extractVideoHostURL(from: text) {
                return .remoteURL(u)
            }
        }

        if let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL] {
            for url in urls {
                if !url.isFileURL, (url.scheme == "http" || url.scheme == "https") {
                    return .remoteURL(url.absoluteString)
                }
            }
        }

        return nil
    }

    static func looksLikeVideo(in pb: NSPasteboard) -> Bool {
        if pb.availableType(from: movieTypes) != nil { return true }
        guard let c = findCandidate(in: pb) else { return false }
        switch c {
        case .localFile: return true
        case .remoteURL(let s):
            guard let url = URL(string: s),
                  let host = url.host?.lowercased() else { return false }
            return videoHosts.contains(host)
        }
    }

    private static func extractVideoHostURL(from text: String) -> String? {
        let pattern = #"https?://[^\s"'<>()\\]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        for m in matches {
            let s = ns.substring(with: m.range)
            guard let url = URL(string: s), let host = url.host?.lowercased() else { continue }
            if videoHosts.contains(host) { return url.absoluteString }
        }
        return nil
    }
}
