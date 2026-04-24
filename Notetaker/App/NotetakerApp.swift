import SwiftUI

@main
struct NotetakerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            if let env = appDelegate.environment {
                SettingsView().environmentObject(env)
            } else {
                Text("Loading…")
                    .font(.nkMeta)
                    .foregroundStyle(.secondary)
                    .padding(40)
            }
        }
    }
}
