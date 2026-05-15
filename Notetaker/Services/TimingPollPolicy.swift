import Foundation

/// Decides whether the MediaRemoteService AppleScript timing poll
/// should actually send its `tell application "Spotify" / "Music"`
/// query, or skip this tick.
///
/// Background: `MediaRemoteService.startAppScriptTimingTimer` schedules
/// a Timer that fires every 2.5s while music is playing, dispatching
/// an AppleScript to read the live `player position`. The AppleScript
/// goes out via Apple Events and can synchronously block the main
/// thread for 30-80ms on a cold bridge — most aggressively in the
/// 30s-2min window after the Mac wakes from sleep, when the bridge
/// is re-warming.
///
/// The position read is only used to keep the music card's progress
/// bar accurate. When the user isn't looking at the music card (slab
/// hidden, or slab open on a non-music tab), refining position to
/// sub-second accuracy buys nothing — the next display will
/// extrapolate from the last known position + elapsed time, which is
/// within ~0.3s for typical wait windows.
///
/// PerformanceProbe trace 2026-05-15 (file `performance-2026-05-15-
/// 083614.log`) showed periodic 50-56ms spikes every 2.4-2.8s with
/// `active=false`, matching this timer exactly. After wake, the
/// cluster persists for the user-reported ~30s-2min before settling.
enum TimingPollPolicy {
    struct Inputs {
        /// Whether music is currently playing (per `lastInfo.isPlaying`).
        /// If false, the timer self-stops elsewhere; this struct only
        /// matters when music IS active.
        let musicPlaying: Bool
        /// Whether the slab is currently displayed (`presenter.isShown`).
        let panelVisible: Bool
        /// Whether the currently-active tab is the music tab
        /// (`presenter.activeTab == .music`).
        let onMusicTab: Bool
    }

    /// True iff this tick should run the AppleScript. When false,
    /// the timer fires but skips the work — keeps the timer cadence
    /// stable so it can resume the moment the user opens the panel
    /// onto the music card, without re-installing a fresh timer.
    static func shouldPollNow(_ inputs: Inputs) -> Bool {
        guard inputs.musicPlaying else { return false }
        return inputs.panelVisible && inputs.onMusicTab
    }
}
