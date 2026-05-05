import AppKit
import SwiftUI

/// Menu-bar status item. Left-click toggles the notch panel,
/// right-click opens a menu with timer presets and a cancel
/// affordance. The right-click menu is rebuilt on every show
/// (`menuNeedsUpdate`) so the cancel item only appears when a
/// timer is actually running.
///
/// Per BUG-041 fix: marked `@MainActor`. NSStatusBar /
/// NSStatusItem APIs touch AppKit and must be used from the
/// main thread. The closure properties (`onClick`,
/// `onStartTimer`, etc.) are also stored in instance state
/// that the read paths in `handleClick` etc. dereference —
/// without actor isolation, a future caller setting them
/// from a non-main context would race with reads. In
/// practice all current callers are AppDelegate (which is
/// already @MainActor) so the existing code is safe; this
/// annotation prevents future regressions.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let onClick: () -> Void

    /// Closures the AppDelegate installs to drive the timer.
    /// Optional so the controller works standalone; if no
    /// closures are wired, the timer menu items just no-op.
    var onStartTimer: ((TimeInterval) -> Void)?
    var onCancelTimer: (() -> Void)?
    var isTimerRunning: () -> Bool = { false }

    /// Wired to AppDelegate to fire a synthetic pill of the given
    /// kind. Lets the user verify each pill's appearance without
    /// having to trigger the real-world event (charge/unplug,
    /// connect AirPods, receive an AirDrop, etc.). Only exposed
    /// in the right-click menu.
    var onTriggerTestPill: ((TestPill) -> Void)?

    enum TestPill {
        case charging
        case bluetoothConnected
        case bluetoothDisconnected
        case timerFinished
        case calendarUpcoming
        case airDropReceived
        case noteSaved
    }

    init(onClick: @escaping () -> Void) {
        self.onClick = onClick
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            // 2026-05-02: replaced the leftover Notetaker
            // `square.and.pencil` SF Symbol with the nox brand
            // mark — the same ring-with-notch silhouette as the
            // app icon, rendered as a template image so macOS
            // adapts it to the menu bar's tint (white in dark mode,
            // black in light). Rendered from the SwiftUI NoxGlyph
            // view via ImageRenderer so the silhouette matches
            // every other place the brand mark appears in the app.
            button.image = Self.makeMenuBarIcon()
            button.image?.isTemplate = true
            button.image?.accessibilityDescription = "nox"
            button.target = self
            button.action = #selector(handleClick)
            // Receive both left- and right-click events so we can
            // route them differently. Default mask is just
            // .leftMouseUp, which makes right-click a no-op.
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    /// Renders `NoxGlyph` to an NSImage sized for the menu bar.
    /// Uses pure black so `isTemplate = true` lets macOS auto-tint
    /// based on menu bar appearance (white on dark menu bar, black
    /// on light).
    ///
    /// 2026-05-02: shrunk from 20pt → 18pt outer frame with the
    /// glyph itself drawn at 13pt centered, giving ~2.5pt padding
    /// around the ring. The earlier 20pt edge-to-edge rendering was
    /// noticeably bigger than neighboring SF Symbols (WiFi, Battery,
    /// Control Center) which conventionally occupy ~13–14pt of
    /// visual content inside an 18pt slot. Stroke also dropped to
    /// 1.3pt to match SF Symbol body weight at this scale.
    private static func makeMenuBarIcon() -> NSImage? {
        let glyph = NoxGlyph(size: 13, lineWidth: 1.3, tint: .black)
            .frame(width: 18, height: 18)
        let renderer = ImageRenderer(content: glyph)
        renderer.scale = 2  // @2x for crisp display
        guard let cg = renderer.cgImage else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: 18, height: 18))
    }

    @objc private func handleClick() {
        guard let event = NSApp.currentEvent else { onClick(); return }
        if event.type == .rightMouseUp {
            showContextMenu()
        } else {
            onClick()
        }
    }

    private func showContextMenu() {
        let menu = NSMenu()
        menu.delegate = self
        // Build now (instead of after a click) so the menu has its
        // items by the time popUp is called — the delegate's
        // `menuNeedsUpdate(_:)` rebuilds the contents on every show.
        menuNeedsUpdate(menu)

        // Pop the menu directly at the status item's button. The
        // earlier approach (set `statusItem.menu`, then synthesize
        // `performClick(nil)`) was unreliable: AppKit's status-item
        // event loop intermittently swallowed the synthesized click,
        // leaving the right-click silent — which the user reported
        // as "none of these features are working" because the timer
        // presets live in this menu.
        //
        // `popUp(positioning:at:in:)` shows the menu synchronously
        // at a precise location in the button's coordinate space —
        // works on every right-click without the racy `performClick`
        // hop. The chosen origin is the button's bottom-left corner
        // so the menu drops down from under the status icon, the
        // standard macOS menu placement.
        guard let button = statusItem.button else { return }
        let origin = NSPoint(x: 0, y: button.bounds.height + 4)
        menu.popUp(positioning: nil, at: origin, in: button)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        // Open / toggle panel (matches left-click behavior).
        let openItem = NSMenuItem(title: "Open nox", action: #selector(handleOpen), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        menu.addItem(.separator())

        // Timer submenu — five common Pomodoro durations plus a
        // cancel item when one is active.
        let timerHeader = NSMenuItem(title: "Timer", action: nil, keyEquivalent: "")
        timerHeader.isEnabled = false
        menu.addItem(timerHeader)
        let presets: [(String, TimeInterval)] = [
            ("5 minutes", 5 * 60),
            ("10 minutes", 10 * 60),
            ("15 minutes", 15 * 60),
            ("25 minutes", 25 * 60),
            ("45 minutes", 45 * 60)
        ]
        for (title, duration) in presets {
            let item = NSMenuItem(title: title, action: #selector(handleStartTimer(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = duration
            menu.addItem(item)
        }
        if isTimerRunning() {
            menu.addItem(.separator())
            let cancel = NSMenuItem(title: "Cancel Timer", action: #selector(handleCancelTimer), keyEquivalent: "")
            cancel.target = self
            menu.addItem(cancel)
        }

        // Debug pill testing. Lets the user fire any of the new pills
        // synthetically — no need to actually trigger the underlying
        // event (plug a charger, AirDrop a file, finish a timer, etc.)
        // to see the animation. The submenu is always present so this
        // also works as a quick way to verify the animations after a
        // build without setting up real triggers.
        menu.addItem(.separator())
        let testHeader = NSMenuItem(title: "Test pill", action: nil, keyEquivalent: "")
        testHeader.isEnabled = false
        menu.addItem(testHeader)
        let testItems: [(String, TestPill)] = [
            ("Charging", .charging),
            ("Bluetooth connected", .bluetoothConnected),
            ("Bluetooth disconnected", .bluetoothDisconnected),
            ("Timer finished", .timerFinished),
            ("Calendar upcoming", .calendarUpcoming),
            ("AirDrop received", .airDropReceived),
            ("Note saved", .noteSaved)
        ]
        for (title, kind) in testItems {
            let item = NSMenuItem(title: title, action: #selector(handleTestPill(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = kind
            menu.addItem(item)
        }

        // Settings + Quit. Per user feedback: "there is no quite
        // button in the note taker." Notetaker is a menu-bar /
        // accessory app (LSUIElement = true) — it has no Dock
        // icon and no app-menu in the system menu bar, so the
        // ONLY discoverable place to put Settings and Quit is
        // this dropdown. Without these, the user has to force-
        // quit via Activity Monitor to fully exit, which is bad UX.
        //
        // ⌘, for Settings and ⌘Q for Quit match macOS conventions
        // so muscle memory works the moment the menu opens.
        menu.addItem(.separator())
        // "Check for Updates…" — kicks off Sparkle's user-initiated
        // check, which always shows feedback (either an "up to date"
        // dialog or the "new version available" prompt). Without
        // this menu item the user has no manual path to trigger an
        // update; they have to wait for SUScheduledCheckInterval to
        // fire (default 4h, set in Info.plist). User feedback after
        // 1.5 install on a second Mac: "no notification ever came" —
        // because Sparkle's first scheduled check hadn't fired yet
        // when 1.6 went live.
        let checkUpdatesItem = NSMenuItem(title: "Check for Updates…",
                                          action: #selector(handleCheckForUpdates),
                                          keyEquivalent: "")
        checkUpdatesItem.target = self
        menu.addItem(checkUpdatesItem)
        let settingsItem = NSMenuItem(title: "Settings…",
                                      action: #selector(handleOpenSettings),
                                      keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        let quitItem = NSMenuItem(title: "Quit nox",
                                  action: #selector(handleQuit),
                                  keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    @objc private func handleCheckForUpdates() {
        // Route through Sparkle's standard updater. `checkForUpdates`
        // is the user-initiated path: it always shows UI (either
        // "you're up to date" or the update-available sheet) so
        // the user gets clear feedback that a check happened, vs
        // `checkForUpdatesInBackground()` which silently noops if
        // there's nothing new.
        AppDelegate.shared?.sparkleUpdaterController.updater.checkForUpdates()
    }

    @objc private func handleOpenSettings() {
        // AppDelegate owns the Settings window — see
        // /Users/apple/Note taker app/Notetaker/Settings/SettingsWindow.swift
        // and the AppDelegate.shared.openSettings() bridge.
        AppDelegate.shared?.openSettings()
    }

    @objc private func handleQuit() {
        NSApp.terminate(nil)
    }

    @objc private func handleTestPill(_ sender: NSMenuItem) {
        guard let kind = sender.representedObject as? TestPill else { return }
        onTriggerTestPill?(kind)
    }

    @objc private func handleOpen() {
        onClick()
    }

    @objc private func handleStartTimer(_ sender: NSMenuItem) {
        guard let duration = sender.representedObject as? TimeInterval else { return }
        onStartTimer?(duration)
    }

    @objc private func handleCancelTimer() {
        onCancelTimer?()
    }

    var iconFrame: NSRect? {
        guard let button = statusItem.button,
              let window = button.window else { return nil }
        let frameInWindow = button.convert(button.bounds, to: nil)
        return window.convertToScreen(frameInWindow)
    }
}
