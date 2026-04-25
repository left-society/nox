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

    private func registerDefaults() {
        toggleHotkey = HotKey(key: .space, modifiers: [.option])
        toggleHotkey?.keyDownHandler = { [weak self] in
            NSLog("Notetaker: ⌥Space fired")
            self?.handler(.togglePanel)
        }
        NSLog("Notetaker: registered ⌥Space (toggle=\(toggleHotkey != nil))")

        // Primary: ⌥⌘V — often gets swallowed by Chrome / extensions.
        grabTabHotkey = HotKey(key: .v, modifiers: [.option, .command])
        grabTabHotkey?.keyDownHandler = { [weak self] in
            NSLog("Notetaker: ⌥⌘V fired")
            self?.handler(.grabCurrentTab)
        }
        NSLog("Notetaker: registered ⌥⌘V (grabTab=\(grabTabHotkey != nil))")

        // Fallback: ⌃⌥V — almost never bound by other apps, so it's a
        // reliable escape hatch when ⌥⌘V is blocked.
        grabTabAltHotkey = HotKey(key: .v, modifiers: [.control, .option])
        grabTabAltHotkey?.keyDownHandler = { [weak self] in
            NSLog("Notetaker: ⌃⌥V fired")
            self?.handler(.grabCurrentTab)
        }
        NSLog("Notetaker: registered ⌃⌥V (grabTabAlt=\(grabTabAltHotkey != nil))")
    }
}
