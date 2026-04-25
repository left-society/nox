import Foundation
import AppKit
import GRDB
import ImageIO
import UniformTypeIdentifiers

@MainActor
final class ImageStore: ObservableObject {
    @Published private(set) var images: [ImageRecord] = []
    /// In-flight async saves (e.g. drag-drop). Rendered as placeholder
    /// cells in ImagesGridView so the user gets immediate "got it"
    /// feedback while disk I/O + thumbnail generation run in the
    /// background.
    @Published private(set) var inflight: [InflightUpload] = []
    private let db: Database
    private let rootURL: URL
    /// IDs whose deferred save is still in flight but already had a
    /// `clearExpiryDeferred` call. The async save path consults this
    /// after `performSave` completes and applies the clear before
    /// publishing the record.
    private var pendingClearExpiry: Set<String> = []
    /// Hold the inflight cell on screen for at least this long so the
    /// spinner is perceivable. A 200KB drop saves in ~40ms — well below
    /// human perception — so without this floor the placeholder flashes
    /// for a single frame and users think nothing happened. `nonisolated`
    /// so the detached save task can read it without hopping back to the
    /// main actor.
    private nonisolated static let minimumInflightDisplay: TimeInterval = 0.6

    struct InflightUpload: Identifiable {
        let id: String
        let preview: NSImage?
    }

    init(db: Database, rootURL: URL? = nil) throws {
        self.db = db
        if let rootURL = rootURL {
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
            at: self.rootURL.appendingPathComponent("images"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: self.rootURL.appendingPathComponent("thumbs"),
            withIntermediateDirectories: true
        )
        reload()
    }

    func reload() {
        do {
            let fetched = try db.dbQueue.read { conn in
                try ImageRecord
                    .filter(ImageRecord.Columns.status == "active")
                    .order(ImageRecord.Columns.createdAt.desc)
                    .fetchAll(conn)
            }
            self.images = fetched
        } catch {
            NSLog("ImageStore reload failed: \(error)")
        }
    }

    @discardableResult
    func saveImage(
        data: Data,
        mimeType: String,
        noteId: String?,
        source: String,
        expiresAt: Double? = nil
    ) throws -> ImageRecord {
        if let existing = duplicateRecord(for: data) {
            return existing
        }
        let id = UUID().uuidString
        let record = try Self.performSave(
            id: id,
            data: data,
            mimeType: mimeType,
            noteId: noteId,
            source: source,
            expiresAt: expiresAt,
            db: db,
            rootURL: rootURL
        )
        images.insert(record, at: 0)
        return record
    }

    /// Fire-and-forget save. Inserts a placeholder into `inflight`
    /// synchronously so the UI shows feedback immediately, then runs
    /// the disk + DB work on a detached Task so a 10MB browser drag
    /// doesn't freeze the panel for half a second. Drops AND screenshots
    /// use this — the returned id lets callers (e.g. the screenshot
    /// burst detector) reference the eventual record before it lands.
    @discardableResult
    func saveImageDeferred(
        data: Data,
        mimeType: String,
        noteId: String?,
        source: String,
        expiresAt: Double? = nil
    ) -> String {
        let id = UUID().uuidString
        let preview = NSImage(data: data)
        inflight.insert(InflightUpload(id: id, preview: preview), at: 0)

        let startTime = DispatchTime.now()
        let db = self.db
        let rootURL = self.rootURL
        Task.detached(priority: .userInitiated) {
            do {
                let record = try Self.performSave(
                    id: id,
                    data: data,
                    mimeType: mimeType,
                    noteId: noteId,
                    source: source,
                    expiresAt: expiresAt,
                    db: db,
                    rootURL: rootURL
                )
                // Resolve any clearExpiryDeferred that came in mid-save.
                let shouldClearExpiry = await MainActor.run { () -> Bool in
                    self.pendingClearExpiry.remove(id) != nil
                }
                var pendingRecord = record
                if shouldClearExpiry {
                    do {
                        try await db.dbQueue.write { conn in
                            try conn.execute(
                                sql: "UPDATE images SET expires_at = NULL WHERE id = ?",
                                arguments: [id]
                            )
                        }
                        pendingRecord.expiresAt = nil
                    } catch {
                        NSLog("saveImageDeferred clear-expiry failed: \(error)")
                    }
                }
                // Freeze the record into a let before the cross-actor hop —
                // captured-var-in-concurrent-code is a Swift 6 hard error.
                let finalRecord = pendingRecord
                // Hold the inflight placeholder on screen for at least
                // `minimumInflightDisplay` so the spinner is actually
                // perceivable on small saves that finish in <50ms.
                let elapsedNanos = DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds
                let minimumNanos = UInt64(Self.minimumInflightDisplay * 1_000_000_000)
                if elapsedNanos < minimumNanos {
                    try? await Task.sleep(nanoseconds: minimumNanos - elapsedNanos)
                }
                await MainActor.run {
                    self.inflight.removeAll { $0.id == id }
                    self.images.insert(finalRecord, at: 0)
                }
            } catch {
                NSLog("saveImageDeferred failed: \(error)")
                await MainActor.run {
                    self.inflight.removeAll { $0.id == id }
                    self.pendingClearExpiry.remove(id)
                }
            }
        }
        return id
    }

    /// Heavy-lifting body shared by the sync and deferred save paths.
    /// `nonisolated static` so it can run from any actor — only depends
    /// on its arguments.
    private nonisolated static func performSave(
        id: String,
        data: Data,
        mimeType: String,
        noteId: String?,
        source: String,
        expiresAt: Double?,
        db: Database,
        rootURL: URL
    ) throws -> ImageRecord {
        let ext = Self.ext(for: mimeType)
        let fileRel = "images/\(id).\(ext)"
        let thumbRel = "thumbs/\(id).jpg"

        let fileURL = rootURL.appendingPathComponent(fileRel)
        let thumbURL = rootURL.appendingPathComponent(thumbRel)

        try data.write(to: fileURL)
        try Self.writeThumbnail(from: fileURL, to: thumbURL, maxPixel: 256)

        let (w, h) = Self.dimensions(of: fileURL)
        var record = ImageRecord(
            id: id,
            noteId: noteId,
            filePath: fileRel,
            thumbPath: thumbRel,
            width: w,
            height: h,
            mimeType: mimeType,
            source: source,
            createdAt: Date().timeIntervalSince1970,
            status: "active",
            trashedAt: nil,
            expiresAt: expiresAt
        )
        try db.dbQueue.write { try record.insert($0) }
        return record
    }

    /// Like `clearExpiry`, but tolerant of records that haven't yet
    /// finished their deferred save. If the row already exists we
    /// update it directly; otherwise we record the intent and the
    /// `saveImageDeferred` completion path applies it before
    /// publishing the record. Burst detection on screenshots uses this
    /// because the burst can fire before either save has landed.
    func clearExpiryDeferred(id: String) {
        if images.contains(where: { $0.id == id }) {
            clearExpiry(id: id)
        } else {
            pendingClearExpiry.insert(id)
        }
    }

    /// Clears the TTL on an auto-saved screenshot when the user triggers
    /// a burst — we want to keep it around permanently now.
    func clearExpiry(id: String) {
        do {
            try db.dbQueue.write { conn in
                try conn.execute(
                    sql: "UPDATE images SET expires_at = NULL WHERE id = ?",
                    arguments: [id]
                )
            }
            if let idx = images.firstIndex(where: { $0.id == id }) {
                images[idx].expiresAt = nil
            }
        } catch {
            NSLog("clearExpiry failed: \(error)")
        }
    }

    func fullURL(for record: ImageRecord) -> URL {
        rootURL.appendingPathComponent(record.filePath)
    }

    func thumbURL(for record: ImageRecord) -> URL {
        rootURL.appendingPathComponent(record.thumbPath)
    }

    func trashAll() throws {
        let now = Date().timeIntervalSince1970
        try db.dbQueue.write { conn in
            try conn.execute(
                sql: "UPDATE images SET status = 'trashed', trashed_at = ? WHERE status = 'active'",
                arguments: [now]
            )
        }
        images = []
    }

    // MARK: - Helpers

    // Scans the most recent active images and returns the first one whose
    // bytes match the incoming data. Stops after a small window so this stays
    // cheap even with large libraries.
    private func duplicateRecord(for data: Data) -> ImageRecord? {
        let window = 8
        for record in images.prefix(window) {
            let url = fullURL(for: record)
            guard let existing = try? Data(contentsOf: url) else { continue }
            if existing == data { return record }
        }
        return nil
    }

    private nonisolated static func ext(for mime: String) -> String {
        switch mime {
        case "image/png": return "png"
        case "image/jpeg": return "jpg"
        case "image/gif": return "gif"
        case "image/webp": return "webp"
        default: return "bin"
        }
    }

    private nonisolated static func dimensions(of url: URL) -> (Int?, Int?) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        else { return (nil, nil) }
        let w = props[kCGImagePropertyPixelWidth] as? Int
        let h = props[kCGImagePropertyPixelHeight] as? Int
        return (w, h)
    }

    private nonisolated static func writeThumbnail(from src: URL, to dst: URL, maxPixel: Int) throws {
        guard let imageSource = CGImageSourceCreateWithURL(src as CFURL, nil) else {
            throw NSError(
                domain: "ImageStore",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Cannot read source image"]
            )
        }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, opts as CFDictionary) else {
            throw NSError(
                domain: "ImageStore",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Cannot create thumbnail"]
            )
        }
        guard let destination = CGImageDestinationCreateWithURL(
            dst as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw NSError(
                domain: "ImageStore",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Cannot create thumb destination"]
            )
        }
        CGImageDestinationAddImage(destination, thumb, nil)
        if !CGImageDestinationFinalize(destination) {
            throw NSError(
                domain: "ImageStore",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Cannot finalize thumb"]
            )
        }
    }
}
