import AppKit
import HotKey

enum HotkeyEvent {
    case togglePanel
    case togglePushToTalk
}

final class HotkeyService {
    private var toggleHotkey: HotKey?
    private var pttHotkey: HotKey?
    private let handler: (HotkeyEvent) -> Void

    init(handler: @escaping (HotkeyEvent) -> Void) {
        self.handler = handler
        registerDefaults()
    }

    private func registerDefaults() {
        toggleHotkey = HotKey(key: .space, modifiers: [.option])
        toggleHotkey?.keyDownHandler = { [weak self] in
            self?.handler(.togglePanel)
        }

        pttHotkey = HotKey(key: .v, modifiers: [.option])
        pttHotkey?.keyDownHandler = { [weak self] in
            self?.handler(.togglePushToTalk)
        }
    }
}
