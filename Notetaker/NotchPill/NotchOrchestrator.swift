import AppKit
import Foundation

/// Single owner of the notch HUD subsystem. Wires the
/// `PowerSourceWatcher` (event source) to the
/// `NotchHUDWindowController` (visual surface), with a dash of
/// debouncing in between so we only bloom the pill on real
/// transitions — not on the periodic refresh notifications IOKit
/// sometimes emits while a battery is steady-state on AC.
///
/// Future HUDs (now-playing, AirPods, focus mode, etc.) plug in here
/// the same way: a watcher emits a state, the orchestrator decides
/// whether the new state warrants a presentation, and the HUD
/// controller takes care of the rest. Keeping this in one place means
/// future HUDs can compete for notch real estate (queue / preempt) in
/// a single coordinated spot rather than fighting each other across
/// scattered modules.
@MainActor
final class NotchOrchestrator {
    // Per BUG-120: `hudController` (NotchHUDWindowController +
    // NowPlayingPillView + ChargingPillView) was the original
    // HUD pipeline; it was migrated to the unified pill in
    // PanelRootView but the field stayed wired for ~700 lines
    // of dead code. The field, its init, the
    // `onMediaCommand` wire-up, and the `hide()` call are all
    // removed. The unified pill in PanelRootView already
    // handles every presentation the HUD subsystem was
    // designed for. The .swift files (NotchHUDWindowController,
    // NowPlayingPillView, ChargingPillView) are now orphaned —
    // their types compile but no consumer references them.
    // Pending Xcode-project-level file deletion in a follow-up
    // pass.
    private let powerWatcher: PowerSourceWatcher
    private let mediaService: MediaRemoteService
    /// Fallback browser-tab probe — used when MediaRemote is
    /// restricted (macOS 15.4+ revokes private framework access)
    /// and we need SOMETHING to publish for YouTube/SoundCloud/etc.
    private let browserProbe: BrowserMediaProbe
    /// Universal "what app is producing audio" detector via
    /// CoreAudio. Catches everything (YouTube, WhatsApp, Discord,
    /// VLC, etc.) that the browser probe misses. Publishes the
    /// app name + bundle ID; the pill's existing icon-fallback
    /// fills in the artwork from the app bundle.
    private let audioWatcher: SystemAudioWatcher
    /// Perl-bridged MediaRemote adapter (ungive/mediaremote-adapter).
    /// `/usr/bin/perl` retains the entitled MediaRemote artwork
    /// access that direct dlopen lost on macOS 15.4+. When the
    /// adapter is running, it streams full now-playing payloads
    /// (including episode title + artwork bytes for Apple Podcasts,
    /// YouTube tabs in any browser, audiobooks) over stdout JSON-
    /// lines. We feed those snapshots through the same
    /// handleNowPlayingChange pipeline as the dlopen path so the
    /// rest of the app doesn't need to know which channel produced
    /// the data — we just get richer payloads when the adapter is
    /// alive. Falls back gracefully to the dlopen MediaRemoteService
    /// when the Perl spawn fails (older macOS, missing /usr/bin/perl,
    /// etc.).
    private let mediaRemoteAdapter: MediaRemoteAdapterService
    private let lockScreenWatcher: LockScreenWatcher
    /// Wall-clock time of the last MediaRemote publish — drives
    /// the browserProbe's `isMediaRemoteSilent` gate so we don't
    /// clobber real MediaRemote data when it eventually arrives.
    private var lastMediaRemoteAt: Date = .distantPast
    /// Bundle ID + isPlaying snapshot from the last MediaRemote
    /// publish. Used by `handleAudioWatcherChange` to detect the
    /// "user paused Spotify and started Podcasts" case — when
    /// MediaRemote's owned source is PAUSED and a DIFFERENT bundle
    /// is producing audio, the audio watcher takes over immediately
    /// (no 5s wait). This fixes the 2026-04-29 user-reported bug
    /// where Spotify's paused metadata camped on screen while the
    /// user was actively listening to an Apple Podcasts episode.
    private var lastMediaRemoteBundleID: String?
    private var lastMediaRemoteIsPlaying: Bool = false
    private var quietWatchdog: Timer?

    /// Most recent NON-NIL info we forwarded to the panel. Used by
    /// `handleNowPlayingChange` to merge artwork forward across
    /// stub updates: if a new emission for the SAME track + source
    /// arrives without artworkData (browser pause re-emit, source
    /// app's two-stage publishing, MediaRemote post-pause stub),
    /// we splice the previous artworkData into the new info before
    /// forwarding. Without this merge, the panel sees `artworkData
    /// = nil` on a "same track, new isPlaying" update and the
    /// resting pill blanks to the placeholder despite the artwork
    /// being known. boring.notch's NowPlayingController uses the
    /// same pattern.
    private var lastForwardedInfo: NowPlayingInfo?

    /// Timestamp of the most recent `isAudioFlowing` false→true
    /// transition. Used by the nil→paused transform's grace gate:
    /// the transform should only fire when audio has been
    /// CONTINUOUSLY flowing for a few seconds (Chrome-paused-with-IO-
    /// held case), not when audio just resumed and MR is still
    /// catching up (Spotify resume case). Without this, the transform
    /// keeps re-asserting isPlaying=false in the 1-3s window after
    /// resume before MR's first playing snapshot arrives.
    private var audioFlowingSinceAt: Date = .distantPast

    /// External now-playing observer. AppDelegate installs this to
    /// forward MediaRemote snapshots into PanelPresenter so the
    /// notes-panel can render its own music page (MusicPanelView)
    /// without having to know about the orchestrator. Fires for
    /// every snapshot — including nil when nothing's playing —
    /// because PanelPresenter's `visibleTabs` and "auto-bounce off
    /// .music when playback stops" logic both depend on the nil
    /// transition arriving promptly.
    var onNowPlayingChange: ((NowPlayingInfo?) -> Void)?

    /// Fired when SystemAudioWatcher's `isAudioFlowing` flips.
    /// AppDelegate forwards this into `PanelPresenter.isAudioFlowing`
    /// so the waveform animation in the music view can drive off
    /// the CoreAudio signal instead of the (less reliable)
    /// `nowPlaying.isPlaying` flag.
    var onAudioFlowingChange: ((Bool) -> Void)?

    /// Charging plug-in / unplug events. Routed to AppDelegate
    /// which sets `presenter.pendingSystemEvent`, causing the
    /// resting pill to morph into a transient charging indicator
    /// for a few seconds, then revert to music. Replaces the
    /// previous separate-HUD pill that floated below the notch.
    var onChargingChange: ((Int, Bool) -> Void)?

    /// Edges from LockScreenWatcher. AppDelegate routes this into
    /// `presenter.isLocked` so the lock-screen music card window
    /// can show/hide based on session state.
    var onLockStateChange: ((Bool) -> Void)?

    /// Send a media command (play/pause/skip) into whichever app owns
    /// the now-playing slot. Exposed publicly so MusicPanelView's
    /// transport buttons (routed via `PanelPresenter.onMediaCommand`)
    /// can drive playback the same way the notch HUD's transport
    /// buttons already do.
    ///
    /// Dispatch:
    ///   - Browser sources (the bundle ID matches a tab the
    ///     BrowserMediaProbe is currently tracking) → run an
    ///     AppleScript that activates the audible tab and
    ///     synthesizes the page's keystroke (k for YouTube
    ///     play/pause, etc.). MRMediaRemoteSendCommand is restricted
    ///     on macOS 15.4+ and won't reach Chrome anyway, so this is
    ///     the only path that actually controls a YouTube tab.
    ///   - Everything else → MediaRemoteService.send, which
    ///     dispatches to AppleScript for Spotify/Music and
    ///     MRMediaRemoteSendCommand for the rest.
    func sendMediaCommand(_ command: MediaRemoteService.Command) {
        if let ref = browserProbe.lastAudibleTab,
           ref.bundleID == lastForwardedBundleID {
            if browserProbe.sendCommandToAudibleTab(command) {
                return
            }
        }
        mediaService.send(command)
    }

    /// Bring the source app for the currently-displayed track to the
    /// front. For browser audio, jumps to the specific tab playing
    /// (via BrowserMediaProbe's cached AudibleTabRef). For everything
    /// else, just opens the app by bundle ID.
    ///
    /// PanelPresenter.onOpenSourceApp is wired here from AppDelegate
    /// so MusicPanelView's artwork tap travels through this single
    /// dispatch instead of doing NSWorkspace.openApplication itself
    /// (which would always open the app to its default window — not
    /// the YouTube tab the user actually wants to look at).
    func openSourceApp() {
        if let ref = browserProbe.lastAudibleTab,
           ref.bundleID == lastForwardedBundleID {
            if browserProbe.openAudibleTab() {
                return
            }
        }
        guard let bundleID = lastForwardedBundleID else { return }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in
            if let error {
                NSLog("nox: failed to open \(bundleID): \(error)")
            }
        }
    }

    /// Mirrors the most recently forwarded NowPlayingInfo's source
    /// bundle so transport / open-source dispatch can decide whether
    /// the displayed pill came from a browser tab. Updated inside
    /// `handleNowPlayingChange`.
    private var lastForwardedBundleID: String?

    /// Tracked separately from PowerSourceWatcher's internal dedup so
    /// we can apply orchestrator-level rules (only show on transition,
    /// not on every IOKit emit). Nil until the first state lands.
    private var lastPowerState: PowerState?
    private var didReceiveInitialPowerState = false

    /// Wall-clock time of the last adapter snapshot. When the
    /// Perl-bridge adapter is actively emitting (within the last
    /// 30s), we treat it as authoritative and SKIP the dlopen
    /// `mediaService.onChange` publishes — those return empty /
    /// "Operation not permitted" payloads on 15.4+ and were
    /// silently clobbering the adapter's rich data because both
    /// channels feed the same `handleNowPlayingChange` and last-
    /// emit-wins. This was the root cause of "Notetaker shows
    /// Nothing playing while Apple Podcasts is playing" on 2026-04-29.
    private var lastAdapterEmitAt: Date = .distantPast

    /// Track ID + first-seen timestamp for the transient-media filter.
    /// We suppress pill bloom for tracks shorter than `transientMediaDurationThreshold`
    /// UNLESS they've been continuously playing for `transientMinPlayTime`.
    /// Pattern from Alcove (`transientMediaDurationThreshold` symbol in
    /// the binary). Stops short browser ads, system tones, error
    /// chimes from triggering the full pill expansion.
    private var lastTrackKey: String = ""
    private var lastTrackFirstSeenAt: Date = .distantPast
    private let transientMediaDurationThreshold: TimeInterval = 5.0
    private let transientMinPlayTime: TimeInterval = 1.0

    // Now-playing dedup state used to live here, when the orchestrator
    // also bloomed the notch HUD on title / play-state changes. After
    // unifying the pill with the main panel (Alcove-style), the panel
    // itself owns now-playing presentation: it sits at resting-pill
    // geometry whenever there's a current track and morphs into the
    // full music page on hover. The orchestrator's only remaining
    // responsibility for now-playing is to forward every snapshot to
    // the external subscriber (PanelPresenter via AppDelegate), so
    // there is no decision left for it to make and no state to track.

    init() {
        self.mediaService = MediaRemoteService()
        self.browserProbe = BrowserMediaProbe()
        self.audioWatcher = SystemAudioWatcher()
        self.mediaRemoteAdapter = MediaRemoteAdapterService()
        self.lockScreenWatcher = LockScreenWatcher()
        let box = WeakBox()
        self.powerWatcher = PowerSourceWatcher { state in
            box.target?.handlePowerState(state)
        }
        self.mediaService.onChange = { [weak box] info in
            box?.target?.handleMediaRemoteChange(info)
        }
        // Adapter snapshots are RICHER than dlopen MediaRemote on
        // 15.4+ — they include artwork bytes for Podcasts/YouTube/
        // audiobooks. Route them through the same channel so the
        // existing inheritance/dedup logic in MediaRemoteService.publish
        // still applies, AND mark MediaRemote as "fresh" so the
        // browser probe / audio watcher don't fight the adapter for
        // the same payload.
        self.mediaRemoteAdapter.onSnapshot = { [weak box] info in
            box?.target?.handleAdapterSnapshot(info)
        }
        self.browserProbe.onChange = { [weak box] info in
            box?.target?.handleBrowserProbeChange(info)
        }
        self.audioWatcher.onChange = { [weak box] info in
            box?.target?.handleAudioWatcherChange(info)
        }
        self.audioWatcher.onAudioFlowingChange = { [weak box] flowing in
            box?.target?.handleAudioFlowingChange(flowing)
        }
        self.lockScreenWatcher.onChange = { [weak box] locked in
            box?.target?.onLockStateChange?(locked)
        }
        // (Removed: `hudController.onMediaCommand` wire-up —
        // hudController is gone per BUG-120. Media commands
        // from the unified pill route directly through
        // mediaService.send() at the call sites that need them.)
        box.target = self
    }

    /// MediaRemote-source publish path. Only marks "real" data as
    /// active when the source is actively PLAYING — paused-but-loaded
    /// tracks (Spotify keeping metadata after the user pauses it)
    /// shouldn't lock out the browser probe. Otherwise a paused
    /// Spotify session perpetually wins over a YouTube tab the user
    /// is actively watching, which is exactly the bug the user
    /// reported: "when I'm playing a YouTube video, it has the
    /// overlay of Spotify."
    private func handleMediaRemoteChange(_ info: NowPlayingInfo?) {
        // 2026-04-29 fix: when the Perl-bridge adapter has emitted
        // anything in the last 30s, treat it as authoritative and
        // SKIP this path's publish. Both channels feed the same
        // handleNowPlayingChange — last-emit-wins meant the dlopen
        // path's "Operation not permitted" empty payloads were
        // silently clobbering the adapter's rich data.
        let adapterFresh = Date().timeIntervalSince(lastAdapterEmitAt) < 30.0
        if adapterFresh {
            return
        }
        if let info, info.isPlaying {
            lastMediaRemoteAt = Date()
            browserProbe.isMediaRemoteSilent = false
        } else if info == nil {
            // Explicit clear from MediaRemote — let the probe step in
            // immediately, no need to wait for the watchdog.
            browserProbe.isMediaRemoteSilent = true
        }
        // Snapshot the source identity + playback state for the
        // audio-watcher cross-check. When MediaRemote-owned source
        // is PAUSED and the audio watcher detects a DIFFERENT bundle
        // producing audio, the watcher overrides immediately.
        lastMediaRemoteBundleID = info?.sourceBundleID
        lastMediaRemoteIsPlaying = info?.isPlaying ?? false
        // For paused-but-loaded info: forward it (so the pill still
        // shows the track data and pause-state correctly) BUT don't
        // refresh `lastMediaRemoteAt`. After 5s of paused state,
        // the watchdog will mark MediaRemote silent and the browser
        // probe will start publishing — taking precedence over the
        // stale paused metadata.
        handleNowPlayingChange(info)
    }

    /// Browser-probe fallback publish path. Only used when MediaRemote
    /// has been silent for a while (the gate is enforced by the probe
    /// itself). Routes through the same handler so downstream
    /// (PanelPresenter) doesn't need to distinguish sources.
    ///
    /// 2026-05-01 race-fix: the probe's `isMediaRemoteSilent` gate is
    /// checked on main BEFORE a 50–200ms background AppleScript scan
    /// runs, then the result lands back on main and publishes. In
    /// that window MR/adapter can come back online — gate said
    /// "silent, run" at check time, but the publish is now overwriting
    /// fresh MR data. Real-world symptom from /tmp/notetaker-mra.log:
    ///
    ///   [10:55:21Z] MRA snapshot: title="Re:ZERO..." artist="Env7y" art=15544b
    ///   [10:55:22Z] PILL refresh: title="Sakamoto Days..." artist="Google Chrome" decoded=false
    ///
    /// MR was publishing Re:ZERO correctly, then the probe's in-flight
    /// scan landed and replaced it with a stale Sakamoto Days tab
    /// title plus zero artwork bytes. The pill then showed the wrong
    /// title and the music-note placeholder.
    ///
    /// Defense-in-depth: re-check freshness HERE, on the main-thread
    /// publish path, after all the async work. If MR/adapter has
    /// emitted within the last 8s, the probe's stub is strictly
    /// inferior — drop it. The 8s window is generous enough to cover
    /// MR's natural inter-tick gaps without letting the probe sneak
    /// through during a brief adapter nil flicker.
    private func handleBrowserProbeChange(_ info: NowPlayingInfo?) {
        let mostRecent = max(lastMediaRemoteAt, lastAdapterEmitAt)
        let mediaRemoteFresh = Date().timeIntervalSince(mostRecent) < 8.0
        if mediaRemoteFresh, info != nil {
            // MR/adapter is the authoritative source for this window.
            // Probe's nil-artwork stub would overwrite real data.
            return
        }
        handleNowPlayingChange(info)
    }

    /// Perl-bridge adapter snapshot path. The adapter produces full
    /// MediaRemote payloads (including artwork bytes for Podcasts,
    /// YouTube, audiobooks) that the dlopen `mediaService` can't
    /// surface on 15.4+. We treat adapter data as authoritative and
    /// also bump `lastMediaRemoteAt`/source-state so the browser
    /// probe and audio watcher gates correctly suppress themselves
    /// while the adapter is feeding us data.
    private func handleAdapterSnapshot(_ info: NowPlayingInfo?) {
        lastAdapterEmitAt = Date()
        if let info, info.isPlaying {
            lastMediaRemoteAt = Date()
            browserProbe.isMediaRemoteSilent = false
        } else if info == nil {
            browserProbe.isMediaRemoteSilent = true
        }
        lastMediaRemoteBundleID = info?.sourceBundleID
        lastMediaRemoteIsPlaying = info?.isPlaying ?? false
        handleNowPlayingChange(info)
    }

    /// Audio-watcher fallback publish path. Wins when MediaRemote
    /// has nothing AND the browser probe has nothing (or yields
    /// the same data). Provides app-name + bundle ID for any
    /// process producing audio system-wide.
    ///
    /// 2026-04-29: added the "different-bundle override" branch —
    /// when MediaRemote's owned source is PAUSED and the watcher
    /// detects a DIFFERENT bundle producing audio, the watcher
    /// publishes immediately, bypassing the 5s silence gate. This
    /// fixes "I'm playing Apple Podcast it's showing Spotify": the
    /// previous logic kept Spotify's paused metadata on screen
    /// because MediaRemote kept re-firing paused-state notifications,
    /// which prevented the silence gate from ever opening.
    private func handleAudioFlowingChange(_ flowing: Bool) {
        // Simple forwarder. The pill-visibility decision happens
        // downstream in AppDelegate.updatePillVisibility, which
        // combines `isAudioFlowing` with `nowPlaying.isPlaying`.
        // No transforms here — the cascading "fix" attempts
        // (resume-flip, grace gates) all created more bugs than
        // they solved.
        onAudioFlowingChange?(flowing)
    }

    private func handleAudioWatcherChange(_ info: NowPlayingInfo?) {
        if info == nil {
            // Audio stopped — if MediaRemote isn't currently
            // publishing, clear the pill.
            let mostRecent = max(lastMediaRemoteAt, lastAdapterEmitAt)
            let mediaRemoteSilent = Date().timeIntervalSince(mostRecent) > 5.0
            if mediaRemoteSilent {
                handleNowPlayingChange(nil)
            }
            return
        }
        // 2026-05-01 v4 — don't let the SystemAudioWatcher's
        // synthetic info (always has `artist = ""` because
        // CoreAudio doesn't know track titles) overwrite the
        // RICHER data MediaRemote/adapter has for the same bundle.
        //
        // Original bug: user scrubs YouTube. Chrome's audio
        // briefly drops. Watcher fires `onChange(nil)` (suppressed
        // by the nil-handler above). Audio resumes. Watcher fires
        // synthetic Chrome info (title="Chrome", artist="") which
        // would overwrite the rich YouTube title + artwork.
        //
        // 2026-05-01 v4 fix: the previous `lastMediaRemoteIsPlaying`
        // condition broke pause→resume on YouTube. Sequence: user
        // pauses YouTube → MR emits isPlaying=false → that flips
        // `lastMediaRemoteIsPlaying` to false → user resumes
        // YouTube → audio flows → watcher fires synthetic Chrome
        // info → gate's isPlaying check FAILS → watcher's degraded
        // info propagates and overwrites YouTube. The thumbnail
        // disappears (synthetic info has no artwork) and the
        // title becomes "Google Chrome".
        //
        // The fix: suppress when bundles match REGARDLESS of
        // MR's isPlaying flag. Same bundle means MR's payload
        // (whatever its play state) is always richer than the
        // watcher's synthetic stub. The "user switched from paused
        // Spotify to playing Podcasts" case the isPlaying check
        // was originally protecting still works because bundles
        // DIFFER in that scenario (com.spotify.client vs
        // com.apple.podcasts).
        let watcherBundle = info?.sourceBundleID
        if watcherBundle != nil
            && watcherBundle == lastMediaRemoteBundleID {
            return
        }
        handleNowPlayingChange(info)
    }

    /// Tiny weak holder so the watcher's closure can resolve back to
    /// self without retaining it. Plain `[weak self]` doesn't work
    /// directly because `self` isn't fully initialized at the point
    /// the watcher is constructed.
    private final class WeakBox {
        weak var target: NotchOrchestrator?
    }

    // MARK: - Lifecycle

    /// Begin observing power and media events. Idempotent — repeat
    /// calls don't double-register with IOKit or MediaRemote.
    func start() {
        powerWatcher.start()
        mediaService.start()
        // Start the Perl-bridge adapter BEFORE the browser probe /
        // audio watcher so its richer payloads suppress the
        // fallback gates from the first emit.
        let adapterStarted = mediaRemoteAdapter.start()
        NSLog("nox: MRA adapter start \(adapterStarted ? "succeeded" : "failed — falling back to dlopen path")")
        browserProbe.start()
        audioWatcher.start()
        lockScreenWatcher.start()
        // Quiet-window watchdog: flip the probe's gate to "silent"
        // when MediaRemote hasn't published in 5s. This is what
        // lets the browser probe step in for YouTube/SoundCloud
        // when MediaRemote is restricted on macOS 15.4+.
        quietWatchdog?.invalidate()
        quietWatchdog = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let silent = Date().timeIntervalSince(self.lastMediaRemoteAt) > 5.0
                self.browserProbe.isMediaRemoteSilent = silent
            }
        }
    }

    /// Tear down all watchers and dismiss any visible HUD. Useful at
    /// app shutdown so runloop sources / notification observers aren't
    /// leaked into the next process spawn (relevant during dev; AppKit
    /// usually reaps these on quit, but explicit teardown keeps the
    /// behavior deterministic).
    func stop() {
        powerWatcher.stop()
        mediaService.stop()
        mediaRemoteAdapter.stop()
        browserProbe.stop()
        audioWatcher.stop()
        lockScreenWatcher.stop()
        quietWatchdog?.invalidate()
        quietWatchdog = nil
        // (Removed: `hudController.hide()` — hudController is
        // dead code per BUG-120. The unified pill's hide path
        // is owned by PanelWindowController.)
        lastPowerState = nil
        didReceiveInitialPowerState = false
    }

    // MARK: - Power events

    /// Decide whether the freshly-reported power state warrants a HUD
    /// bloom. Rules:
    /// - Drop the very first emission. PowerSourceWatcher always emits
    ///   once on start() so callers know the baseline; we don't want
    ///   the HUD to bloom every time the app launches just because the
    ///   user happens to be on AC.
    /// - Only bloom when the *charging signal* flips. A change in
    ///   percentage alone (87% → 88% while plugged in) is not a HUD
    ///   event — that would spam the user during long charges.
    /// - Forward the resulting presentation to the controller; the
    ///   controller handles auto-hide and animation.
    private func handlePowerState(_ state: PowerState) {
        defer { lastPowerState = state }

        guard didReceiveInitialPowerState else {
            didReceiveInitialPowerState = true
            return
        }

        // Only show on plug-in / unplug transitions. This is the
        // moment the user wants visual confirmation that the cable
        // registered. Percentage updates while the charging state is
        // unchanged are silent.
        let chargingChanged = state.isCharging != lastPowerState?.isCharging
        guard chargingChanged else {
            return
        }

        // Route the event into the unified pill (via AppDelegate →
        // presenter.pendingSystemEvent) instead of opening a
        // separate floating HUD pill. The pill morphs in place
        // from music → charging indicator → music. User: "the pill
        // should have animations for different kinds of actions
        // ... should transform the music into that charging
        // animation, into the same size."
        onChargingChange?(state.percent, state.isCharging)
    }

    // MARK: - Now-playing events

    /// Forward the latest now-playing snapshot to the external
    /// subscriber (PanelPresenter via AppDelegate). The orchestrator no
    /// longer drives a separate now-playing HUD pill — that role moved
    /// to the unified panel/pill, which sits at resting-pill geometry
    /// whenever a track is current and morphs into the full music page
    /// on hover. AppDelegate observes this stream to call
    /// `enterRestingMode` / `exitRestingMode` on the panel controller.
    ///
    /// We forward EVERY snapshot — including artwork-only updates and
    /// nil — so the panel's `nowPlaying` published var (and the
    /// resting-mode lifecycle) stay in sync without dedup. The pill
    /// shows whenever info is non-nil (playing or paused, matching
    /// Alcove's "ambient indicator" behavior); it collapses the
    /// instant the source app stops publishing.
    private func handleNowPlayingChange(_ info: NowPlayingInfo?) {
        // 2026-05-01 SIMPLIFICATION.
        //
        // The previous version of this funnel had 6 stacked
        // transforms (nil→paused, cross-source CoreAudio drop,
        // empty-content drop, audio-resumed flip, grace gate,
        // sticky cache update) that each fixed one symptom but
        // broke another. Verified in /tmp/notetaker-mra.log:
        //
        //   [15:05:05Z] MRA: "Softcore" / The Neighbourhood   ← user clicked NEXT
        //   [15:05:06Z] MRA: bundle=nil                        ← post-track-change blip
        //   [15:05:06Z] orchestrator: nil→paused transform     ← re-paused new track
        //   [15:05:06Z] PILL refresh: title="good 4 u"         ← OLD track restored
        //
        // The transform couldn't distinguish "user paused" from
        // "MR's normal nil between track changes." Every NEXT
        // skip looked like a pause and got re-paused.
        //
        // New design: trust MediaRemote/adapter's emissions as
        // ground truth. ONE transform stays — the artwork merge
        // for same-track stub emissions — because it has an
        // unambiguous trigger condition (same bundle + same
        // non-empty title + new emission has nil artwork) and
        // can't misfire on track changes (titles differ).
        //
        // Pause/resume detection now lives entirely downstream
        // in `AppDelegate.updatePillVisibility`, which AND's
        // `isAudioFlowing` (CoreAudio truth) with
        // `nowPlaying.isPlaying` (MediaRemote's flag, may be
        // stale for browsers). For Spotify and most apps that
        // release IO procs on pause, this works correctly.
        // For Chrome (which holds IO procs across pause), the
        // small pill stays visible until Chrome eventually
        // releases — known limitation, accepted as the
        // alternative was breaking next-track and resume.

        // Drop empty-content emissions. The MRA produces these as
        // stubs (bundle=nil title="" artist="" with maybe iTunes-Search
        // ghost artwork). They have nothing to display and would
        // overwrite presenter.nowPlaying with garbage, leaving the
        // pill stuck on "Nothing playing" while music is actually
        // playing. This filter is SAFE because real track changes
        // always have a non-empty title — it can't misfire.
        if let new = info, new.title.isEmpty && new.artist.isEmpty {
            return
        }

        // Artwork merge for same-track stub emissions. Match on
        // (sourceBundleID + title). This handles MR re-emitting a
        // metadata refresh without artworkData (Spotify's two-stage
        // publish, browser-probe fallback that has no artwork).
        var merged = info
        if let new = info,
           let last = lastForwardedInfo,
           new.sourceBundleID == last.sourceBundleID,
           new.title == last.title,
           !new.title.isEmpty,
           new.artworkData == nil,
           last.artworkData != nil {
            merged = NowPlayingInfo(
                title: new.title,
                artist: !new.artist.isEmpty ? new.artist : last.artist,
                album: new.album ?? last.album,
                artworkData: last.artworkData,
                isPlaying: new.isPlaying,
                sourceBundleID: new.sourceBundleID,
                duration: new.duration ?? last.duration,
                elapsedTime: new.elapsedTime ?? last.elapsedTime,
                infoTimestamp: new.infoTimestamp
            )
        }

        // Only update lastForwardedInfo with usable info — never
        // with empty-title stubs (MRA ghost emissions) or nil. The
        // cache stays anchored on the last meaningful track.
        if let m = merged, !m.title.isEmpty {
            lastForwardedInfo = m
        }

        lastForwardedBundleID = merged?.sourceBundleID
        onNowPlayingChange?(merged)
        // When the source is a known browser, kick off a title-based
        // tab scan so `openSourceApp` / `sendMediaCommand` know which
        // tab to act on. MediaRemote tells us "Chrome is playing
        // 'Cruel Summer'" — but not WHICH Chrome tab. AppleScript
        // closes the loop. See BrowserMediaProbe.refreshAudibleTab
        // for the full rationale (this is the Alcove-decoded pattern).
        refreshBrowserTabIfNeeded(for: merged)
    }

    /// Last (bundle, title) we already kicked off a title-scan for.
    /// Prevents firing a fresh AppleScript for every artwork-only
    /// update — MediaRemote sends ~1/s while a track plays, but the
    /// tab doesn't change between artwork ticks.
    private var lastBrowserScanKey: String?

    private func refreshBrowserTabIfNeeded(for info: NowPlayingInfo?) {
        guard let info,
              let bundleID = info.sourceBundleID,
              !info.title.isEmpty,
              BrowserMediaProbe.isKnownBrowser(bundleID: bundleID) else {
            // Not a browser source (or no title) — clear the scan
            // dedup so the next browser publish triggers a fresh scan
            // instead of being suppressed.
            lastBrowserScanKey = nil
            return
        }
        let key = "\(bundleID)|\(info.title)"
        if key == lastBrowserScanKey { return }
        lastBrowserScanKey = key
        browserProbe.refreshAudibleTab(forBundleID: bundleID, titleHint: info.title) { found in
            if !found {
                // Title scan didn't land — most likely TCC denied or
                // the song name doesn't appear verbatim in the tab
                // title. Clear dedup so a follow-up publish (with a
                // possibly different title) gets retried.
                self.lastBrowserScanKey = nil
            }
        }
    }
}
