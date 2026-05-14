import XCTest
import GRDB
@testable import nox

final class DatabaseTests: XCTestCase {
    func test_migrations_createTables() throws {
        let db = try Database(inMemory: true)
        try db.dbQueue.read { conn in
            XCTAssertTrue(try conn.tableExists("notes"))
            XCTAssertTrue(try conn.tableExists("images"))
            XCTAssertTrue(try conn.tableExists("audio_recordings"))
        }
    }

    func test_note_roundTrip() throws {
        let db = try Database(inMemory: true)
        let now = Date().timeIntervalSince1970
        var note = Note(
            id: UUID().uuidString,
            title: "Test",
            body: "Hello world",
            createdAt: now,
            updatedAt: now,
            status: "active",
            trashedAt: nil,
            kind: "text"
        )
        try db.dbQueue.write { conn in
            try note.insert(conn)
        }
        let fetched = try db.dbQueue.read { try Note.fetchOne($0, id: note.id) }
        XCTAssertEqual(fetched, note)
    }

    func test_cascadeDelete_notesDeleteAttachedImages() throws {
        let db = try Database(inMemory: true)
        let now = Date().timeIntervalSince1970
        let noteId = UUID().uuidString
        var note = Note(
            id: noteId,
            title: nil,
            body: "",
            createdAt: now,
            updatedAt: now,
            status: "active",
            trashedAt: nil,
            kind: "text"
        )
        var image = ImageRecord(
            id: UUID().uuidString,
            noteId: noteId,
            filePath: "images/x.png",
            thumbPath: "thumbs/x.jpg",
            width: 10,
            height: 10,
            mimeType: "image/png",
            source: "paste",
            createdAt: now,
            status: "active",
            trashedAt: nil
        )
        try db.dbQueue.write { conn in
            try note.insert(conn)
            try image.insert(conn)
        }
        try db.dbQueue.write { conn in
            _ = try Note.deleteOne(conn, key: noteId)
        }
        let remaining = try db.dbQueue.read { try ImageRecord.fetchCount($0) }
        XCTAssertEqual(remaining, 0)
    }
}
