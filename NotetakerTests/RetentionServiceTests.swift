import XCTest
import GRDB
@testable import Notetaker

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
        var oldNote = Note(id: "old", title: nil, body: "x",
                           createdAt: threeDaysAgo, updatedAt: threeDaysAgo,
                           status: "active", trashedAt: nil)
        var newNote = Note(id: "new", title: nil, body: "y",
                           createdAt: fakeNow.timeIntervalSince1970,
                           updatedAt: fakeNow.timeIntervalSince1970,
                           status: "active", trashedAt: nil)
        try db.dbQueue.write {
            try oldNote.insert($0)
            try newNote.insert($0)
        }

        let svc = RetentionService(db: db, imageRoot: tmp, clock: { fakeNow })
        await svc.sweep()

        let fetchedOld = try db.dbQueue.read { try Note.fetchOne($0, id: "old") }
        let fetchedNew = try db.dbQueue.read { try Note.fetchOne($0, id: "new") }
        XCTAssertEqual(fetchedOld?.status, "trashed")
        XCTAssertEqual(fetchedNew?.status, "active")
    }

    func test_sweep_hardDeletesOldTrashed() async throws {
        let db = try Database(inMemory: true)
        let tmp = try makeTmp()

        let fakeNow = Date(timeIntervalSince1970: 10_000_000)
        let tenDaysAgo = fakeNow.addingTimeInterval(-10 * 24 * 3600).timeIntervalSince1970
        var oldTrash = Note(id: "t", title: nil, body: "", createdAt: tenDaysAgo,
                            updatedAt: tenDaysAgo, status: "trashed", trashedAt: tenDaysAgo)
        try db.dbQueue.write { try oldTrash.insert($0) }

        let svc = RetentionService(db: db, imageRoot: tmp, clock: { fakeNow })
        await svc.sweep()

        let fetched = try db.dbQueue.read { try Note.fetchOne($0, id: "t") }
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

        var expired = ImageRecord(
            id: "expired", noteId: nil,
            filePath: fileRel, thumbPath: thumbRel,
            width: 10, height: 10,
            mimeType: "image/png", source: "paste",
            createdAt: tenDaysAgo, status: "trashed", trashedAt: tenDaysAgo
        )
        try db.dbQueue.write { try expired.insert($0) }

        let svc = RetentionService(db: db, imageRoot: tmp, clock: { fakeNow })
        await svc.sweep()

        XCTAssertFalse(FileManager.default.fileExists(atPath: fullURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: thumbURL.path))
        let row = try db.dbQueue.read { try ImageRecord.fetchOne($0, id: "expired") }
        XCTAssertNil(row)
    }
}
