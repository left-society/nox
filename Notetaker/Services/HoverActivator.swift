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
    /// fire `onActivate`. Bumped from 0.12s → 0.20s so the tease has a
    /// perceivable lifetime of its own — at 120ms the user couldn't
    /// distinguish the tease from a hair-trigger full open. The user
    /// described 0.2s as the right reference behavior ("when I'm
    /// placing the cursor for like 0.2 seconds or a little bit longer,
    /// it opens").
    private let dwellSeconds: TimeInterval = 0.20

    /// Lockout window after a fire. Without this, a user who just
    /// dismissed the panel while their cursor still sat in the notch
    /// would see it pop right back open — punishing the very gesture
    /// that hides it.
    private let cooldownSeconds: TimeInterval = 0.6

    /// Hot-zone width centered on the screen's horizontal midpoint.
    /// 220pt comfortably covers the physical notch on every notched
    /// Mac without sprawling far enough that a cursor heading for the
    /// menu's app-name area triggers us.
    private let hotZoneWidth: CGFloat = 220

    // MARK: - State

    private let onTeaseStart: () -> Void
    private let onTeaseEnd: () -> Void
    private let onActivate: () -> Void
    private var monitor: Any?
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
        // We can't touch `@MainActor` state from deinit, but the AppKit
        // APIs below are safe to call from any thread and idempotent
        // against nil — so do best-effort cleanup if `stop()` was missed.
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        if let screenChangeObserver {
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

        monitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            // Global monitors deliver on the main thread but the closure
            // signature isn't `@MainActor`, so hop into the actor explicitly.
            Task { @MainActor in
                self?.handleMouseMoved()
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

        if let screenChangeObserver {
            NotificationCenter.default.removeObserver(screenChangeObserver)
        }
        screenChangeObserver = nil

        cancelTease()
        isInsideZone = false
    }

    // MARK: - Event handling

    private func handleMouseMoved() {
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

        if inside && !isInsideZone {
            isInsideZone = true
            // Cooldown blocks BOTH the tease bloom and the activate.
            // A user who just dismissed wants the panel to stay quiet
            // for the cooldown window — even a pre-bloom would
            // visually punish the dismiss gesture they just made.
            if Date() < cooldownUntil {
                return
            }
            teaseFired = true
            NSLog("Notetaker: HoverActivator → tease")
            onTeaseStart()
            armDwellTimer()
        } else if !inside && isInsideZone {
            isInsideZone = false
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
            // If the cursor left, fall through to cancelTease so the
            // tease bloom collapses cleanly.
            guard let zone = self.currentHotZone(),
                  zone.contains(NSEvent.mouseLocation) else {
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
        let stripBottom = visible.maxY
        let stripTop = frame.maxY
        guard stripTop > stripBottom else {
            cachedHotZone = nil
            return
        }

        let width = min(hotZoneWidth, frame.width)
        let zone = CGRect(
            x: frame.midX - width / 2,
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
