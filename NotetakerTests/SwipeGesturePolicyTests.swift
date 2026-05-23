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

/// Apple's rubber-band physics (`RubberBand`) — the resistance curve and
/// the WebKit spring-back decay used by the two-finger stretch.
final class RubberBandTests: XCTestCase {

    // MARK: - resist (during-drag resistance curve)

    func testResistZeroPullIsZero() {
        XCTAssertEqual(RubberBand.resist(0, dimension: 100), 0, accuracy: 0.0001)
    }

    func testResistSmallPullApproximatesConstantTimesPull() {
        // For x << d, b ≈ c·x. With c = 0.55, a 1pt pull on a 100pt
        // dimension should be ≈ 0.55pt.
        XCTAssertEqual(RubberBand.resist(1, dimension: 100), 0.55, accuracy: 0.01)
    }

    func testResistMatchesSimplifiedFormula() {
        // b = (x·d·c) / (d + c·x), c = 0.55, at x = d = 100.
        let expected: CGFloat = (100 * 100 * 0.55) / (100 + 0.55 * 100)
        XCTAssertEqual(RubberBand.resist(100, dimension: 100), expected, accuracy: 0.0001)
    }

    func testResistAsymptotesToDimensionButNeverReachesIt() {
        let d: CGFloat = 70
        let huge = RubberBand.resist(100_000, dimension: d)
        XCTAssertLessThan(huge, d)              // never exceeds the dimension
        XCTAssertGreaterThan(huge, 0.99 * d)    // but approaches it
    }

    func testResistIsMonotonicIncreasing() {
        let d: CGFloat = 70
        var prev = RubberBand.resist(0, dimension: d)
        for x in stride(from: CGFloat(5), through: 300, by: 5) {
            let cur = RubberBand.resist(x, dimension: d)
            XCTAssertGreaterThan(cur, prev)     // strictly grows with pull
            XCTAssertLessThan(cur, x)           // always less than the raw pull (resisted)
            prev = cur
        }
    }

    func testResistIsSignedForBothDirections() {
        let d: CGFloat = 70
        XCTAssertEqual(RubberBand.resist(-40, dimension: d),
                       -RubberBand.resist(40, dimension: d),
                       accuracy: 0.0001)
    }

    // MARK: - reboundOffset (WebKit spring-back decay)

    func testReboundStartsAtReleasePositionWhenNoVelocity() {
        // At t = 0 with no throw velocity, the offset equals the
        // release position (e^0 = 1).
        XCTAssertEqual(RubberBand.reboundOffset(position: 26, velocity: 0, elapsed: 0),
                       26, accuracy: 0.0001)
    }

    func testReboundDecaysTowardZeroOverTime() {
        let early = RubberBand.reboundOffset(position: 26, velocity: 0, elapsed: 0.05)
        let late = RubberBand.reboundOffset(position: 26, velocity: 0, elapsed: 0.4)
        XCTAssertLessThan(abs(late), abs(early))      // monotonic decay
        XCTAssertLessThan(abs(late), 0.2)             // nearly settled by ~0.4s (τ ≈ 80ms)
    }
}
