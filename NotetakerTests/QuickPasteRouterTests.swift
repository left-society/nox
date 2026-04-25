import XCTest
@testable import Notetaker

final class QuickPasteRouterTests: XCTestCase {
    func test_text_returnsFirstWhenIndexZero() {
        let result = QuickPasteRouter.itemAt(index: 0, texts: ["alpha", "beta", "gamma"])
        if case .text(let s) = result {
            XCTAssertEqual(s, "alpha")
        } else {
            XCTFail("expected .text(\"alpha\"), got \(result)")
        }
    }

    func test_text_returnsNthString() {
        let result = QuickPasteRouter.itemAt(index: 2, texts: ["alpha", "beta", "gamma"])
        if case .text(let s) = result {
            XCTAssertEqual(s, "gamma")
        } else {
            XCTFail("expected .text(\"gamma\"), got \(result)")
        }
    }

    func test_text_outOfRange_returnsNone() {
        XCTAssertEqual(
            QuickPasteRouter.itemAt(index: 5, texts: ["only-one"]),
            .none
        )
    }

    func test_text_emptyArray_returnsNone() {
        XCTAssertEqual(
            QuickPasteRouter.itemAt(index: 0, texts: []),
            .none
        )
    }

    func test_text_negativeIndex_returnsNone() {
        XCTAssertEqual(
            QuickPasteRouter.itemAt(index: -1, texts: ["alpha"]),
            .none
        )
    }

    func test_urls_returnsNthURL() throws {
        let urls = try (0..<3).map { i -> URL in
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("f\(i).txt")
            try Data("hi".utf8).write(to: url)
            return url
        }
        defer {
            urls.forEach { try? FileManager.default.removeItem(at: $0.deletingLastPathComponent()) }
        }

        let result = QuickPasteRouter.itemAt(index: 1, urls: urls)
        if case .fileURL(let u) = result {
            XCTAssertEqual(u.lastPathComponent, "f1.txt")
        } else {
            XCTFail("expected .fileURL, got \(result)")
        }
    }

    func test_urls_outOfRange_returnsNone() {
        XCTAssertEqual(
            QuickPasteRouter.itemAt(index: 9, urls: []),
            .none
        )
    }
}
