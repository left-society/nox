import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    var environment: AppEnvironment?
    var menuBarController: MenuBarController?
    var panelController: PanelWindowController?
    var hotkeyService: HotkeyService?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        do {
            let env = try AppEnvironment()
            self.environment = env
            panelController = PanelWindowController(environment: env)
        } catch {
            NSLog("Notetaker failed to initialize: \(error)")
            NSApp.terminate(nil)
            return
        }

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
