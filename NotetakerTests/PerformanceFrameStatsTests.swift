import XCTest
@testable import nox

final class PerformanceFrameStatsTests: XCTestCase {
    func testRecordClassifiesFrameBudgetMisses() {
        var stats = PerformanceFrameStats()

        [10.0, 17.0, 25.0, 34.0, 80.0, 125.0].forEach {
            stats.record(deltaMs: $0)
        }

        XCTAssertEqual(stats.sampleCount, 6)
        XCTAssertEqual(stats.over60BudgetCount, 5)
        XCTAssertEqual(stats.over20MsCount, 4)
        XCTAssertEqual(stats.over33MsCount, 3)
        XCTAssertEqual(stats.over50MsCount, 2)
        XCTAssertEqual(stats.over100MsCount, 1)
        XCTAssertEqual(stats.worstMs, 125.0)
        XCTAssertEqual(stats.averageMs, 48.5, accuracy: 0.001)
    }

    func testSnapshotAndResetClearsAccumulatedStats() {
        var stats = PerformanceFrameStats()
        stats.record(deltaMs: 18.0)
        stats.record(deltaMs: 40.0)

        let snapshot = stats.snapshotAndReset()

        XCTAssertEqual(snapshot.sampleCount, 2)
        XCTAssertEqual(snapshot.over60BudgetCount, 2)
        XCTAssertEqual(snapshot.over33MsCount, 1)
        XCTAssertEqual(stats.sampleCount, 0)
        XCTAssertEqual(stats.averageMs, 0)
        XCTAssertEqual(stats.worstMs, 0)
    }

    func testRecordIgnoresInvalidSamples() {
        var stats = PerformanceFrameStats()

        stats.record(deltaMs: -1)
        stats.record(deltaMs: .nan)
        stats.record(deltaMs: .infinity)

        XCTAssertEqual(stats.sampleCount, 0)
    }

    func testHitchRatioNormalizesLateFrameTime() {
        var stats = PerformanceFrameStats()

        stats.record(deltaMs: 16.0)
        stats.record(deltaMs: PerformanceFrameStats.sixtyFPSBudgetMs + 4.0)
        stats.record(deltaMs: PerformanceFrameStats.sixtyFPSBudgetMs + 12.0)

        XCTAssertEqual(stats.hitchTimeMs, 16.0, accuracy: 0.001)
        XCTAssertEqual(stats.hitchRatioMsPerSecond(overDuration: 2.0), 8.0, accuracy: 0.001)
        XCTAssertEqual(stats.hitchRatioMsPerSecond(overDuration: 0), 0)
    }

    func testPerformanceLogWriterFlushesQueuedLines() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nox-performance-writer-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = try PerformanceLogWriter(url: url)
        writer.write("first\n")
        writer.write("second\n")
        writer.flush()
        writer.close()

        let contents = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(contents, "first\nsecond\n")
    }

    func testRestingWaveformUsesLowerCadenceUnlessInteracting() {
        XCTAssertEqual(
            WaveformRefreshPolicy.minimumInterval(
                isCompactResting: true,
                isInteractionActive: false
            ),
            1.0 / 12.0,
            accuracy: 0.0001
        )

        XCTAssertEqual(
            WaveformRefreshPolicy.minimumInterval(
                isCompactResting: true,
                isInteractionActive: true
            ),
            1.0 / 30.0,
            accuracy: 0.0001
        )

        XCTAssertEqual(
            WaveformRefreshPolicy.minimumInterval(
                isCompactResting: false,
                isInteractionActive: false
            ),
            1.0 / 30.0,
            accuracy: 0.0001
        )
    }

    func testTrackBannerDismissesToNotchHiddenWhenAnchorIsGone() {
        XCTAssertEqual(
            TrackBannerDismissalPolicy.targetKind(
                isVisible: false,
                isTeasing: false,
                pillAnchored: false
            ),
            .notchHidden
        )

        XCTAssertEqual(
            TrackBannerDismissalPolicy.targetKind(
                isVisible: false,
                isTeasing: false,
                pillAnchored: true
            ),
            .pill
        )

        XCTAssertEqual(
            TrackBannerDismissalPolicy.targetKind(
                isVisible: true,
                isTeasing: false,
                pillAnchored: false
            ),
            .none
        )
    }
}
