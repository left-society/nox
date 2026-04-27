import AppKit

/// Menu-bar status item. Left-click toggles the notch panel,
/// right-click opens a menu with timer presets and a cancel
/// affordance. The right-click menu is rebuilt on every show
/// (`menuNeedsUpdate`) so the cancel item only appears when a
/// timer is actually running.
final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let onClick: () -> Void

    /// Closures the AppDelegate installs to drive the timer.
    /// Optional so the controller works standalone; if no
    /// closures are wired, the timer menu items just no-op.
    var onStartTimer: ((TimeInterval) -> Void)?
    var onCancelTimer: (() -> Void)?
    var isTimerRunning: () -> Bool = { false }

    init(onClick: @escaping () -> Void) {
        self.onClick = onClick
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "square.and.pencil",
                accessibilityDescription: "Notetaker"
            )
            button.image?.isTemplate = true
            button.target = self
            button.action = #selector(handleClick)
            // Receive both left- and right-click events so we can
            // route them differently. Default mask is just
            // .leftMouseUp, which makes right-click a no-op.
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
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
        statusItem.menu = menu
        // Trigger the menu via the status item's button. Setting
        // `.menu` makes the next click of any kind show it; we
        // pop it programmatically here so the right-click that
        // got us here actually opens it without a second press.
        statusItem.button?.performClick(nil)
        // Detach so the next left-click goes back to onClick
        // (otherwise the menu would fire on every click).
        DispatchQueue.main.async { [weak self] in
            self?.statusItem.menu = nil
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        // Open / toggle panel (matches left-click behavior).
        let openItem = NSMenuItem(title: "Open Notetaker", action: #selector(handleOpen), keyEquivalent: "")
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
