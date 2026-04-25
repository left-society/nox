import Foundation
import GRDB

@MainActor
final class RetentionService {
    private let db: Database
    private let imageRoot: URL
    private let clock: () -> Date
    private var timer: Timer?

    var retentionSeconds: Double = 2 * 24 * 3600
    var trashRetentionSeconds: Double = 7 * 24 * 3600

    init(db: Database, imageRoot: URL, clock: @escaping () -> Date = Date.init) {
        self.db = db
        self.imageRoot = imageRoot
        self.clock = clock
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in try? self?.sweep() }
        }
        try? sweep()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func sweep() throws {
        let now = clock().timeIntervalSince1970
        let activeCutoff = now - retentionSeconds
        let trashCutoff = now - trashRetentionSeconds

        try db.dbQueue.write { conn in
            try conn.execute(sql: """
                UPDATE notes SET status = 'trashed', trashed_at = ?
                WHERE status = 'active' AND updated_at < ?
            """, arguments: [now, activeCutoff])

            try conn.execute(sql: """
                UPDATE images SET status = 'trashed', trashed_at = ?
                WHERE status = 'active' AND created_at < ?
            """, arguments: [now, activeCutoff])

            // Hard-delete ephemeral screenshots whose TTL has passed. These
            // were auto-saved single shots the user never opened the panel to
            // see — we drop them outright rather than routing through trash.
            let ephemeralExpired = try ImageRecord.fetchAll(conn, sql: """
                SELECT * FROM images WHERE expires_at IS NOT NULL AND expires_at < ?
            """, arguments: [now])
            for img in ephemeralExpired {
                try? FileManager.default.removeItem(
                    at: imageRoot.appendingPathComponent(img.filePath)
                )
                try? FileManager.default.removeItem(
                    at: imageRoot.appendingPathComponent(img.thumbPath)
                )
            }
            try conn.execute(sql: """
                DELETE FROM images WHERE expires_at IS NOT NULL AND expires_at < ?
            """, arguments: [now])

            let expired = try ImageRecord.fetchAll(conn, sql: """
                SELECT * FROM images WHERE status = 'trashed' AND trashed_at < ?
            """, arguments: [trashCutoff])

            for img in expired {
                try? FileManager.default.removeItem(
                    at: imageRoot.appendingPathComponent(img.filePath)
                )
                try? FileManager.default.removeItem(
                    at: imageRoot.appendingPathComponent(img.thumbPath)
                )
            }

            try conn.execute(sql: """
                DELETE FROM images WHERE status = 'trashed' AND trashed_at < ?
            """, arguments: [trashCutoff])

            try conn.execute(sql: """
                DELETE FROM notes WHERE status = 'trashed' AND trashed_at < ?
            """, arguments: [trashCutoff])
        }
    }
}
