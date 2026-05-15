import XCTest
@testable import nox

final class ScreenshotPillPolicyTests: XCTestCase {
    func testFiresWhenSlabHiddenAndIdle() {
        let result = ScreenshotPillPolicy.shouldFirePill(
            .init(slabShown: false, slabMorphing: false))
        XCTAssertTrue(result)
    }

    func testSuppressesWhenSlabShown() {
        let result = ScreenshotPillPolicy.shouldFirePill(
            .init(slabShown: true, slabMorphing: false))
        XCTAssertFalse(result)
    }

    func testSuppressesWhenSlabMorphing() {
        let result = ScreenshotPillPolicy.shouldFirePill(
            .init(slabShown: false, slabMorphing: true))
        XCTAssertFalse(result)
    }

    func testSuppressesWhenBothShownAndMorphing() {
        let result = ScreenshotPillPolicy.shouldFirePill(
            .init(slabShown: true, slabMorphing: true))
        XCTAssertFalse(result)
    }
}
