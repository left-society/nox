import Foundation

struct DownloadProgress {
    var fraction: Double
    var downloadedBytes: Int64?
    var totalBytes: Int64?
    var speedBytesPerSec: Double?
    var etaSec: Double?
}

struct DownloadResult {
    var fileURL: URL
    var thumbURL: URL?
    var infoURL: URL?
    var title: String?
    var durationSec: Double?
    var width: Int?
    var height: Int?
    var extractor: String?
    var sizeBytes: Int64?
}

enum DownloadError: LocalizedError {
    case binaryMissing
    case ytDlpFailed(code: Int32, message: String)
    case outputMissing
    case cancelled

    var errorDescription: String? {
        switch self {
        case .binaryMissing: return "Video downloader binary is missing from the app."
        case .ytDlpFailed(_, let message): return message.isEmpty ? "Download failed." : message
        case .outputMissing: return "Downloader finished but no video file was produced."
        case .cancelled: return "Cancelled."
        }
    }
}

final class VideoDownloader {
    static func ytDlpURL() -> URL? {
        Bundle.main.resourceURL?.appendingPathComponent("bin/yt-dlp")
    }

    static func ffmpegURL() -> URL? {
        Bundle.main.resourceURL?.appendingPathComponent("bin/ffmpeg")
    }

    private var process: Process?
    private var isCancelled = false

    func cancel() {
        isCancelled = true
        process?.terminate()
    }

    func download(
        url: String,
        outputDir: URL,
        id: String,
        onProgress: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> DownloadResult {
        NSLog("VideoDownloader.download url=\(url) outputDir=\(outputDir.path)")
        guard let ytdlp = Self.ytDlpURL(),
              FileManager.default.fileExists(atPath: ytdlp.path) else {
            NSLog("VideoDownloader.download binary missing at \(Self.ytDlpURL()?.path ?? "nil")")
            throw DownloadError.binaryMissing
        }
        let ffmpegPath = Self.ffmpegURL()?.path ?? ""
        NSLog("VideoDownloader.download ytdlp=\(ytdlp.path) ffmpeg=\(ffmpegPath.isEmpty ? "<none>" : ffmpegPath)")

        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let outputTemplate = outputDir.appendingPathComponent("\(id).%(ext)s").path

        let p = Process()
        p.executableURL = ytdlp
        // Per BUG-114 fix: read the user's "Default quality"
        // setting from UserDefaults and translate to a yt-dlp
        // -f format string. Previously this UserDefaults key was
        // ONLY written by the Settings UI and never read — the
        // user could pick "720p" / "Best" but every download
        // ignored the choice. Now the choice actually drives
        // yt-dlp's format selector. Defaults to "1080p" when
        // unset (matches the Settings UI's default).
        let qualityRaw = UserDefaults.standard.string(forKey: "videoQualityRaw") ?? "1080p"
        let formatSelector: String
        switch qualityRaw {
        case "720p":
            // Cap at 720p height. Mirrors the explicit user
            // intent ("don't burn bandwidth on 4K"). Falls back
            // through smaller heights, then mp4 at any size,
            // then best of anything.
            formatSelector = "bv*[height<=720]+ba/b[height<=720]/best"
        case "Best":
            // Best video + best audio, merged. Resolution-
            // unconstrained.
            formatSelector = "bv*+ba/best"
        default: // 1080p (default)
            formatSelector = "bv*[height<=1080]+ba/b[height<=1080]/best"
        }

        // Per BUG-005 fix: yt-dlp itself parses options out of its
        // argv. If a clipboard or drag-drop string starts with
        // "--exec=rm -rf ~" or "--config-location ...", yt-dlp
        // would interpret it as an option flag, NOT a URL — and
        // `--exec` runs arbitrary shell commands during download.
        // The `--` token tells yt-dlp "stop parsing options; what
        // follows is positional," which makes the URL inert no
        // matter what string is in there. Process arguments
        // themselves aren't shell-interpreted (we use argv, not
        // /bin/sh), so the only attack surface is yt-dlp's own
        // option parser. The `--` closes it.
        var args: [String] = [
            "-o", outputTemplate,
            "--newline",
            "--no-part",
            "--no-playlist",
            "--no-mtime",
            "--no-cache-dir",
            "--write-info-json",
            "--write-thumbnail",
            "--convert-thumbnails", "jpg",
            "-f", formatSelector,
            "--merge-output-format", "mp4",
            // Added `total_bytes_estimate` so the parser has a
            // fallback when `total_bytes` is NA — which is the
            // ENTIRE first phase of HLS / DASH / fragment-based
            // downloads. Without an estimate the bar reads 0%
            // until the very end, then snaps to 100%. With it,
            // the bar moves smoothly throughout (yt-dlp's
            // estimate is computed from the manifest before
            // a single byte is fetched).
            "--progress-template",
            "download:PROG|%(progress.status)s|%(progress.downloaded_bytes)s|%(progress.total_bytes)s|%(progress.total_bytes_estimate)s|%(progress.speed)s|%(progress.eta)s",
        ]
        if !ffmpegPath.isEmpty {
            args.append(contentsOf: ["--ffmpeg-location", ffmpegPath])
        }
        // The `--` MUST come last so any further options we add
        // above still get parsed. The user-supplied URL is the
        // only positional after the option terminator.
        args.append("--")
        args.append(url)
        p.arguments = args

        var env = ProcessInfo.processInfo.environment
        env["LC_ALL"] = "en_US.UTF-8"
        env["LANG"] = "en_US.UTF-8"
        env["PYTHONIOENCODING"] = "utf-8"
        p.environment = env

        let stdout = Pipe()
        let stderr = Pipe()
        p.standardOutput = stdout
        p.standardError = stderr

        let stderrHolder = StderrHolder()

        // Per BUG-006 watchdog: timestamp of the last activity
        // observed on either pipe. If the read-side handlers stop
        // firing for too long we assume yt-dlp is stuck (typically
        // because the GCD queue dispatching readabilityHandler has
        // stalled and the OS pipe buffer filled, blocking yt-dlp's
        // next write). The watchdog Task below kills the process
        // in that case so the UI doesn't hang in "Downloading"
        // forever.
        let lastActivity = TimestampHolder()

        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            lastActivity.touch()
            for line in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
                if let p = Self.parseProgressLine(String(line)) {
                    onProgress(p)
                }
            }
        }

        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty, let text = String(data: data, encoding: .utf8) {
                lastActivity.touch()
                stderrHolder.append(text)
            }
        }

        self.process = p
        NSLog("VideoDownloader.download spawning yt-dlp args=\(args)")
        do {
            try p.run()
        } catch {
            NSLog("VideoDownloader.download Process.run threw: \(error)")
            throw error
        }
        NSLog("VideoDownloader.download yt-dlp pid=\(p.processIdentifier)")
        lastActivity.touch()

        // Watchdog: poll every 5s while the process is running.
        // If no pipe activity in 300s, terminate yt-dlp.
        //
        // 300s (was 120s) accounts for the FFMPEG MERGE phase at
        // the end of multi-format downloads. yt-dlp downloads
        // video + audio separately and then invokes ffmpeg to
        // merge them into a single mp4. During merge, yt-dlp
        // emits no progress lines on stdout AND ffmpeg-merge of
        // a 4K / 1-hour video on a slow Mac can take 2-3 minutes
        // of pure CPU work without writing anything to stderr.
        // The earlier 120s window was triggering false-positive
        // kills on legitimate end-of-download merges. 300s is
        // comfortably above the worst observed merge time
        // (~150s on an M1 with thermal throttling) and still
        // catches actually-stuck pipes within a reasonable
        // window. Stops on its own when the process exits.
        let watchdog = Task.detached {
            let stallLimit: TimeInterval = 300
            while p.isRunning {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                if !p.isRunning { break }
                let idle = Date().timeIntervalSince(lastActivity.value)
                if idle >= stallLimit {
                    NSLog("VideoDownloader watchdog: no pipe activity for \(Int(idle))s, killing yt-dlp pid=\(p.processIdentifier)")
                    p.terminate()
                    break
                }
            }
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            p.terminationHandler = { _ in
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                continuation.resume()
            }
        }
        watchdog.cancel()
        self.process = nil

        NSLog("VideoDownloader.download exited code=\(p.terminationStatus) cancelled=\(isCancelled)")
        if !stderrHolder.tail().isEmpty {
            NSLog("VideoDownloader.download stderr tail: \(stderrHolder.tail(500))")
        }

        if isCancelled {
            throw DownloadError.cancelled
        }
        if p.terminationStatus != 0 {
            throw DownloadError.ytDlpFailed(
                code: p.terminationStatus,
                message: stderrHolder.tail()
            )
        }

        return try Self.collectResult(outputDir: outputDir, id: id)
    }

    /// Tracks the LAST KNOWN good downloaded-bytes value across
    /// successive progress lines. yt-dlp's `progress.downloaded_bytes`
    /// can flicker to "NA" between segments / phases of a fragmented
    /// download (HLS / DASH); we use the last known value when the
    /// current one is unparseable so the progress bar doesn't
    /// reset to 0 (or freeze) every time. Static-thread-local-style
    /// state is fine here — parseProgressLine is only called from
    /// the stdout readabilityHandler of one yt-dlp process at a
    /// time per VideoDownloader instance, and instances aren't
    /// shared across downloads.
    private static var lastKnownDownloadedBytes: Int64 = 0

    private static func parseProgressLine(_ raw: String) -> DownloadProgress? {
        guard let range = raw.range(of: "PROG|") else { return nil }
        let body = raw[range.upperBound...]
        let parts = body.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        // New template shape: status | downloaded | total | total_estimate | speed | eta
        guard parts.count >= 5 else { return nil }

        let downloaded: Int64
        if let parsed = Int64(parts[1]) {
            downloaded = parsed
            lastKnownDownloadedBytes = parsed
        } else {
            downloaded = lastKnownDownloadedBytes
        }
        let total = Int64(parts[2])
        let totalEstimate = Int64(parts[3])
        let speed = Double(parts[4])
        let eta = parts.count > 5 ? Double(parts[5]) : nil

        // BUG-032 fix v3: the bar was sitting at 0% all the way
        // through HLS/DASH downloads because `total_bytes` is NA
        // for those — yt-dlp only has the manifest's
        // `total_bytes_estimate` until the final segment lands.
        // The previous logic returned `fraction = 0` whenever
        // `total` was missing, so the user saw a stuck bar from
        // start until the very last moment when total fills in
        // and the math suddenly works. Now we cascade through
        // total → estimate → ETA-derived progress, in that order.
        let fraction: Double
        if let total, total > 0 {
            fraction = min(1.0, Double(downloaded) / Double(total))
        } else if let totalEstimate, totalEstimate > 0 {
            fraction = min(0.99, Double(downloaded) / Double(totalEstimate))
        } else if let eta, eta > 0, let speed, speed > 0 {
            // Last-resort smooth motion: assume the bar should
            // travel from current/(current+speed*eta) every tick.
            // Caps at 0.95 so the bar never claims completion
            // before it's actually done — only the terminal
            // status line gets to push fraction to 1.0.
            let projectedTotal = Double(downloaded) + speed * eta
            fraction = projectedTotal > 0 ? min(0.95, Double(downloaded) / projectedTotal) : 0
        } else {
            fraction = 0
        }
        return DownloadProgress(
            fraction: fraction,
            downloadedBytes: downloaded,
            totalBytes: total ?? totalEstimate,
            speedBytesPerSec: speed,
            etaSec: eta
        )
    }

    private static func collectResult(outputDir: URL, id: String) throws -> DownloadResult {
        let fm = FileManager.default
        let contents = (try? fm.contentsOfDirectory(at: outputDir, includingPropertiesForKeys: nil)) ?? []
        let matching = contents.filter { $0.lastPathComponent.hasPrefix("\(id).") }

        let videoURL = matching.first { url in
            let name = url.lastPathComponent
            return !name.hasSuffix(".info.json")
                && !name.hasSuffix(".jpg")
                && !name.hasSuffix(".jpeg")
                && !name.hasSuffix(".png")
                && !name.hasSuffix(".webp")
        }
        guard let videoURL else { throw DownloadError.outputMissing }

        let thumbURL = matching.first { $0.lastPathComponent.hasSuffix(".jpg") }
        let infoURL = matching.first { $0.lastPathComponent.hasSuffix(".info.json") }

        var title: String?
        var durationSec: Double?
        var width: Int?
        var height: Int?
        var extractor: String?
        if let infoURL,
           let data = try? Data(contentsOf: infoURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            title = json["title"] as? String
            durationSec = json["duration"] as? Double
            width = json["width"] as? Int
            height = json["height"] as? Int
            extractor = (json["extractor_key"] as? String) ?? (json["extractor"] as? String)
        }

        let attrs = try? fm.attributesOfItem(atPath: videoURL.path)
        let sizeBytes = (attrs?[.size] as? NSNumber)?.int64Value

        return DownloadResult(
            fileURL: videoURL,
            thumbURL: thumbURL,
            infoURL: infoURL,
            title: title,
            durationSec: durationSec,
            width: width,
            height: height,
            extractor: extractor,
            sizeBytes: sizeBytes
        )
    }
}

private final class StderrHolder: @unchecked Sendable {
    private let queue = DispatchQueue(label: "VideoDownloader.stderr")
    private var buffer = ""

    func append(_ text: String) {
        queue.sync { buffer.append(text) }
    }

    func tail(_ maxChars: Int = 800) -> String {
        queue.sync {
            let trimmed = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.count <= maxChars { return trimmed }
            let start = trimmed.index(trimmed.endIndex, offsetBy: -maxChars)
            return "…" + String(trimmed[start...])
        }
    }
}

/// Thread-safe holder for the last-pipe-activity timestamp used
/// by the BUG-006 watchdog. `touch()` is called from the
/// readabilityHandler closures (any GCD queue), the watchdog
/// Task reads `value` while polling.
private final class TimestampHolder: @unchecked Sendable {
    private let queue = DispatchQueue(label: "VideoDownloader.timestamp")
    private var ts = Date()

    func touch() {
        queue.sync { ts = Date() }
    }

    var value: Date {
        queue.sync { ts }
    }
}
