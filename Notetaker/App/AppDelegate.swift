import AppKit
import SwiftUI
import Combine

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
    /// Lock-screen music card (separate NSPanel, attached to the
    /// SkyLight space at level 400 alongside the main notch panel).
    /// Created lazily after `panelController` exists so it can share
    /// the same `PanelPresenter` for now-playing data.
    var lockMusicCard: LockMusicCardWindowController?
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self
        NSApp.setActivationPolicy(.accessory)

        do {
            let env = try AppEnvironment()
            self.environment = env
            env.retentionService.start()
            env.bluetoothDeviceService.start()
            // Wire connect/disconnect HUD pills. When a device
            // appears in the connected list (after the initial
            // poll completes), show a brief pill with the device
            // name. Same for disconnect. These flow through the
            // pendingSystemEvent pipeline like charging /
            // screenshot pills, so they share the same morph
            // animation system.
            env.bluetoothDeviceService.onDeviceConnected = { [weak self] device in
                guard Self.bluetoothPillEnabled() else { return }
                self?.panelController?.presenter.setPendingSystemEvent(
                    .bluetoothConnected(deviceName: device.name, isAirPods: device.isAirPods)
                )
                HapticFeedback.bluetoothChange()
            }
            env.bluetoothDeviceService.onDeviceDisconnected = { [weak self] device in
                guard Self.bluetoothPillEnabled() else { return }
                self?.panelController?.presenter.setPendingSystemEvent(
                    .bluetoothDisconnected(deviceName: device.name, isAirPods: device.isAirPods)
                )
                HapticFeedback.bluetoothChange()
            }
            panelController = PanelWindowController(environment: env)
            // Lock-screen music card: a second NSPanel attached to
            // the SkyLight space at level 400, visible when locked
            // AND something is playing. Shares the main panel's
            // presenter so the card observes the same now-playing
            // data the desktop pill does.
            if let presenter = panelController?.presenter {
                lockMusicCard = LockMusicCardWindowController(presenter: presenter)
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
        } catch {
            NSLog("Notetaker failed to initialize: \(error)")
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

        hotkeyService = HotkeyService { [weak self] event in
            switch event {
            case .togglePanel:
                NSLog("Notetaker: toggle() called, panel=\(self?.panelController != nil ? "exists" : "nil")")
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

        orchestrator.start()
        self.notchOrchestrator = orchestrator

        // Dev-only: auto-show the panel on launch for visual verification.
        if ProcessInfo.processInfo.environment["NOTETAKER_AUTOSHOW"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.panelController?.show()
            }
        }

        // Dev-only: self-trigger a download so we can verify the pipeline
        // without having to drive a browser hotkey. Set NOTETAKER_TEST_URL
        // in the Xcode scheme or launch env to exercise the code path.
        if let testURL = ProcessInfo.processInfo.environment["NOTETAKER_TEST_URL"],
           !testURL.isEmpty {
            NSLog("Notetaker: NOTETAKER_TEST_URL set — firing startDownload in 1.5s for \(testURL)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.environment?.videoStore.startDownload(url: testURL)
                self?.panelController?.showOnTab(.videos)
            }
        }
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
        NSLog("Notetaker: openSettings() entered, env=\(environment != nil), cached=\(settingsWindow != nil)")
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
            NSLog("Notetaker: openSettings called before environment ready")
            return
        }

        let host = NSHostingController(rootView: SettingsView().environmentObject(env))
        let window = NSWindow(contentViewController: host)
        window.title = "Notetaker Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("NotetakerSettingsWindow")
        // Drop back to menu-bar-only when the user closes Settings, so
        // we don't strand a Dock icon for an `LSUIElement` app.
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { _ in
            Task { @MainActor in
                NSApp.setActivationPolicy(.accessory)
            }
        }
        settingsWindow = window
        window.makeKeyAndOrderFront(nil)
        NSLog("Notetaker: settings window ordered front, level=\(window.level.rawValue) visible=\(window.isVisible)")
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
        // Cancel any pending nil-teardown. If we're getting a non-nil,
        // music's still alive; if we're getting another nil, restart
        // the debounce window so we don't fire halfway through.
        nowPlayingNilDebounce?.cancel()
        nowPlayingNilDebounce = nil

        if let info = info {
            // Music alive — propagate immediately and ensure the pill
            // is showing. Idempotent on repeated calls (enterRestingMode
            // is a no-op when already resting).
            panel.presenter.nowPlaying = info
            panel.enterRestingMode()
            return
        }

        // Nil emission — schedule a debounced teardown. If a non-nil
        // arrives within 4s, this work item is cancelled above and the
        // pill never disappears. 4s is generous enough to cover Safari
        // tab transitions, audio-session preemptions, and our own
        // panel-internal video-preview plays. Longer would feel
        // sticky after a true playback stop; shorter would let
        // transient gaps still collapse the pill.
        let work = DispatchWorkItem { [weak self, weak panel] in
            guard let self, let panel else { return }
            // Re-check guard: if something else nudged the panel
            // out of resting mode in the meantime, don't double-act.
            if panel.presenter.nowPlaying != nil || panel.presenter.isResting == false {
                // Either music came back through a path that bypassed
                // this debounce, or the pill was already torn down
                // somewhere else. Either way, nothing to do here —
                // just clean up our reference.
                self.nowPlayingNilDebounce = nil
                return
            }
            panel.presenter.nowPlaying = nil
            panel.exitRestingMode()
            self.nowPlayingNilDebounce = nil
        }
        nowPlayingNilDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0, execute: work)
    }

    private func grabCurrentBrowserTab() {
        NSLog("Notetaker: ⌥⌘V fired")
        guard let env = environment, let panel = panelController else {
            NSLog("Notetaker: env or panel nil")
            return
        }
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil"
        NSLog("Notetaker: frontmost=\(front)")
        if let urlString = BrowserURLService.currentTabURL() {
            NSLog("Notetaker: got URL=\(urlString)")
            env.videoStore.startDownload(url: urlString)
        } else {
            NSLog("Notetaker: currentTabURL returned nil")
        }
        panel.showOnTab(.videos)
    }

    private func handleNewScreenshot(at url: URL) {
        NSLog("Notetaker: handleNewScreenshot fired for \(url.path)")
        guard let env = environment, let panel = panelController else {
            NSLog("Notetaker: handleNewScreenshot bail — env or panel nil")
            return
        }
        guard let data = try? Data(contentsOf: url) else {
            NSLog("Notetaker: handleNewScreenshot bail — couldn't read data at \(url.path)")
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

        // Text FIRST. Browser text copies (and most rich-text copies)
        // ride on the pasteboard with a TIFF preview attached as a
        // rich-text fallback — if we check images first we'd misroute
        // a normal Cmd+C into the slow image-save path, which is what
        // made copies feel sluggish and "not registered." Only fall
        // through to the image branch when there's no meaningful text.
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
            if env.noteStore.notes.contains(where: { $0.body == text }) {
                return
            }
            do {
                let note = try env.noteStore.createNote()
                try env.noteStore.updateBody(id: note.id, body: text)
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

        // No text on the pasteboard → either Ctrl+Shift+Cmd+3/4 (macOS
        // clipboard screenshot) or "Copy Image" from a browser. Both
        // give us image data with no string companion, so this branch
        // is safe.
        if let pngData = pb.data(forType: .png) {
            // Same fast-path inversion as handleNewScreenshot:
            // pill flash + thumbnail fire BEFORE the deferred save.
            let pendingCount = recentScreenshots.count + 1
            panel.presenter.lastScreenshotThumbnail = NSImage(data: pngData)
            panel.enterRestingMode()
            panel.presenter.setPendingSystemEvent(.screenshotSaved(count: pendingCount))
            HapticFeedback.generic()
            saveClipboardImage(env: env, data: pngData, mime: "image/png")
            return
        }
        if let tiffData = pb.data(forType: .tiff),
           let pngData = Self.tiffToPNG(tiffData) {
            let pendingCount = recentScreenshots.count + 1
            panel.presenter.lastScreenshotThumbnail = NSImage(data: pngData)
            panel.enterRestingMode()
            panel.presenter.setPendingSystemEvent(.screenshotSaved(count: pendingCount))
            HapticFeedback.generic()
            saveClipboardImage(env: env, data: pngData, mime: "image/png")
            return
        }

        if !panel.isVisible {
            panel.show()
        }
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
}
