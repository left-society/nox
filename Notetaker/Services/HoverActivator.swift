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
    ///   • 0.12s/0.14s: hair-trigger — every cursor swing past the
    ///     notch popped the panel open.
    ///   • 0.40s: too slow.
    ///   • 0.27s: the working middle ground.
    /// Now reads from `@AppStorage("hoverDwellSeconds")` so users
    /// can dial it from Settings → General → Open delay. Default
    /// stays at 0.27s — the explored sweet spot.
    private var dwellSeconds: TimeInterval {
        let stored = UserDefaults.standard.double(forKey: "hoverDwellSeconds")
        return stored > 0 ? stored : 0.27
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

    init(
        onTeaseStart: @escaping () -> Void,
        onTeaseEnd: @escaping () -> Void,
        onActivate: @escaping () -> Void
    ) {
        self.onTeaseStart = onTeaseStart
        self.onTeaseEnd = onTeaseEnd
        self.onActivate = onActivate
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

        // Listen for display reconfiguration (resolution change, monitor
        // plugged in, lid closed) so a stale rect doesn't cause us to
        // either miss or spuriously fire. We just clear the cache; the
        // next mouse event recomputes lazily.
        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.cachedHotZone = nil
                self?.isInsideZone = false
                self?.cancelTease()
                NSLog("Notetaker: HoverActivator screen params changed, hot zone invalidated")
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

        NSLog("Notetaker: HoverActivator started zone=\(cachedHotZone.map { "\($0)" } ?? "nil")")
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
        guard let zone, zone.width > 0, zone.height > 0 else {
            isInsideZone = false
            cancelTease()
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
                NSLog("Notetaker: HoverActivator → activate (drag fast path)")
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
                NSLog("Notetaker: HoverActivator → tease")
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
            NSLog("Notetaker: HoverActivator → activate")
            self.onActivate()
        }
        dwellWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + dwellSeconds, execute: work)
    }

    // MARK: - Hot-zone geometry

    private func currentHotZone() -> CGRect? {
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

        let width = min(hotZoneWidth, frame.width)
        // Anchor on the actual notch midX, not screen.midX. On
        // some hardware these differ by 0.5–1pt, and on a future
        // off-center notch revision we'd want the hover trigger
        // to follow the cutout regardless. Falls back to
        // `frame.midX` for non-notched displays.
        let cx: CGFloat
        if let leftArea = screen.auxiliaryTopLeftArea,
           let rightArea = screen.auxiliaryTopRightArea {
            cx = (leftArea.maxX + rightArea.minX) / 2
        } else {
            cx = frame.midX
        }
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
