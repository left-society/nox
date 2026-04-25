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
        var args: [String] = [
            url,
            "-o", outputTemplate,
            "--newline",
            "--no-part",
            "--no-playlist",
            "--no-mtime",
            "--no-cache-dir",
            "--write-info-json",
            "--write-thumbnail",
            "--convert-thumbnails", "jpg",
            "-f", "mp4/bv*+ba/best",
            "--merge-output-format", "mp4",
            "--progress-template",
            "download:PROG|%(progress.status)s|%(progress.downloaded_bytes)s|%(progress.total_bytes)s|%(progress.speed)s|%(progress.eta)s",
        ]
        if !ffmpegPath.isEmpty {
            args.append(contentsOf: ["--ffmpeg-location", ffmpegPath])
        }
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

        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            for line in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
                if let p = Self.parseProgressLine(String(line)) {
                    onProgress(p)
                }
            }
        }

        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty, let text = String(data: data, encoding: .utf8) {
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

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            p.terminationHandler = { _ in
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                continuation.resume()
            }
        }
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

    private static func parseProgressLine(_ raw: String) -> DownloadProgress? {
        guard let range = raw.range(of: "PROG|") else { return nil }
        let body = raw[range.upperBound...]
        let parts = body.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 4 else { return nil }
        let downloaded = Int64(parts[1]) ?? 0
        let total = Int64(parts[2])
        let speed = Double(parts[3])
        let eta = parts.count > 4 ? Double(parts[4]) : nil
        let fraction: Double
        if let total, total > 0 {
            fraction = min(1.0, Double(downloaded) / Double(total))
        } else {
            fraction = 0
        }
        return DownloadProgress(
            fraction: fraction,
            downloadedBytes: downloaded,
            totalBytes: total,
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
