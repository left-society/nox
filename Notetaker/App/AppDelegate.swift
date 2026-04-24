import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    var menuBarController: MenuBarController?
    var panelController: PanelWindowController?
    var hotkeyService: HotkeyService?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        panelController = PanelWindowController()
        menuBarController = MenuBarController { [weak self] in
            self?.panelController?.toggle()
        }
        panelController?.menuBarController = menuBarController

        hotkeyService = HotkeyService { [weak self] event in
            switch event {
            case .togglePanel:
                self?.panelController?.toggle()
            case .togglePushToTalk:
                break
            }
        }
    }
}
