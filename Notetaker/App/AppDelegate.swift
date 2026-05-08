import AppKit
import SwiftUI
import Combine
import ServiceManagement
import Sparkle

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Static handle so callers (e.g. `SettingsWindow.open`, NSAlert
    /// callbacks) can reach us without going through `NSApp.delegate`.
    /// SwiftUI's `@NSApplicationDelegateAdaptor` sometimes wraps the
    /// delegate behind its own forwarder, which makes the
    /// `NSApp.delegate as? AppDelegate` cast unreliable.
    static private(set) var shared: AppDelegate?

    var environment: AppEnvironment?
    var menuBarController: MenuBarController?
    var panelController: PanelWindowController?
    var hotkeyService: HotkeyService?
    var clipboardMonitor: ClipboardMonitor?
    var dragMonitor: DragMonitor?
    var screenshotWatcher: ScreenshotWatcher?
    /// Cursor-on-notch auto-open. Mirrors Alcove's hover gesture so the
    /// panel is reachable without remembering ⌥Space.
    var hoverActivator: HoverActivator?
    /// Owns the separate notch HUD pills (charging, music, etc.) that
    /// auto-bloom on system events independent of the notes panel.
    var notchOrchestrator: NotchOrchestrator?
    /// Dictation pipeline — Fn-key (or custom hotkey) starts a
    /// recording, transcribes via Groq Whisper (or user-configured
    /// OpenAI-compat provider), and pastes the cleaned text at the
    /// cursor in whatever app is frontmost. Wired up at launch so
    /// the hotkey listener is live system-wide.
    var dictationOrchestrator: DictationOrchestrator?
    /// Hotkey mode that should be applied to the dictation
    /// orchestrator once onboarding has been completed. Stored at
    /// launch (read from UserDefaults) but NOT applied immediately
    /// for first-launch users — calling setHotkeyMode pops the macOS
    /// Accessibility permission dialog, which we want to fire from
    /// the onboarding "Accessibility" step (after the privacy
    /// explainer) rather than over the welcome panel. Cleared after
    /// `startTCCDeferredServices` consumes it.
    var dictationPendingHotkeyMode: DictationOrchestrator.HotkeyMode?

    /// First-launch onboarding manager. Lazy: only allocated if
    /// the user hasn't completed onboarding yet (or if Settings
    /// invokes "Show onboarding" to re-run the flow).
    private let onboardingManager = OnboardingManager()
    /// Lock-screen music card (separate NSPanel, attached to the
    /// SkyLight space at level 400 alongside the main notch panel).
    /// Created lazily after `panelController` exists so it can share
    /// the same `PanelPresenter` for now-playing data.
    var lockMusicCard: LockMusicCardWindowController?
    /// Small lock-pill that hangs from the notch on the lock screen.
    /// Separate panel from the music card so it can sit at the
    /// notch independently. Shake-on-tap conveys "you can't do
    /// anything until you unlock" — the same affordance Alcove has.
    var lockNotchIndicator: LockNotchIndicatorController?
    /// Countdown timer (Pomodoro-style). Drives a notch pill that
    /// shows live MM:SS remaining; on finish, fires a "Time's up"
    /// pill with a haptic ding.
    var timerService: TimerService?
    /// Focus / DND watcher. Pumps `presenter.isFocused` so
    /// `setPendingSystemEvent` can suppress ambient pills while
    /// the user is in heads-down mode. Authorization is requested
    /// lazily — the Settings → General → "Auto-hide pills during
    /// Focus" toggle is what triggers the system prompt the first
    /// time, so users who don't want the feature never see it.
    var focusStatusService: FocusStatusService?
    /// Calendar / EventKit poller. Every 30s checks for an event
    /// starting within the lead-time window and pushes a
    /// `.calendarUpcoming` pill. Authorization is opt-in via
    /// Settings → Calendar → "Show next meeting pill"; without
    /// it the service is a no-op and no pill ever fires.
    var calendarMonitor: CalendarMonitorService?
    /// AirDrop arrival watcher (NSMetadataQuery on
    /// `kMDItemWhereFroms LIKE "AirDrop"`). Pushes an
    /// `.airDropReceived` pill the moment a new file lands.
    /// Always-on by default — there's no auth prompt because
    /// Spotlight metadata is already indexed for the user.
    var airDropWatcher: AirDropWatcher?
    /// CoreAudio output-volume / mute listener. Fires on volume
    /// keys, menu-bar slider drags, and AppleScript adjustments.
    /// We push a `.volumeChanged` SystemEvent and call
    /// `panel.showVolumeBanner()` so the notch expands into the
    /// volume HUD banner. Per-event timeout (1.5s) auto-dismisses
    /// after the user stops adjusting; held-key tick spam re-pushes
    /// each tick which extends the visible window.
    var systemVolumeWatcher: SystemVolumeWatcher?
    /// Timestamp of the most recent track change. Set whenever
    /// `presenter.nowPlaying` is updated with a new title/artist
    /// pair. Used to suppress the volume HUD for a brief window
    /// after a track change — Spotify/Apple Music apps often
    /// briefly dip system audio for crossfade or track-boundary
    /// transitions, which fires our volume listener and pops the
    /// HUD when the user just wanted to hear a new track.
    private var lastTrackChangeTime: Date?
    /// Pending dismiss work-item for the volume banner. Held so a
    /// fresh volume change can cancel an in-flight dismiss and
    /// extend the visible window. Without this, if the user adjusts
    /// volume right at the 1.5s deadline we'd race the dismiss
    /// (panel collapsing as the next keypress fires).
    private var volumeDismissWorkItem: DispatchWorkItem?
    /// Combine subscription that bridges the Focus service's
    /// `isFocused` into the panel presenter. Held here so its
    /// lifetime ties to the AppDelegate.
    private var focusCancellable: AnyCancellable?
    /// Combine subscriptions for the timer service. Keeping them
    /// here ties their lifetime to AppDelegate's, which lives the
    /// entire app session — so the sink stays alive for the full
    /// duration of any running timer.
    private var timerCancellables = Set<AnyCancellable>()

    /// Debounce timer for transient `nowPlaying = nil` emissions.
    /// macOS's MediaRemote regularly briefly drops the now-playing slot
    /// when audio sessions transition (a video starts/stops, a YouTube
    /// tab ends, AirPods disconnect, etc.) — sometimes for as little as
    /// 200ms before the previously-playing app re-claims its spot. If
    /// we tear down the resting pill on every nil, those mid-session
    /// transitions cause the pill to disappear and never come back
    /// until the user re-triggers playback. The user reported exactly
    /// this: "when I open any video / see images / select images, the
    /// music player becomes gone and it doesn't come back until I run
    /// new music." We hold a 4-second debounce on nils — non-nil
    /// emissions cancel any pending teardown, so a transient gap never
    /// reaches the panel controller.
    private var nowPlayingNilDebounce: DispatchWorkItem?

    /// Transient-media filter state. Track key + first-seen timestamp
    /// for the most recent short-duration track. Used by
    /// `isTransientMedia(_:)` to suppress pill bloom on browser ads,
    /// system tones, error chimes, etc. — anything with duration <5s
    /// gets a 1-second dwell time before the pill is allowed to
    /// expand. Pattern from Alcove (`transientMediaDurationThreshold`
    /// in their binary).
    private var lastTransientTrackKey: String = ""

    /// Last (title|artist) we fired a `.trackChanged` announcement
    /// pill for. Separate from `lastTransientTrackKey` (which is
    /// about filtering ad jingles) — this one's about not re-firing
    /// the announcement when MR re-emits the same track on every
    /// position update or when the user pauses and resumes.
    private var lastAnnouncedTrackKey: String = ""
    private var lastTransientFirstSeenAt: Date = .distantPast

    /// Pending pill-retract work when audio stops flowing. Cancelled
    /// if audio resumes within the 2s debounce window so the pill
    /// doesn't flicker out and back during brief gaps (YouTube
    /// scrub, Spotify track-change pause, ad-break).
    private var audioFlowingRetractWork: DispatchWorkItem?

    /// Wall-clock timestamp of the moment audio started flowing
    /// while there was NO MediaRemote info available (np=nil).
    /// Used to suppress the pill for short system sounds — popup
    /// chimes, app-launch beeps, notification dings — which all
    /// trigger CoreAudio's `isAudioFlowing=true` for <1s without
    /// any MR data. The pill only shows when this no-MR audio
    /// has been flowing for at least `noMRSustainThreshold`
    /// seconds. User feedback 2026-05-07: "sometimes it's
    /// turning on some system audio like popups, new app
    /// opening and stuff like that which we don't need".
    /// Reset to `.distantPast` whenever audio stops or MR data
    /// becomes available.
    private var noMRAudioStartedAt: Date = .distantPast
    /// Minimum sustained no-MR audio duration before the pill is
    /// allowed to bloom. 2.5s is long enough to filter every
    /// macOS/system sound effect (all under 1s) plus most short
    /// notification chimes, while still being short enough that
    /// real long-form non-MR audio (YouTube without MR, Discord
    /// voice, etc.) shows up promptly.
    private static let noMRSustainThreshold: TimeInterval = 2.5

    /// Pending bloom-after-sustain work scheduled when no-MR audio
    /// starts. Fires `updatePillVisibility` after the threshold so
    /// genuinely-sustained audio still gets a pill. Cancelled if
    /// audio stops before the threshold (system-sound case).
    private var noMRSustainWork: DispatchWorkItem?

    /// Reusable Settings window. We manage this ourselves rather than
    /// relying on the SwiftUI `Settings { }` scene because that scene's
    /// open mechanism (`SettingsLink`, `\.openSettings`, or
    /// `NSApp.sendAction("showSettingsWindow:", …)`) is unreliable when
    /// the only visible UI is an `NSPanel` hosted via
    /// `NSHostingController`. The hosting controller's SwiftUI tree
    /// doesn't share the App scene's environment, so `\.openSettings`
    /// is unbound there; and with `LSUIElement = true` there's no main
    /// window in the responder chain to handle the action selector
    /// either. Net result: the gear icon was a dead pixel. Owning the
    /// window directly here makes "click gear → Settings appears" a
    /// straight call into AppKit, which Just Works.
    private var settingsWindow: NSWindow?
    /// Token returned by `NotificationCenter.addObserver(forName:...)`
    /// for the Settings window's willClose hook. Stored so we can
    /// `removeObserver(_:)` when the window closes — without this,
    /// the observer leaks for the lifetime of the AppDelegate (i.e.
    /// the app), and every subsequent open of Settings adds another
    /// orphan observer pointing at a dead window. Per BUG-015 fix.
    private var settingsWindowCloseObserver: NSObjectProtocol?

    /// Sliding window of recent screenshots — used only for the in-memory
    /// dedup of file-watcher vs clipboard captures of the same shot.
    private var recentScreenshots: [(time: TimeInterval, id: String)] = []
    /// Burst window — defaults to 3s, overridable from Settings →
    /// Images → Burst window. Read on every screenshot so a flip
    /// in Settings takes effect immediately.
    private var burstWindow: TimeInterval {
        let stored = UserDefaults.standard.double(forKey: "screenshotBurstWindow")
        return stored > 0 ? stored : 3.0
    }

    /// Per BUG-122 / BUG-123 fix: tear down the dictation
    /// orchestrator's hotkey listeners before app exit. The
    /// orchestrator's CGEventTap and Carbon hotkey handlers hold
    /// retained references to the orchestrator (so callbacks can
    /// never see freed memory), and those references are released
    /// here in `stop()`. Without this call, the orchestrator
    /// would leak its retained-self refs at shutdown — harmless
    /// in practice (process is exiting anyway) but the diagnostic
    /// log line in the orchestrator's deinit would fire.
    ///
    /// applicationWillTerminate runs on the main actor, which is
    /// the right thread for the CGEvent / Carbon teardown calls.
    func applicationWillTerminate(_ notification: Notification) {
        dictationOrchestrator?.stop()
    }

    /// macOS App Nap activity token. When held, this tells the OS
    /// that the app is performing user-initiated work and must not
    /// be throttled. Without this, after ~2 minutes of idle, macOS
    /// puts the app into App Nap state — CPU priority drops, the
    /// Metal pipeline goes cold, CPU caches age out. The first
    /// open after idle then takes ~870ms instead of ~290ms because
    /// all of that has to spool back up while our spring is trying
    /// to run.
    ///
    /// Confirmed in /tmp/notetaker-dictation.log on 2026-05-04:
    /// avgDt=26.5ms (vs 10ms baseline) on the first morph after a
    /// 2-minute idle window, normalizing back to 10ms after 3-4
    /// opens. Classic App Nap thermal/priority signature.
    ///
    /// `.userInitiatedAllowingIdleSystemSleep` is the right reason:
    /// our work IS user-initiated (notch hover/click), and we DON'T
    /// need to prevent system sleep — only the per-app throttling.
    private var antiAppNapToken: NSObjectProtocol?

    /// Sparkle auto-updater. SPUStandardUpdaterController wraps the
    /// SPUUpdater + SPUStandardUserDriver pair Sparkle ships out of
    /// the box: polls SUFeedURL on schedule (see Info.plist
    /// SUScheduledCheckInterval), shows the standard "update
    /// available" dialog when a newer version is found, downloads
    /// the DMG, verifies its EdDSA signature against SUPublicEDKey,
    /// then prompts to install + relaunch.
    ///
    /// Kept as a property (not a local) so the updater stays alive
    /// for the lifetime of the app — Sparkle's checks fire on a
    /// timer, so the controller has to outlive any one method call.
    /// `startingUpdater: true` kicks off the first scheduled check
    /// shortly after launch (10s delay built in by Sparkle).
    ///
    /// `userDriverDelegate` and `updaterDelegate` left nil — the
    /// standard implementations match macOS HIG and don't need
    /// customization for v1. Hooking them later (e.g. to surface
    /// release notes inline in the panel UI) is straightforward.
    private(set) lazy var sparkleUpdaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self
        NSApp.setActivationPolicy(.accessory)

        // RELOCATE-TO-/APPLICATIONS — runs first, BEFORE onboarding.
        //
        // If the user is launching nox from the mounted DMG, from
        // ~/Downloads, from a path-translocated sandbox, or any other
        // non-canonical location, AppMover offers to move the bundle
        // to /Applications and relaunch from there. The relaunched
        // instance is the same signed bundle so notarization stays
        // valid; TCC permissions granted later attach to the new
        // canonical path so they survive future updates.
        //
        // Returns true if the move was performed — in which case the
        // process is about to exit and we should bail out of further
        // setup (nothing we do here matters; the relaunched copy
        // re-runs applicationDidFinishLaunching from scratch).
        if AppMover.relocateIfNeededAndRelaunch() {
            return
        }

        // FIRST-RUN ONBOARDING — present BEFORE any service that can
        // trigger TCC prompts. The previous order ran ~900 lines of
        // service setup (NotchOrchestrator → MediaRemoteService
        // AppleScript polls → BrowserMediaProbe) before queuing the
        // onboarding window with a 0.4s delay. On a freshly factory-
        // reset Mac, the AppleScript polls fired Apple Events
        // permission prompts ("Allow nox to control Spotify/Chrome?")
        // before the user even saw the welcome screen — and because
        // the mic-permission prompt is gated on the Allow button in
        // onboarding, dismissing those prompts without finishing
        // onboarding meant mic access was never asked for either.
        // User feedback: "Access requesting is getting far before
        // than even go to onboarding so everything becomes a mess."
        //
        // Now: present synchronously at the top. The onboarding
        // window claims focus immediately; service initialization
        // continues underneath, but the user sees the welcome panel
        // first. Any subsequent permission prompts read as "this app
        // is setting itself up" instead of "what is this app doing."
        //
        // No-op if onboardingCompletedV2 is already set (existing
        // installs skip this and proceed straight to setup).
        onboardingManager.presentIfNeeded()

        // 2026-05-04: disable App Nap for the lifetime of this
        // process. Notch HUD must respond instantly to user
        // gestures; we cannot afford ~500ms of "wake up the
        // pipeline" latency every time the user has been idle.
        antiAppNapToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "Notch HUD must respond instantly to user gestures (hover/click)"
        )

        // SECURITY: one-shot migration of API keys from plaintext
        // UserDefaults → encrypted Keychain. Idempotent — gated by
        // `noxKeychainMigrationV1Done`. Runs BEFORE any service that
        // might try to read a key, so the migration completes before
        // first use. After migration the plaintext entries are
        // removed from the .plist on disk. See SecureKeyStore for
        // the full audit rationale.
        SecureKeyStore.shared.migrateFromUserDefaultsIfNeeded()

        // Touch the lazy Sparkle controller so it initializes during
        // launch — this kicks off Sparkle's internal startup
        // (~10s delay before the first scheduled SUFeedURL fetch)
        // so updates can be discovered without the user explicitly
        // invoking "Check for Updates."
        _ = sparkleUpdaterController

        // First-run bootstrap of "Launch at login". The Settings UI
        // defaults this @AppStorage toggle to `true`, but it only
        // calls SMAppService.mainApp.register() when the user
        // actually flips the switch — which most users never do
        // because they assume "default = on" already means it's
        // registered. Fix: register on first launch automatically,
        // and remember we did it so user opt-outs later don't get
        // overridden.
        let defaults = UserDefaults.standard
        let bootstrapKey = "noxLaunchAtLoginBootstrapped"
        if !defaults.bool(forKey: bootstrapKey) {
            do {
                try SMAppService.mainApp.register()
                defaults.set(true, forKey: bootstrapKey)
                defaults.set(true, forKey: "launchAtLogin")
                NSLog("nox: registered for launch-at-login on first run")
            } catch {
                NSLog("nox: launch-at-login registration failed: \(error)")
            }
        }

        // Diagnostic dump of the host screen geometry. Surfaces in
        // /tmp/notetaker-dictation.log on every launch so users
        // (and us) can see the exact dimensions Notetaker is
        // adapting to. Especially useful for diagnosing pill /
        // notch mismatches across MacBook Pro 14"/16" and Air
        // 13"/15" — each model has slightly different
        // safeAreaInsets.top and notch-cutout widths.
        for screen in NSScreen.screens {
            let frame = screen.frame
            let visible = screen.visibleFrame
            let safe = screen.safeAreaInsets
            DictationOrchestrator.dlog("screen \(screen.localizedName): frame=\(Int(frame.width))x\(Int(frame.height)) visible=\(Int(visible.width))x\(Int(visible.height)) scale=\(screen.backingScaleFactor) safeTop=\(safe.top)")
        }

        do {
            let env = try AppEnvironment()
            self.environment = env
            env.retentionService.start()
            env.bluetoothDeviceService.start()
            // Volume-HUD takeover (idea borrowed from SuperIsland).
            // Off by default — when the user flips Settings → General →
            // "Replace system volume HUD", we install a CGEventTap on
            // F10/F11/F12 that suppresses Apple's white overlay and
            // mutates volume via CoreAudio. The interceptor handles
            // the Accessibility-permission retry loop internally, so
            // it's safe to call start() on every launch.
            if UserDefaults.standard.bool(forKey: "replaceSystemVolumeHUD") {
                MediaKeyInterceptor.shared.start()
            }
            // One-shot retroactive tagging: re-classifies obvious
            // clipboard auto-saves (URLs, pure-digit snippets, short
            // single-token captures) from the legacy data so the
            // user's existing notes split sensibly the first time
            // they open the new Notes tab. Idempotent — gated by
            // a UserDefaults flag, runs once per install.
            env.noteStore.backfillClipboardKindIfNeeded()
            // Wire connect/disconnect HUD pills. When a device
            // appears in the connected list (after the initial
            // poll completes), show a brief pill with the device
            // name. Same for disconnect. These flow through the
            // pendingSystemEvent pipeline like charging /
            // screenshot pills, so they share the same morph
            // animation system.
            env.bluetoothDeviceService.onDeviceConnected = { [weak self] device in
                guard Self.bluetoothPillEnabled() else { return }
                guard let panel = self?.panelController else { return }
                // Bring the panel up at pill geometry first — without
                // this, when no music is playing the panel is
                // offscreen and the pill content has nowhere to
                // render. PanelRootView's pill overlay gates on
                // `presenter.isResting && !presenter.isShown`, so
                // resting mode IS the surface this event paints on.
                panel.enterRestingMode()
                panel.presenter.setPendingSystemEvent(
                    .bluetoothConnected(deviceName: device.name, isAirPods: device.isAirPods)
                )
                HapticFeedback.bluetoothChange()
            }
            env.bluetoothDeviceService.onDeviceDisconnected = { [weak self] device in
                guard Self.bluetoothPillEnabled() else { return }
                guard let panel = self?.panelController else { return }
                panel.enterRestingMode()
                panel.presenter.setPendingSystemEvent(
                    .bluetoothDisconnected(deviceName: device.name, isAirPods: device.isAirPods)
                )
                HapticFeedback.bluetoothChange()
            }
            panelController = PanelWindowController(environment: env)
            // Bring the panel up at notch-hidden (invisible behind
            // hardware notch) on launch so AppKit drag-and-drop has a
            // registered destination from the start. Without this,
            // the very first drag-into-notch (before any hover/show)
            // wouldn't be picked up — the user would see no drop
            // picker until they'd hovered the notch at least once.
            // The silhouette at notch-hidden is black-on-black with
            // the hardware cutout = visually invisible, but the
            // window is alive and registered for dragged types.
            panelController?.parkAtNotchHidden()
            // Eagerly warm up the on-device Whisper model so the
            // first dictation doesn't pay the ~5-10s Core ML
            // compile + ANE engine selection cost. Cache hits
            // resolve in <1s; cache miss kicks off the ~466 MB
            // small.en download in the background. Either way,
            // by the time the user triggers dictation the
            // pipeline is ready.
            Task.detached(priority: .background) {
                await LocalWhisperService.shared.prepare()
            }
            // Lock-screen music card: a second NSPanel attached to
            // the SkyLight space at level 400, visible when locked
            // AND something is playing. Shares the main panel's
            // presenter so the card observes the same now-playing
            // data the desktop pill does.
            if let presenter = panelController?.presenter {
                lockMusicCard = LockMusicCardWindowController(presenter: presenter)
                // Lock-screen notch indicator — small pill hanging
                // from the notch with a "Locked" label and shake-on-
                // tap. Visible whenever the screen is locked,
                // regardless of whether music is playing. Same
                // SkyLight space attach so it composites on the
                // lock-screen surface.
                lockNotchIndicator = LockNotchIndicatorController(presenter: presenter)
            }
            // Countdown timer service. Pushes a `.timerRunning(s)`
            // SystemEvent every tick (the pill stays pinned because
            // `setPendingSystemEvent` resets the timeout each call),
            // and fires `onFinish` once at zero — which we handle
            // by transitioning to `.timerFinished` and playing a
            // success haptic.
            let timer = TimerService()
            timer.onFinish = { [weak self] in
                guard let panel = self?.panelController else { return }
                // Same surface-availability guarantee as Bluetooth:
                // the pill renders on the resting overlay, which
                // requires resting mode to be active. Without this
                // call, a timer that finishes while no music is
                // playing produces no visible pill.
                panel.enterRestingMode()
                panel.presenter.setPendingSystemEvent(.timerFinished)
                // Per-event toggle: respect Settings → Timer → Haptic
                // feedback even if global haptics are on. Default true.
                if Self.userDefaultBool(SettingsKey.timerHapticOnFinish, default: true) {
                    HapticFeedback.alignment()
                }
                // Optional system chime. Default true so first-launch
                // users get the audible "ding" they'd expect from a
                // timer; users who don't want it can flip it off.
                if Self.userDefaultBool(SettingsKey.timerSoundOnFinish, default: true) {
                    NSSound(named: NSSound.Name("Glass"))?.play()
                }
            }
            // Bridge TimerService.remaining → presenter via Combine
            // sink so any tick updates the displayed pill. Drops
            // updates while remaining=0 (means timer was canceled
            // or hasn't started).
            var lastPushedSeconds = -1
            let cancellable = timer.$remaining.sink { [weak self] remaining in
                guard let panel = self?.panelController, remaining > 0 else { return }
                let seconds = Int(ceil(remaining))
                if seconds != lastPushedSeconds {
                    lastPushedSeconds = seconds
                    // First tick of a fresh timer needs to surface the
                    // panel before the pill push — subsequent ticks
                    // are a no-op because `enterRestingMode` early-
                    // returns when already resting.
                    panel.enterRestingMode()
                    panel.presenter.setPendingSystemEvent(.timerRunning(remainingSeconds: seconds))
                }
            }
            timerCancellables.insert(cancellable)
            timerService = timer

            // Focus/DND auto-hide. Spin up the watcher in idle
            // mode — we don't request authorization until the user
            // explicitly toggles the Settings switch on. If the
            // user has previously authorized, `start()` will
            // immediately surface the current status; if not, the
            // service stays in `notDetermined` and `isFocused`
            // remains false. Either way the gate fails open.
            let focus = FocusStatusService()
            focus.start()
            focusCancellable = focus.$isFocused
                .removeDuplicates()
                .sink { [weak self] isFocused in
                    self?.panelController?.presenter.isFocused = isFocused
                    // Re-morph the resting pill to its current
                    // closedPillFrame width so the panel grows /
                    // shrinks alongside the SwiftUI Focus cluster
                    // appearing / disappearing inside it. No-op if
                    // the panel isn't currently at resting (slab
                    // open / transient banner showing).
                    self?.panelController?.morphRestingFrameForFocusChange()
                }
            // If we already have authorization from a prior session,
            // sync the initial state into the presenter so the very
            // first event after launch respects it.
            panelController?.presenter.isFocused = focus.isFocused
            focusStatusService = focus

            // Calendar / EventKit upcoming-meeting service. Mirrors
            // the Focus model: lazy authorization, fail-open. Even
            // if `Show next meeting pill` is off, we still spin up
            // the service so flipping the toggle on later is one
            // hop instead of an "app restart required" experience.
            // The service itself respects authorization status —
            // when not granted, `refresh()` is a no-op.
            let calendar = CalendarMonitorService()
            calendar.onUpcomingChange = { [weak self] event in
                guard let self, let panel = self.panelController else { return }
                let enabled = Self.userDefaultBool(
                    SettingsKey.showNextMeetingPill, default: false
                )
                guard enabled else {
                    panel.presenter.upcomingMeetingJoinURL = nil
                    return
                }
                guard let event = event else {
                    panel.presenter.upcomingMeetingJoinURL = nil
                    return
                }
                panel.presenter.upcomingMeetingJoinURL = event.joinURL
                panel.presenter.setPendingSystemEvent(
                    .calendarUpcoming(title: event.title,
                                      minutesUntilStart: event.minutesUntilStart)
                )
                panel.enterRestingMode()
            }
            calendar.start()
            calendarMonitor = calendar

            // AirDrop receiver pill. Spotlight predicate runs in
            // userland — no special auth needed beyond the user's
            // existing Spotlight index. When a file lands via
            // AirDrop in the last 90s, we surface a tappable pill
            // that reveals the file in Finder.
            let airDrop = AirDropWatcher()
            airDrop.onArrival = { [weak self] url in
                guard let self, let panel = self.panelController else { return }
                let enabled = Self.userDefaultBool(
                    SettingsKey.showAirDropPill, default: true
                )
                guard enabled else { return }
                panel.presenter.lastAirDropURL = url
                panel.presenter.setPendingSystemEvent(
                    .airDropReceived(filename: url.lastPathComponent)
                )
                panel.enterRestingMode()
                HapticFeedback.generic()
            }
            airDrop.start()
            airDropWatcher = airDrop

            // System volume HUD. CoreAudio property listener on the
            // default output device fires on every volume / mute
            // change (volume keys, menu-bar slider, AppleScript).
            // We push a `.volumeChanged` SystemEvent and grow the
            // panel into the volume banner geometry so the notch
            // expands into a Sound HUD that mirrors Alcove's. The
            // watcher itself suppresses the spurious initial-attach
            // fire so we don't pop on app launch.
            //
            // Gating mirrors the trackChanged path
            // (panel.presenter.isResting && !panel.presenter.isShown):
            // volume HUD only fires when the panel is in resting
            // pill mode and not currently in slab. If the panel is
            // at notch-hidden mode (no music, empty state), call
            // enterRestingMode FIRST and let its grow-spring settle
            // BEFORE kicking off showVolumeBanner — back-to-back
            // calls were cancelling each other's springs and
            // leaving the panel in an indeterminate state ("now it's
            // not showing anything" feedback).
            let volume = SystemVolumeWatcher()
            volume.onVolumeChange = { [weak self] level, muted in
                guard let self, let panel = self.panelController else {
                    SystemVolumeWatcher.log("AppDelegate.onVolumeChange — no self or panel")
                    return
                }
                SystemVolumeWatcher.log("AppDelegate.onVolumeChange — level=\(level) muted=\(muted) isResting=\(panel.presenter.isResting) isShown=\(panel.presenter.isShown)")
                // Don't fight the slab — if the user is actively
                // using the full panel, skip the HUD entirely
                // (matches Alcove + macOS behaviour: their HUD
                // doesn't draw over an active app surface).
                if panel.presenter.isShown {
                    SystemVolumeWatcher.log("AppDelegate.onVolumeChange — ABORT slab is shown")
                    return
                }

                // Suppress the HUD while the track-change banner is
                // ACTIVELY SHOWING. The banner runs for ~3.5s and
                // morphs the panel.frame to trackBannerFrame.
                // Letting the volume HUD fire during this window
                // would: (a) overwrite pendingSystemEvent from
                // .trackChanged → .volumeChanged mid-banner, killing
                // the banner content; (b) re-target the panel.frame
                // mid-morph, producing the "glitch" the user sees.
                //
                // Two-layer check:
                //   1. pendingSystemEvent is .trackChanged → banner
                //      is on screen, suppress
                //   2. Fallback: lastTrackChangeTime within 0.4s —
                //      covers the very-brief crossfade dip where
                //      the banner hasn't fired yet. Window short
                //      enough that user volume taps right after
                //      track-change land normally.
                if case .trackChanged = panel.presenter.pendingSystemEvent {
                    SystemVolumeWatcher.log("AppDelegate.onVolumeChange — ABORT track banner active")
                    return
                }
                if let lastChange = self.lastTrackChangeTime,
                   Date().timeIntervalSince(lastChange) < 0.4 {
                    SystemVolumeWatcher.log("AppDelegate.onVolumeChange — ABORT crossfade dip window")
                    return
                }

                // Push the SystemEvent now; the content overlay
                // will swap in regardless of whether the silhouette
                // morph happens this tick or after enterRestingMode.
                panel.presenter.setPendingSystemEvent(
                    .volumeChanged(level: level, muted: muted)
                )

                // If we're already resting, fire the banner morph
                // right now. If we're at notch-hidden (no music),
                // bring the panel into resting mode first and only
                // call showVolumeBanner once that grow has actually
                // started — back-to-back enterRestingMode + show
                // VolumeBanner cancelled each other's springs.
                if panel.presenter.isResting {
                    SystemVolumeWatcher.log("AppDelegate.onVolumeChange — already resting, calling showVolumeBanner")
                    panel.showVolumeBanner()
                } else {
                    SystemVolumeWatcher.log("AppDelegate.onVolumeChange — not resting, enterRestingMode then showVolumeBanner+50ms")
                    panel.enterRestingMode()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        [weak panel] in
                        SystemVolumeWatcher.log("AppDelegate.onVolumeChange — calling delayed showVolumeBanner")
                        panel?.showVolumeBanner()
                    }
                }

                // Schedule dismiss. Cancel any in-flight dismiss
                // first so a fresh volume change extends the visible
                // window cleanly (no race with an about-to-fire
                // dismiss collapsing the banner mid-keypress).
                self.volumeDismissWorkItem?.cancel()
                let work = DispatchWorkItem { [weak panel] in
                    guard let panel else { return }
                    panel.dismissVolumeBanner {
                        if case .volumeChanged = panel.presenter.pendingSystemEvent {
                            panel.presenter.pendingSystemEvent = nil
                        }
                    }
                }
                self.volumeDismissWorkItem = work
                DispatchQueue.main.asyncAfter(
                    deadline: .now() + 1.55,
                    execute: work
                )
            }
            systemVolumeWatcher = volume
        } catch {
            // Per BUG-030 fix: previously the user saw the app
            // open and immediately quit with no explanation —
            // worst possible first-launch experience. Now we
            // surface a real NSAlert that:
            //   • names the failure (DB migration / init)
            //   • explains the recovery path (delete the data
            //     folder, which uninstalls then reinstalls user
            //     data)
            //   • shows the underlying error so a power user can
            //     diagnose / file a useful bug report
            // The terminate happens AFTER the alert is dismissed,
            // so the user has a clear story for what happened
            // instead of "the app just crashed."
            NSLog("nox failed to initialize: \(error)")
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "nox can't start"
            alert.informativeText = """
            The local database couldn't be opened or migrated.

            Details: \(error.localizedDescription)

            To recover, quit nox and remove the folder at:
            ~/Library/Application Support/nox

            (On older installs that haven't migrated yet the
            folder may still be named "Notetaker" — same data,
            same recovery step.)

            That'll reset the database to a fresh state. Your
            Spotify history, screenshots, and AirDrops will be
            untouched — only nox's own notes / images / videos
            cache lives there.
            """
            alert.addButton(withTitle: "Quit")
            alert.runModal()
            NSApp.terminate(nil)
            return
        }

        menuBarController = MenuBarController { [weak self] in
            self?.panelController?.toggle()
        }
        panelController?.menuBarController = menuBarController

        // Wire the right-click timer presets through the menu bar
        // → TimerService. The menu builds itself on every show
        // (`menuNeedsUpdate`) and reads `isTimerRunning` to decide
        // whether to render the "Cancel Timer" item, so this trio
        // keeps the menu consistent with whatever the service is
        // actually doing.
        //
        // Cancel also clears the pending system event so the pill
        // disappears immediately instead of waiting for the 5s
        // watchdog timeout — without this, the user taps "Cancel
        // Timer" and the pill lingers, which reads as "did the
        // tap register?"
        menuBarController?.onStartTimer = { [weak self] duration in
            self?.timerService?.start(seconds: duration)
        }
        menuBarController?.onCancelTimer = { [weak self] in
            self?.timerService?.cancel()
            self?.panelController?.presenter.clearPendingSystemEvent()
        }
        menuBarController?.isTimerRunning = { [weak self] in
            self?.timerService?.isRunning ?? false
        }

        // Debug pill triggers. Fires a synthetic SystemEvent of the
        // selected kind so the user can verify pill animations without
        // having to trigger the real-world event (plug in a charger,
        // AirDrop a file, etc.). Each synthetic event runs through the
        // same `setPendingSystemEvent` pipeline that the real handlers
        // use, so what you see here is exactly what'd happen on a real
        // event.
        menuBarController?.onTriggerTestPill = { [weak self] kind in
            guard let panel = self?.panelController else { return }
            panel.enterRestingMode()
            switch kind {
            case .charging:
                panel.presenter.setPendingSystemEvent(.charging(percent: 67, plugged: true))
                HapticFeedback.chargingChange()
            case .bluetoothConnected:
                panel.presenter.setPendingSystemEvent(
                    .bluetoothConnected(deviceName: "AirPods Pro", isAirPods: true)
                )
                HapticFeedback.bluetoothChange()
            case .bluetoothDisconnected:
                panel.presenter.setPendingSystemEvent(
                    .bluetoothDisconnected(deviceName: "AirPods Pro", isAirPods: true)
                )
                HapticFeedback.bluetoothChange()
            case .timerFinished:
                panel.presenter.setPendingSystemEvent(.timerFinished)
                HapticFeedback.alignment()
                NSSound(named: NSSound.Name("Glass"))?.play()
            case .calendarUpcoming:
                panel.presenter.setPendingSystemEvent(
                    .calendarUpcoming(title: "Standup", minutesUntilStart: 2)
                )
            case .airDropReceived:
                // Use the most-recent file in Downloads as a stand-in
                // "received" URL so the pill's UTI glyph reflects a
                // real file type rather than always falling back to
                // the generic doc icon.
                let url = Self.mostRecentDownloadURL()
                    ?? URL(fileURLWithPath: NSHomeDirectory() + "/Downloads/photo.jpg")
                panel.presenter.lastAirDropURL = url
                panel.presenter.setPendingSystemEvent(
                    .airDropReceived(filename: url.lastPathComponent)
                )
                HapticFeedback.generic()
            case .noteSaved:
                panel.presenter.setPendingSystemEvent(.noteSaved)
                HapticFeedback.generic()
            }
        }

        hotkeyService = HotkeyService { [weak self] event in
            switch event {
            case .togglePanel:
                NSLog("nox: toggle() called, panel=\(self?.panelController != nil ? "exists" : "nil")")
                self?.panelController?.toggle()
            case .grabCurrentTab:
                Task { @MainActor in self?.grabCurrentBrowserTab() }
            }
        }

        let monitor = ClipboardMonitor { [weak self] in
            Task { @MainActor in
                self?.handleExternalClipboardChange()
            }
        }
        monitor.start()
        self.clipboardMonitor = monitor

        let drag = DragMonitor(
            onImageDrag: { [weak self] in
                Task { @MainActor in
                    self?.panelController?.showOnTab(.images)
                }
            },
            onVideoDrag: { [weak self] in
                Task { @MainActor in
                    self?.panelController?.showOnTab(.videos)
                }
            }
        )
        drag.start()
        self.dragMonitor = drag

        let screenshots = ScreenshotWatcher { [weak self] url in
            self?.handleNewScreenshot(at: url)
        }
        screenshots.start()
        self.screenshotWatcher = screenshots

        // Cursor-into-notch → two-stage hover gesture, matching what
        // the user described from Alcove / Elkhob: "when I'm going to
        // the cursor into that thing, it just moves a little bit; it
        // doesn't open the whole thing. When I'm placing the cursor
        // for like 0.2 seconds or a little bit longer, it opens."
        //
        // - onTeaseStart: cursor entered the hot zone → tease the
        //   panel (small pre-bloom pill, no content tree). Gives
        //   immediate visual feedback so the entry feels acknowledged.
        // - onTeaseEnd: cursor left before the dwell completed →
        //   collapse the tease and order out. The panel returns to
        //   hidden; nothing else happens.
        // - onActivate: cursor stayed for the dwell window → promote
        //   to a full slab open. show() detects we're already teasing
        //   and lets animateOpen blend smoothly from the tease frame
        //   into the slab without a setFrame snap.
        //
        // Pass `mode: .hover` so the panel installs cursor-leave
        // monitors and auto-dismisses when the user moves away — the
        // user explicitly asked for "when i move my cursor from the
        // thing it should just close automatically" for hover-opened
        // panels, while click/hotkey-opened panels stay sticky until
        // an explicit click-outside.
        let hover = HoverActivator(
            onTeaseStart: { [weak self] in
                guard let panel = self?.panelController else { return }
                // Suppress tease when the pill is in video-preview
                // mode. The pill becomes a tappable download button
                // while a video URL is pending — letting the slab
                // tease in would cover the button before the user
                // can land on it. ("we can just finish the work on
                // the pill itself, so we don't need to open another
                // tab.")
                if panel.presenter.pendingVideoCandidate != nil { return }
                panel.tease()
            },
            onTeaseEnd: { [weak self] in
                self?.panelController?.dismissTease()
            },
            onActivate: { [weak self] in
                guard let self, let panel = self.panelController else { return }
                if panel.presenter.pendingVideoCandidate != nil { return }
                if !panel.isVisible {
                    panel.show(mode: .hover)
                }
            }
        )
        hover.start()
        self.hoverActivator = hover

        // Notch HUD subsystem — independent of the notes panel. Pops
        // a charging pill on plug-in / unplug, ready to grow with
        // music/AirPods/focus presentations later.
        let orchestrator = NotchOrchestrator()

        // Bridge MediaRemote → PanelPresenter so the panel's music
        // page (MusicPanelView) can observe the same now-playing
        // stream that drives the resting pill. We fire on every
        // snapshot (including nil) so the presenter's `visibleTabs`
        // and the "auto-bounce off .music when playback stops" logic
        // stay in sync without polling.
        //
        // This callback is also where the unified pill+panel toggles
        // its resting state. Whenever there's a current track (info
        // non-nil — playing or paused, matching Alcove's "ambient
        // indicator" behavior) we ask the panel controller to enter
        // resting mode: the NSPanel is ordered front at closed-pill
        // geometry and stays there until the user hovers (which morphs
        // it into the full slab) or music stops. When info goes nil
        // we exit resting mode and the panel orders out — but only if
        // it isn't currently visible/teasing in another mode, so a
        // music-stop mid-session doesn't yank a panel out from under
        // the user's cursor.
        orchestrator.onNowPlayingChange = { [weak self] info in
            guard let self, let panel = self.panelController else { return }
            self.handleNowPlayingChange(info, panel: panel)
        }
        // CoreAudio-driven "is audio actually flowing" signal,
        // forwarded into the presenter so SwiftUI views can bind
        // to it as the authoritative "is something playing" check.
        orchestrator.onAudioFlowingChange = { [weak self] flowing in
            guard let self else { return }
            self.panelController?.presenter.isAudioFlowing = flowing
            self.handleAudioFlowingChange(flowing)
        }

        // Lock-state edge → drives the music card's visibility.
        // Setting `presenter.isLocked` triggers the Combine
        // pipeline inside `LockMusicCardWindowController` which
        // calls `orderFront` / `orderOut` on the card panel.
        orchestrator.onLockStateChange = { [weak self] locked in
            self?.panelController?.presenter.isLocked = locked
        }

        // Wire the music card's transport buttons through the
        // existing media command pipeline. Same `sendMediaCommand`
        // path the desktop pill uses, so play/pause/skip on lock
        // drive the same Spotify/Apple Music/browser session.
        lockMusicCard?.onMediaCommand = { [weak orchestrator] command in
            orchestrator?.sendMediaCommand(command)
        }
        lockMusicCard?.onOpenSourceApp = { [weak orchestrator] in
            orchestrator?.openSourceApp()
        }

        // Route charging events into the unified pill instead of
        // a separate floating HUD. The pill briefly morphs to
        // show the new charging state, then auto-reverts to music
        // after `pendingSystemEventTimeout` seconds.
        orchestrator.onChargingChange = { [weak self] percent, plugged in
            guard let self, let panel = self.panelController else { return }
            // Settings → Charging → Show charging pill. Default on
            // for first-launch users.
            let showPill: Bool = {
                if UserDefaults.standard.object(forKey: "showChargingPill") == nil { return true }
                return UserDefaults.standard.bool(forKey: "showChargingPill")
            }()
            guard showPill else { return }
            panel.presenter.setPendingSystemEvent(.charging(percent: percent, plugged: plugged))
            // Make sure the pill is on screen so the user can
            // actually see the charging morph (otherwise the
            // change happens invisibly behind a closed panel).
            panel.enterRestingMode()
            // Tactile confirmation that the cable change registered
            // — same vocabulary Alcove uses for hardware events.
            // Routed through `chargingChange()` (instead of raw
            // `alignment()`) so the per-event Settings toggle
            // actually gates this — it was a dead key before.
            HapticFeedback.chargingChange()
        }

        // Reverse bridge: MusicPanelView's transport buttons (prev /
        // play-pause / next) route through PanelPresenter.onMediaCommand,
        // which we point at the orchestrator's MediaRemoteService. This
        // closure is captured for the lifetime of the panel controller —
        // both objects live for the whole app lifetime, so a strong
        // reference here is fine and avoids a [weak] dance during
        // every button tap.
        panelController?.presenter.onMediaCommand = { [weak orchestrator] command in
            orchestrator?.sendMediaCommand(command)
        }

        // Click-on-artwork in MusicPanelView routes through this
        // closure so the orchestrator can decide between "jump to
        // YouTube tab" (via BrowserMediaProbe) and "open the source
        // app generically" (via NSWorkspace).
        panelController?.presenter.onOpenSourceApp = { [weak orchestrator] in
            orchestrator?.openSourceApp()
        }

        // Calendar pill click → open the meeting URL. We pull the
        // URL out of the presenter (the calendar service stashes
        // it there each time it pushes a new event) so the click
        // handler doesn't need to know about EKEvent. NSWorkspace
        // routes to the user's default browser unless they have
        // the relevant app's URL scheme registered (Zoom, Teams).
        panelController?.presenter.onJoinUpcomingMeeting = { [weak self] in
            guard let url = self?.panelController?.presenter.upcomingMeetingJoinURL else { return }
            NSWorkspace.shared.open(url)
        }

        // AirDrop pill click → reveal in Finder. Same indirection
        // pattern: presenter holds the URL, AppDelegate owns the
        // AppKit hop. `activateFileViewerSelecting` selects the
        // file inside its containing folder, which is the AirDrop
        // UX users expect (vs. blindly opening it).
        panelController?.presenter.onRevealAirDrop = { [weak self] in
            guard let url = self?.panelController?.presenter.lastAirDropURL else { return }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }

        // Transient-pill cleanup. When a charging / Bluetooth /
        // timer / AirDrop pill expires through its auto-dismiss
        // timeout AND there's no music to anchor the resting pill,
        // we exit resting mode so the empty silhouette doesn't camp
        // on screen. With music, we stay resting because the pill
        // body falls back to the now-playing artwork+waveform.
        panelController?.presenter.onTransientEventCleared = { [weak self] in
            guard let panel = self?.panelController else { return }
            if panel.presenter.nowPlaying == nil {
                panel.exitRestingMode()
            }
        }

        // Wire the "user tapped Download in the video preview pill"
        // callback. Routes to the existing video-store download path
        // (the same one the panel's auto-routing uses), then opens
        // the panel to the videos tab so the user sees their item
        // queue up.
        panelController?.presenter.onDownloadVideo = { [weak self] url in
            guard let self, let env = self.environment, let panel = self.panelController else { return }
            Self.dispatchDownload(url: url, env: env)
            // Stay on the pill — the user explicitly wanted the
            // entire interaction to live there. Clearing the
            // pending candidate triggers the bouncy reverse
            // transition back to the music pill (or empty state),
            // which feels like the pill "danced" the action out.
            panel.presenter.clearPendingVideo()
        }

        self.notchOrchestrator = orchestrator
        // 2026-05-06 — gate orchestrator.start() on onboardingCompletedV2.
        //
        // orchestrator.start() kicks off MediaRemoteService which uses
        // AppleScript-based timing fallbacks. The first time it sends
        // a script to Spotify or Music while either is running, macOS
        // fires the Automation / Apple Events permission prompt. Bad
        // UX: that prompt lands BEFORE the user has any context about
        // what nox is. Per-permission onboarding now explains the
        // music card before any prompt fires.
        //
        // For users who've already completed onboarding (upgrades),
        // start immediately — they've seen the explanation. For
        // first-launch users, deferred until the onboarding flow
        // calls `startTCCDeferredServices()` from its onComplete /
        // windowWillClose paths.
        if UserDefaults.standard.bool(forKey: "onboardingCompletedV2") {
            orchestrator.start()
        }

        // Dictation orchestrator — starts the Fn-key listener +
        // wires the audio recorder + transcription service to the
        // paste helper. Pulls API key + provider config from
        // UserDefaults; disabled (no hotkey installed) if the user
        // hasn't entered a key yet — they'll see a Settings →
        // Dictation prompt directing them to grab a free Groq key.
        let dictation = DictationOrchestrator()
        // Note: the old `resolveActiveAudioSource` / `sendMediaCommand`
        // wiring was removed when dictation switched to muting the
        // **system audio output** instead of pausing the source app.
        // See `SystemAudioMuter` — videos and music keep playing
        // silently during recording, so nothing needs the source
        // bundle ID anymore.
        dictation.onTranscriptReady = { text in
            // One-shot in-app routing: if a view (e.g. note editor's
            // mic button) claimed the next transcript via
            // DictationRouter.pendingDestination, deliver it there
            // and skip system-wide typing entirely. Otherwise type
            // the text at the cursor of the frontmost app via direct
            // CGEvent unicode keystrokes (no clipboard touched).
            if let destination = DictationRouter.pendingDestination {
                DictationRouter.pendingDestination = nil
                destination(text)
            } else {
                DictationPasteHelper.paste(text)
            }
        }
        // Mirror the orchestrator's state onto PanelPresenter so the
        // pill UI can react. Maps internal DictationOrchestrator.State
        // to the simpler PanelPresenter.DictationPhase enum the views
        // observe.
        //
        // Critical secondary effect: when entering .recording, the
        // panel needs to be in resting mode (pill visible) even when
        // no music is playing. Without that gate flip, the dictation
        // pill content lives inside an invisible panel — the user
        // hears nothing happen and sees no notch react. We call
        // `enterRestingMode()` to force the NSPanel front + flip
        // `isResting=true`. On exit (.idle) we leave resting mode
        // alone — the music auto-pause wiring already restores
        // whatever was playing, and the resting state sticks if
        // music is back.
        dictation.onStateChange = { [weak self] state in
            // Broadcast to in-app dictation UI (mic buttons in
            // toolbars) — they listen on this and update their
            // visual state regardless of where the dictation was
            // triggered from.
            let isRecording: Bool
            if case .recording = state { isRecording = true } else { isRecording = false }
            NotificationCenter.default.post(
                name: .notetakerDictationStateChanged,
                object: nil,
                userInfo: ["isRecording": isRecording]
            )

            guard let panel = self?.panelController else {
                DictationOrchestrator.dlog("⚠️ onStateChange — panelController is nil, can't update UI")
                return
            }
            let presenter = panel.presenter
            switch state {
            case .idle:
                presenter.dictationPhase = .idle
                presenter.dictationLevel = 0
                DictationOrchestrator.dlog("UI ⇒ idle (isResting=\(presenter.isResting) isShown=\(presenter.isShown))")
            case .recording(let level):
                if presenter.dictationPhase != .recording {
                    presenter.dictationPhase = .recording
                    // Clear any stale pendingSystemEvent (most likely
                    // a recent .volumeChanged HUD) so the dictation
                    // pill takes over the pill content cleanly. The
                    // pillContentOverlay branches check
                    // pendingSystemEvent BEFORE dictationPhase, so
                    // without this clear, a HUD that's still in its
                    // 1.5s timeout window would block the dictation
                    // pill from rendering.
                    if case .volumeChanged = presenter.pendingSystemEvent {
                        self?.volumeDismissWorkItem?.cancel()
                        presenter.pendingSystemEvent = nil
                    }
                    panel.enterRestingMode()
                    DictationOrchestrator.dlog("UI ⇒ recording — called enterRestingMode (isResting=\(presenter.isResting) isShown=\(presenter.isShown))")
                }
                presenter.dictationLevel = level
            case .transcribing:
                presenter.dictationPhase = .transcribing
                presenter.dictationLevel = 0
                DictationOrchestrator.dlog("UI ⇒ transcribing (isResting=\(presenter.isResting) isShown=\(presenter.isShown))")
            case .error(let msg):
                presenter.dictationPhase = .error(msg)
                presenter.dictationLevel = 0
                DictationOrchestrator.dlog("UI ⇒ error: \(msg)")
            }
        }
        dictation.configure(serviceConfig: AppDelegate.loadDictationConfig())
        // Default to FN-HOLD (press to start, release to stop) — what
        // the user explicitly asked for: "I press on Fn; it kind of
        // has an animation of talking … when I dispress the Fn, it
        // just automatically gets off." Toggle stayed as a settings
        // option for users who prefer tap-to-toggle.
        let savedMode = UserDefaults.standard.string(forKey: "dictationHotkeyMode")
            .flatMap { DictationOrchestrator.HotkeyMode(rawValue: $0) }
            ?? .fnHold
        self.dictationOrchestrator = dictation
        self.dictationPendingHotkeyMode = savedMode
        // 2026-05-06 — gate setHotkeyMode on onboardingCompletedV2.
        //
        // setHotkeyMode → installFnKeyTap → AXIsProcessTrustedWithOptions
        // with prompt=true — that's the call that pops the macOS
        // Accessibility permission dialog. THIS is the prompt the
        // user reported was firing in the background of the
        // onboarding window before they could see what nox even is.
        //
        // For users who've already completed onboarding, install the
        // tap immediately. For first-launch users, deferred until
        // the onboarding flow's Accessibility step has explained
        // why we need it; `startTCCDeferredServices()` then installs
        // the tap.
        if UserDefaults.standard.bool(forKey: "onboardingCompletedV2") {
            dictation.setHotkeyMode(savedMode)
        }

        // In-app dictation entry point: views (note editor mic
        // button, etc.) post `.notetakerStartDictation` after
        // setting `DictationRouter.pendingDestination`. We start
        // recording in toggle mode (release isn't bound to anything
        // — the user must tap the same button or hit the Fn key /
        // ⌘⇧D backup to stop).
        NotificationCenter.default.addObserver(
            forName: .notetakerStartDictation,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self, let orch = self.dictationOrchestrator else { return }
            // If we're already recording, treat the request as a
            // toggle-stop. This lets the same button start AND stop
            // dictation without the user needing two distinct
            // affordances.
            if case .recording = orch.state {
                orch.stopRecording()
            } else {
                orch.startRecording()
            }
        }

        // Per BUG-008 fix: the entire NOTETAKER_* environment-
        // variable surface is gated behind `#if DEBUG` so it
        // doesn't ship in release builds. The shipped binary
        // previously included ~150 lines of test paths,
        // including NOTETAKER_TEST_URL which would call
        // `videoStore.startDownload(url:)` against any string
        // an attacker could plant via `launchctl setenv` — a
        // remote-controlled video downloader surface, exactly
        // the kind of thing an Apple Notarization reviewer
        // would flag. DEBUG builds (Xcode Run, dev iteration)
        // keep the helpers; Release builds (DMG, archive)
        // strip them entirely.
        #if DEBUG
        // Dev-only: auto-show the panel on launch for visual verification.
        if ProcessInfo.processInfo.environment["NOTETAKER_AUTOSHOW"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.panelController?.show()
            }
        }

        // Dev-only: fire a synthetic test pill on launch so the
        // visual can be verified via `screencapture` without
        // requiring the user to drive the menubar manually. Maps
        // env var values to MenuBarController.TestPill cases.
        if let testKind = ProcessInfo.processInfo.environment["NOTETAKER_TEST_PILL"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                let pill: MenuBarController.TestPill?
                switch testKind {
                case "airdrop": pill = .airDropReceived
                case "charging": pill = .charging
                case "btconn": pill = .bluetoothConnected
                case "btdisc": pill = .bluetoothDisconnected
                case "timer": pill = .timerFinished
                case "calendar": pill = .calendarUpcoming
                case "noteSaved": pill = .noteSaved
                default: pill = nil
                }
                if let pill = pill {
                    self?.menuBarController?.onTriggerTestPill?(pill)
                }
                // Also support starting an actual countdown timer
                // (rather than the "finished" pill) — useful for
                // verifying the running pill body specifically.
                if testKind == "timerRun" {
                    self?.timerService?.start(seconds: 25)
                }
                // Pre-select the first 3 notes so the multi-select
                // toolbar renders for screencapture verification.
                // No real-world equivalent — purely a test path.
                if testKind == "selectNotes" {
                    NSLog("nox: selectNotes test starting")
                    guard let env = self?.environment else {
                        NSLog("nox: selectNotes — env nil, abort")
                        return
                    }
                    self?.panelController?.show()
                    self?.panelController?.presenter.activeTab = .notes
                    NSLog("nox: selectNotes — show + tab set, scheduling seed")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        let firstThree = env.noteStore.notes.prefix(3).map(\.id)
                        NSLog("nox: selectNotes — seeding \(firstThree.count) ids")
                        UserDefaults.standard.set(Array(firstThree),
                                                   forKey: "Notetaker.testSelectedNoteIds")
                        NotificationCenter.default.post(
                            name: NSNotification.Name("Notetaker.TestSeedSelection"),
                            object: nil
                        )
                    }
                }
                // Synthetic two-stage swap: simulates Spotify's
                // real behavior where a track change emits
                // metadata first, artwork ~200ms later. Without
                // the same-track artwork-refresh handler, the
                // slab would show stale artwork forever (the
                // bug the user reported as "next song's
                // thumbnails not appearing").
                //
                // Stage 1: track1 with red 1x1 PNG → visible.
                // Stage 2: track2 with NO artwork → should clear.
                // Stage 3: track2 with green 1x1 PNG → should
                //   trigger the same-track refresh branch and
                //   load the green artwork.
                if testKind == "musicTwoStage" {
                    guard let panel = self?.panelController else { return }
                    panel.presenter.activeTab = .music
                    let red = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")
                    let green = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==")
                    let track1 = NowPlayingInfo(
                        title: "Track One", artist: "Artist Red",
                        album: "Album", artworkData: red,
                        isPlaying: true, sourceBundleID: nil,
                        duration: 200, elapsedTime: 0, infoTimestamp: Date()
                    )
                    panel.presenter.nowPlaying = track1
                    panel.enterRestingMode()
                    NSLog("nox: TEST stage 1 — track1 with red artwork")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        let track2NoArt = NowPlayingInfo(
                            title: "Track Two", artist: "Artist Green",
                            album: "Album", artworkData: nil,
                            isPlaying: true, sourceBundleID: nil,
                            duration: 240, elapsedTime: 0, infoTimestamp: Date()
                        )
                        panel.presenter.nowPlaying = track2NoArt
                        NSLog("nox: TEST stage 2 — track2 metadata, NO artwork")
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                        let track2WithArt = NowPlayingInfo(
                            title: "Track Two", artist: "Artist Green",
                            album: "Album", artworkData: green,
                            isPlaying: true, sourceBundleID: nil,
                            duration: 240, elapsedTime: 0, infoTimestamp: Date()
                        )
                        panel.presenter.nowPlaying = track2WithArt
                        NSLog("nox: TEST stage 3 — track2 same-track with green artwork")
                    }
                }
                // Synthetic music + skip flow. Injects a fake
                // nowPlaying snapshot, then 1.5s later swaps to a
                // second track. Lets us visually verify the
                // tilt+blur+offset song-change animation on the
                // pill without needing actual audio playback.
                if testKind == "musicSkip" {
                    guard let panel = self?.panelController else { return }
                    let track1 = NowPlayingInfo(
                        title: "First Track", artist: "Test Artist",
                        album: "Test Album", artworkData: nil,
                        isPlaying: true, sourceBundleID: nil,
                        duration: 200, elapsedTime: 0,
                        infoTimestamp: Date()
                    )
                    panel.presenter.nowPlaying = track1
                    panel.enterRestingMode()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        let track2 = NowPlayingInfo(
                            title: "Second Track", artist: "Other Artist",
                            album: "Other Album", artworkData: nil,
                            isPlaying: true, sourceBundleID: nil,
                            duration: 240, elapsedTime: 0,
                            infoTimestamp: Date()
                        )
                        panel.presenter.nowPlaying = track2
                    }
                }
            }
        }

        // Dev-only: self-trigger a download so we can verify the pipeline
        // without having to drive a browser hotkey. Set NOTETAKER_TEST_URL
        // in the Xcode scheme or launch env to exercise the code path.
        if let testURL = ProcessInfo.processInfo.environment["NOTETAKER_TEST_URL"],
           !testURL.isEmpty {
            NSLog("nox: NOTETAKER_TEST_URL set — firing startDownload in 1.5s for \(testURL)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.environment?.videoStore.startDownload(url: testURL)
                self?.panelController?.showOnTab(.videos)
            }
        }
        #endif // DEBUG — closes the BUG-008 gate

        // Onboarding presentation moved to the TOP of this method
        // (right after setActivationPolicy) so it appears BEFORE
        // service-startup-triggered TCC prompts. See the call-site
        // comment up there for the full rationale.
    }

    /// Kicks on the services whose `start()` methods can fire macOS
    /// TCC permission prompts. Held back at launch (gated on the
    /// onboardingCompletedV2 flag) so first-launch users see the
    /// onboarding flow's per-permission privacy explainers BEFORE
    /// any system permission dialog appears.
    ///
    /// Called from `OnboardingManager` when the user finishes (or
    /// dismisses) the flow. Idempotent — re-calling is a no-op
    /// because each underlying `start()` / `setHotkeyMode()` is
    /// itself idempotent.
    func startTCCDeferredServices() {
        // Defensive: only run once onboarding really has been
        // marked complete. The OnboardingManager only invokes us
        // after setting the flag, but a Settings → "Show
        // onboarding" re-run path could theoretically call this
        // before the flag flips.
        guard UserDefaults.standard.bool(forKey: "onboardingCompletedV2") else {
            DictationOrchestrator.dlog("startTCCDeferredServices: bailing — flag not set yet")
            return
        }
        // MediaRemote AppleScript timing fallback can fire the
        // Automation / Apple Events permission prompt the first
        // time it queries Spotify or Music while either is running.
        notchOrchestrator?.start()
        // installFnKeyTap → AXIsProcessTrustedWithOptions(prompt=true)
        // is the call that pops the Accessibility permission dialog.
        if let mode = dictationPendingHotkeyMode {
            dictationOrchestrator?.setHotkeyMode(mode)
            dictationPendingHotkeyMode = nil
        }
    }

    /// Re-runs the onboarding flow on demand (Settings → "Show
    /// onboarding again" button). Kept alongside `openSettings`
    /// since the trigger lives in the Settings UI.
    func presentOnboarding() {
        onboardingManager.present()
    }

    /// Opens (or refocuses) the Settings window. Builds the SwiftUI tree
    /// directly with `NSHostingController` and hands its environmentObject
    /// the same `AppEnvironment` the panel uses, so the API key field,
    /// retention toggles, etc. all read/write the live state. The window
    /// is cached so repeated clicks just bring the existing one forward
    /// instead of stacking duplicates.
    ///
    /// Two non-obvious bits:
    ///
    /// 1. **Dismiss the panel.** It runs at `.popUpMenu` level (101) so a
    ///    plain `.normal`-level window opens BEHIND it and looks like
    ///    nothing happened. Hiding the panel first gives the Settings
    ///    window a clean field of view; the user just left the panel
    ///    anyway by clicking the gear.
    ///
    /// 2. **Bump activation policy to `.regular`.** With LSUIElement we
    ///    launch as `.accessory`, which means new windows don't get
    ///    real keyboard focus / Dock presence. Flipping to `.regular`
    ///    while Settings is up gets us a proper foreground window;
    ///    we revert to `.accessory` on close so the Dock icon doesn't
    ///    linger.
    func openSettings() {
        NSLog("nox: openSettings() entered, env=\(environment != nil), cached=\(settingsWindow != nil)")
        panelController?.hide()

        NSApp.setActivationPolicy(.regular)
        if #available(macOS 14, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }

        if let window = settingsWindow {
            window.makeKeyAndOrderFront(nil)
            return
        }

        guard let env = environment else {
            NSLog("nox: openSettings called before environment ready")
            return
        }

        let host = NSHostingController(rootView: SettingsView().environmentObject(env))
        let window = NSWindow(contentViewController: host)
        window.title = "nox Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("NoxSettingsWindow")
        // Drop back to menu-bar-only when the user closes Settings, so
        // we don't strand a Dock icon for an `LSUIElement` app.
        // Per BUG-015 fix: capture the observer token + clear the
        // window reference inside the close handler so the observer
        // can be removed (preventing leak) and a future
        // `openSettings()` correctly takes the create-new path
        // instead of re-using a closed window.
        settingsWindowCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                NSApp.setActivationPolicy(.accessory)
                if let token = self?.settingsWindowCloseObserver {
                    NotificationCenter.default.removeObserver(token)
                    self?.settingsWindowCloseObserver = nil
                }
                self?.settingsWindow = nil
            }
        }
        settingsWindow = window
        window.makeKeyAndOrderFront(nil)
        NSLog("nox: settings window ordered front, level=\(window.level.rawValue) visible=\(window.isVisible)")
    }

    /// Forward the orchestrator's now-playing snapshot to the panel,
    /// debouncing transient nils. macOS's MediaRemote occasionally
    /// drops the now-playing slot to nil for a few hundred ms when
    /// audio sessions transition — a YouTube video starts in Safari
    /// while Spotify is paused, a video preview plays inside our own
    /// panel, AirPods reconnect, etc. Without debounce, every such
    /// gap collapses the resting pill and the user has to manually
    /// restart playback to get it back. Holding a 4-second timer on
    /// nil emissions means any transient gap is invisible: the next
    /// non-nil snapshot cancels the pending teardown before it fires.
    ///
    /// Only the `exitRestingMode` + `presenter.nowPlaying = nil`
    /// branch is debounced. Non-nil snapshots flow through
    /// immediately so artwork / title updates land without delay,
    /// and any pending teardown is cancelled (the music came back).
    private func handleNowPlayingChange(_ info: NowPlayingInfo?, panel: PanelWindowController) {
        // 2026-05-01 ALCOVE-STYLE REWRITE.
        //
        // Old design: pill visibility was tied to `presenter.nowPlaying
        // != nil`, with a 4s nil-debounce that cleared the cache when
        // MR went silent. That caused the cascade of bugs the user
        // ran into — pill flipping to "Nothing playing" on pause,
        // ghost stubs polluting the cache, cross-source bleed-through.
        //
        // New design (matches Alcove behavior the user described):
        //   • SMALL PILL visibility = `effectivelyPlaying`
        //     = `isAudioFlowing && (nowPlaying?.isPlaying ?? true)`.
        //     Pill is up only when there's live audio AND we're not
        //     explicitly paused. Pause → small pill collapses
        //     within 1.5s. Resume → pill grows back from the notch.
        //   • SLAB content = sticky `presenter.nowPlaying`. Once
        //     a track is set, it persists until a NEW non-nil
        //     emission replaces it. nil emissions never wipe the
        //     cache. So the user can hover the notch hours after
        //     pausing and still see the paused track in the slab,
        //     ready to resume from the play button.
        //
        // The orchestrator's nil→paused transform handles the
        // "MR went silent but audio still flowing" case by flipping
        // `nowPlaying.isPlaying` to false — that's what drives the
        // small-pill collapse here without touching the cache.
        nowPlayingNilDebounce?.cancel()
        nowPlayingNilDebounce = nil

        if let info = info {
            // Transient stuff (ad jingles, error chimes < 5s) doesn't
            // pollute the sticky cache and doesn't trigger pill bloom.
            if !isTransientMedia(info) {
                // Predict whether this update will fire a track-change
                // banner BEFORE we update presenter.nowPlaying. If yes,
                // set the flag so PanelRootView's .onChange Branch 4
                // skips the music-pill swap animation — otherwise the
                // 250ms pre-show window flickers as the music pill
                // animates underneath the (not-yet-visible) banner.
                let predictedTrackKey = "\(info.title)|\(info.artist)"
                let willFireBanner = !info.title.isEmpty
                    && predictedTrackKey != lastAnnouncedTrackKey
                    && info.isPlaying
                    && panel.presenter.isResting
                    && !panel.presenter.isShown
                if willFireBanner {
                    panel.presenter.trackChangedFiring = true
                    // Capture the OLD artwork BEFORE updating nowPlaying.
                    // The banner's front face will display this; the
                    // flip animation reveals the new artwork on the
                    // back face. User direction: "we need to tilt the
                    // artwork when it's changing the music and the
                    // thing expanding".
                    panel.presenter.bannerFromArtwork = panel.presenter.nowPlaying?.artworkData
                }

                // Detect track CHANGE (title or artist differs from
                // the existing nowPlaying) so we can mark a suppress
                // window for the volume HUD. Track boundaries often
                // produce a brief system-audio dip (Spotify crossfade
                // / app-driven volume ramp) that fires our volume
                // listener and pops the HUD spuriously.
                let prev = panel.presenter.nowPlaying
                let isTrackChange = prev == nil
                    || prev?.title != info.title
                    || prev?.artist != info.artist
                if isTrackChange {
                    self.lastTrackChangeTime = Date()
                }

                panel.presenter.nowPlaying = info

                // 2026-05-07 — Alcove-style track-change announcement.
                // When MR reports a NEW (title|artist) and the track
                // is actively playing:
                //   1. Stash the artwork on the presenter so the
                //      banner body can render it (presenter is the
                //      sole shared surface between AppDelegate and
                //      the SwiftUI tree).
                //   2. Tell the panel to grow into banner geometry
                //      (PanelWindowController.showTrackBanner) so
                //      the silhouette drops a visible apron BELOW
                //      the notch hardware where text is readable.
                //   3. Fire the .trackChanged SystemEvent so
                //      PanelRootView swaps in the announcement
                //      content and the presenter's 3.5s timeout
                //      auto-clears it.
                //   4. Schedule dismissTrackBanner() at the same
                //      timeout so the panel returns to closedPillFrame.
                //
                // Gated on `isPlaying` so paused-track-info updates
                // (e.g. art finishing decode after a pause) don't
                // re-fire the banner. Gated on resting+!isShown so
                // the banner doesn't fight an open slab or a tease
                // in flight.
                let trackKey = "\(info.title)|\(info.artist)"
                if !info.title.isEmpty,
                   trackKey != lastAnnouncedTrackKey,
                   info.isPlaying,
                   panel.presenter.isResting,
                   !panel.presenter.isShown {
                    lastAnnouncedTrackKey = trackKey
                    panel.presenter.lastAnnouncedTrackArtwork = info.artworkData
                    // Alcove timing (measured from supplied recording):
                    //   • Track changes → ~100ms beat → banner appears
                    //   • Banner sustains ~1500ms
                    //   • Banner dismisses ~250ms
                    //   • Total visible: ~1850ms
                    // User feedback: "alcove one is coming late going
                    // sooner than ours". Prior 3.5s sustain was 2x
                    // too long.
                    //
                    // 250ms pre-show delay — Alcove user feedback
                    // 2026-05-07: "it should be expending few mili
                    // seconds late please just like alcove". Earlier
                    // 100ms wasn't enough of a beat; 250ms gives the
                    // user a clear pause to register the track change
                    // before the banner appears.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak panel] in
                        guard let panel = panel,
                              panel.presenter.isResting,
                              !panel.presenter.isShown else { return }
                        panel.showTrackBanner()
                        panel.presenter.setPendingSystemEvent(
                            .trackChanged(title: info.title, artist: info.artist)
                        )
                    }
                    // Dismiss after total ~2000ms from track-change
                    // emission (250ms delay + 1500ms sustain + 250ms
                    // dismiss spring). PanelPresenter's auto-clear at
                    // 3.0s is the safety net; this dispatched closure
                    // is the source of truth in the normal case.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak panel] in
                        guard let panel = panel else { return }
                        panel.presenter.trackChangedFiring = false
                        panel.dismissTrackBanner {
                            // animated: false is the banner→pill handoff —
                            // the banner already showed the new artwork
                            // inside the flip, so animating the music
                            // pill in again with .softMusicEntrance reads
                            // as a duplicate fade-in glitch. Snap-swap.
                            panel.presenter.clearPendingSystemEvent(animated: false)
                        }
                    }
                } else if trackKey == lastAnnouncedTrackKey,
                          let bytes = info.artworkData,
                          panel.presenter.lastAnnouncedTrackArtwork != info.artworkData {
                    // Spotify two-stage emission: stage 1 has metadata
                    // only (artworkData=nil), stage 2 lands ~50ms later
                    // with the JPEG bytes. The banner captured nil at
                    // trigger time and is showing the placeholder
                    // music.note glyph; update its artwork now so the
                    // banner cuts over to the actual album art mid-
                    // display. Only fires when bytes are non-nil and
                    // actually different — no-op for repeated same-
                    // bytes emissions.
                    _ = bytes
                    panel.presenter.lastAnnouncedTrackArtwork = info.artworkData
                }
            }
        }
        // Nil emission path: leave `presenter.nowPlaying` sticky.
        // Pill visibility is decided below from the live audio signal,
        // not from nowPlaying-nil events. This is the key invariant
        // that lets the slab show "your last track, paused" even
        // after the source app has gone fully silent.

        updatePillVisibility(panel: panel)
    }

    /// Single decision point for "is the small pill currently visible."
    /// Combines CoreAudio's "is audio flowing" with MediaRemote's
    /// "is the source actually playing." Either signal turning false
    /// retracts the pill (after a 1.5s anti-flicker debounce); both
    /// must be true for the pill to bloom.
    ///
    /// Why both:
    ///   • `isAudioFlowing` alone is unreliable for browsers (Chrome
    ///     keeps its audio helper's IO procs alive across pauses, so
    ///     CoreAudio still says "Chrome is producing output" with
    ///     silence flowing — verified in /tmp/notetaker-mra.log).
    ///   • `nowPlaying.isPlaying` alone is unreliable because some
    ///     sources (Discord chime, system tones) don't publish
    ///     MediaRemote info at all — `nowPlaying` is nil and we'd
    ///     never show the pill. The `?? true` default covers those:
    ///     "no MR data → trust the audio signal alone."
    ///
    /// AND'ing them means: pill is up iff something is actively
    /// producing user-perceptible audio.
    private func updatePillVisibility(panel: PanelWindowController) {
        let audioOn = panel.presenter.isAudioFlowing
        let np = panel.presenter.nowPlaying
        let mrSaysPlaying = np?.isPlaying ?? false
        // 2026-05-02 Bluetooth-flicker fix.
        //
        // Log evidence: during stable Bluetooth playback the
        // CoreAudio `isAudioFlowing` signal flickers between true
        // and false (Bluetooth's audio output IO procs cycle as
        // the device's buffer fills). My old logic AND'd audioOn
        // with mrSaysPlaying, so any 1.5s+ false-flicker would
        // collapse the pill while music was clearly still playing.
        //
        // New rule: if MR has rich track info AND says isPlaying=true,
        // trust MR — show the pill regardless of audioOn flickers.
        // MR is the authoritative "is the source app playing" signal;
        // CoreAudio is the corroborator for sources WITHOUT MR data
        // (Discord chimes, system tones).
        //
        // Three buckets:
        //   1. MR says isPlaying=true            → show (Bluetooth-flicker-proof)
        //   2. MR says isPlaying=false           → hide (user paused)
        //   3. No MR data (np==nil) AND audioOn  → show (synthetic case)
        //   4. Otherwise                         → hide
        // Sustained-audio threshold for the no-MR path.
        // CoreAudio reports `isAudioFlowing=true` for any output —
        // including system sounds, popup chimes, app-launch beeps,
        // notification dings — all of which are <1s. Without a
        // sustain check, every system sound briefly blooms the pill.
        //
        //   • If MR has track info → trust MR (skip threshold).
        //   • If no MR but audio just started → start the timer,
        //     don't show pill yet, schedule a re-check after threshold.
        //   • If no MR and audio has been flowing past threshold →
        //     allow the pill (genuinely sustained non-MR audio).
        //   • If audio stops → reset timer.
        let now = Date()
        var noMRGated = false
        if np != nil {
            // MR present — reset no-MR tracking.
            noMRAudioStartedAt = .distantPast
            noMRSustainWork?.cancel()
            noMRSustainWork = nil
        } else if audioOn {
            // No MR, audio flowing — gate behind sustain threshold.
            if noMRAudioStartedAt == .distantPast {
                noMRAudioStartedAt = now
            }
            let sustained = now.timeIntervalSince(noMRAudioStartedAt)
            if sustained < Self.noMRSustainThreshold {
                noMRGated = true
                // Schedule a re-evaluation right when the threshold
                // would be crossed, so genuinely-sustained no-MR audio
                // still gets a pill (we don't depend on a CoreAudio
                // re-emission to land at exactly that moment).
                if noMRSustainWork == nil {
                    let work = DispatchWorkItem { [weak self] in
                        self?.noMRSustainWork = nil
                        if let panel = self?.panelController {
                            self?.updatePillVisibility(panel: panel)
                        }
                    }
                    noMRSustainWork = work
                    let remaining = Self.noMRSustainThreshold - sustained
                    DispatchQueue.main.asyncAfter(deadline: .now() + remaining + 0.05, execute: work)
                }
            }
        } else {
            // Audio off — reset.
            noMRAudioStartedAt = .distantPast
            noMRSustainWork?.cancel()
            noMRSustainWork = nil
        }

        let effectivelyPlaying: Bool = {
            if let np = np {
                return np.isPlaying
            }
            return audioOn && !noMRGated
        }()

        MediaRemoteAdapterService.fileLog("updatePillVisibility: audioOn=\(audioOn) np.title=\"\(np?.title ?? "nil")\" mrSaysPlaying=\(mrSaysPlaying) effectivelyPlaying=\(effectivelyPlaying) noMRGated=\(noMRGated) currentlyResting=\(panel.presenter.isResting)")

        audioFlowingRetractWork?.cancel()
        audioFlowingRetractWork = nil

        if effectivelyPlaying {
            // enterRestingMode is idempotent.
            panel.enterRestingMode()
        } else {
            // 1.5s debounce so brief gaps (track changes, scrubs)
            // don't flicker the pill. After 1.5s of no effective
            // playback the pill collapses to the notch silhouette.
            let work = DispatchWorkItem { [weak self] in
                self?.panelController?.exitRestingMode()
                self?.audioFlowingRetractWork = nil
            }
            audioFlowingRetractWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
        }
    }

    /// Audio-flow signal handler. The actual visibility decision is
    /// made in `updatePillVisibility` which combines `isAudioFlowing`
    /// with `nowPlaying.isPlaying` so paused-but-still-flowing browser
    /// audio (Chrome holds IO procs across pause) doesn't keep the
    /// pill stuck visible.
    private func handleAudioFlowingChange(_ flowing: Bool) {
        guard let panel = panelController else { return }
        updatePillVisibility(panel: panel)
    }

    /// Per Alcove's `transientMediaDurationThreshold` pattern.
    /// Suppresses pill bloom for very short tracks (browser ad
    /// jingles, system sounds, error chimes that get a duration
    /// under 5 seconds) UNLESS they've been playing for at least
    /// 1 second (proving it's not a transient bumper). After 1s
    /// of consecutive play, the pill is allowed to expand.
    ///
    /// Tracks WITHOUT a duration field (most browser audio,
    /// SystemAudioWatcher fallbacks) bypass the filter entirely
    /// — we only have evidence to suppress when we know the
    /// track is genuinely short.
    private func isTransientMedia(_ info: NowPlayingInfo) -> Bool {
        guard let duration = info.duration, duration > 0,
              duration < 5.0 else { return false }
        let trackKey = "\(info.title)|\(info.artist)"
        let now = Date()
        if trackKey == lastTransientTrackKey {
            // Same short track we saw before — has it been playing
            // for the minimum dwell time?
            return now.timeIntervalSince(lastTransientFirstSeenAt) < 1.0
        }
        // New short track — record first-seen timestamp and
        // suppress until min dwell time elapses.
        lastTransientTrackKey = trackKey
        lastTransientFirstSeenAt = now
        return true
    }

    private func grabCurrentBrowserTab() {
        NSLog("nox: ⌥⌘V fired")
        guard let panel = panelController else {
            NSLog("nox: panel nil")
            return
        }
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil"
        NSLog("nox: frontmost=\(front)")
        // Surface the URL via the pending-video pill (with Download
        // button) instead of starting the download immediately. The
        // user has been explicit: nothing should download until they
        // click the Download button on the pill.
        // Per BUG-018 fix: BrowserURLService.currentTabURL is async
        // now (the inner clipboard poll was blocking the main
        // thread for up to 400ms). Wrap in a Task so the hotkey
        // handler returns immediately and the UI doesn't freeze
        // while we wait for the browser to copy the URL.
        Task { @MainActor in
            if let urlString = await BrowserURLService.currentTabURL(),
               let url = URL(string: urlString) {
                NSLog("nox: got URL=\(urlString) — surfacing pending-video pill")
                panel.presenter.setPendingVideo(url)
                panel.enterRestingMode()
            } else {
                NSLog("nox: currentTabURL returned nil")
            }
        }
    }

    private func handleNewScreenshot(at url: URL) {
        NSLog("nox: handleNewScreenshot fired for \(url.path)")
        guard let env = environment, let panel = panelController else {
            NSLog("nox: handleNewScreenshot bail — env or panel nil")
            return
        }
        guard let data = try? Data(contentsOf: url) else {
            NSLog("nox: handleNewScreenshot bail — couldn't read data at \(url.path)")
            return
        }
        let mime = Self.mime(forExtension: url.pathExtension.lowercased())

        let now = Date().timeIntervalSince1970
        recentScreenshots.removeAll { now - $0.time > burstWindow }

        // === FAST PATH: surface the pill BEFORE the save ===
        // Earlier the order was save → setPendingSystemEvent, which
        // made the pop wait on disk I/O even though the user already
        // SAW the screenshot capture. Inverting it: derive the count
        // from the burst window (+1 for THIS shot since we haven't
        // appended yet), set the thumbnail, fire the pill, then do
        // the save. Pill appears in the next render frame instead
        // of after a couple I/O hops.
        let pendingCount = recentScreenshots.count + 1
        // Real thumbnail in the pill. NSImage(data:) is a sync
        // decode but for a typical screenshot (~1-3MB PNG) it's
        // sub-50ms on Apple Silicon — well under the FSEvents
        // latency we just paid to detect the file, so it doesn't
        // add perceptible delay.
        panel.presenter.lastScreenshotThumbnail = NSImage(data: data)
        panel.enterRestingMode()
        panel.presenter.setPendingSystemEvent(.screenshotSaved(count: pendingCount))
        HapticFeedback.generic()

        // === Save (deferred) — happens after the user sees the pill ===
        let id = env.imageStore.saveImageDeferred(
            data: data,
            mimeType: mime,
            noteId: nil,
            source: "screenshot",
            expiresAt: nil
        )
        recentScreenshots.append((time: now, id: id))
    }

    /// Inspect a copied string and return a URL iff it looks like
    /// something we should offer to download — either a yt-dlp
    /// video (YouTube etc.) or a file-host link (Google Drive,
    /// Dropbox, Frame.io, Mega, WeTransfer, Box, OneDrive, iCloud).
    /// The pill's Download button routes through `dispatchDownload`
    /// to either yt-dlp or the user's browser depending on host.
    private static func extractVideoURL(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Reject strings that aren't single-line URLs — if the user
        // copied a paragraph that happens to contain a YouTube link
        // somewhere, they almost certainly want to keep that as a
        // note, not download.
        guard trimmed.contains("://") || trimmed.hasPrefix("www.") else { return nil }
        guard !trimmed.contains("\n"), !trimmed.contains(" ") else { return nil }

        let normalized = trimmed.hasPrefix("http") ? trimmed : "https://" + trimmed
        guard let url = URL(string: normalized),
              let host = url.host?.lowercased()
        else { return nil }

        if VideoDropScanner.videoHosts.contains(host) { return url }
        if Self.isYtdlpFileHost(host) { return url }
        return nil
    }

    /// File-share hosts that yt-dlp's extractors can pull from
    /// directly — same silent download path as YouTube etc., no
    /// browser tab involved. Limited to what yt-dlp actually
    /// handles: Drive and Dropbox. Mega/Frame.io/WeTransfer/Box/
    /// OneDrive/iCloud are deliberately NOT here because there is
    /// no silent path — they'd have required popping a browser tab,
    /// which the user explicitly rejected ("instead of downloading,
    /// it's opening a new tab. Can we avoid that?").
    private static func isYtdlpFileHost(_ host: String) -> Bool {
        if host.hasSuffix("drive.google.com") { return true }
        if host.hasSuffix("dropbox.com") { return true }
        return false
    }

    /// Route the pill's Download tap to yt-dlp via VideoStore. Both
    /// video hosts and the supported file-share hosts go through
    /// the same path — yt-dlp's extractors know how to resolve
    /// each one to a direct file URL, so the actual download is
    /// silent and progress shows up in the Videos tab.
    fileprivate static func dispatchDownload(url: URL, env: AppEnvironment) {
        _ = env.videoStore.startDownload(url: url.absoluteString)
        // Brief "Downloading from <host>" pill flash so the user
        // gets a visual ack right when they tap Download. Mirrors
        // the screenshot pill blip — keeps the interaction
        // grounded with a transient pill morph + haptic.
        if let app = AppDelegate.shared, let panel = app.panelController {
            let host = url.host ?? "download"
            panel.enterRestingMode()
            panel.presenter.setPendingSystemEvent(.downloadStarted(host: host))
            HapticFeedback.generic()
        }
    }

    /// Settings → Bluetooth → Show connect/disconnect pill. Default true.
    /// Centralised here (rather than read inline at every callsite)
    /// because both the connect and disconnect handlers need the same
    /// gate, and we'd rather not have two slightly-different reads
    /// drift apart later.
    private static func bluetoothPillEnabled() -> Bool {
        userDefaultBool(SettingsKey.showBluetoothPill, default: true)
    }

    /// Newest file in ~/Downloads, used by the synthetic AirDrop test
    /// trigger so the pill's UTI glyph (photo / video / pdf / generic)
    /// reflects something the user actually has on disk. Skips
    /// directories and dotfiles. Returns nil if Downloads is empty.
    fileprivate static func mostRecentDownloadURL() -> URL? {
        guard let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        else { return nil }
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isDirectoryKey, .isHiddenKey]
        guard let items = try? fm.contentsOfDirectory(
            at: downloads, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return nil }
        let files = items.filter { url in
            let v = try? url.resourceValues(forKeys: Set(keys))
            return v?.isDirectory == false && v?.isHidden == false
        }
        return files.max { a, b in
            let aDate = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let bDate = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return aDate < bDate
        }
    }

    /// Read a bool from `UserDefaults`, falling back to `default`
    /// when the key has never been written. We can't use plain
    /// `bool(forKey:)` because it returns false for missing keys,
    /// which would silently flip every "default-on" toggle off
    /// for first-launch users. The presence-check via `object(forKey:)`
    /// is the same pattern `HapticFeedback.isEnabled` and the
    /// charging-pill gate use elsewhere in the app.
    fileprivate static func userDefaultBool(_ key: String, default fallback: Bool) -> Bool {
        if UserDefaults.standard.object(forKey: key) == nil { return fallback }
        return UserDefaults.standard.bool(forKey: key)
    }

    private static func mime(forExtension ext: String) -> String {
        switch ext {
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "tiff", "tif": return "image/tiff"
        default: return "image/png"
        }
    }

    private func handleExternalClipboardChange() {
        guard let env = environment, let panel = panelController else { return }

        // If WE are frontmost — i.e. the user is interacting with our own
        // Settings window or panel and just pasted into a SecureField /
        // TextField — auto-saving that paste as a note would leak whatever
        // they typed (e.g. a Gemini API key) into the notes list as plain
        // text. The clipboard monitor's whole point is to capture content
        // the user copied for later reference; pastes INTO our own UI are
        // not that. Bail.
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Bundle.main.bundleIdentifier {
            return
        }

        // Copying inside an editor / IDE / terminal / writing app is just
        // normal editing — the user isn't capturing something to save. Popping
        // the panel here steals focus and breaks Enter / arrow keys in the
        // app they're working in. So we bail early when the frontmost app is
        // one of those.
        if Self.isEditorContext() { return }

        let pb = NSPasteboard.general

        // EXPLICIT-IMAGE-FORMAT-FIRST. Earlier today I made this
        // image-first too aggressively (any image data wins), which
        // misclassified browser TEXT copies as images — Chrome /
        // Safari attach a TIFF preview to ~every text copy, and the
        // pill kept flashing the "screenshot saved" tile on every
        // text Cmd+C. With no music to anchor the resting pill,
        // that read as the jitter the user reported.
        //
        // Correct heuristic: only treat the clipboard as an image
        // if it carries an EXPLICIT image format (PNG / JPEG / GIF /
        // WebP / HEIC). TIFF is excluded here because it's the
        // universal preview-fallback. Real "Copy Image" from a
        // browser still lands as image because Chrome+Safari put
        // PNG (or JPEG) on the pasteboard for genuine image copies,
        // not just the URL string.
        if Self.pasteboardHasExplicitImage(pb),
           let (imageData, mime) = ImageDropExtractor.extract(from: pb) {
            let pendingCount = recentScreenshots.count + 1
            panel.presenter.lastScreenshotThumbnail = NSImage(data: imageData)
            panel.enterRestingMode()
            panel.presenter.setPendingSystemEvent(.screenshotSaved(count: pendingCount))
            HapticFeedback.generic()
            saveClipboardImage(env: env, data: imageData, mime: mime)
            return
        }

        // Otherwise — check text. Browser text copies that ride
        // with a TIFF-preview fallback land here, where they belong.
        let text = pb.string(forType: .string)
        let hasText = text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false

        if hasText, let text = text {
            // Video URL? Don't auto-save as a note AND don't auto-
            // download. Instead, surface a "video detected" preview
            // in the pill with a Download button — the user picks
            // whether to actually fetch it. After 15s with no
            // action, the preview clears and the pill reverts. User
            // explicitly asked for this: "when I'm copying some
            // links, it's automatically downloading the video,
            // which can be problematic ... we need the pill to
            // animate and go, something like a video thumbnail
            // ... and a download button."
            if let videoURL = Self.extractVideoURL(from: text) {
                panel.presenter.setPendingVideo(videoURL)
                panel.enterRestingMode()
                return
            }

            // Settings → Notes → Auto-save copied text. When the
            // user disables this, plain-text clipboard items are
            // ignored entirely (no auto-create, no panel pop) —
            // the user is back to manual paste workflows.
            // Default true for first-launch via the object-presence
            // check that mirrors HapticFeedback's pattern.
            let autoSaveEnabled: Bool = {
                if UserDefaults.standard.object(forKey: "autoSaveCopiedText") == nil { return true }
                return UserDefaults.standard.bool(forKey: "autoSaveCopiedText")
            }()
            guard autoSaveEnabled else { return }

            // Existing-note short-circuit. Don't create a duplicate
            // and don't pop the pill again — user already saw the
            // earlier capture.
            //
            // Earlier rev only matched EXACT body strings, so
            // "hello world" vs "hello world\n" (trailing newline)
            // vs "Hello World" all bypassed the dedupe and stacked
            // up as separate notes. User feedback 2026-05-08:
            // "in notes same thing won't copy twice in 6-7 line".
            // Now we normalize (case-fold + collapse whitespace)
            // and only inspect the most-recent 7 notes — a
            // recent-window check matches the user's intent
            // (don't re-capture something I just captured) and
            // doesn't false-positive on legitimately-repeated
            // text across hours of usage.
            let normalize: (String) -> String = { s in
                s.lowercased()
                    .components(separatedBy: .whitespacesAndNewlines)
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
            }
            let normalizedIncoming = normalize(text)
            let recentDupe = env.noteStore.notes
                .prefix(7)
                .contains { normalize($0.body) == normalizedIncoming }
            if recentDupe { return }
            do {
                // Tag this as a clipboard capture (NOT handwritten).
                // The Notes tab UI segments on this so user can scan
                // their real notes without the URL/snippet noise.
                _ = try env.noteStore.createNote(kind: .clipboard, body: text)
            } catch {
                NSLog("Auto-save clipboard failed: \(error)")
                return
            }
            // Pill morph instead of opening the panel — the user
            // explicitly asked: "for saving copying something it
            // shouldn't open the whole thing, it should react in
            // the pill right?". Same pattern as screenshots: the
            // resting pill flashes a "Note saved" tile, then
            // returns to whatever was there (music, empty, etc).
            panel.enterRestingMode()
            panel.presenter.setPendingSystemEvent(.noteSaved)
            HapticFeedback.generic()
            return
        }

        // No explicit image format AND no text — fall back to TIFF
        // / file-URL paths. This catches the "browser image drag
        // that decided to be TIFF-only with no string companion"
        // edge case without false-positiving on rich-text copies
        // (which always include a string).
        if let (imageData, mime) = ImageDropExtractor.extract(from: pb) {
            let pendingCount = recentScreenshots.count + 1
            panel.presenter.lastScreenshotThumbnail = NSImage(data: imageData)
            panel.enterRestingMode()
            panel.presenter.setPendingSystemEvent(.screenshotSaved(count: pendingCount))
            HapticFeedback.generic()
            saveClipboardImage(env: env, data: imageData, mime: mime)
            return
        }

        // Nothing recognized — don't expand the slab. The previous
        // fall-through called `panel.show()` here, which is exactly
        // why an unclassifiable copy popped the full panel instead
        // of the pill. We ignore unknown clipboard types now: the
        // monitor's job is to capture useful captures, not to react
        // to every changeCount tick.
    }

    /// Whether the pasteboard carries an EXPLICIT image format —
    /// PNG, JPEG, GIF, WebP, or HEIC. TIFF deliberately excluded:
    /// macOS attaches TIFF previews to ~all rich-text copies as a
    /// universal fallback, so reading "has image" off TIFF
    /// presence misclassifies regular browser text copies as
    /// images. The other formats only show up when the user
    /// actually copied a picture.
    private static func pasteboardHasExplicitImage(_ pb: NSPasteboard) -> Bool {
        let explicit: [NSPasteboard.PasteboardType] = [
            .png,
            NSPasteboard.PasteboardType("public.jpeg"),
            NSPasteboard.PasteboardType("com.compuserve.gif"),
            NSPasteboard.PasteboardType("org.webmproject.webp"),
            NSPasteboard.PasteboardType("public.heic")
        ]
        for type in explicit where pb.data(forType: type) != nil {
            return true
        }
        return false
    }

    /// Routes a clipboard image into the same deferred-save path that
    /// file screenshots use, so the user gets the inflight cell + spinner
    /// regardless of how the screenshot was captured.
    private func saveClipboardImage(env: AppEnvironment, data: Data, mime: String) {
        let now = Date().timeIntervalSince1970
        let id = env.imageStore.saveImageDeferred(
            data: data,
            mimeType: mime,
            noteId: nil,
            source: "screenshot-clipboard",
            expiresAt: nil
        )
        recentScreenshots.removeAll { now - $0.time > burstWindow }
        recentScreenshots.append((time: now, id: id))
    }

    private static func tiffToPNG(_ data: Data) -> Data? {
        guard let rep = NSBitmapImageRep(data: data) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    private static func isEditorContext() -> Bool {
        guard let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else {
            return false
        }
        if editorBundleIDs.contains(bundleID) { return true }
        // JetBrains ships a whole family under com.jetbrains.* — catch all.
        if bundleID.hasPrefix("com.jetbrains.") { return true }
        return false
    }

    /// Apps where Cmd+C is almost always "move/duplicate text I'm editing"
    /// rather than "capture something interesting." We suppress the panel
    /// auto-open when any of these is frontmost.
    private static let editorBundleIDs: Set<String> = [
        // Code editors / IDEs
        "com.apple.dt.Xcode",
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.todesktop.230313mzl4w4u92",   // Cursor
        "dev.zed.Zed",
        "dev.zed.Zed-Preview",
        "com.sublimetext.4",
        "com.sublimetext.3",
        "com.panic.Nova",
        "com.barebones.bbedit",
        "com.github.atom",
        "com.macromates.TextMate",
        "io.vscodium.VSCodium",

        // Terminals
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "co.zeit.hyper",
        "com.mitchellh.ghostty",
        "org.alacritty",
        "net.kovidgoyal.kitty",
        "com.github.Tabby",

        // Writing / notes
        "com.apple.TextEdit",
        "com.apple.iWork.Pages",
        "com.apple.Notes",
        "com.microsoft.Word",
        "md.obsidian",
        "notion.id",
        "net.shinyfrog.bear",
        "com.ulyssesapp.mac",
        "pro.writer.mac",                   // iA Writer
        "com.agiletortoise.Drafts-OSX",
        "abnerworks.Typora",
        "com.logseq.logseq",
        "com.luki.craft",

        // Email (Cmd+C here is usually editing a reply)
        "com.apple.mail",
        "com.readdle.smartemail-Mac",       // Spark
        "it.bloop.airmail3",
        "com.microsoft.Outlook",

        // AI desktop apps
        "com.anthropic.claudefordesktop",

        // Design
        "com.figma.Desktop",
        "com.bohemiancoding.sketch3",
        "com.pixelmatorteam.pixelmator.pro",
        "com.adobe.Photoshop",
        "com.adobe.illustrator"
    ]

    // MARK: - Dictation config

    /// Build a `DictationService.Configuration` from UserDefaults
    /// keys the Settings UI writes. Falls back to Groq defaults
    /// for any missing/empty values. Called at AppDelegate launch
    /// AND whenever Settings → Dictation saves.
    static func loadDictationConfig() -> DictationService.Configuration {
        let defaults = UserDefaults.standard
        // API key — Keychain-backed as of 2026-05-02 security audit.
        // Earlier comment ("the key is a free Groq key, not a paid
        // OpenAI key, so the security cost is small") was wrong:
        // even a free Groq key gives an attacker the ability to drain
        // the user's per-key rate limit, fingerprint usage, or pivot
        // if the user reuses keys across services. Migrated to
        // SecureKeyStore (kSecClassGenericPassword,
        // kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly) — not
        // synced via iCloud Keychain, not exported in Time Machine,
        // bound to the nox bundle.
        let apiKey = SecureKeyStore.shared.load(.dictationApiKey) ?? ""
        let provider = defaults.string(forKey: "dictationProvider") ?? "groq"
        let baseDefault: URL
        let modelDefault: String
        let cleanupDefault: String?
        switch provider {
        case "openai":
            baseDefault = URL(string: "https://api.openai.com/v1")!
            modelDefault = "whisper-1"
            cleanupDefault = "gpt-4o-mini"
        case "custom":
            // 2026-05-08 audit M18: previously an empty / whitespace-
            // only custom URL became `URL(string: "")` (= nil) and
            // silently fell back to Groq — the user picked "custom"
            // and got their dictation routed to a different provider
            // without warning. Now we trim, validate the URL parses,
            // and log the fallback so the maintainer can spot
            // configurations that need fixing.
            let rawCustom = (defaults.string(forKey: "dictationCustomURL") ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let parsed = URL(string: rawCustom), !rawCustom.isEmpty,
               (parsed.scheme == "http" || parsed.scheme == "https") {
                baseDefault = parsed
            } else {
                NSLog("nox: provider=custom but dictationCustomURL is empty/invalid (\(rawCustom)) — falling back to Groq. Set a real URL in Settings → Voice → Custom.")
                baseDefault = URL(string: "https://api.groq.com/openai/v1")!
            }
            modelDefault = defaults.string(forKey: "dictationCustomModel") ?? "whisper-large-v3-turbo"
            cleanupDefault = defaults.string(forKey: "dictationCustomCleanupModel")
        default:  // "groq" or anything else
            baseDefault = URL(string: "https://api.groq.com/openai/v1")!
            modelDefault = "whisper-large-v3-turbo"
            cleanupDefault = "llama-3.3-70b-versatile"
        }
        // Allow disabling cleanup pass via the toggle.
        let cleanupEnabled = defaults.object(forKey: "dictationCleanupEnabled") as? Bool ?? true
        // Default to English. Settings exposes a language picker
        // (UserDefaults key `dictationLanguage`) so users dictating
        // in other languages can override.
        let language = defaults.string(forKey: "dictationLanguage") ?? "en"
        // Custom vocabulary — passed to Whisper as the `prompt`
        // field (biases recognition toward listed terms) and
        // appended to the cleanup LLM's system prompt (second
        // line of defense). User edits this in Settings →
        // Dictation. Empty/nil = no vocabulary hint.
        let customVocabulary = defaults.string(forKey: "dictationCustomVocabulary")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Local Whisper toggle. Default ON (true) — privacy +
        // offline + zero per-transcription cost. Users can
        // disable in Settings to fall back to the remote
        // (Groq/OpenAI) path for max accuracy.
        let useLocal: Bool = {
            // Treat unset as true — fresh installs default to local.
            if defaults.object(forKey: "dictationUseLocalWhisper") == nil { return true }
            return defaults.bool(forKey: "dictationUseLocalWhisper")
        }()
        return DictationService.Configuration(
            apiKey: apiKey,
            baseURL: baseDefault,
            transcriptionModel: modelDefault,
            cleanupModel: cleanupEnabled ? cleanupDefault : nil,
            cleanupSystemPrompt: DictationService.Configuration.defaultCleanupPrompt,
            language: language.isEmpty ? nil : language,
            customVocabulary: (customVocabulary?.isEmpty ?? true) ? nil : customVocabulary,
            useLocalWhisper: useLocal
        )
    }
}
