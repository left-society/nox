import XCTest
@testable import nox

@MainActor
final class NoteStoreTests: XCTestCase {
    private func makeStore() throws -> NoteStore {
        let db = try Database(inMemory: true)
        return NoteStore(db: db)
    }

    func test_createNote_insertsAtTop() throws {
        let store = try makeStore()
        let n1 = try store.createNote()
        let n2 = try store.createNote()
        XCTAssertEqual(store.notes.map(\.id), [n2.id, n1.id])
    }

    func test_updateBody_refreshesTitleAndOrder() throws {
        let store = try makeStore()
        let n1 = try store.createNote()
        _ = try store.createNote()
        try store.updateBody(id: n1.id, body: "Hello world")
        XCTAssertEqual(store.notes.first?.id, n1.id)
        XCTAssertEqual(store.notes.first?.title, "Hello world")
    }

    func test_deriveTitle_takesFirstLineTrimmed() {
        XCTAssertEqual(NoteStore.deriveTitle(from: "  First  \nSecond"), "First")
        XCTAssertNil(NoteStore.deriveTitle(from: ""))
        XCTAssertEqual(
            NoteStore.deriveTitle(from: String(repeating: "a", count: 100)),
            String(repeating: "a", count: 60)
        )
    }

    func test_trash_removesFromActiveList() throws {
        let store = try makeStore()
        let n = try store.createNote()
        try store.trash(id: n.id)
        XCTAssertTrue(store.notes.isEmpty)
    }
}
