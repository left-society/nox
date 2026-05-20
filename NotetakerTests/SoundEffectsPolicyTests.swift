import XCTest
@testable import nox

/// Tests for `SoundEffectsPolicy.shouldPlay(_:)` — the pure decision
/// struct that gates whether a given system-event sound should
/// actually emit. The Service-layer call site composes Inputs from
/// UserDefaults + `FocusStatusService.isFocused`; these tests only
/// exercise the rule so they can run without AppKit / NSSound.
final class SoundEffectsPolicyTests: XCTestCase {
    // MARK: - Required by sprint doc §4

    func testNotPlayedWhenEventDisabled() {
        // User has the master toggle on but flipped the per-event
        // switch off (e.g. wants Bluetooth chime but not the
        // charging Tink) — must stay silent.
        let result = SoundEffectsPolicy.shouldPlay(
            .init(
                masterEnabled: true,
                eventEnabled: false,
                isFocused: false,
                respectFocusMode: true
            )
        )
        XCTAssertFalse(result)
    }

    func testNotPlayedDuringFocusWhenRespected() {
        // macOS Focus is active AND the user has the "auto-hide
        // pills during Focus" toggle on (default true). Even
        // though the event is enabled, the Focus gate wins —
        // matches the existing pill suppression semantics.
        let result = SoundEffectsPolicy.shouldPlay(
            .init(
                masterEnabled: true,
                eventEnabled: true,
                isFocused: true,
                respectFocusMode: true
            )
        )
        XCTAssertFalse(result)
    }

    func testPlayedWhenEnabledAndNotFocused() {
        // The golden path: everything on, no Focus → emit.
        let result = SoundEffectsPolicy.shouldPlay(
            .init(
                masterEnabled: true,
                eventEnabled: true,
                isFocused: false,
                respectFocusMode: true
            )
        )
        XCTAssertTrue(result)
    }

    // MARK: - Additional branch coverage

    func testNotPlayedWhenMasterDisabled() {
        // Master kill-switch off → no per-event toggle can override.
        // Mirrors how `HapticFeedback.isEnabled` gates every haptic
        // emission regardless of the per-event flags.
        let result = SoundEffectsPolicy.shouldPlay(
            .init(
                masterEnabled: false,
                eventEnabled: true,
                isFocused: false,
                respectFocusMode: true
            )
        )
        XCTAssertFalse(result)
    }

    func testPlayedWhenFocusedButRespectFocusOff() {
        // User explicitly disabled "auto-hide pills during Focus" —
        // they've opted to receive notifications even while Focused.
        // Sounds should follow the same rule (respect-Focus is one
        // shared knob across pill suppression AND sound playback).
        let result = SoundEffectsPolicy.shouldPlay(
            .init(
                masterEnabled: true,
                eventEnabled: true,
                isFocused: true,
                respectFocusMode: false
            )
        )
        XCTAssertTrue(result)
    }

    func testNotPlayedWhenBothMasterAndEventDisabled() {
        // Defense-in-depth: short-circuit on the first failing gate
        // either way. This test ensures the two gates compose without
        // a bug like "AND-of-NOTs lets the sound through."
        let result = SoundEffectsPolicy.shouldPlay(
            .init(
                masterEnabled: false,
                eventEnabled: false,
                isFocused: false,
                respectFocusMode: true
            )
        )
        XCTAssertFalse(result)
    }
}
