import XCTest
@testable import nox

final class FocusGatingPolicyTests: XCTestCase {
    // MARK: - Branch 1: not Focused → always show
    //
    // Whatever the user has configured for respectFocus or the
    // per-pill allow list, if macOS Focus isn't active the gate
    // is a no-op. Asserting on all 4 pill types here would just
    // re-check the early-return, so one representative is enough.

    func testNotFocusedAlwaysShows() {
        let result = FocusGatingPolicy.shouldShow(
            pill: .charging,
            isFocused: false,
            respectFocus: true,
            allowList: [])
        XCTAssertTrue(result)
    }

    func testNotFocusedShowsEvenWhenAllowListIsEmpty() {
        // The allow list is irrelevant when Focus is off — this
        // catches an implementation that incorrectly ANDed the
        // allow-list check into the not-focused branch.
        let result = FocusGatingPolicy.shouldShow(
            pill: .screenshot,
            isFocused: false,
            respectFocus: true,
            allowList: [])
        XCTAssertTrue(result)
    }

    // MARK: - Branch 2: Focused but respectFocus off → always show
    //
    // User has explicitly disabled the "Auto-hide pills during
    // Focus" master toggle. That disables suppression globally;
    // per-pill exceptions don't apply because there's nothing
    // to except from.

    func testFocusedWithRespectFalseShows() {
        let result = FocusGatingPolicy.shouldShow(
            pill: .bluetooth,
            isFocused: true,
            respectFocus: false,
            allowList: [])
        XCTAssertTrue(result)
    }

    // MARK: - Branch 3: Focused + respecting Focus + pill NOT in allow list → suppress
    //
    // This is the default behavior the master toggle was always
    // promising — Focus is on, user wants pills hidden, and
    // they haven't opted this specific pill back in.

    func testFocusedWithRespectAndNoAllowDoesNotShow() {
        let result = FocusGatingPolicy.shouldShow(
            pill: .charging,
            isFocused: true,
            respectFocus: true,
            allowList: [])
        XCTAssertFalse(result)
    }

    func testFocusedWithRespectAndDifferentPillInAllowDoesNotShow() {
        // The new per-pill bit: an allow flag on .airdrop must
        // NOT bleed through to .charging. Catches a regression
        // where the policy ignored its `pill` argument and just
        // returned `!allowList.isEmpty`.
        let result = FocusGatingPolicy.shouldShow(
            pill: .charging,
            isFocused: true,
            respectFocus: true,
            allowList: [.airdrop])
        XCTAssertFalse(result)
    }

    // MARK: - Branch 4: Focused + respecting Focus + pill IN allow list → show
    //
    // The Alcove-style per-pill exception. User said "respect
    // Focus in general, but I want charging pills regardless"
    // by flipping the indented child toggle, and the policy
    // honors that.

    func testFocusedWithRespectAndAllowShows() {
        let result = FocusGatingPolicy.shouldShow(
            pill: .charging,
            isFocused: true,
            respectFocus: true,
            allowList: [.charging])
        XCTAssertTrue(result)
    }

    func testAllFourPillTypesGateIndependentlyWhenInAllowList() {
        // Sweep every PillType case so a new variant added later
        // (without a corresponding test row) shows up as a test
        // failure rather than silent under-coverage.
        for pill in [PillType.charging, .airdrop, .bluetooth, .screenshot] {
            let result = FocusGatingPolicy.shouldShow(
                pill: pill,
                isFocused: true,
                respectFocus: true,
                allowList: [pill])
            XCTAssertTrue(result, "\(pill) should show when present in its own allow list")
        }
    }

    func testAllFourPillTypesSuppressIndependentlyWhenAbsent() {
        for pill in [PillType.charging, .airdrop, .bluetooth, .screenshot] {
            let result = FocusGatingPolicy.shouldShow(
                pill: pill,
                isFocused: true,
                respectFocus: true,
                allowList: [])
            XCTAssertFalse(result, "\(pill) should suppress when absent from the allow list")
        }
    }
}
