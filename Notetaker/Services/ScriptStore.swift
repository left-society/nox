import Foundation
import GRDB
import Combine

/// Persistent store for teleprompter scripts. Same architectural
/// shape as `NoteStore` (the closest sibling) — `@MainActor`,
/// `@Published private(set) var scripts: [Script]`, GRDB-backed,
/// CRUD methods that update both the DB and the in-memory copy
/// so SwiftUI re-renders without a separate refetch.
///
/// Scripts table schema lives in `Database.swift` migration v8.
/// See `Models.swift` for the Script struct.
@MainActor
final class ScriptStore: ObservableObject {
    @Published private(set) var scripts: [Script] = []
    private let db: Database

    init(db: Database) {
        self.db = db
        reload()
    }

    func reload() {
        do {
            let fetched = try db.dbQueue.read { conn in
                try Script
                    .filter(Script.Columns.status == "active")
                    .order(Script.Columns.updatedAt.desc)
                    .fetchAll(conn)
            }
            self.scripts = fetched
        } catch {
            NSLog("nox: ScriptStore reload failed: \(error)")
        }
    }

    /// Create an empty script ready for the user to paste content
    /// into. Defaults: 150 WPM (comfortable reading pace), no
    /// title (auto-derives from first line of body when saved).
    @discardableResult
    func create(title: String? = nil, body: String = "") throws -> Script {
        let now = Date().timeIntervalSince1970
        var script = Script(
            id: UUID().uuidString,
            title: title ?? Self.deriveTitle(from: body),
            body: body,
            wpm: 150,
            lastReadOffset: 0,
            createdAt: now,
            updatedAt: now,
            status: "active",
            trashedAt: nil
        )
        try db.dbQueue.write { try script.insert($0) }
        scripts.insert(script, at: 0)
        return script
    }

    /// Update body / title / wpm. Bumps `updatedAt` so the list
    /// re-sorts (most-recently-edited first, matching Notes).
    /// Pass nil to leave a field unchanged.
    func update(id: String,
                title: String?? = nil,
                body: String? = nil,
                wpm: Int? = nil) throws {
        guard let idx = scripts.firstIndex(where: { $0.id == id }) else { return }
        var script = scripts[idx]
        if case let .some(t) = title { script.title = t }
        if let b = body { script.body = b }
        if let w = wpm { script.wpm = w }
        script.updatedAt = Date().timeIntervalSince1970
        try db.dbQueue.write { try script.update($0) }
        // Re-sort by updatedAt DESC so the just-edited script
        // jumps to the top of the list (matches Notes behaviour).
        scripts.remove(at: idx)
        scripts.insert(script, at: 0)
    }

    /// Save the user's current reading position. Doesn't bump
    /// `updatedAt` — position changes are scrub events, not edits,
    /// and we don't want them to re-sort the list mid-read.
    func saveReadPosition(id: String, offset: Int) throws {
        guard let idx = scripts.firstIndex(where: { $0.id == id }) else { return }
        var script = scripts[idx]
        script.lastReadOffset = max(0, offset)
        try db.dbQueue.write { try script.update($0) }
        scripts[idx] = script
    }

    /// Soft-delete (move to trash). RetentionService will hard-
    /// delete after `trashRetentionSeconds` elapses.
    func trash(id: String) throws {
        guard let idx = scripts.firstIndex(where: { $0.id == id }) else { return }
        var script = scripts[idx]
        script.status = "trashed"
        script.trashedAt = Date().timeIntervalSince1970
        try db.dbQueue.write { try script.update($0) }
        scripts.remove(at: idx)
    }

    // MARK: - Helpers

    /// Title falls back to the first non-empty line of the body
    /// when the user hasn't typed an explicit title. Capped at
    /// ~60 chars so list rows don't truncate to nothing useful.
    static func deriveTitle(from body: String) -> String? {
        let trimmed = body
            .split(whereSeparator: { $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first(where: { !$0.isEmpty })
        guard let line = trimmed, !line.isEmpty else { return nil }
        if line.count <= 60 { return line }
        return String(line.prefix(60)) + "…"
    }

    /// Word count of the body. Used by the list row's "142 words"
    /// stat and the editor's "~25s at 150 WPM" estimate.
    static func wordCount(_ body: String) -> Int {
        body.split { $0.isWhitespace || $0.isNewline }.count
    }

    /// Estimated reading duration at the script's configured WPM.
    static func estimatedReadingTime(_ script: Script) -> TimeInterval {
        let words = Double(wordCount(script.body))
        let wpm = max(1.0, Double(script.wpm))
        return (words / wpm) * 60.0
    }
}
