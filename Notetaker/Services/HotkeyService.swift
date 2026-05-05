import AppKit
import HotKey

enum HotkeyEvent {
    case togglePanel
    case grabCurrentTab
}

final class HotkeyService {
    private var toggleHotkey: HotKey?
    private var grabTabHotkey: HotKey?
    private var grabTabAltHotkey: HotKey?
    private let handler: (HotkeyEvent) -> Void

    init(handler: @escaping (HotkeyEvent) -> Void) {
        self.handler = handler
        registerDefaults()
    }

    /// Tracks whether we've ever observed our toggle hotkey fire.
    /// Per BUG-025 mitigation: if it stays false for several
    /// minutes after launch we log a louder warning to point the
    /// user at the diagnostic. Heuristic, not perfect — a user
    /// who hasn't opened the panel yet will trip this even though
    /// the hotkey is fine — but the false-positive is just one
    /// extra Console.app log line, not a UI alert.
    private var observedToggleFire = false

    private func registerDefaults() {
        // ⌥Space is the toggle hotkey. Per BUG-025: this combo
        // CAN be claimed by other apps (Character Viewer is the
        // most common offender on macOS), and the underlying
        // HotKey lib returns a non-nil instance even when Carbon's
        // RegisterEventHotKey fails — so we can't tell from the
        // init alone whether it actually grabbed the combo.
        // Until we ship a Settings UI for remapping, the best we
        // can do is:
        //   1. Log clearly which combos got "registered."
        //   2. Document the ⌃⌥V fallback in the user-visible help.
        //   3. Track `observedToggleFire` and emit a louder
        //      warning if the hotkey never fires — ambient signal
        //      that something might be wrong.
        toggleHotkey = HotKey(key: .space, modifiers: [.option])
        toggleHotkey?.keyDownHandler = { [weak self] in
            NSLog("nox: ⌥Space fired")
            self?.observedToggleFire = true
            self?.handler(.togglePanel)
        }
        NSLog("nox: registered ⌥Space (toggle=\(toggleHotkey != nil))")

        // Primary: ⌥⌘V — often gets swallowed by Chrome / extensions.
        grabTabHotkey = HotKey(key: .v, modifiers: [.option, .command])
        grabTabHotkey?.keyDownHandler = { [weak self] in
            NSLog("nox: ⌥⌘V fired")
            self?.handler(.grabCurrentTab)
        }
        NSLog("nox: registered ⌥⌘V (grabTab=\(grabTabHotkey != nil))")

        // Fallback: ⌃⌥V — almost never bound by other apps, so it's a
        // reliable escape hatch when ⌥⌘V is blocked.
        grabTabAltHotkey = HotKey(key: .v, modifiers: [.control, .option])
        grabTabAltHotkey?.keyDownHandler = { [weak self] in
            NSLog("nox: ⌃⌥V fired")
            self?.handler(.grabCurrentTab)
        }
        NSLog("nox: registered ⌃⌥V (grabTabAlt=\(grabTabAltHotkey != nil))")

        // Heuristic conflict warning at the 5-minute mark. If
        // the user hasn't triggered the panel by then AND has
        // the menu-bar icon visible, ⌥Space is most likely
        // bound by another app. We log loudly so a user filing
        // a "panel doesn't open" report has a console hit they
        // can search for.
        DispatchQueue.main.asyncAfter(deadline: .now() + 300) { [weak self] in
            guard let self, !self.observedToggleFire else { return }
            NSLog("nox: ⚠️ ⌥Space hasn't fired in 5 min — possible hotkey conflict (Character Viewer or another app may have claimed it). Use the Notetaker menu-bar icon to open the panel manually.")
        }
    }
}
