import XCTest
@testable import nox

/// Tests for the two pure image-display policies that back the
/// 2026-05-23 photo-viewing restructure:
///   • `ThumbnailDisplayPolicy` — thumbnail-or-full fallback so a cell
///     never renders empty ("photo become hidden").
///   • `ImageViewerIndexPolicy` — clamped, no-wrap navigation for the
///     full-resolution viewer window.
///
/// Both live in `ImageStore.swift`. Pure logic, no AppKit / file
/// system / SwiftUI, so every branch is exercised here directly —
/// matching the `TimingPollPolicyTests` / `ScreenshotPillPolicyTests`
/// convention.
final class ImageDisplayPolicyTests: XCTestCase {
    private let thumb = URL(fileURLWithPath: "/lib/thumbs/x.jpg")
    private let full = URL(fileURLWithPath: "/lib/images/x.png")

    // MARK: - ThumbnailDisplayPolicy

    func testDisplayUsesThumbnailWhenItExists() {
        let r = ThumbnailDisplayPolicy.displayURL(thumbExists: true, thumbURL: thumb, fullURL: full)
        XCTAssertEqual(r, thumb)
    }

    func testDisplayFallsBackToFullWhenThumbnailMissing() {
        let r = ThumbnailDisplayPolicy.displayURL(thumbExists: false, thumbURL: thumb, fullURL: full)
        XCTAssertEqual(r, full)
    }

    // MARK: - ImageViewerIndexPolicy.startIndex

    func testStartIndexFindsRequestedID() {
        XCTAssertEqual(ImageViewerIndexPolicy.startIndex(for: "c", in: ["a", "b", "c", "d"]), 2)
    }

    func testStartIndexFailsSafeToZeroWhenNotFound() {
        XCTAssertEqual(ImageViewerIndexPolicy.startIndex(for: "zzz", in: ["a", "b", "c"]), 0)
    }

    func testStartIndexIsZeroForEmptyLibrary() {
        XCTAssertEqual(ImageViewerIndexPolicy.startIndex(for: "a", in: []), 0)
    }

    // MARK: - ImageViewerIndexPolicy.nextIndex (clamp, no wrap)

    func testNextIndexAdvancesInMiddle() {
        XCTAssertEqual(ImageViewerIndexPolicy.nextIndex(after: 1, count: 4), 2)
    }

    func testNextIndexClampsAtEnd() {
        XCTAssertEqual(ImageViewerIndexPolicy.nextIndex(after: 3, count: 4), 3)
    }

    func testNextIndexHandlesEmptyCount() {
        XCTAssertEqual(ImageViewerIndexPolicy.nextIndex(after: 0, count: 0), 0)
    }

    // MARK: - ImageViewerIndexPolicy.previousIndex (clamp, no wrap)

    func testPreviousIndexRetreatsInMiddle() {
        XCTAssertEqual(ImageViewerIndexPolicy.previousIndex(before: 2, count: 4), 1)
    }

    func testPreviousIndexClampsAtStart() {
        XCTAssertEqual(ImageViewerIndexPolicy.previousIndex(before: 0, count: 4), 0)
    }

    // MARK: - ImageViewerIndexPolicy.canGoNext / canGoPrevious

    func testCanGoNextTrueInMiddle() {
        XCTAssertTrue(ImageViewerIndexPolicy.canGoNext(from: 2, count: 4))
    }

    func testCanGoNextFalseAtEnd() {
        XCTAssertFalse(ImageViewerIndexPolicy.canGoNext(from: 3, count: 4))
    }

    func testCanGoPreviousTrueInMiddle() {
        XCTAssertTrue(ImageViewerIndexPolicy.canGoPrevious(from: 1, count: 4))
    }

    func testCanGoPreviousFalseAtStart() {
        XCTAssertFalse(ImageViewerIndexPolicy.canGoPrevious(from: 0, count: 4))
    }
}
