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

    /// Create an empty note. `kind` defaults to `.handwritten` so
    /// existing call sites (the "+ New note" button, etc.) keep
    /// behaving the way they always did. The clipboard auto-save
    /// path passes `.clipboard` explicitly.
    @discardableResult
    func createNote(kind: Note.Kind = .handwritten,
                    body: String = "") throws -> Note {
        let now = Date().timeIntervalSince1970
        var note = Note(
            id: UUID().uuidString,
            title: Self.deriveTitle(from: body),
            body: body,
            summary: nil,
            createdAt: now,
            updatedAt: now,
            status: "active",
            trashedAt: nil,
            kind: kind.rawValue,
            videoURL: nil
        )
        try db.dbQueue.write { try note.insert($0) }
        notes.insert(note, at: 0)
        return note
    }

    /// Set / clear a video companion URL on a note. Used by the
    /// note editor's "📺 Video" toolbar button. Pass nil to detach
    /// the video. Doesn't bump `updatedAt` so attaching a video
    /// doesn't re-sort the list.
    func updateVideoURL(id: String, videoURL: String?) throws {
        guard let idx = notes.firstIndex(where: { $0.id == id }) else { return }
        var note = notes[idx]
        note.videoURL = videoURL
        try db.dbQueue.write { try note.update($0) }
        notes[idx] = note
    }

    /// One-shot heuristic backfill — runs ONCE per install when the
    /// kind feature lands, and reclassifies obvious clipboard auto-
    /// saves from the legacy data. Without this, every note created
    /// before the v6 migration is tagged `handwritten` (the migration
    /// default), so the user can't see the new clipboard segment do
    /// anything useful with their existing data.
    ///
    /// Heuristic — conservative, designed to NEVER misclassify a
    /// real handwritten note as clipboard. Only flips to clipboard if:
    ///   1. The body is a single line (no `\n`), AND
    ///   2. (a) it parses as a URL (starts with http:// or https://), OR
    ///      (b) it's pure digits / numeric-only (e.g. "127488"), OR
    ///      (c) it's a single "word" — no spaces, < 80 chars, no
    ///          markdown chars (no `#`, `*`, `>`, `-`, `[`).
    /// Anything multi-line, anything with prose-like spacing, anything
    /// that looks like markdown stays as handwritten. False positives
    /// are recoverable via the per-row "Convert to note" action; false
    /// negatives just mean the user manually re-tags those rows.
    ///
    /// Idempotent — gated by `noxClipboardBackfillV1Done` flag.
    func backfillClipboardKindIfNeeded() {
        let flagKey = "noxClipboardBackfillV1Done"
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: flagKey) else { return }

        let urlRegex = try? NSRegularExpression(
            pattern: #"^https?://\S+$"#,
            options: [.caseInsensitive]
        )
        let digitRegex = try? NSRegularExpression(pattern: #"^\d+$"#)

        var reclassifiedCount = 0
        do {
            try db.dbQueue.write { db in
                let active = try Note
                    .filter(Note.Columns.status == "active")
                    .filter(Note.Columns.kind == Note.Kind.handwritten.rawValue)
                    .fetchAll(db)
                for var n in active {
                    let body = n.body.trimmingCharacters(in: .whitespacesAndNewlines)
                    let isMultiLine = body.contains("\n")
                    guard !isMultiLine else { continue }
                    guard !body.isEmpty else { continue }

                    let range = NSRange(body.startIndex..., in: body)
                    let isURL = urlRegex?.firstMatch(in: body, range: range) != nil
                    let isDigits = digitRegex?.firstMatch(in: body, range: range) != nil
                    let hasMarkdown = body.contains(where: { "#*>-[".contains($0) })
                    let hasSpaces = body.contains(" ")
                    let isShortToken = body.count < 80 && !hasSpaces && !hasMarkdown

                    let looksLikeClipboard = isURL || isDigits || isShortToken
                    guard looksLikeClipboard else { continue }

                    n.kind = Note.Kind.clipboard.rawValue
                    try n.update(db)
                    reclassifiedCount += 1
                }
            }
            NSLog("nox: clipboard-kind backfill — moved \(reclassifiedCount) note(s) to clipboard")
        } catch {
            NSLog("nox: clipboard-kind backfill failed: \(error)")
            return  // don't set the flag; we'll retry next launch
        }

        defaults.set(true, forKey: flagKey)
        // Reload so the in-memory list reflects the DB.
        reload()
    }

    /// Soft-trash every clipboard-kind note. Powers the "Clear
    /// clipboard" affordance in the Notes tab — lets the user
    /// nuke transient auto-saves without touching their real
    /// handwritten notes.
    func trashAllClipboard() throws {
        let trashedAt = Date().timeIntervalSince1970
        let clipboardKind = Note.Kind.clipboard.rawValue
        try db.dbQueue.write { db in
            for var note in notes where note.kind == clipboardKind {
                note.status = "trashed"
                note.trashedAt = trashedAt
                try note.update(db)
            }
        }
        notes.removeAll(where: { $0.kind == clipboardKind })
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
