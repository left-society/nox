import XCTest
@testable import nox

final class SwipeGesturePolicyTests: XCTestCase {

    // MARK: - Helpers

    private func inputs(
        delta: CGFloat,
        phase: SwipeGesturePolicy.Phase = .changed,
        natural: Bool = true,
        success: CGFloat = 60,
        reset: CGFloat = 30
    ) -> SwipeGesturePolicy.Inputs {
        .init(delta: delta,
              phase: phase,
              naturalMovement: natural,
              successThreshold: success,
              resetThreshold: reset)
    }

    // MARK: - Idle (below reset threshold, in flight)

    func testIdleBelowResetThreshold() {
        // A 20pt drag is below the 30pt reset threshold: the user hasn't
        // committed to a swipe yet, the consumer should keep the pill's
        // visual offset at zero (no scrub yet).
        let result = SwipeGesturePolicy.decide(inputs(delta: 20))
        XCTAssertEqual(result, .idle)
    }

    func testIdleAtExactlyZeroDelta() {
        let result = SwipeGesturePolicy.decide(inputs(delta: 0))
        XCTAssertEqual(result, .idle)
    }

    func testIdleForNegativeDeltaBelowReset() {
        // Negative side gets the same treatment — magnitude is what
        // matters for thresholds.
        let result = SwipeGesturePolicy.decide(inputs(delta: -25))
        XCTAssertEqual(result, .idle)
    }

    // MARK: - Scrubbing (between reset and success, in flight)

    func testScrubbingProgressBetweenThresholds() {
        // 45pt is exactly halfway between reset (30) and success (60)
        // — progress should land at 0.5.
        let result = SwipeGesturePolicy.decide(inputs(delta: 45))
        guard case .scrubbing(let progress) = result else {
            return XCTFail("Expected .scrubbing, got \(result)")
        }
        XCTAssertEqual(progress, 0.5, accuracy: 0.001)
    }

    func testScrubbingProgressAtJustAboveReset() {
        // 31pt — just over reset. Progress should be near 0 but > 0.
        let result = SwipeGesturePolicy.decide(inputs(delta: 31))
        guard case .scrubbing(let progress) = result else {
            return XCTFail("Expected .scrubbing, got \(result)")
        }
        XCTAssertGreaterThan(progress, 0)
        XCTAssertLessThan(progress, 0.1)
    }

    func testScrubbingTreatsNegativeDeltaByMagnitude() {
        // -45pt is mirror of +45pt — progress is symmetric.
        let result = SwipeGesturePolicy.decide(inputs(delta: -45))
        guard case .scrubbing(let progress) = result else {
            return XCTFail("Expected .scrubbing for negative drag, got \(result)")
        }
        XCTAssertEqual(progress, 0.5, accuracy: 0.001)
    }

    // MARK: - Commit forward / backward × natural-movement on/off

    func testCommitForwardWithNaturalMovementOn() {
        // Natural ON: swipe LEFT (negative delta) skips FORWARD —
        // matches macOS natural-scroll trackpad direction. Drag the
        // content leftward → next item enters from the right, same
        // as flicking a feed upward to see the next post.
        let result = SwipeGesturePolicy.decide(
            inputs(delta: -80, natural: true))
        XCTAssertEqual(result, .commitForward)
    }

    func testCommitForwardWithNaturalMovementOff() {
        // Natural OFF: swipe RIGHT (positive delta) skips FORWARD —
        // matches reading direction ("→ next, ← previous"). This is
        // the orientation Alcove ships with, and the one most users
        // who grew up with non-natural scroll expect.
        let result = SwipeGesturePolicy.decide(
            inputs(delta: 80, natural: false))
        XCTAssertEqual(result, .commitForward)
    }

    func testCommitBackwardWithNaturalMovementOn() {
        // Natural ON, right swipe → previous track.
        let result = SwipeGesturePolicy.decide(
            inputs(delta: 80, natural: true))
        XCTAssertEqual(result, .commitBackward)
    }

    func testCommitBackwardWithNaturalMovementOff() {
        // Natural OFF, left swipe → previous track.
        let result = SwipeGesturePolicy.decide(
            inputs(delta: -80, natural: false))
        XCTAssertEqual(result, .commitBackward)
    }

    func testCommitFiresAtExactlySuccessThreshold() {
        // Boundary: a drag exactly at the success threshold counts
        // as a commit (≥, not >). Avoids a dead band where the user
        // drags to the magic number and nothing happens.
        let result = SwipeGesturePolicy.decide(
            inputs(delta: 60, natural: true))
        XCTAssertEqual(result, .commitBackward) // right at +60 with natural ON
    }

    func testCommitWinsOverPhaseEnded() {
        // If the user releases past the success threshold, the
        // commit wins — the consumer fires the haptic + media
        // command, and snaps the offset back independently.
        let result = SwipeGesturePolicy.decide(
            inputs(delta: -120, phase: .ended, natural: true))
        XCTAssertEqual(result, .commitForward)
    }

    // MARK: - Reset (released without crossing success threshold)

    func testResetWhenReleasedBelowSuccessThreshold() {
        // Released at 45pt — scrubbing zone, never crossed success.
        // Consumer animates the pill offset back to zero.
        let result = SwipeGesturePolicy.decide(
            inputs(delta: 45, phase: .ended))
        XCTAssertEqual(result, .reset)
    }

    func testResetWhenReleasedBelowResetThreshold() {
        // Released at 10pt — never even started scrubbing. Same
        // .reset signal so the consumer's onEnded handler has one
        // path for "snap the visual state home."
        let result = SwipeGesturePolicy.decide(
            inputs(delta: 10, phase: .ended))
        XCTAssertEqual(result, .reset)
    }

    func testResetSymmetricForNegativeRelease() {
        let result = SwipeGesturePolicy.decide(
            inputs(delta: -45, phase: .ended))
        XCTAssertEqual(result, .reset)
    }

    // MARK: - Defaults

    func testStaticDefaultsMatchSpec() {
        // Sprint doc §Session-2 §Implementation-requirements: the
        // default success threshold is 60pt and reset threshold is
        // 30pt. Lock those defaults in a test so a drive-by edit
        // can't silently widen / narrow the dead band.
        XCTAssertEqual(SwipeGesturePolicy.defaultSuccessThreshold, 60)
        XCTAssertEqual(SwipeGesturePolicy.defaultResetThreshold, 30)
    }
}
