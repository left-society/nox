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
        note.updatedAt = Date().timeIntervalSince1970
        try db.dbQueue.write { try note.update($0) }
        notes.remove(at: idx)
        notes.insert(note, at: 0)
    }

    func trash(id: String) throws {
        guard let idx = notes.firstIndex(where: { $0.id == id }) else { return }
        var note = notes[idx]
        note.status = "trashed"
        note.trashedAt = Date().timeIntervalSince1970
        try db.dbQueue.write { try note.update($0) }
        notes.remove(at: idx)
    }

    static func deriveTitle(from body: String) -> String? {
        let firstLine = body.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(60))
    }
}
