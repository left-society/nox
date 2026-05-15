import XCTest
@testable import nox

final class TimingPollPolicyTests: XCTestCase {
    func testPollsWhenMusicPlayingAndPanelOnMusicTab() {
        let result = TimingPollPolicy.shouldPollNow(
            .init(musicPlaying: true, panelVisible: true, onMusicTab: true))
        XCTAssertTrue(result)
    }

    func testSkipsWhenMusicPaused() {
        let result = TimingPollPolicy.shouldPollNow(
            .init(musicPlaying: false, panelVisible: true, onMusicTab: true))
        XCTAssertFalse(result)
    }

    func testSkipsWhenPanelHidden() {
        let result = TimingPollPolicy.shouldPollNow(
            .init(musicPlaying: true, panelVisible: false, onMusicTab: true))
        XCTAssertFalse(result)
    }

    func testSkipsWhenOnOtherTab() {
        let result = TimingPollPolicy.shouldPollNow(
            .init(musicPlaying: true, panelVisible: true, onMusicTab: false))
        XCTAssertFalse(result)
    }

    func testSkipsWhenHiddenAndPaused() {
        let result = TimingPollPolicy.shouldPollNow(
            .init(musicPlaying: false, panelVisible: false, onMusicTab: false))
        XCTAssertFalse(result)
    }
}
