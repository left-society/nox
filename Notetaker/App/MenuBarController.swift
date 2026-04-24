import AppKit

final class MenuBarController {
    private let statusItem: NSStatusItem
    private let onClick: () -> Void

    init(onClick: @escaping () -> Void) {
        self.onClick = onClick
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "square.and.pencil",
                accessibilityDescription: "Notetaker"
            )
            button.image?.isTemplate = true
            button.target = self
            button.action = #selector(handleClick)
        }
    }

    @objc private func handleClick() {
        onClick()
    }

    var iconFrame: NSRect? {
        guard let button = statusItem.button,
              let window = button.window else { return nil }
        let frameInWindow = button.convert(button.bounds, to: nil)
        return window.convertToScreen(frameInWindow)
    }
}
