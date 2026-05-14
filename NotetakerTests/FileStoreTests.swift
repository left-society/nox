import XCTest
@testable import nox

@MainActor
final class FileStoreTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func writeFile(name: String, bytes: Int = 64) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try Data(repeating: 0xAB, count: bytes).write(to: url)
        return url
    }

    func test_initiallyEmpty() {
        let store = FileStore()
        XCTAssertTrue(store.files.isEmpty)
    }

    func test_stage_appendsOne() throws {
        let store = FileStore()
        let url = try writeFile(name: "alpha.pdf")
        store.stage(urls: [url])
        XCTAssertEqual(store.files.count, 1)
        XCTAssertEqual(store.files.first?.displayName, "alpha.pdf")
        XCTAssertEqual(store.files.first?.sizeBytes, 64)
    }

    func test_stage_dedupesByPath() throws {
        let store = FileStore()
        let url = try writeFile(name: "beta.zip")
        store.stage(urls: [url])
        store.stage(urls: [url])
        XCTAssertEqual(store.files.count, 1)
    }

    func test_stage_acceptsMultipleAtOnce() throws {
        let store = FileStore()
        let a = try writeFile(name: "a.txt")
        let b = try writeFile(name: "b.txt")
        store.stage(urls: [a, b])
        XCTAssertEqual(store.files.count, 2)
    }

    func test_remove_dropsById() throws {
        let store = FileStore()
        let url = try writeFile(name: "c.csv")
        store.stage(urls: [url])
        let id = store.files[0].id
        store.remove(id: id)
        XCTAssertTrue(store.files.isEmpty)
    }

    func test_clearAll_emptiesEverything() throws {
        let store = FileStore()
        let a = try writeFile(name: "x.dat")
        let b = try writeFile(name: "y.dat")
        store.stage(urls: [a, b])
        store.clearAll()
        XCTAssertTrue(store.files.isEmpty)
    }

    func test_isStillResolvable_falseAfterFileDeleted() throws {
        let store = FileStore()
        let url = try writeFile(name: "ghost.tmp")
        store.stage(urls: [url])
        let staged = store.files[0]
        try FileManager.default.removeItem(at: url)
        XCTAssertFalse(store.isStillResolvable(staged))
    }
}
