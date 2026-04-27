import Foundation
import GRDB
import Combine

@MainActor
final class NoteStore: ObservableObject {
    @Published private(set) var notes: [Note] = []
    private let db: Database

    init(db: Database) {
        self.db = db
        reload()
    }

    func reload() {
        do {
            let fetched = try db.dbQueue.read { conn in
                try Note
                    .filter(Note.Columns.status == "active")
                    .order(Note.Columns.updatedAt.desc)
                    .fetchAll(conn)
            }
            self.notes = fetched
        } catch {
            NSLog("NoteStore reload failed: \(error)")
        }
    }

    @discardableResult
    func createNote() throws -> Note {
        let now = Date().timeIntervalSince1970
        var note = Note(
            id: UUID().uuidString,
            title: nil,
            body: "",
            summary: nil,
            createdAt: now,
            updatedAt: now,
            status: "active",
            trashedAt: nil
        )
        try db.dbQueue.write { try note.insert($0) }
        notes.insert(note, at: 0)
        return note
    }

    func updateBody(id: String, body: String) throws {
        guard let idx = notes.firstIndex(where: { $0.id == id }) else { return }
        var note = notes[idx]
        note.body = body
        note.title = Self.deriveTitle(from: body)
        // Stale the summary on body change — it'll be regenerated
        // by `summarize(id:)` after the editor commits.
        note.summary = nil
        note.updatedAt = Date().timeIntervalSince1970
        try db.dbQueue.write { try note.update($0) }
        notes.remove(at: idx)
        notes.insert(note, at: 0)
    }

    /// Persist a Gemini-generated summary for the given note. Called
    /// asynchronously after `updateBody` so the user's save is never
    /// blocked on the network round-trip — the row updates whenever
    /// the summary lands.
    func updateSummary(id: String, summary: String) throws {
        guard let idx = notes.firstIndex(where: { $0.id == id }) else { return }
        var note = notes[idx]
        // Don't bump `updatedAt` for a summary update — the user
        // didn't edit anything; we just enriched the row. Bumping
        // would re-sort the list and cause notes to jump around as
        // background summarization completes.
        note.summary = summary
        try db.dbQueue.write { try note.update($0) }
        notes[idx] = note
    }

    func trash(id: String) throws {
        guard let idx = notes.firstIndex(where: { $0.id == id }) else { return }
        var note = notes[idx]
        note.status = "trashed"
        note.trashedAt = Date().timeIntervalSince1970
        try db.dbQueue.write { try note.update($0) }
        notes.remove(at: idx)
    }

    /// Soft-trash every active note in one shot. Mirrors
    /// `ImageStore.trashAll` and `FileStore.clear` so the Notes
    /// tab gets the same "Clear everything" affordance the
    /// other content tabs already have. Notes are flagged
    /// `status = "trashed"` rather than hard-deleted so they
    /// remain recoverable from the trashed pool if we ever expose
    /// undo / restore in the UI.
    func trashAll() throws {
        let trashedAt = Date().timeIntervalSince1970
        try db.dbQueue.write { db in
            for var note in notes {
                note.status = "trashed"
                note.trashedAt = trashedAt
                try note.update(db)
            }
        }
        notes.removeAll()
    }

    static func deriveTitle(from body: String) -> String? {
        let firstLine = body.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(60))
    }
}
