import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @EnvironmentObject var env: AppEnvironment
    @AppStorage("retentionDays") private var retentionDays: Int = 2
    @AppStorage("trashRetentionDays") private var trashRetentionDays: Int = 7
    @AppStorage("launchAtLogin") private var launchAtLogin: Bool = true

    var body: some View {
        Form {
            Section("Retention") {
                Picker("Active for", selection: $retentionDays) {
                    Text("1 day").tag(1)
                    Text("2 days").tag(2)
                    Text("7 days").tag(7)
                    Text("14 days").tag(14)
                    Text("30 days").tag(30)
                }
                .onChange(of: retentionDays) { new in
                    env.retentionService.retentionSeconds = Double(new) * 24 * 3600
                }

                Picker("Trash kept for", selection: $trashRetentionDays) {
                    Text("Delete immediately").tag(0)
                    Text("7 days").tag(7)
                    Text("14 days").tag(14)
                    Text("30 days").tag(30)
                }
                .onChange(of: trashRetentionDays) { new in
                    env.retentionService.trashRetentionSeconds = Double(new) * 24 * 3600
                }
            }

            Section("Startup") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { on in
                        setLaunchAtLogin(on)
                    }
            }
        }
        .formStyle(.grouped)
        .frame(width: 380, height: 260)
        .onAppear { syncRetentionFromAppStorage() }
    }

    private func syncRetentionFromAppStorage() {
        env.retentionService.retentionSeconds = Double(retentionDays) * 24 * 3600
        env.retentionService.trashRetentionSeconds = Double(trashRetentionDays) * 24 * 3600
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("Login item toggle failed: \(error)")
        }
    }
}

enum SettingsWindow {
    static func open() {
        NSApp.activate(ignoringOtherApps: true)
        if #available(macOS 14, *) {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        } else {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
    }
}
