import SwiftUI
import AppKit

@MainActor
final class PanelPresenter: ObservableObject {
    @Published var isShown: Bool = false
    @Published var activeTab: PanelTab = .notes

    /// CoreAudio-driven "is any user-facing app actually outputting
    /// audio right now?" signal. Sourced from
    /// `SystemAudioWatcher.isAudioFlowing` via NotchOrchestrator.
    /// Drives the waveform animation as the AUTHORITATIVE
    /// "playing" state — more reliable than `nowPlaying.isPlaying`
    /// because it can't lie. CoreAudio only reports `true` if
    /// bytes are actually flowing to the output device this tick.
    /// When the user pauses Spotify, this drops to false within
    /// ~1 second (CoreAudio sample window) regardless of whether
    /// MediaRemote got around to flipping its `isPlaying` flag.
    @Published var isAudioFlowing: Bool = false

    /// True while a panel-frame morph is in flight (~0.5–1s
    /// window). Set by PanelWindowController right before its
    /// SpringFrameAnimator starts, cleared in the spring's
    /// completion handler. Heavy continuous content (the sphere
    /// visualizer's 60Hz draw loop) gates on this so it doesn't
    /// compete with the spring for main-thread runloop slots — the
    /// Timer-based spring needs uncontested pacing to read as
    /// "buttery smooth jelly" rather than the jittery wobble the
    /// user reported.
    @Published var isMorphing: Bool = false
    /// Driven by PanelDropContainer (the contentView wrapper) when a drag
    /// hovers over the panel. Used by PanelRootView to draw an accent ring.
    @Published var isDropTargeted: Bool = false

    /// Two-zone drop picker state. While `dropPickerActive == true`,
    /// the panel renders a `DropPickerView` overlay with two large
    /// zones (Save / AirDrop), and the panel frame morphs to a wider
    /// "picker" silhouette so the zones have room to breathe.
    /// `dropPickerHoveredZone` mirrors which zone the cursor is over
    /// during the drag, so the SwiftUI overlay can highlight it.
    /// Both flip via `PanelDropContainer.draggingEntered/Updated/
    /// Exited` — the AppKit drop layer is the source of truth.
    @Published var dropPickerActive: Bool = false
    @Published var dropPickerHoveredZone: DropDestination? = nil
    /// File count for the in-flight drag, computed in
    /// `VideoDropCatcher.draggingEntered`. Drives the AirDrop
    /// zone's "✈ N" badge so the user sees the batch was
    /// recognized before they release. Resets to 0 on drag exit.
    @Published var dropPickerFileCount: Int = 0

    /// True while the system session is locked. Driven by
    /// `LockScreenWatcher`'s `com.apple.screenIsLocked` /
    /// `com.apple.screenIsUnlocked` subscriptions and routed
    /// through AppDelegate.
    ///
    /// Read by `LockMusicCardWindowController` to gate visibility
    /// of the lock-screen music card. Could also be read by
    /// PanelRootView in the future if we want to show different
    /// pill content on lock vs desktop.
    @Published var isLocked: Bool = false

    /// True while the user is in any system Focus or DND mode AND
    /// has authorized us to read it. Pumped from `FocusStatusService`
    /// in AppDelegate. Used by `setPendingSystemEvent` to mute
    /// non-essential transient pills (charging, screenshots,
    /// downloads, BT, note-saved) so the pill doesn't pop while
    /// the user is in heads-down mode. User-initiated events
    /// (timer countdown, video preview, charging IF the user has
    /// explicitly opted into seeing it through Focus) still fire.
    ///
    /// Default false — when the user hasn't authorized Focus access
    /// or hasn't opted into the auto-hide behavior, this stays
    /// false forever and the gating becomes a no-op.
    @Published var isFocused: Bool = false

    /// True when the panel is sitting at closed-pill geometry as a
    /// persistent now-playing indicator (Alcove-style "always-on" pill).
    /// Mutually exclusive with `isShown` in spirit — the panel transitions
    /// resting → shown on hover-activate and shown → resting on dismissal.
    /// Strings extracted from `/Applications/Alcove.app/Contents/MacOS/Alcove`
    /// confirm this is exactly Alcove's model: a single `NotchController`
    /// with `_isExpanded` / `_isHovering` flags driving a morph between
    /// the resting pill silhouette and the expanded slab — not two
    /// separate windows. We keep one NSPanel and let SwiftUI swap content
    /// based on these flags.
    ///
    /// PanelRootView reads this to render the artwork+waveform pill body
    /// (when `isResting && !isShown`) vs the full header/segmented/content
    /// tree (when `isShown`). The clip-shape's bottom corner radius also
    /// keys off it (16pt for the pill, 34pt for the slab) so the
    /// silhouette morphs smoothly during the expand animation.
    @Published var isResting: Bool = false

    /// True when the panel has parked at notch-hidden geometry (no-music
    /// close target — exact hardware-notch dimensions). Used by
    /// PanelRootView to render the silhouette WITHOUT the inverse-bow
    /// shoulder + convex bottom flare that the slab/music-pill states use.
    ///
    /// Why this matters — the "triangle" close fix:
    /// At slab/music-pill widths (278pt+), topR=6 + bottomR=8 = 14pt
    /// per-side narrowing reads as ~5% inward taper — a clean pill curve.
    /// At notch-hidden width (185pt = hardware notch), the SAME 14pt
    /// per-side narrowing becomes ~7.5% taper across only 32pt of height,
    /// which the user perceives as a wedge ("triangle"). Solving by
    /// scaling radii proportionally (e.g. 4/5) still leaves visible
    /// shoulder narrowing; the cleaner answer is to match the actual
    /// hardware-notch silhouette character — sharp 90° top corners
    /// (the notch hardware meets the screen edge at 90°, no flare) and
    /// a subtle rounded bottom (the cutout's bottom edge has a small
    /// corner radius). With topR=0 and bottomR=4 at notch-hidden state,
    /// the silhouette renders as a flat-topped rectangle with subtle
    /// rounded bottom corners — visually identical to the hardware
    /// notch cutout itself, so panel + hardware merge as one shape.
    /// This is the "exactly the same as music close, but at hardware
    /// size" the user asked for — same clean-pill character, sized
    /// to the hardware cutout.
    ///
    /// Set by PanelWindowController.animateClose completion when target
    /// is notchHidden. Cleared by show()/open paths so the slab radii
    /// (22 / innerCornerRadius) take over for the open silhouette.
    @Published var isAtNotchHidden: Bool = false

    /// Latest now-playing snapshot from MediaRemoteService, forwarded
    /// here by NotchOrchestrator so SwiftUI views inside the panel
    /// (specifically MusicPanelView and the segmented bar) can observe
    /// it without having to know about the orchestrator. Nil means
    /// nothing is playing — when this flips from non-nil to nil, the
    /// segmented bar drops the .music tab and the active tab auto-
    /// rotates back to .notes if it was .music.
    /// Per BUG-082 fix: stays as `@Published` so the projected
    /// `$nowPlaying` publisher is preserved for Combine consumers
    /// (LockMusicCardWindow, etc.). The performance concern from
    /// the bug review — redundant SwiftUI re-renders on byte-
    /// identical re-emissions — is substantially mitigated by:
    /// (a) MediaRemoteService publishing the equality-deduplicated
    /// snapshot already (`publish(_:)` checks `lastInfo != info`
    /// before forwarding), and (b) SwiftUI's view diffing eliding
    /// the actual UI updates when body output is identical.
    /// Combine subscribers that need stricter dedup can chain
    /// `.removeDuplicates()` on `$nowPlaying`.
    @Published var nowPlaying: NowPlayingInfo? {
        didSet {
            // Auto-collapse: if music stops mid-session and we were
            // showing the music tab, hop to notes. Without this the
            // user is stuck staring at an empty music page until they
            // manually switch tabs — bad UX, and the segmented bar
            // would also drop the .music segment, making the active
            // tab effectively orphaned.
            if nowPlaying == nil && activeTab == .music {
                activeTab = .notes
            }
        }
    }

    /// Forwards play/pause/skip taps from MusicPanelView to whoever
    /// owns MediaRemoteService (currently NotchOrchestrator, wired up
    /// by AppDelegate at launch). Optional because the presenter is
    /// constructed before the orchestrator exists; the delegate
    /// installs this closure once both have been built.
    var onMediaCommand: ((MediaRemoteService.Command) -> Void)?

    /// "Bring the source app for the now-playing track to the front."
    /// Wired by AppDelegate to NotchOrchestrator.openSourceApp, which
    /// knows how to jump to the specific browser tab when the source
    /// is YouTube/SoundCloud/Twitch (instead of just opening Chrome
    /// to whatever tab happens to be active).
    var onOpenSourceApp: (() -> Void)?

    /// Pending video-URL candidate from the clipboard. When set, the
    /// pill content swaps from the music indicator to a video preview
    /// (thumbnail/icon + Download button on the right). User: "we
    /// need the pill we have right now for playing music to animate
    /// and go, something like a video thumbnail or something like
    /// that, and a download button."
    ///
    /// Auto-clears after `pendingVideoTimeout` seconds if the user
    /// neither downloads nor explicitly dismisses — at which point
    /// the pill reverts to whatever it was showing before (music or
    /// system audio).
    @Published var pendingVideoCandidate: URL? = nil

    // MARK: - Dictation state (FreeFlow-style voice-to-text)

    /// Current phase of the dictation pipeline. Set by
    /// `DictationOrchestrator` via the wiring in AppDelegate.
    /// Drives the resting pill's content swap: when `.recording`
    /// the pill replaces music artwork+waveform with a mic icon +
    /// 9-bar audio level waveform; when `.transcribing` it shows
    /// a processing indicator. `.idle` returns to the normal
    /// music HUD content.
    enum DictationPhase: Equatable {
        case idle
        case recording
        case transcribing
        case error(String)
    }
    @Published var dictationPhase: DictationPhase = .idle

    /// Live microphone RMS level in [0, 1]. Updated 30Hz from the
    /// recorder's audio queue when `.recording` is the current
    /// dictation phase. Drives waveform-bar amplitudes.
    @Published var dictationLevel: Float = 0

    /// Closure that the AppDelegate installs to handle "user clicked
    /// Download on the video preview pill." Lifts the actual download
    /// dispatch out of the presenter (which has no access to
    /// `videoStore` or `panelController`) and into the layer that
    /// owns those references.
    var onDownloadVideo: ((URL) -> Void)?

    /// Transient system events (charging plug/unplug, volume change,
    /// etc.) that should briefly take over the pill's content area
    /// then auto-revert to music. User: "the pill should have
    /// animations for different kinds of actions ... should
    /// transform the music into that charging animation, into the
    /// same size."
    enum SystemEvent: Equatable {
        case charging(percent: Int, plugged: Bool)
        /// Brief flash when a screenshot is captured. The
        /// associated value is the count of screenshots taken
        /// within the recent burst window — single capture shows
        /// just "Saved", a burst shows "Saved · 3" so the user
        /// gets multi-shot acknowledgement without the pill
        /// flickering off and on per shot. Setting this with the
        /// same case (different count) just resets the timer,
        /// extending the visible window through the burst.
        case screenshotSaved(count: Int)
        /// Video download is starting. Pill shows the platform-tinted
        /// glyph + "Downloading" badge while the user gets a clear
        /// "yes, your tap registered" tell.
        case downloadStarted(host: String)
        /// Video download finished successfully. Brief checkmark
        /// flash; user knows the file is in the Videos tab now.
        case downloadCompleted(host: String)
        /// Plain text auto-saved to a new note from the clipboard.
        /// Yellow note glyph in the pill so the user knows the
        /// copy was captured — replaces the previous "open panel
        /// on every copy" behavior, which was disruptive.
        case noteSaved
        /// Bluetooth device just connected. Pill shows the device
        /// name and a small headphones glyph. Fades after the
        /// per-event window. `isAirPods` swaps the icon to a
        /// dedicated AirPods symbol.
        case bluetoothConnected(deviceName: String, isAirPods: Bool)
        /// Bluetooth device just disconnected. Same shape as
        /// connected but with a "disconnected" affordance —
        /// fades to nothing as the device walks away.
        case bluetoothDisconnected(deviceName: String, isAirPods: Bool)
        /// Active countdown timer. The remaining-seconds value is
        /// updated 1Hz by `TimerService` and pushed through the
        /// pendingSystemEvent slot — each tick replaces the
        /// previous case with the new value. The pill stays
        /// visible the entire time the timer is counting; the
        /// auto-dismiss timer is reset on every push to keep it
        /// pinned. When the timer hits zero we transition to
        /// `timerFinished` for a brief celebratory pill.
        case timerRunning(remainingSeconds: Int)
        /// Timer just hit zero. Pill shows "Timer done" with a
        /// quick checkmark; auto-dismisses after the per-event
        /// window. The owning service plays the "ding" haptic on
        /// the same edge.
        case timerFinished
        /// Next calendar meeting is about to start (within the
        /// CalendarMonitorService.leadTime window). Pill shows
        /// title + minutes remaining. The owner-side click handler
        /// reads the join URL out of `PanelPresenter.upcomingMeetingJoinURL`
        /// rather than putting it in the enum, so the enum stays
        /// Equatable-cheap (URLs aren't a clean Hashable for our
        /// purposes — same-string-different-encoding gotchas).
        case calendarUpcoming(title: String, minutesUntilStart: Int)
        /// File just landed via AirDrop. Pill shows the filename
        /// + a small AirDrop glyph. Tap-to-reveal in Finder via
        /// `PanelPresenter.lastAirDropURL` (kept off the enum for
        /// the same Equatable-friendliness reason as the calendar
        /// join URL).
        case airDropReceived(filename: String)
        /// User just SENT N files via AirDrop. Pill flashes the
        /// AirDrop mark + checkmark + file count. NSSharingService
        /// doesn't expose the recipient name to third-party apps so
        /// we don't show "Sent to Sarah", just the confirmation
        /// that the send went through.
        case airDropSent(count: Int)
        /// User canceled the AirDrop sheet, or the send failed.
        /// Brief acknowledgement so the user doesn't wonder if
        /// their files went somewhere they didn't intend.
        case airDropFailed
    }
    @Published var pendingSystemEvent: SystemEvent? = nil
    private var pendingSystemEventTimer: Task<Void, Never>?

    /// Fires after a transient pendingSystemEvent's auto-dismiss
    /// timer expires and the slot is cleared. AppDelegate hooks
    /// this to call `panelController.exitRestingMode()` when there
    /// is no music to anchor the pill — without it, a transient
    /// charging / timer / Bluetooth / AirDrop pill would leave the
    /// resting overlay on screen forever showing an empty silhouette.
    /// Not fired when the event is replaced by a new one (only when
    /// it actually expires through inactivity).
    var onTransientEventCleared: (() -> Void)?

    /// Latest join URL for the calendar pill, kept out-of-band from
    /// the SystemEvent enum so the enum's Equatable conformance stays
    /// cheap (URL equality has encoding gotchas). Set by AppDelegate
    /// each time CalendarMonitorService pushes a new upcoming event;
    /// nil otherwise. Read by the click handler to open the join link.
    @Published var upcomingMeetingJoinURL: URL? = nil

    /// Closure AppDelegate installs to forward a "user tapped the
    /// calendar pill" signal. Defaults to opening
    /// `upcomingMeetingJoinURL` in the user's browser.
    var onJoinUpcomingMeeting: (() -> Void)?

    /// Most recent AirDrop arrival. Set when the watcher pushes a
    /// `.airDropReceived` event; used by the pill's click handler
    /// to reveal the file in Finder. Cleared when the event window
    /// expires (same lifecycle as `lastScreenshotThumbnail`).
    @Published var lastAirDropURL: URL? = nil

    /// AirDrop pill click → reveal in Finder. AppDelegate installs
    /// this; PanelRootView calls it on tap. Same indirection as
    /// `onJoinUpcomingMeeting` so the presenter stays unaware of
    /// AppKit specifics.
    var onRevealAirDrop: (() -> Void)?

    /// Latest screenshot's actual image, displayed inside the
    /// screenshot pill instead of the camera glyph. Cleared when
    /// the event window expires. Lives on PanelPresenter (rather
    /// than being an associated value of `SystemEvent`) so the
    /// SystemEvent enum can stay Equatable cheaply — comparing
    /// NSImage references through Equatable would be brittle and
    /// the count-update flow (which DOES fire on equality) would
    /// pay for unnecessary diffs.
    @Published var lastScreenshotThumbnail: NSImage? = nil

    /// 3.5s window — long enough for the user to glance and read,
    /// short enough that they're back to the music pill quickly.
    /// Overridable from Settings → Charging → Visible for (only
    /// applies to charging events; the others use shorter
    /// per-event durations below).
    static let pendingSystemEventTimeout: TimeInterval = 3.5

    /// Per-event timeout. Charging respects the Settings override;
    /// screenshot/download events are quicker (1.5–2s) so they
    /// don't linger over the music pill.
    private static func timeout(for event: SystemEvent) -> TimeInterval {
        switch event {
        case .charging:
            let stored = UserDefaults.standard.double(forKey: "chargingPillDuration")
            return stored > 0 ? stored : pendingSystemEventTimeout
        case .screenshotSaved: return 1.4
        case .downloadStarted: return 1.8
        case .downloadCompleted: return 1.8
        case .noteSaved: return 1.4
        case .bluetoothConnected: return 2.2     // longer so user can read the device name
        case .bluetoothDisconnected: return 1.6
        case .timerRunning:
            // Reset every second by the service, so this is just
            // a watchdog "if we miss a tick, hide after 5s." In
            // normal flow the pill stays pinned via repeated
            // setPendingSystemEvent(.timerRunning(...)).
            return 5.0
        case .timerFinished: return 3.0
        case .calendarUpcoming:
            // 60s watchdog. The CalendarMonitorService re-pushes
            // every 30s while the event is in the lead-time
            // window, so this just guards against a service
            // hiccup leaving a stale pill on screen.
            return 60.0
        case .airDropReceived:
            // Long enough to read the filename and decide whether
            // to tap-to-reveal; short enough that an ignored
            // arrival doesn't camp on the music pill.
            return 4.0
        case .airDropSent:
            // Quick acknowledgement of a successful send. The user
            // initiated the action, so they only need a brief
            // confirmation that it landed before the pill goes away.
            return 2.5
        case .airDropFailed:
            // Even shorter — the user already knows they canceled
            // (or it failed); we just don't want them wondering if
            // something went out by accident.
            return 2.0
        }
    }

    /// Should this transient pill be suppressed while the user is in
    /// a Focus / DND mode? Yes for ambient/system events (charging,
    /// screenshots, BT pairing, downloads, autocopy) — no for events
    /// the user explicitly initiated (timer countdown, timer finished).
    /// Music keeps showing because it's not routed through
    /// `setPendingSystemEvent` — the resting pill gates on
    /// `nowPlaying`, not on this enum.
    private static func isMutedByFocus(_ event: SystemEvent) -> Bool {
        switch event {
        case .charging, .screenshotSaved, .downloadStarted,
             .downloadCompleted, .noteSaved,
             .bluetoothConnected, .bluetoothDisconnected:
            return true
        case .timerRunning, .timerFinished:
            return false
        case .calendarUpcoming:
            // Meeting reminders are exactly the kind of thing
            // people want during Focus — "deep work, but please
            // remind me when my standup starts." Don't mute.
            return false
        case .airDropReceived:
            // AirDrop is initiated by another person interacting
            // with the user's device; muting it would mean the
            // user wonders if their accept landed. Always show.
            return false
        case .airDropSent, .airDropFailed:
            // User explicitly initiated this AirDrop send — they
            // need to know whether it landed regardless of focus.
            return false
        }
    }

    func setPendingSystemEvent(_ event: SystemEvent) {
        // Focus / DND auto-hide. When the user has enabled the
        // "respect Focus" toggle (`SettingsKey.respectFocusMode`,
        // default true), and their system Focus is active, swallow
        // the ambient pills so the pill stays out of the way. This
        // intentionally does NOT clear an already-displayed event —
        // if the user toggled Focus on while a charging pill was
        // mid-fade, let it finish; only NEW events get muted.
        if isFocused && Self.isMutedByFocus(event) {
            let respect: Bool = {
                if UserDefaults.standard.object(forKey: "respectFocusMode") == nil { return true }
                return UserDefaults.standard.bool(forKey: "respectFocusMode")
            }()
            if respect { return }
        }

        pendingSystemEvent = event
        pendingSystemEventTimer?.cancel()
        let duration = Self.timeout(for: event)
        pendingSystemEventTimer = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.pendingSystemEvent = nil
            self.pendingSystemEventTimer = nil
            // Drop the thumbnail too. NSImage holds the decoded
            // backing store; for a 1080p screenshot that's ~6MB.
            // No reason to keep it around once the pill window has
            // closed — the next screenshot will set a fresh one.
            self.lastScreenshotThumbnail = nil
            // And the AirDrop URL — once the pill is gone the
            // tap target it would have routed to is also gone.
            self.lastAirDropURL = nil
            // Notify the panel controller that this transient event
            // is fully done. AppDelegate routes this to
            // `exitRestingMode()` when no music is anchoring the
            // resting pill — otherwise the empty pill silhouette
            // would camp on screen forever.
            self.onTransientEventCleared?()
        }
    }

    func clearPendingSystemEvent() {
        pendingSystemEvent = nil
        pendingSystemEventTimer?.cancel()
        pendingSystemEventTimer = nil
    }

    /// 15s visibility window before the preview auto-dismisses.
    /// Long enough for the user to read it and decide; short enough
    /// that an ignored copy doesn't get stuck onscreen forever.
    static let pendingVideoTimeout: TimeInterval = 15.0

    private var pendingVideoTimer: Task<Void, Never>?

    /// Set the pending video candidate and arm the auto-dismiss
    /// timer. Replacing an existing candidate restarts the timer
    /// (so a fresh copy resets the 15s window).
    func setPendingVideo(_ url: URL) {
        pendingVideoCandidate = url
        pendingVideoTimer?.cancel()
        pendingVideoTimer = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.pendingVideoTimeout * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.pendingVideoCandidate = nil
            self.pendingVideoTimer = nil
        }
    }

    /// Clear the pending video candidate immediately — called when
    /// the user taps Download (we route the URL elsewhere) or when
    /// something else explicitly takes over the pill.
    func clearPendingVideo() {
        pendingVideoCandidate = nil
        pendingVideoTimer?.cancel()
        pendingVideoTimer = nil
    }

    /// Tabs to show in the segmented bar, in display order. Music
    /// only appears when something is actively playing — when nothing
    /// is playing the bar is the original 4-tab strip and the user
    /// never sees a "Music" segment that does nothing.
    var visibleTabs: [PanelTab] {
        var tabs: [PanelTab] = []
        if nowPlaying != nil { tabs.append(.music) }
        tabs.append(contentsOf: [.notes, .images, .videos, .files])
        return tabs
    }
}

/// Where a file dropped on the notch should go.
///
/// The drop picker presents these as side-by-side zones during a
/// drag; the user releases over the zone they want.
///
///   • `.save` → existing auto-routing (videos→Videos store,
///     images→Images store, generic→Files staging). No behavior
///     change vs the pre-picker drop flow.
///   • `.airDrop` → macOS native AirDrop sheet via
///     `NSSharingService(named: .sendViaAirDrop)`. The user picks
///     the receiver from macOS's UI.
enum DropDestination: Equatable {
    case save
    case airDrop
}
