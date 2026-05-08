import Foundation
import GRDB

@MainActor
final class RetentionService {
    // db / imageRoot / clock are nonisolated so the off-main sweep
    // can access them without an actor hop. db is GRDB which has
    // its own internal serialization, URL is a value type, and
    // clock is a captured @Sendable closure (Date.init by default).
    nonisolated private let db: Database
    nonisolated private let imageRoot: URL
    nonisolated private let clock: @Sendable () -> Date
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

    init(db: Database, imageRoot: URL, clock: @escaping @Sendable () -> Date = Date.init) {
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
            // Hop off main for the actual sweep — the timer fires
            // on the runloop the timer was scheduled from (main),
            // but the work itself runs detached. Audit H4.
            Task.detached { [weak self] in
                await self?.sweep()
            }
        }
        Task.detached { [weak self] in
            await self?.sweep()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Run a single retention sweep. Logs failures but does not
    /// throw — sweep is fire-and-forget from the timer's perspective
    /// and one failed cycle shouldn't kill the schedule.
    ///
    /// 2026-05-08 audit H4: the sweep used to be `@MainActor throws`
    /// — and `dbQueue.write` blocks the caller until the GRDB serial
    /// writer queue finishes the closure, so for a user with hundreds
    /// of trashed images the file-removal loop stalled the main
    /// thread for seconds every 30 minutes (and on launch). Now the
    /// public entry is `nonisolated async`; we capture the cutoff
    /// inputs on a brief MainActor hop, then run all DB + file I/O
    /// off-main inside a sync Task body. UI no longer freezes.
    nonisolated func sweep() async {
        // Snapshot the configurable retention windows from MainActor.
        // `retentionSeconds` etc. are isolated; this is the only
        // crossing point. The rest of the work uses captured locals.
        let inputs: SweepInputs
        do {
            inputs = try await readInputsOnMain()
        } catch {
            NSLog("nox: RetentionService failed to read inputs: \(error)")
            return
        }
        let now = inputs.now
        let activeCutoff = now - inputs.retentionSeconds
        let imageActiveCutoff = now - inputs.imageRetentionSeconds
        let trashCutoff = now - inputs.trashRetentionSeconds
        let imageRoot = self.imageRoot
        let db = self.db

        do {
            try await Task.detached(priority: .utility) {
                try db.dbQueue.write { conn in
                    try conn.execute(sql: """
                        UPDATE notes SET status = 'trashed', trashed_at = ?
                        WHERE status = 'active' AND updated_at < ?
                    """, arguments: [now, activeCutoff])

                    try conn.execute(sql: """
                        UPDATE images SET status = 'trashed', trashed_at = ?
                        WHERE status = 'active' AND created_at < ?
                    """, arguments: [now, imageActiveCutoff])

                    // Hard-delete ephemeral screenshots whose TTL has passed.
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
            }.value
        } catch {
            NSLog("nox: RetentionService sweep failed: \(error)")
        }
    }

    /// Snapshot of the retention windows + the current time, taken
    /// on MainActor so the off-main sweep doesn't have to cross the
    /// isolation boundary mid-flight.
    private struct SweepInputs {
        let now: TimeInterval
        let retentionSeconds: Double
        let trashRetentionSeconds: Double
        let imageRetentionSeconds: Double
    }

    @MainActor
    private func readInputsOnMain() throws -> SweepInputs {
        SweepInputs(
            now: clock().timeIntervalSince1970,
            retentionSeconds: retentionSeconds,
            trashRetentionSeconds: trashRetentionSeconds,
            imageRetentionSeconds: imageRetentionSeconds
        )
    }
}
