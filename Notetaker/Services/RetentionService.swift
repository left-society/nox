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
    /// Per BUG-119 fix: separate retention for images. Previously
    /// the sweep used the same `retentionSeconds` for notes AND
    /// images, so the Settings UI's "Image retention" picker did
    /// nothing — toggling it just wrote to UserDefaults that no
    /// consumer ever read. Now images age out on their own clock,
    /// driven by `imageRetentionDays` from Settings.
    /// Default `.infinity` (= "Forever") matches the Settings UI's
    /// default selection.
    var imageRetentionSeconds: Double = .infinity

    init(db: Database, imageRoot: URL, clock: @escaping () -> Date = Date.init) {
        self.db = db
        self.imageRoot = imageRoot
        self.clock = clock
        // Per BUG-118 fix: seed retention values from UserDefaults
        // at init so the user's stored choice survives an app
        // restart. Previously these were hardcoded defaults that
        // only got overridden via the SwiftUI Settings UI's
        // .onChange handlers — which fire only when the user
        // touches the picker, so any setting set in a previous
        // session reverted to "2 days active / 7 days trashed"
        // until the user re-opened Settings and re-selected.
        // Real trust violation: settings UI showed the user's
        // choice but the service was using a different value.
        //
        // Special-case retentionDays = -1 = "Forever" (per the
        // SettingsWindow Picker tagging convention) — maps to
        // .infinity so the sweep never marks anything as expired.
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "retentionDays") != nil {
            let days = defaults.integer(forKey: "retentionDays")
            retentionSeconds = days < 0 ? .infinity : Double(days) * 86400
        }
        if defaults.object(forKey: "trashRetentionDays") != nil {
            let days = defaults.integer(forKey: "trashRetentionDays")
            trashRetentionSeconds = Double(days) * 86400
        }
        // Per BUG-119 fix: also seed the image-retention clock.
        if defaults.object(forKey: "imageRetentionDays") != nil {
            let days = defaults.integer(forKey: "imageRetentionDays")
            imageRetentionSeconds = days < 0 ? .infinity : Double(days) * 86400
        }
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
        // Per BUG-119 fix: images use their own retention clock
        // (`imageRetentionSeconds`), not the notes one. With
        // .infinity → cutoff = -.infinity → no image's
        // `created_at < cutoff` is true → no image gets auto-
        // trashed → matches the "Forever" Settings UI tag.
        let imageActiveCutoff = now - imageRetentionSeconds
        let trashCutoff = now - trashRetentionSeconds

        try db.dbQueue.write { conn in
            try conn.execute(sql: """
                UPDATE notes SET status = 'trashed', trashed_at = ?
                WHERE status = 'active' AND updated_at < ?
            """, arguments: [now, activeCutoff])

            try conn.execute(sql: """
                UPDATE images SET status = 'trashed', trashed_at = ?
                WHERE status = 'active' AND created_at < ?
            """, arguments: [now, imageActiveCutoff])

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
