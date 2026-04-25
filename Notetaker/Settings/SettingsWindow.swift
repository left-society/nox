import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @EnvironmentObject var env: AppEnvironment
    @AppStorage("retentionDays") private var retentionDays: Int = 2
    @AppStorage("trashRetentionDays") private var trashRetentionDays: Int = 7
    @AppStorage("launchAtLogin") private var launchAtLogin: Bool = true
    /// Gemini API key, used by `GeminiOCRService` to extract chat
    /// messages from screenshots. Stored in NSUserDefaults — same as
    /// any other personal-but-non-secret app setting. The user enters
    /// the key here once and it survives across launches.
    ///
    /// We deliberately do NOT use the macOS Keychain. The key is only
    /// readable from this app (sandboxed defaults), the user supplies
    /// it themselves rather than receiving it from us, and the
    /// Keychain prompt-on-first-read UX would be jarring for what's
    /// essentially "paste this string into a textbox and forget it".
    /// If a future scenario calls for tighter handling we can migrate
    /// without touching the rest of the OCR pipeline.
    @AppStorage(GeminiOCRService.apiKeyDefaultsKey) private var geminiApiKey: String = ""

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

            Section("Chat Extraction (Gemini)") {
                SecureField("Gemini API key", text: $geminiApiKey, prompt: Text("Paste key…"))
                    .textFieldStyle(.roundedBorder)
                Text("Used to turn chat screenshots into pasteable text via right-click → Extract Messages. Get a key at aistudio.google.com — leave blank to disable.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 380)
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
    /// Single, reliable entry point for showing Settings. Delegates to the
    /// AppDelegate, which owns the window directly via `NSHostingController`.
    ///
    /// Why we don't go through SwiftUI's `Settings { }` scene anymore:
    /// the only visible UI in this app is an `NSPanel` whose SwiftUI tree
    /// is mounted via `NSHostingController`. That hosting controller
    /// creates a separate SwiftUI root that does not share the App scene's
    /// environment, so `\.openSettings`, `SettingsLink`, and the
    /// `showSettingsWindow:` action selector all fail to reach a valid
    /// handler. Hosting the window in AppKit and pushing the SwiftUI tree
    /// in by hand sidesteps the entire scene-plumbing problem.
    @MainActor
    static func open() {
        NSLog("Notetaker: SettingsWindow.open invoked, shared=\(AppDelegate.shared != nil) appDelegate=\(NSApp.delegate.map { String(describing: type(of: $0)) } ?? "nil")")
        if let app = AppDelegate.shared {
            app.openSettings()
            return
        }
        if let app = NSApp.delegate as? AppDelegate {
            app.openSettings()
            return
        }
        NSLog("Notetaker: SettingsWindow.open could not reach AppDelegate")
    }
}
