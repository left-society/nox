// MARK: - Wiring Spec (for coordinator)
//
// This file is the policy only. The consumer wiring lives in
// `PanelRootView.swift` (the existing resting-pill DragGesture at
// ~line 2960) and a Settings toggle in `SettingsWindow.swift`'s
// `MusicSettings` view.
//
// ──────────────────────────────────────────────────────────────────
// 1. SettingsKey additions
//    File: Notetaker/Settings/SettingsWindow.swift
//    Section: `enum SettingsKey { ... // Music ... }` (~line 212)
//    Add (right after `pillSwipeToSkip`):
//
//        /// Natural swipe direction on the resting music pill.
//        /// Default true: dragging LEFT skips forward, matching
//        /// macOS "natural scroll" (content follows the finger).
//        /// Flip to false for reading-order direction (RIGHT = next).
//        /// Read inline via `SwipeGesturePolicy.naturalMovementDefault`'s
//        /// UserDefaults adapter in the consumer view so a flip in
//        /// Settings takes effect on the next gesture.
//        static let naturalSwipeDirection = "naturalSwipeDirection"
//
//        // Tuning thresholds for the horizontal-swipe-to-skip gesture.
//        // Hidden from Settings UI in 1.9.21 — exposed via
//        // `SwipeGesturePolicy.defaultSuccessThreshold` /
//        // `defaultResetThreshold` and overridable by power users
//        // via `defaults write app.trynox` if they want a longer or
//        // shorter throw. Promoting to an "Advanced" panel is a
//        // v1.10 decision.
//        static let horizontalSwipeSuccessThreshold = "horizontalSwipeSuccessThreshold"
//        static let horizontalSwipeResetThreshold   = "horizontalSwipeResetThreshold"
//
// ──────────────────────────────────────────────────────────────────
// 2. SettingsWindow.swift — Music section UI
//    File: Notetaker/Settings/SettingsWindow.swift
//    Struct: `private struct MusicSettings: View` (~line 885)
//    Add an @AppStorage binding alongside `pillSwipeToSkip`:
//
//        @AppStorage(SettingsKey.naturalSwipeDirection)
//        private var naturalSwipeDirection: Bool = true
//
//    And a child SettingsRow inside the same SettingsCard, right
//    after the existing "Swipe to skip" row (which becomes
//    `divider: true` instead of `false` so the new row sits below
//    it cleanly, with the new row taking the final-row `divider: false`):
//
//        SettingsRow(title: "Natural swipe direction",
//                    subtitle: "Swipe left for next track. Off = reverse.",
//                    divider: false) {
//            Toggle("", isOn: $naturalSwipeDirection).labelsHidden()
//        }
//        .disabled(!pillSwipeToSkip)   // grey-out when master swipe is off
//
// ──────────────────────────────────────────────────────────────────
// 3. PanelRootView.swift — replace the existing inline DragGesture
//    body (lines ~2961-3019) with a SwipeGesturePolicy.decide call.
//    Mechanical translation, no behavior change beyond what the
//    policy adds (separate success / reset thresholds, natural-
//    direction toggle):
//
//        @State private var pillSwipeOffset: CGFloat = 0
//        @State private var pillSwipeArmedDirection: Int = 0   // unchanged
//
//        // Add these reads near `pillSwipeEnabled`:
//        private var naturalSwipeDirection: Bool {
//            if UserDefaults.standard.object(
//                forKey: SettingsKey.naturalSwipeDirection) == nil { return true }
//            return UserDefaults.standard.bool(
//                forKey: SettingsKey.naturalSwipeDirection)
//        }
//
//        // In the DragGesture .onChanged closure (replace lines
//        // ~2971-2990):
//        let dx = value.translation.width
//        let dy = abs(value.translation.height)
//        guard dy < abs(dx) * 1.2 else { return }   // unchanged angle guard
//        pillSwipeOffset = dx
//        let decision = SwipeGesturePolicy.decide(.init(
//            delta: dx,
//            phase: .changed,
//            naturalMovement: naturalSwipeDirection,
//            successThreshold: SwipeGesturePolicy.defaultSuccessThreshold,
//            resetThreshold: SwipeGesturePolicy.defaultResetThreshold))
//        switch decision {
//        case .commitForward where pillSwipeArmedDirection != 1:
//            HapticFeedback.generic()          // tug-at-threshold
//            pillSwipeArmedDirection = 1
//        case .commitBackward where pillSwipeArmedDirection != -1:
//            HapticFeedback.generic()
//            pillSwipeArmedDirection = -1
//        case .idle, .scrubbing where pillSwipeArmedDirection != 0:
//            pillSwipeArmedDirection = 0       // drifted back below
//        default: break
//        }
//
//        // In the DragGesture .onEnded closure (replace lines
//        // ~3002-3019):
//        let decision = SwipeGesturePolicy.decide(.init(
//            delta: value.translation.width,
//            phase: .ended,
//            naturalMovement: naturalSwipeDirection,
//            successThreshold: SwipeGesturePolicy.defaultSuccessThreshold,
//            resetThreshold: SwipeGesturePolicy.defaultResetThreshold))
//        switch decision {
//        case .commitForward:
//            presenter.onMediaCommand?(.next)
//            HapticFeedback.alignment()
//        case .commitBackward:
//            presenter.onMediaCommand?(.previous)
//            HapticFeedback.alignment()
//        case .reset, .idle, .scrubbing:
//            break
//        }
//        withAnimation(.spring(
//            response: SwipeGesturePolicy.resetSpringResponse,
//            dampingFraction: SwipeGesturePolicy.resetSpringDampingFraction)) {
//            pillSwipeOffset = 0
//        }
//        pillSwipeArmedDirection = 0
//
// ──────────────────────────────────────────────────────────────────
// 4. Xcode project registration
//    File: Notetaker.xcodeproj/project.pbxproj
//    Register both this file AND `NotetakerTests/SwipeGesturePolicyTests.swift`
//    in their respective Compile Sources phases. See the doc
//    "🟦 Coordinator Session §5" for the exact pbxproj surgery
//    (mirror the TimingPollPolicy / TimingPollPolicyTests
//    PBXBuildFile + PBXFileReference + PBXGroup + PBXSourcesBuildPhase
//    entries; the existing IDs `TIMPOLL00A1B2C3D4E5F000{1..4}` are
//    a good shape to copy).
//
// END WIRING SPEC

import Foundation
import CoreGraphics

/// Pure decision policy for the horizontal swipe-to-skip-track
/// gesture on the resting now-playing pill.
///
/// Lives separately from `PanelRootView`'s DragGesture body so the
/// rule — "given the live drag delta, the natural-movement
/// preference, and the configured thresholds, what should the pill
/// do right now?" — can be exercised by `SwipeGesturePolicyTests`
/// without dragging in AppKit, SwiftUI, or the panel's
/// `@EnvironmentObject` stack. The previous handler (1.9.20 ship,
/// committed in baf4a06) inlined every threshold check inside the
/// `.onChanged` / `.onEnded` closures; this struct lifts that logic
/// out so future polish (per-app threshold overrides, a Settings
/// "swipe sensitivity" slider, two-finger guards) doesn't have to
/// re-touch a 5500-line view file.
///
/// **Policy contract:**
///   • Below `resetThreshold` (in flight): `.idle` — the consumer
///     keeps the pill's visual offset at zero. Gesture hasn't
///     committed to anything.
///   • Between `resetThreshold` and `successThreshold` (in flight):
///     `.scrubbing(progress: 0…1)` — the consumer applies an
///     `offset(x:)` proportional to progress so the user feels the
///     drag tracking under their finger.
///   • At or past `successThreshold` (either phase): `.commitForward`
///     or `.commitBackward` — the consumer fires
///     `HapticFeedback.generic()` once (tug-at-threshold) and, on
///     release, runs the media command + `.alignment` haptic. The
///     forward/backward axis flips with the `naturalMovement`
///     preference (see below).
///   • Released below `successThreshold`: `.reset` — the consumer
///     animates the pill offset back to zero with the
///     `resetSpring*` parameters exposed below.
///
/// **Natural-movement preference** (2026-05-17 sprint, Alcove parity):
/// `naturalMovement: true` (default) matches macOS's natural-scroll
/// trackpad direction — dragging LEFT pushes content rightward in
/// your mental model, so the NEXT track slides in from the right
/// (forward = left swipe). `false` matches reading order
/// (forward = right swipe = →), which is how Alcove ships and how
/// users who disabled natural-scroll system-wide expect it to feel.
/// The toggle lives at `SettingsKey.naturalSwipeDirection`; this
/// struct doesn't read UserDefaults itself — the consumer passes
/// the current value in via `Inputs`.
///
/// **The policy does NOT touch AppKit / SwiftUI.** No
/// `NSHapticFeedbackManager` calls, no `withAnimation`, no
/// `@Environment` reads. The consumer view is responsible for:
///   (a) firing the threshold-cross haptic via `HapticFeedback`
///       (already a settings-aware wrapper around the AppKit API),
///   (b) running `withAnimation(.spring(...))` on `.reset`, and
///   (c) de-duplicating the haptic across consecutive
///       `.onChanged` ticks so it fires once per threshold crossing
///       and not every frame.
///
/// This split keeps `SwipeGesturePolicyTests` runnable in pure
/// Foundation — no `@MainActor` test bleed, no AppKit haptic side
/// effect during a CI run, no flaky `XCTAssertEqual` against an
/// `Animation` value.
enum SwipeGesturePolicy {

    // MARK: - Inputs

    /// Phase of the underlying `DragGesture`. Distinguishes "the
    /// user is still dragging" from "the user just released" so the
    /// policy can return `.reset` only on the release tick.
    enum Phase: Equatable {
        /// In-flight `.onChanged` tick.
        case changed
        /// Final `.onEnded` tick — finger lifted.
        case ended
    }

    /// Snapshot of everything the policy looks at. Kept as a struct
    /// (vs. positional args) so a future input — e.g. "is there an
    /// in-flight media command from a prior swipe we shouldn't
    /// double-fire" — slots in without changing every call site.
    struct Inputs: Equatable {
        /// Signed horizontal translation in points, taken straight
        /// from `DragGesture.Value.translation.width`. Negative =
        /// dragging left, positive = dragging right.
        let delta: CGFloat
        /// `.changed` while the finger is still down, `.ended` on
        /// release. Drives whether sub-threshold drags resolve as
        /// `.idle` (in-flight) or `.reset` (released).
        let phase: Phase
        /// User's `SettingsKey.naturalSwipeDirection` choice.
        /// True (default): left swipe = next track.
        /// False: right swipe = next track.
        let naturalMovement: Bool
        /// Magnitude (in points) at which the gesture commits — the
        /// release will run the media command and the threshold
        /// crossing fires the tug haptic. Defaults to
        /// `SwipeGesturePolicy.defaultSuccessThreshold` (60pt).
        let successThreshold: CGFloat
        /// Magnitude below which the gesture is still "idle" — the
        /// pill stays put visually. Between this and
        /// `successThreshold` the consumer renders a scrub offset.
        /// Defaults to `SwipeGesturePolicy.defaultResetThreshold`
        /// (30pt). Choosing reset < success creates a soft dead
        /// band at the start of the drag so accidental
        /// finger-jitter doesn't immediately tug the pill — matches
        /// Alcove's "you actually meant this" affordance.
        let resetThreshold: CGFloat
    }

    // MARK: - Decision

    /// What the consumer view should do this tick.
    enum Decision: Equatable {
        /// Drag is below the reset threshold (or zero) and still in
        /// flight — keep pill offset at 0, do nothing else.
        case idle
        /// Drag is between reset and success thresholds — apply an
        /// offset proportional to `progress` (0…1) so the user
        /// feels the pill follow the finger. The consumer typically
        /// pipes this through its own rubber-banding curve before
        /// rendering.
        case scrubbing(progress: Double)
        /// Crossed the success threshold in the "next track"
        /// direction. With `naturalMovement: true` this is a LEFT
        /// swipe; with `false` it's a RIGHT swipe. Consumer fires
        /// the tug haptic once per crossing and the media command +
        /// alignment haptic on release.
        case commitForward
        /// Mirror of `.commitForward` for the previous-track
        /// direction.
        case commitBackward
        /// Finger lifted without crossing the success threshold.
        /// Consumer animates the pill offset back to zero using the
        /// `resetSpring*` parameters below.
        case reset
    }

    // MARK: - The rule

    /// The whole policy in one switch-table. No side effects.
    static func decide(_ inputs: Inputs) -> Decision {
        let magnitude = abs(inputs.delta)

        // Past success — commit, regardless of phase. Returning the
        // commit on `.changed` is what lets the consumer fire the
        // tug haptic AT THE MOMENT of crossing (not on release),
        // which is the entire Alcove-parity polish ask for this
        // sprint. On `.ended` we still surface the commit so the
        // consumer can dispatch the actual media command.
        if magnitude >= inputs.successThreshold {
            let isLeftSwipe = inputs.delta < 0
            // Direction mapping:
            //   naturalMovement ON  → left swipe = forward (next)
            //   naturalMovement OFF → right swipe = forward (next)
            // The truth-table reduces to "XOR of isLeftSwipe and
            // !naturalMovement," but the if-else form below reads
            // straight from the spec without forcing the reader to
            // chase through an XOR.
            let forward: Bool
            if inputs.naturalMovement {
                forward = isLeftSwipe
            } else {
                forward = !isLeftSwipe
            }
            return forward ? .commitForward : .commitBackward
        }

        // Released below success — snap home. One reset signal for
        // both "released-mid-scrub" and "released-while-idle" so
        // the consumer's `.onEnded` has one path to follow.
        if inputs.phase == .ended {
            return .reset
        }

        // In flight, below reset — gesture hasn't committed to
        // anything yet. Consumer keeps pill offset at 0.
        if magnitude < inputs.resetThreshold {
            return .idle
        }

        // In flight, between thresholds — visual scrub. Linear map
        // from the reset boundary to the success boundary gives a
        // progress value the consumer can pipe through its own
        // easing (the existing rubber-banded `sign * cap * (1 -
        // exp(-magnitude/cap))` curve in `PanelRootView`).
        let span = inputs.successThreshold - inputs.resetThreshold
        let raw = Double((magnitude - inputs.resetThreshold) / span)
        return .scrubbing(progress: min(1, max(0, raw)))
    }

    // MARK: - Defaults

    /// Default commit threshold (points). 60pt is the sprint-spec
    /// value, sitting between the previous shipped 35pt (felt
    /// trigger-happy on small horizontal trackpad twitches during
    /// vertical scrolls — user feedback 2026-05-17 sprint doc) and
    /// macOS's own swipe-to-back threshold of ~150pt (felt sluggish
    /// for a 478pt-wide pill). 60pt gives ~12% of the pill width as
    /// the committed throw — enough deliberateness to feel
    /// intentional, short enough to feel reactive.
    static let defaultSuccessThreshold: CGFloat = 60

    /// Default reset threshold (points). 30pt is half the success
    /// threshold so the dead band consumes the first 30pt of any
    /// horizontal motion, then the scrubbing zone fills the next
    /// 30pt up to the commit. Linear easing in that 30pt span maps
    /// finger travel to visual scrub 1:1 before the consumer's
    /// rubber-band curve takes over.
    static let defaultResetThreshold: CGFloat = 30

    // MARK: - Reset spring (exposed as plain numbers, NOT SwiftUI types)

    /// Spring `response` (in seconds) for the `.reset` snap-back
    /// animation. The consumer wraps the offset reset in
    /// `withAnimation(.spring(response: ..., dampingFraction: ...))`
    /// using these constants. Exposing them as `Double` (not a
    /// SwiftUI `Animation`) keeps this file free of AppKit/SwiftUI
    /// imports — the test target can read them without importing
    /// the GUI stack.
    ///
    /// `0.4 / 0.85` was the sprint-spec ask. It sits between
    /// `DSAnimation.rowHover` (0.22 / 0.9, snappier) and
    /// `DSAnimation.panelOpen` (0.42 / 0.78, larger amplitude) —
    /// reads as a small element settling firmly, no overshoot. The
    /// previous shipped reset (`response: 0.32, dampingFraction:
    /// 0.78`, see `PanelRootView` line ~3015) snapped too hard on
    /// release; the softer 0.4/0.85 lands closer to the resting
    /// pill feeling like it "drifts" rather than "snaps" home,
    /// matching Alcove's release vocabulary.
    static let resetSpringResponse: Double = 0.4

    /// Spring `dampingFraction` for `.reset`. See
    /// `resetSpringResponse` for sourcing rationale.
    static let resetSpringDampingFraction: Double = 0.85
}
