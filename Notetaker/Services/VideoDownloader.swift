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

    /// Probe the filesystem for a `node` binary and return its absolute
    /// path if found. yt-dlp's web player_client requires a JavaScript
    /// runtime to decrypt YouTube's signed URL signatures; macOS users
    /// commonly have node installed via homebrew or nvm but the .app
    /// process doesn't inherit those tool dirs in PATH. We pass the
    /// resolved path explicitly via `--js-runtimes node:<path>`.
    ///
    /// Search order matches typical macOS install priorities:
    ///   1. Homebrew Apple Silicon (`/opt/homebrew/bin/node`)
    ///   2. Homebrew Intel (`/usr/local/bin/node`)
    ///   3. System (`/usr/bin/node` — rare; macOS doesn't ship node)
    ///   4. Latest nvm-installed node
    ///   5. `which node` via login shell as last resort (handles
    ///      asdf, fnm, volta, and other version managers)
    static func findNode() -> String? {
        let fm = FileManager.default
        let staticCandidates = [
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node",
            "/usr/bin/node"
        ]
        for path in staticCandidates {
            if fm.isExecutableFile(atPath: path) { return path }
        }
        // nvm: pick the highest-versioned install. Sort
        // lexicographically (nvm names dirs `v20.20.2` etc., which
        // sorts roughly correctly within a major-version line — close
        // enough; the user only needs A node, not the latest).
        let nvmDir = ("~/.nvm/versions/node" as NSString).expandingTildeInPath
        if let entries = try? fm.contentsOfDirectory(atPath: nvmDir) {
            let sorted = entries.sorted(by: >)
            for entry in sorted {
                let nodePath = "\(nvmDir)/\(entry)/bin/node"
                if fm.isExecutableFile(atPath: nodePath) { return nodePath }
            }
        }
        // Last resort: ask a login shell to resolve `node`. Login
        // shell sources the user's profile so PATH includes whatever
        // their version manager (asdf/fnm/volta) injects.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l", "-c", "command -v node"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                let path = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let path, !path.isEmpty,
                   fm.isExecutableFile(atPath: path) {
                    return path
                }
            }
        } catch {
            NSLog("VideoDownloader.findNode login-shell probe failed: \(error)")
        }
        return nil
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
        // 2026-05-04: PRIORITIZE mp4-compatible streams (H.264 video +
        // AAC audio). User reported downloads landing as `.webm`
        // (VP9/AV1+Opus) which Premiere Pro can't import natively.
        // YouTube serves VP9/AV1 webm alongside H.264 mp4 at 1080p
        // and below; without an explicit `[ext=mp4]` filter, yt-dlp's
        // "best" selector picks the higher-bitrate webm.
        //
        // Format string ladder, evaluated in order until one matches:
        //   1. mp4 video stream + m4a audio stream (cleanest path —
        //      H.264/AAC, merges directly into mp4 with no recode)
        //   2. mp4-only combined stream (older single-file route)
        //   3. ANY video + audio (fallback — webm/AV1 if mp4 absent)
        //   4. ANY combined stream (last resort)
        // The `--recode-video mp4` flag below converts step 3/4
        // outputs to H.264 mp4 post-download — slow (re-encodes)
        // but guarantees a Premiere-readable file. For step 1/2 the
        // recode is a no-op (already mp4/H.264).
        switch qualityRaw {
        case "720p":
            // Top rung pins vcodec to avc1 (H.264) and acodec to mp4a
            // (AAC). [ext=mp4] alone is no longer sufficient: YouTube
            // serves AV1 inside mp4 containers for an increasing
            // share of videos, and Premiere/FCP/DaVinci can't import
            // AV1. avc1 is universally supported by NLEs.
            formatSelector = "bv*[vcodec^=avc1][height<=720]+ba[acodec^=mp4a]/bv*[ext=mp4][height<=720]+ba[ext=m4a]/b[ext=mp4][height<=720]/bv*[height<=720]+ba/b[height<=720]/bv*+ba/best"
        case "Best":
            formatSelector = "bv*[vcodec^=avc1]+ba[acodec^=mp4a]/bv*[ext=mp4]+ba[ext=m4a]/b[ext=mp4]/bv*+ba/best"
        default: // 1080p (default)
            formatSelector = "bv*[vcodec^=avc1][height<=1080]+ba[acodec^=mp4a]/bv*[ext=mp4][height<=1080]+ba[ext=m4a]/b[ext=mp4][height<=1080]/bv*[height<=1080]+ba/b[height<=1080]/bv*+ba/best"
        }
        // Vertical-Shorts safety net: every rung above with
        // `[height<=720]` / `[height<=1080]` filters by the VERTICAL
        // dimension. A vertical 1080p Short is 1080×1920 — height=1920,
        // so every height-capped rung skips and the chain used to
        // fall through to `best` alone. In some yt-dlp paths `best`
        // can land on audio-only when no single-file video format
        // matches, which is exactly the "downloaded a Short and got
        // an mp3" symptom. The new `bv*+ba` rung BEFORE `best`
        // forces a video+audio merge whenever any video stream
        // exists at any resolution — Shorts get a video file,
        // landscape clips still get the height-capped preference.

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
            // Belt-and-suspenders for Premiere Pro compatibility.
            //
            // `--remux-video mp4`: if the merged file landed in a
            // non-mp4 container (mkv/webm — happens when yt-dlp picks
            // a non-mp4 codec via the format ladder's fallback rungs)
            // but the codecs ARE mp4-compatible, this rewrites the
            // container with no re-encode. Free when applicable.
            //
            // `--recode-video mp4`: if the streams aren't mp4-
            // compatible (VP9, AV1, Opus), transcode to H.264/AAC
            // mp4. Slow — re-encoding a 4K AV1 video can take many
            // minutes — but it's the only way to produce a file
            // Premiere can import directly. yt-dlp pipelines these:
            // remux runs first; recode only kicks in when remux
            // can't (incompatible codecs).
            //
            // Combined effect: Premiere/Final Cut/DaVinci can ALWAYS
            // import the resulting file. For the common case (1080p
            // YouTube where format selector already picks H.264 mp4)
            // both flags are no-ops at the cost of one stat call.
            "--remux-video", "mp4",
            "--recode-video", "mp4",
            // YouTube-specific player-client preference. Different
            // clients return different player-response payloads:
            //   • `android` — typically returns ready-to-stream URLs
            //     that don't require JavaScript signature decryption.
            //   • `tv_embedded` — bypasses age-gate and some bot
            //     checks that the web client trips.
            //   • `web` — most format coverage but ALWAYS requires JS
            //     evaluation (nsig decryption).
            // yt-dlp tries each client in order until one returns
            // playable formats. Android-first means most downloads
            // succeed even when no JS runtime is available; web is
            // there as a last resort.
            "--extractor-args", "youtube:player_client=android,tv_embedded,web",
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
        // 2026-05-05: Make a JS runtime visible to yt-dlp so the
        // `web` player_client fallback can decrypt the signature
        // when `android` and `tv_embedded` don't return formats.
        // yt-dlp 2026.x defaults `--js-runtimes deno`, but the .app
        // bundle doesn't ship deno and macOS users typically don't
        // have it. Node is much more common (homebrew, nvm). We
        // probe the usual install paths and pass an explicit path
        // so yt-dlp finds node even though the .app's PATH doesn't
        // include nvm/homebrew shim dirs.
        if let nodePath = Self.findNode() {
            args.append(contentsOf: ["--js-runtimes", "node:\(nodePath)"])
            NSLog("VideoDownloader.download passing --js-runtimes node:\(nodePath)")
        } else {
            NSLog("VideoDownloader.download no node found — relying on android/tv_embedded clients (web fallback may fail)")
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

        var result = try Self.collectResult(outputDir: outputDir, id: id)
        // NLE-compatibility safety net. yt-dlp's `--recode-video mp4`
        // skips the convert step when the source extension matches
        // the target — so a file that landed as `.mp4` but with AV1
        // INSIDE the mp4 container passes through untouched. Premiere
        // (and FCP, DaVinci, Resolve free) error on AV1 with messages
        // like `File uses unsupported video compression type "av01"`.
        //
        // We probe the codec via ffmpeg and, if it isn't H.264,
        // transcode in-place to H.264/AAC mp4. Slow (re-encode), but
        // only triggers for the rare case where YouTube served AV1
        // and the format selector's avc1 preference fell through.
        // No-op for the common case (already H.264).
        if !ffmpegPath.isEmpty {
            do {
                result.fileURL = try Self.ensureH264MP4(
                    at: result.fileURL,
                    ffmpegPath: ffmpegPath
                )
            } catch {
                // Don't fail the whole download if the codec-fix pass
                // errors — the user has a file, even if Premiere can't
                // import it. Surface in NSLog so we can debug from
                // /tmp/notetaker-dictation.log via the AppDelegate
                // bridge if it recurs.
                NSLog("VideoDownloader.download codec-fix failed (keeping original): \(error)")
            }
        }
        return result
    }

    /// If the file at `url` is not already H.264 in mp4, re-encode
    /// it in place using bundled ffmpeg. Returns the URL of the
    /// final file (typically the same URL — we transcode to a temp
    /// path and atomically swap, but the path/extension stay mp4).
    ///
    /// Codec detection is done by parsing `ffmpeg -i` stderr (the
    /// banner ffmpeg prints describing input streams). We look for
    /// `Video: h264` (or the legacy `Video: avc1` synonym). Any
    /// other codec (av01, vp09, hevc, mpeg4) triggers the recode.
    private static func ensureH264MP4(at url: URL, ffmpegPath: String) throws -> URL {
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: ffmpegPath)
        // `-hide_banner` suppresses ffmpeg's ~10 lines of build/config
        // header. The stream description follows regardless.
        // Probe-only: no output file. ffmpeg returns non-zero because
        // we don't give it an output, but it still prints stream info
        // to stderr first — which is exactly what we want.
        probe.arguments = ["-hide_banner", "-i", url.path]
        let probeStderr = Pipe()
        probe.standardError = probeStderr
        probe.standardOutput = Pipe()  // discard
        try probe.run()
        let stderrData = probeStderr.fileHandleForReading.readDataToEndOfFile()
        probe.waitUntilExit()
        let stderrText = String(data: stderrData, encoding: .utf8) ?? ""

        // Match against known H.264 markers. ffmpeg labels H.264 as
        // "h264" in the stream descriptor; the codec_tag_string can
        // also be "avc1". Either means we're already Premiere-friendly.
        let isH264 = stderrText.contains("Video: h264")
            || stderrText.contains("Video: avc1")
        if isH264 {
            NSLog("VideoDownloader.ensureH264MP4 already H.264, no recode")
            return url
        }
        NSLog("VideoDownloader.ensureH264MP4 codec is NOT H.264, transcoding (stderr-snippet: \(String(stderrText.prefix(400))))")

        // Transcode to a sibling temp file, then atomically replace.
        // libx264 + AAC + faststart is the universal NLE-friendly
        // combo. CRF 20 = visually lossless to most eyes, smaller
        // than -crf 18. preset medium balances encode speed vs
        // compression efficiency for desktop machines.
        let tempURL = url.deletingPathExtension()
            .appendingPathExtension("tmp.mp4")
        // Defensive: clean up any stale temp file from a previous
        // failed transcode. Without this a `mv` step below would fail
        // with "file exists."
        try? FileManager.default.removeItem(at: tempURL)
        let transcode = Process()
        transcode.executableURL = URL(fileURLWithPath: ffmpegPath)
        transcode.arguments = [
            "-y",
            "-i", url.path,
            "-c:v", "libx264",
            "-preset", "medium",
            "-crf", "20",
            "-pix_fmt", "yuv420p",  // broad NLE compatibility
            "-c:a", "aac",
            "-b:a", "192k",
            "-movflags", "+faststart",
            tempURL.path
        ]
        let transcodeStderr = Pipe()
        transcode.standardError = transcodeStderr
        transcode.standardOutput = Pipe()
        try transcode.run()
        transcode.waitUntilExit()
        if transcode.terminationStatus != 0 {
            let errData = transcodeStderr.fileHandleForReading.readDataToEndOfFile()
            let errText = String(data: errData, encoding: .utf8) ?? ""
            try? FileManager.default.removeItem(at: tempURL)
            throw DownloadError.ytDlpFailed(
                code: transcode.terminationStatus,
                message: "ffmpeg transcode to H.264 failed: \(errText.suffix(400))"
            )
        }

        // Replace original with transcoded version. Same filename so
        // VideoStore / FilesGridView don't need to be told the path
        // changed.
        try FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: tempURL, to: url)
        NSLog("VideoDownloader.ensureH264MP4 transcode complete at \(url.path)")
        return url
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
