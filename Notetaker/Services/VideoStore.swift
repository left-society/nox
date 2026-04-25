import Foundation
import AppKit
import AVFoundation
import GRDB

@MainActor
final class VideoStore: ObservableObject {
    @Published private(set) var videos: [VideoRecord] = []
    @Published private(set) var jobs: [DownloadJob] = []

    private let db: Database
    private let rootURL: URL
    private var activeDownloaders: [UUID: VideoDownloader] = [:]

    init(db: Database, rootURL: URL? = nil) throws {
        self.db = db
        if let rootURL {
            self.rootURL = rootURL
        } else {
            self.rootURL = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            ).appendingPathComponent("Notetaker", isDirectory: true)
        }
        try FileManager.default.createDirectory(
            at: self.rootURL.appendingPathComponent("videos"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: self.rootURL.appendingPathComponent("vthumbs"),
            withIntermediateDirectories: true
        )
        reload()
    }

    func reload() {
        do {
            let fetched = try db.dbQueue.read { conn in
                try VideoRecord
                    .filter(VideoRecord.Columns.status == "active")
                    .order(VideoRecord.Columns.createdAt.desc)
                    .fetchAll(conn)
            }
            self.videos = fetched
        } catch {
            NSLog("VideoStore reload failed: \(error)")
        }
    }

    func fullURL(for record: VideoRecord) -> URL {
        rootURL.appendingPathComponent(record.filePath)
    }

    func thumbURL(for record: VideoRecord) -> URL {
        rootURL.appendingPathComponent(record.thumbPath)
    }

    // MARK: - Local file

    @discardableResult
    func saveLocalFile(_ sourceURL: URL) throws -> VideoRecord {
        let id = UUID().uuidString
        let ext = sourceURL.pathExtension.isEmpty ? "mp4" : sourceURL.pathExtension
        let relFile = "videos/\(id).\(ext)"
        let destURL = rootURL.appendingPathComponent(relFile)
        try FileManager.default.copyItem(at: sourceURL, to: destURL)

        let relThumb = "vthumbs/\(id).jpg"
        let thumbURL = rootURL.appendingPathComponent(relThumb)
        Self.writeAVThumbnail(from: destURL, to: thumbURL)

        let asset = AVURLAsset(url: destURL)
        let duration = CMTimeGetSeconds(asset.duration)
        let track = asset.tracks(withMediaType: .video).first
        let natSize = track?.naturalSize ?? .zero

        let attrs = try? FileManager.default.attributesOfItem(atPath: destURL.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value

        var record = VideoRecord(
            id: id,
            noteId: nil,
            filePath: relFile,
            thumbPath: relThumb,
            sourceUrl: nil,
            title: sourceURL.deletingPathExtension().lastPathComponent,
            width: Int(natSize.width.rounded()),
            height: Int(natSize.height.rounded()),
            durationSec: duration.isFinite ? duration : nil,
            sizeBytes: size.map { Int($0) },
            mimeType: Self.mime(forExtension: ext.lowercased()),
            source: "local",
            createdAt: Date().timeIntervalSince1970,
            status: "active",
            trashedAt: nil
        )
        try db.dbQueue.write { try record.insert($0) }
        videos.insert(record, at: 0)
        return record
    }

    // MARK: - Download jobs

    @discardableResult
    func startDownload(url: String) -> DownloadJob? {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        NSLog("VideoStore.startDownload called url=\(trimmed)")
        guard !trimmed.isEmpty else {
            NSLog("VideoStore.startDownload bail: empty URL")
            return nil
        }

        if let existing = duplicateRecord(forURL: trimmed) {
            NSLog("VideoStore.startDownload duplicate of record \(existing.id) — flashing saved state")
            // Show an informational "Saved" row at the top of the jobs list
            // so the user sees *why* nothing new is downloading, instead of
            // silently popping Finder behind the panel. Auto-dismisses.
            var flash = DownloadJob(url: trimmed)
            flash.title = existing.title ?? flash.titleFallback
            flash.state = .finished(recordId: existing.id)
            jobs.insert(flash, at: 0)
            let flashID = flash.id
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 3_500_000_000)
                guard let self else { return }
                if let idx = self.jobs.firstIndex(where: { $0.id == flashID }) {
                    self.jobs.remove(at: idx)
                }
            }
            return nil
        }
        if jobs.contains(where: { $0.url == trimmed && !$0.state.isTerminal }) {
            NSLog("VideoStore.startDownload bail: job already in flight for this URL")
            return nil
        }

        let job = DownloadJob(url: trimmed)
        jobs.insert(job, at: 0)
        NSLog("VideoStore.startDownload queued job=\(job.id) jobs.count=\(jobs.count)")
        Task { await runJob(job) }
        return job
    }

    func cancelJob(_ job: DownloadJob) {
        activeDownloaders[job.id]?.cancel()
    }

    func retryJob(_ job: DownloadJob) {
        guard job.state.isTerminal else { return }
        if let idx = jobs.firstIndex(where: { $0.id == job.id }) {
            jobs.remove(at: idx)
        }
        startDownload(url: job.url)
    }

    func dismissJob(_ job: DownloadJob) {
        if let idx = jobs.firstIndex(where: { $0.id == job.id }) {
            jobs.remove(at: idx)
        }
    }

    // MARK: - Trash

    func trashAll() throws {
        let now = Date().timeIntervalSince1970
        try db.dbQueue.write { conn in
            try conn.execute(
                sql: "UPDATE videos SET status = 'trashed', trashed_at = ? WHERE status = 'active'",
                arguments: [now]
            )
        }
        videos = []
    }

    func trash(id: String) throws {
        let now = Date().timeIntervalSince1970
        try db.dbQueue.write { conn in
            try conn.execute(
                sql: "UPDATE videos SET status = 'trashed', trashed_at = ? WHERE id = ?",
                arguments: [now, id]
            )
        }
        videos.removeAll { $0.id == id }
    }

    // MARK: - Internals

    private func runJob(_ job: DownloadJob) async {
        NSLog("VideoStore.runJob start job=\(job.id)")
        let downloader = VideoDownloader()
        activeDownloaders[job.id] = downloader
        updateJob(job.id) { $0.state = .downloading }

        let tempDir = rootURL.appendingPathComponent("downloads/\(job.id.uuidString)", isDirectory: true)
        let downloadID = UUID().uuidString
        NSLog("VideoStore.runJob tempDir=\(tempDir.path)")

        // Throttle progress UI updates. yt-dlp emits 10-50 progress lines
        // per second; pushing every one through `@Published var jobs`
        // fires `objectWillChange` at the same rate, which in turn
        // invalidates every view subscribed to VideoStore. Coalescing to
        // ~10Hz (every 100ms) is well above the human visual flicker
        // threshold for a progress bar, while keeping the panel
        // responsive to clicks/scroll/typing during downloads.
        // Throttling state lives in an actor-isolated box so the
        // closure can mutate it from the @Sendable callback.
        let throttle = ProgressThrottle()

        do {
            let result = try await downloader.download(
                url: job.url,
                outputDir: tempDir,
                id: downloadID,
                onProgress: { [weak self] progress in
                    Task { @MainActor in
                        // 100ms throttle, but always let the final tick
                        // through so the bar lands cleanly at 100%.
                        let isFinal = progress.fraction >= 1.0
                        if !isFinal && !throttle.shouldEmit(now: Date()) {
                            return
                        }
                        self?.updateJob(job.id) { j in
                            j.progress = progress.fraction
                            j.downloadedBytes = progress.downloadedBytes
                            j.totalBytes = progress.totalBytes
                            j.title = j.title ?? j.titleFallback
                        }
                    }
                }
            )
            NSLog("VideoStore.runJob download finished file=\(result.fileURL.lastPathComponent) size=\(result.sizeBytes ?? -1)")
            try persistDownload(result: result, job: job, downloadID: downloadID)
            NSLog("VideoStore.runJob persisted job=\(job.id)")
        } catch let error as DownloadError {
            NSLog("VideoStore.runJob DownloadError: \(error.localizedDescription)")
            if case .cancelled = error {
                updateJob(job.id) { $0.state = .cancelled }
            } else {
                updateJob(job.id) {
                    $0.state = .failed(error.localizedDescription)
                }
            }
            try? FileManager.default.removeItem(at: tempDir)
        } catch {
            NSLog("VideoStore.runJob unknown error: \(error.localizedDescription)")
            updateJob(job.id) { $0.state = .failed(error.localizedDescription) }
            try? FileManager.default.removeItem(at: tempDir)
        }
        activeDownloaders.removeValue(forKey: job.id)
        scheduleAutoDismissIfDone(jobID: job.id)
    }

    /// Successful and cancelled rows fade themselves off the jobs list so
    /// the section doesn't grow into a graveyard the user has to manually
    /// clear. Failed rows are intentionally sticky — the user needs to see
    /// the error and decide whether to retry.
    private func scheduleAutoDismissIfDone(jobID: UUID) {
        guard let job = jobs.first(where: { $0.id == jobID }) else { return }
        let delay: UInt64
        switch job.state {
        case .finished: delay = 5_000_000_000 // 5s — long enough to read "Saved"
        case .cancelled: delay = 3_000_000_000 // 3s — less to read, sweep faster
        default: return
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard let self else { return }
            // Only sweep if the row is still the same terminal job. A retry
            // would have replaced the row with a fresh ID, so a strict id
            // match is enough — no need to re-check the state.
            if let idx = self.jobs.firstIndex(where: { $0.id == jobID }) {
                self.jobs.remove(at: idx)
            }
        }
    }

    private func persistDownload(result: DownloadResult, job: DownloadJob, downloadID: String) throws {
        let id = UUID().uuidString
        let videoExt = result.fileURL.pathExtension.isEmpty ? "mp4" : result.fileURL.pathExtension
        let relFile = "videos/\(id).\(videoExt)"
        let relThumb = "vthumbs/\(id).jpg"

        let destFile = rootURL.appendingPathComponent(relFile)
        let destThumb = rootURL.appendingPathComponent(relThumb)

        try FileManager.default.moveItem(at: result.fileURL, to: destFile)
        if let thumb = result.thumbURL {
            try? FileManager.default.moveItem(at: thumb, to: destThumb)
        }
        if !FileManager.default.fileExists(atPath: destThumb.path) {
            Self.writeAVThumbnail(from: destFile, to: destThumb)
        }
        try? FileManager.default.removeItem(at: result.fileURL.deletingLastPathComponent())

        var record = VideoRecord(
            id: id,
            noteId: nil,
            filePath: relFile,
            thumbPath: relThumb,
            sourceUrl: job.url,
            title: result.title ?? job.titleFallback,
            width: result.width,
            height: result.height,
            durationSec: result.durationSec,
            sizeBytes: result.sizeBytes.map { Int($0) },
            mimeType: Self.mime(forExtension: videoExt.lowercased()),
            source: "download",
            createdAt: Date().timeIntervalSince1970,
            status: "active",
            trashedAt: nil
        )
        try db.dbQueue.write { try record.insert($0) }
        videos.insert(record, at: 0)
        updateJob(job.id) { $0.state = .finished(recordId: id) }
    }

    private func updateJob(_ id: UUID, _ update: (inout DownloadJob) -> Void) {
        guard let idx = jobs.firstIndex(where: { $0.id == id }) else { return }
        var job = jobs[idx]
        update(&job)
        jobs[idx] = job
    }

    private func duplicateRecord(forURL url: String) -> VideoRecord? {
        videos.first { $0.sourceUrl == url }
    }

    private static func mime(forExtension ext: String) -> String {
        switch ext {
        case "mp4", "m4v": return "video/mp4"
        case "mov": return "video/quicktime"
        case "webm": return "video/webm"
        case "mkv": return "video/x-matroska"
        default: return "video/mp4"
        }
    }

    private static func writeAVThumbnail(from src: URL, to dst: URL) {
        let asset = AVURLAsset(url: src)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 640)
        let time = CMTime(seconds: min(1.0, CMTimeGetSeconds(asset.duration) / 2), preferredTimescale: 600)
        do {
            let cg = try generator.copyCGImage(at: time, actualTime: nil)
            let rep = NSBitmapImageRep(cgImage: cg)
            if let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.82]) {
                try? data.write(to: dst)
            }
        } catch {
            NSLog("Thumbnail generation failed: \(error)")
        }
    }
}

// MARK: - DownloadJob

struct DownloadJob: Identifiable, Equatable {
    let id = UUID()
    let url: String
    var title: String?
    var progress: Double = 0
    var downloadedBytes: Int64?
    var totalBytes: Int64?
    var state: State = .queued

    var titleFallback: String {
        if let host = URL(string: url)?.host {
            return host.replacingOccurrences(of: "www.", with: "")
        }
        return url
    }

    enum State: Equatable {
        case queued
        case downloading
        case finished(recordId: String)
        case failed(String)
        case cancelled

        var isTerminal: Bool {
            switch self {
            case .finished, .failed, .cancelled: return true
            default: return false
            }
        }
    }
}

/// Coalesces high-frequency progress events down to ~10Hz. Used to keep
/// yt-dlp's 10-50 lines/sec stream from saturating SwiftUI's render
/// loop during downloads. Reads/writes happen on the main actor (the
/// progress closure hops to @MainActor before calling `shouldEmit`),
/// so `@unchecked Sendable` is safe — the actor itself serializes.
@MainActor
private final class ProgressThrottle {
    private var lastEmitted: Date = .distantPast
    private static let interval: TimeInterval = 0.1

    func shouldEmit(now: Date) -> Bool {
        if now.timeIntervalSince(lastEmitted) >= Self.interval {
            lastEmitted = now
            return true
        }
        return false
    }
}
