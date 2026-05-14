import XCTest
@testable import nox

final class NotetakerTests: XCTestCase {
    func testTargetBuilds() {
        XCTAssertTrue(true)
    }

    func testDragDetectedOpenUsesHoverMode() {
        XCTAssertEqual(
            PanelOpenModePolicy.mode(for: .dragDetected),
            PanelWindowController.OpenMode.hover
        )
        XCTAssertEqual(
            PanelOpenModePolicy.mode(for: .explicit),
            PanelWindowController.OpenMode.click
        )
    }
}
