import AppKit

/// Watches the global cursor and drives the two-stage hover-intent
/// gesture: a brief "tease" the moment the cursor enters the notch hot
/// zone, then a full "activate" once the cursor has dwelt long enough
/// to show real intent. Mirrors `com.henrikruscon.Alcove` and Elkhob,
/// which both use this pattern: the panel "moves a little bit" the
/// instant the cursor lands, and only commits to a full bloom after
/// the user holds the cursor still for a beat.
///
/// **Why this exists:** keyboard hotkeys (⌥Space) are great when your
/// hands are already on the keyboard, but a notched MacBook has a
/// natural physical landmark in the middle of the screen that begs to be
/// used as a discoverable trigger. Flicking the cursor into the notch
/// area should reveal the panel without forcing the user to remember a
/// shortcut.
///
/// **Two-stage gesture:** an earlier version fired `onActivate`
/// immediately on the first dwell (120ms) and the user reported it as
/// "that quick second when I place my cursor there" — too eager, no
/// pre-bloom feedback, missed the perceptual rhythm of Alcove. The new
/// flow gives the user a small visual "noticed you" cue on entry, then
/// commits to the full open after a deliberate ~200ms hold.
///
/// **Mechanism:** a global mouse-moved monitor is the cheapest way to
/// observe the cursor without claiming any input — `NSEvent.addGlobal…`
/// only fires for events delivered to *other* apps, which is exactly
/// what we want when our panel is hidden. Each event point-checks the
/// cached hot-zone rect; on entry we fire the tease callback immediately
/// AND arm the dwell timer. On exit we cancel the timer and fire the
/// untease callback. After fire we suppress further activations briefly
/// so dismissing the panel and lingering doesn't bounce it open again.
@MainActor
final class HoverActivator {

    // MARK: - Tunables

    /// How long the cursor must remain inside the hot zone before we
    /// fire `onActivate`. Tuning history:
    ///   • 0.10s: "snappy" — but the reach/tease animation is 0.18s, so
    ///     the open COMMITTED before the reach even finished. The user
    ///     never felt the "notch noticed you, reaching toward you" beat;
    ///     it just blanked open. User 2026-05-22: "opening it too fucking
    ///     fast … give the feeling that apple feel BEFORE opening."
    ///   • 0.22s: deliberately LONGER than the 0.18s reach so it settled
    ///     AND held a ~40ms beat before opening. The user read that beat
    ///     as the open being TWO SEPARATE STEPS — "it nudges, pauses, then
    ///     jumps open" (2026-05-22). The hold WAS the pause.
    ///   • 0.18s (current): matches the reach duration so the open commits
    ///     the instant the reach finishes — no hold, no pause. The reach
    ///     flows straight into the bloom (and the bloom carries a small
    ///     follow-through velocity so the handoff doesn't dip to a stop —
    ///     see `animateOpen`'s initialVelocity). One continuous gesture.
    ///   • Users can still dial it from Settings → General → Open delay
    ///     (slider 0.10–0.60s).
    /// Reads from `@AppStorage("hoverDwellSeconds")` — falling back
    /// to this default when no user override is set.
    private var dwellSeconds: TimeInterval {
        let stored = UserDefaults.standard.double(forKey: "hoverDwellSeconds")
        return stored > 0 ? stored : 0.18
    }

    /// Lockout window after a fire. Without this, a user who just
    /// dismissed the panel while their cursor still sat in the notch
    /// would see it pop right back open — punishing the very gesture
    /// that hides it. 0.35s is short enough that a deliberate
    /// move-out-then-back-in re-engages quickly (the previous 0.6s
    /// felt like the panel was sulking), long enough that an
    /// auto-fire-after-dismiss with a stationary cursor doesn't
    /// happen.
    private let cooldownSeconds: TimeInterval = 0.35

    /// Hot-zone width centered on the screen's horizontal midpoint.
    /// **300pt** — sized to fully cover the resting pill silhouette
    /// (currently 278pt wide) plus a small buffer so the cursor
    /// triggers the tease even at the visible pill edges. User
    /// reported: "even though my cursor is right at the edge it
    /// should respond." Earlier 220pt left ~29pt of pill on each
    /// side outside the hot zone, so cursor at the rounded pill
    /// shoulders silently failed to trigger.
    /// Reads from `@AppStorage("hoverHotZoneWidth")`. Default 300pt
    /// (covers the 278pt resting pill + small buffer).
    private var hotZoneWidth: CGFloat {
        let stored = UserDefaults.standard.double(forKey: "hoverHotZoneWidth")
        return stored > 0 ? CGFloat(stored) : 300
    }

    // MARK: - State

    private let onTeaseStart: () -> Void
    private let onTeaseEnd: () -> Void
    private let onActivate: () -> Void
    private var monitor: Any?
    private var pollTimer: Timer?
    private var dwellWorkItem: DispatchWorkItem?
    private var cachedHotZone: CGRect?
    private var cooldownUntil: Date = .distantPast
    private var isInsideZone: Bool = false
    /// True iff we've fired `onTeaseStart` for the current cursor
    /// session and have NOT yet fired either `onTeaseEnd` (cursor left
    /// before dwell) or `onActivate` (dwell completed). Used to make
    /// sure tease/untease are paired exactly once per session — without
    /// this, a fast wiggle near the zone boundary could fire onTeaseEnd
    /// without a matching onTeaseStart.
    private var teaseFired: Bool = false

    /// Pre-tease entry debounce. Cursor has to dwell at least this
    /// long inside the hot zone before we even FIRE the tease
    /// (which itself is the "small bloom"). Fast cursor sweeps
    /// across the notch — entering and leaving within ~30ms — used
    /// to fire tease+untease in rapid succession, visible as
    /// jittery flicker. 50ms is well below human-perceived "did
    /// I just see something flash?" threshold for deliberate dwells
    /// but well above typical pass-through sweep time.
    private let teaseEntryDebounce: TimeInterval = 0.05
    private var teaseEntryWorkItem: DispatchWorkItem?
    private var screenChangeObserver: NSObjectProtocol?

    // MARK: - Lifecycle

    /// Returns true when there's a visible music pill anchored at
    /// the notch (resting + nowPlaying). Drives the hot-zone width
    /// — wide enough to cover the pill artwork + waveform wings
    /// when music is playing, narrow enough to match the actual
    /// notch hardware when no pill is visible. Default returns
    /// false so existing call sites are unaffected.
    private let isMusicPillVisible: () -> Bool

    /// Cached music-pill state from the last hot-zone resolution.
    /// Used to invalidate `cachedHotZone` when the user starts /
    /// stops music — otherwise the zone width would stay frozen
    /// at whatever state was current when the cache last filled,
    /// and "music started but zone is still narrow" / "music
    /// stopped but zone is still wide" mismatches would surface.
    private var lastKnownMusicState: Bool = false

    init(
        onTeaseStart: @escaping () -> Void,
        onTeaseEnd: @escaping () -> Void,
        onActivate: @escaping () -> Void,
        isMusicPillVisible: @escaping () -> Bool = { false }
    ) {
        self.onTeaseStart = onTeaseStart
        self.onTeaseEnd = onTeaseEnd
        self.onActivate = onActivate
        self.isMusicPillVisible = isMusicPillVisible
    }

    deinit {
        // Per BUG-017 fix: `NSEvent.removeMonitor` is documented as
        // being called from the same thread the monitor was added
        // on (main, since this class is `@MainActor`). deinit can
        // run on ANY thread — calling removeMonitor directly here
        // is undefined behavior and produced occasional crashes
        // during process shutdown. Dispatch the removal to the
        // main queue: the monitor reference is captured by value
        // (it's an opaque pointer NSEvent owns), so it's safe to
        // call after `self` is freed.
        if let monitor = monitor {
            DispatchQueue.main.async {
                NSEvent.removeMonitor(monitor)
            }
        }
        if let screenChangeObserver = screenChangeObserver {
            NotificationCenter.default.removeObserver(screenChangeObserver)
        }
    }

    /// Begin watching for cursor entry into the notch hot zone. Safe to
    /// call repeatedly — re-entry replaces the previous monitor so
    /// callers don't have to track started/stopped state themselves.
    func start() {
        stop()

        recomputeHotZone()

        // 2026-05-21 — FIRST-LAUNCH FIX. `currentHotZone()` caches the
        // computed zone permanently (invalidated only on a screen-
        // params change). On a FRESH INSTALL the screen's notch
        // geometry isn't ready when start() first runs: NSScreen's
        // `auxiliaryTopLeftArea` / `auxiliaryTopRightArea` are nil and
        // `visibleFrame` may not yet exclude the menu bar, so the very
        // first computed zone is wrong — and it sticks, because no
        // screen-params notification fires on a quiet single-display
        // boot. Result: the cursor never registers in the (wrong) zone
        // and the notch "doesn't respond at all" until the app is
        // relaunched. User report: "right after installing it acts bad."
        //
        // Fix: invalidate the cache a few times over the first few
        // seconds so the zone recomputes once CoreGraphics has
        // populated the notch geometry. Cheap (a couple of NSScreen
        // reads) and self-correcting — by 3s the screen is always
        // settled. The screen-params observer below still handles
        // later display changes.
        for delay in [0.5, 1.5, 3.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.cachedHotZone = nil
            }
        }

        // Listen for display reconfiguration (resolution change, monitor
        // plugged in, lid closed) so a stale rect doesn't cause us to
        // either miss or spuriously fire. We just clear the cache; the
        // next mouse event recomputes lazily.
        //
        // 2026-05-16: do NOT reset `isInsideZone` here. Earlier this
        // observer cleared `isInsideZone` and cancelled the tease on
        // every screen-parameters notification — but iPhone
        // Continuity / AirPlay / Bluetooth-display sessions on
        // macOS fire that notification while the cursor sits
        // unchanged inside the notch zone. The forced reset made
        // the next 250ms poll see `inside=true && !isInsideZone`
        // and re-fire the entire tease → dwell → activate chain
        // ~400ms after the iPhone event, opening the slab without
        // any cursor movement. User report 2026-05-16: "it just
        // opens a black window without taking my cursor … happens
        // when I use my phone connected to the mac or when I leave
        // the phone."
        //
        // Just invalidating the cache is enough — `handleMouseMoved`
        // re-evaluates `inside` against the new zone on its next
        // tick. If the cursor genuinely left, the existing exit
        // branch sets `isInsideZone = false` and untease fires. If
        // the cursor is still inside (the iPhone-event case), state
        // stays correct and no spurious activate fires.
        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.cachedHotZone = nil
                // 2026-05-24 stability fix — was a hot-path NSLog firing on
                // every display reconfigure (Continuity, AirPlay,
                // brightness change, fullscreen toggle). NSLog is a
                // synchronous syslog IPC call and can stall the main
                // thread mid-animation. Compiled out in Release.
                #if DEBUG
                NSLog("nox: HoverActivator screen params changed, hot zone invalidated")
                #endif
            }
        }

        // Listen for BOTH plain mouse-moved AND drag-in-progress events.
        // During a file drag from Finder/Photos/etc the cursor emits
        // `.leftMouseDragged` events (NOT `.mouseMoved`), so a
        // mouse-moved-only monitor would miss drags entering the notch
        // zone — the drop picker would never appear because the panel
        // never woke up. User reported "when I'm dragging something it
        // should open two sides for save / airdrop — these features
        // are basically gone." The fix is monitoring both event types.
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        monitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            // Capture the event TYPE before hopping to the main actor —
            // `.leftMouseDragged` definitively means a drag is in
            // progress, and we use that to skip the dwell timer so the
            // drop picker appears in time for the drag gesture.
            // pressedMouseButtons isn't always reliable from a global
            // monitor's perspective (depends on accessibility perms),
            // so the event type is the more dependable signal.
            let isDragEvent = (event.type == .leftMouseDragged)
            Task { @MainActor in
                self?.handleMouseMoved(isDragEvent: isDragEvent)
            }
        }

        // Periodic safety poll. Global mouse monitors only fire when
        // the cursor MOVES — if the user dismisses the panel and
        // their cursor is already inside the hot zone, no further
        // event arrives until they wiggle, and the activator never
        // detects "the cursor is sitting inside, fire the tease."
        // User reported: "cursor stay there for a good amount of
        // time isn't registering and the thing is not opening."
        //
        // Per BUG-016 fix: bumped from 60ms (~17Hz, ~1.4M wakeups
        // per day) to 250ms (4Hz, 345K wakeups per day) — about
        // a 4× drop in polling cost. 250ms is still well below
        // the perceptual threshold for "cursor stayed there a
        // moment, why isn't the panel opening?" (humans don't
        // notice sub-quarter-second response delay on hover-
        // triggered UI). mouseLocation is a cheap syscall but
        // 17Hz forever-on-laptop is a real battery cost; 4Hz is
        // the sweet spot between battery and responsiveness.
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.handleMouseMoved(isDragEvent: false)
            }
        }

        // 2026-05-24 stability — start() is per-app-launch (not hot),
        // but a synchronous NSLog at app launch contends with other
        // start-up work. Compiled out in Release.
        #if DEBUG
        NSLog("nox: HoverActivator started zone=\(cachedHotZone.map { "\($0)" } ?? "nil")")
        #endif
    }

    /// Tear down the global monitor and any pending dwell work. Idempotent.
    /// Fires `onTeaseEnd` if a tease was outstanding, so the panel side
    /// can collapse the pre-bloom rather than getting orphaned half-open.
    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil

        pollTimer?.invalidate()
        pollTimer = nil

        if let screenChangeObserver {
            NotificationCenter.default.removeObserver(screenChangeObserver)
        }
        screenChangeObserver = nil

        cancelTease()
        isInsideZone = false
    }

    // MARK: - Event handling

    private func handleMouseMoved(isDragEvent: Bool = false) {
        let zone = currentHotZone()
        // Defensive: during display reconfigure or weird multi-monitor
        // states the screen frame could briefly be empty. Don't ever
        // fire from a zero-size rect (which would either match nothing
        // or — worse — match the origin point).
        //
        // 2026-05-16: do NOT reset `isInsideZone` when the zone is
        // transiently unavailable. iPhone Continuity / AirPlay /
        // Bluetooth-audio handoff briefly destabilizes the display
        // graph, and `recomputeHotZone()` returns nil for a tick or
        // two before the screen settles. The old reset turned that
        // momentary nil into a "cursor just left the zone" state,
        // and the very next 250ms poll (now with zone re-available)
        // saw `inside=true && !isInsideZone` and re-fired the entire
        // tease → dwell → activate chain ~400ms after the iPhone
        // event — opening the slab with no cursor movement. User
        // report 2026-05-16: "it just opens a black window without
        // taking my cursor." Bailing without state change lets the
        // next tick see the restored zone and find the cursor still
        // inside it; no spurious activate fires.
        guard let zone, zone.width > 0, zone.height > 0 else {
            return
        }

        let location = NSEvent.mouseLocation
        let inside = zone.contains(location)

        // Detect drag-in-progress two ways for reliability:
        //   1. Event type: this call came from a `.leftMouseDragged`
        //      event — definitively a drag.
        //   2. Polled state: NSEvent.pressedMouseButtons bit 0
        //      means left button is currently down.
        // Either signal is sufficient. Need both because:
        //   • Event-type catches drags from other apps reliably
        //     (drag events fire even without accessibility perms).
        //   • Polled state covers the periodic timer wake-ups
        //     (which don't have an event to inspect).
        //
        // The normal hover flow has ~50ms entry debounce + 270ms
        // dwell + ~270ms show animation = ~600ms before the drop
        // picker appears. That's longer than most drag gestures
        // last — by the time the picker would render, the user
        // has already released the mouse.
        //
        // Fix: when a drag is in progress, skip both debounces and
        // fire activate() IMMEDIATELY on cursor entry. The user's
        // intent is clear (they're holding a file and aiming at
        // the notch), so dwell-protection isn't needed — open
        // straight to the slab + drop picker.
        let isDragging = isDragEvent || (NSEvent.pressedMouseButtons & 1) != 0

        // 2026-05-22: removed the per-move diagnostic NSLogs from this hot
        // path. They fired on every zone change / tease / activate — i.e.
        // on the exact frames the "reach" animates — and NSLog does
        // synchronous I/O. The smoothness report flagged this as hover-path
        // overhead; dropping it keeps the reach clean (Alcove's hover is
        // event-driven controller state with no logging in the loop).
        if inside && !isInsideZone {
            isInsideZone = true
            // Cooldown blocks BOTH the tease bloom and the activate.
            if Date() < cooldownUntil {
                return
            }

            if isDragging {
                // Drag-in-progress fast path. Skip tease + dwell
                // entirely; jump straight to activate. The slab
                // opens immediately so AppKit drag tracking can
                // route the in-flight drag into the panel and the
                // DropPickerView renders in time for the user to
                // drop on a zone.
                cooldownUntil = Date().addingTimeInterval(cooldownSeconds)
                onActivate()
                return
            }

            // Normal hover flow — schedule the tease via a small
            // entry-debounce. A fast cursor sweep that enters the
            // zone and leaves within `teaseEntryDebounce` (50ms)
            // gets cancelled before any visible tease ever fires.
            teaseEntryWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.isInsideZone, !self.teaseFired else { return }
                self.teaseFired = true
                self.onTeaseStart()
                self.armDwellTimer()
            }
            teaseEntryWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + teaseEntryDebounce, execute: work)
        } else if !inside && isInsideZone {
            isInsideZone = false
            // Cancel the pending tease entry (if any) — fast cursor
            // pass doesn't even register as a tease event.
            teaseEntryWorkItem?.cancel()
            teaseEntryWorkItem = nil
            cancelTease()
        }
        // If still-inside or still-outside, let the existing timer (if any)
        // run its course — we don't reset on every wiggle, otherwise a
        // jittery hand could indefinitely postpone activation.
    }

    /// Tear down any pending dwell work and untease the panel iff we
    /// previously fired `onTeaseStart` for this hover session. Centralized
    /// so every exit path (cursor leaves, screen reconfigure, monitor
    /// stop) keeps tease/untease perfectly paired — without this guard,
    /// a partial state could leak a permanent pre-bloom to the panel.
    private func cancelTease() {
        dwellWorkItem?.cancel()
        dwellWorkItem = nil
        if teaseFired {
            teaseFired = false
            onTeaseEnd()
        }
    }

    private func armDwellTimer() {
        dwellWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // Re-check that the cursor is still in the zone — a fast
            // diagonal flick can fire .mouseMoved events with the
            // cursor briefly inside, then leave before the next event
            // comes through. mouseLocation gives us ground truth.
            //
            // Use a 6pt tolerance — if the cursor is ALMOST inside
            // (within 6pt of the zone), still trigger. Without
            // tolerance, sub-pixel cursor jitter near the boundary
            // can cause tease-then-immediately-cancel cycles where
            // the user perceives "hover never opened the panel."
            guard let zone = self.currentHotZone() else {
                self.isInsideZone = false
                self.cancelTease()
                return
            }
            let loc = NSEvent.mouseLocation
            let tolerantZone = zone.insetBy(dx: -6, dy: -6)
            guard tolerantZone.contains(loc) else {
                self.isInsideZone = false
                self.cancelTease()
                return
            }
            // The activation "consumes" the tease — clear `teaseFired`
            // so a later cursor exit (now happening AFTER the panel
            // has fully bloomed open) doesn't fire onTeaseEnd. The
            // full panel owns its own dismiss flow once activated.
            self.teaseFired = false
            self.dwellWorkItem = nil
            self.cooldownUntil = Date().addingTimeInterval(self.cooldownSeconds)
            self.onActivate()
        }
        dwellWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + dwellSeconds, execute: work)
    }

    // MARK: - Hot-zone geometry

    private func currentHotZone() -> CGRect? {
        // 2026-05-24 — invalidate the cache when the music state
        // transitions. The hot-zone width depends on whether a
        // music pill is visible (wide cover for pill + wings vs
        // narrow notch-hardware match), so a state change requires
        // a recompute even when no screen-params event fires.
        let currentMusic = isMusicPillVisible()
        if currentMusic != lastKnownMusicState {
            lastKnownMusicState = currentMusic
            cachedHotZone = nil
        }
        if let cachedHotZone {
            return cachedHotZone
        }
        recomputeHotZone()
        return cachedHotZone
    }

    private func recomputeHotZone() {
        // Prefer a notched display; fall back to the main screen so the
        // gesture still works on non-notched Macs (the menu-bar strip
        // there is still a sensible "throw the cursor up there" target).
        let screen = NSScreen.screens.first(where: { screenHasNotch($0) }) ?? NSScreen.main
        guard let screen else {
            cachedHotZone = nil
            return
        }

        let frame = screen.frame
        let visible = screen.visibleFrame

        // The menu-bar strip lives between visibleFrame.maxY and
        // frame.maxY. NSEvent.mouseLocation is in the same screen
        // coordinate space (origin bottom-left), so this rect can be
        // hit-tested against it directly.
        //
        // Extend the rect 8pt DOWN past visibleFrame.maxY so cursor
        // flicks that land just below the menu bar still trigger —
        // people aren't pixel-precise when throwing the cursor at
        // the notch. Plus 4pt UP past frame.maxY (technically off
        // screen, but `NSEvent.mouseLocation` can return values at
        // the screen edge that CGRect.contains excludes due to
        // half-open interval). User reported: "mouse is not
        // registering sometimes when i go with my mouse inside of
        // the pill fast." This was the boundary-precision case.
        let stripBottom = visible.maxY - 8
        let stripTop = frame.maxY + 4
        guard stripTop > stripBottom else {
            cachedHotZone = nil
            return
        }

        // Anchor on the actual notch midX, not screen.midX. On
        // some hardware these differ by 0.5–1pt, and on a future
        // off-center notch revision we'd want the hover trigger
        // to follow the cutout regardless. Falls back to
        // `frame.midX` for non-notched displays.
        let cx: CGFloat
        let actualNotchWidth: CGFloat?
        if let leftArea = screen.auxiliaryTopLeftArea,
           let rightArea = screen.auxiliaryTopRightArea {
            cx = (leftArea.maxX + rightArea.minX) / 2
            actualNotchWidth = rightArea.minX - leftArea.maxX
        } else {
            cx = frame.midX
            actualNotchWidth = nil
        }

        // 2026-05-24 — state-aware hot zone width. User feedback:
        // "cursor should trigger anything when it reachs the notch,
        // the real notch. it's getting triggered by going the
        // cursor to the side of the notch. i think the zone is
        // there is from the music state not the no music state."
        //
        // The default 300pt zone was sized to fully cover the
        // resting MUSIC pill (artwork + waveform wings, ~278pt
        // total). When there's no music, no pill is visible —
        // just the physical notch hardware (~178-188pt on M-series
        // MacBooks). A 300pt zone in that state extends ~50pt
        // past each notch edge, firing on cursor passes that
        // weren't aiming at the notch at all.
        //
        // Music playing → use the user-tunable hotZoneWidth (300pt
        //                 default — covers the pill, generous).
        // No music     → use the ACTUAL notch hardware width plus
        //                 a small 16pt buffer (8pt each side) so
        //                 cursor near-misses still trigger but
        //                 sub-cursor flicks to either side don't.
        let baseWidth = hotZoneWidth
        let resolvedWidth: CGFloat
        if isMusicPillVisible() {
            resolvedWidth = baseWidth
        } else if let notch = actualNotchWidth, notch > 0 {
            resolvedWidth = notch + 16
        } else {
            // Non-notched display fallback — keep the configured
            // width since there's no hardware constraint to read.
            resolvedWidth = baseWidth
        }
        let width = min(resolvedWidth, frame.width)

        let zone = CGRect(
            x: cx - width / 2,
            y: stripBottom,
            width: width,
            height: stripTop - stripBottom
        )
        cachedHotZone = zone
    }

    private func screenHasNotch(_ screen: NSScreen) -> Bool {
        // `safeAreaInsets` is the modern signal for "this screen has a
        // notch" — non-notched screens report .zero. Available since
        // macOS 12, well below our deployment target.
        screen.safeAreaInsets.top > 0
    }
}
