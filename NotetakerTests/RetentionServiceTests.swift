import XCTest
import GRDB
@testable import nox

@MainActor
final class RetentionServiceTests: XCTestCase {
    private func makeTmp() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("RetentionTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    func test_sweep_movesOldActiveToTrashed() async throws {
        let db = try Database(inMemory: true)
        let tmp = try makeTmp()

        let fakeNow = Date(timeIntervalSince1970: 10_000_000)
        let threeDaysAgo = fakeNow.addingTimeInterval(-3 * 24 * 3600).timeIntervalSince1970
        let oldNote = Note(id: "old", title: nil, body: "x",
                           createdAt: threeDaysAgo, updatedAt: threeDaysAgo,
                           status: "active", trashedAt: nil, kind: "text")
        let newNote = Note(id: "new", title: nil, body: "y",
                           createdAt: fakeNow.timeIntervalSince1970,
                           updatedAt: fakeNow.timeIntervalSince1970,
                           status: "active", trashedAt: nil, kind: "text")
        try await db.dbQueue.write {
            var oldNote = oldNote
            var newNote = newNote
            try oldNote.insert($0)
            try newNote.insert($0)
        }

        let svc = RetentionService(db: db, imageRoot: tmp, clock: { fakeNow })
        await svc.sweep()

        let fetchedOld = try await db.dbQueue.read { try Note.fetchOne($0, id: "old") }
        let fetchedNew = try await db.dbQueue.read { try Note.fetchOne($0, id: "new") }
        XCTAssertEqual(fetchedOld?.status, "trashed")
        XCTAssertEqual(fetchedNew?.status, "active")
    }

    func test_sweep_hardDeletesOldTrashed() async throws {
        let db = try Database(inMemory: true)
        let tmp = try makeTmp()

        let fakeNow = Date(timeIntervalSince1970: 10_000_000)
        let tenDaysAgo = fakeNow.addingTimeInterval(-10 * 24 * 3600).timeIntervalSince1970
        let oldTrash = Note(id: "t", title: nil, body: "", createdAt: tenDaysAgo,
                            updatedAt: tenDaysAgo, status: "trashed",
                            trashedAt: tenDaysAgo, kind: "text")
        try await db.dbQueue.write {
            var oldTrash = oldTrash
            try oldTrash.insert($0)
        }

        let svc = RetentionService(db: db, imageRoot: tmp, clock: { fakeNow })
        await svc.sweep()

        let fetched = try await db.dbQueue.read { try Note.fetchOne($0, id: "t") }
        XCTAssertNil(fetched)
    }

    func test_sweep_deletesExpiredImageFilesFromDisk() async throws {
        let db = try Database(inMemory: true)
        let tmp = try makeTmp()
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("images"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("thumbs"),
            withIntermediateDirectories: true
        )

        let fakeNow = Date(timeIntervalSince1970: 10_000_000)
        let tenDaysAgo = fakeNow.addingTimeInterval(-10 * 24 * 3600).timeIntervalSince1970
        let fileRel = "images/expired.png"
        let thumbRel = "thumbs/expired.jpg"
        let fullURL = tmp.appendingPathComponent(fileRel)
        let thumbURL = tmp.appendingPathComponent(thumbRel)
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: fullURL)
        try Data([0xFF, 0xD8, 0xFF]).write(to: thumbURL)

        let expired = ImageRecord(
            id: "expired", noteId: nil,
            filePath: fileRel, thumbPath: thumbRel,
            width: 10, height: 10,
            mimeType: "image/png", source: "paste",
            createdAt: tenDaysAgo, status: "trashed", trashedAt: tenDaysAgo
        )
        try await db.dbQueue.write {
            var expired = expired
            try expired.insert($0)
        }

        let svc = RetentionService(db: db, imageRoot: tmp, clock: { fakeNow })
        await svc.sweep()

        XCTAssertFalse(FileManager.default.fileExists(atPath: fullURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: thumbURL.path))
        let row = try await db.dbQueue.read { try ImageRecord.fetchOne($0, id: "expired") }
        XCTAssertNil(row)
    }
}
