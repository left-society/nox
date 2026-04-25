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
    /// Surface the SwiftUI `Settings` scene from imperative code (e.g. an
    /// `NSAlert` button callback). For SwiftUI-button call sites prefer
    /// `SettingsLink` directly — it talks to the same scene through the
    /// proper SwiftUI environment plumbing instead of guessing at the
    /// responder chain.
    ///
    /// Why this is more careful than `NSApp.sendAction(...)` alone: on
    /// `LSUIElement = true` apps the panel is an `NSPanel`, never the
    /// main window, so the standard selector dispatch starting at
    /// `NSApp.mainWindow` finds nobody to handle `showSettingsWindow:`
    /// and the click silently no-ops. Sending the action with
    /// `to: NSApp.delegate` falls back to the application's responder
    /// chain, where SwiftUI's Settings-scene plumbing actually lives.
    /// The post-dispatch window scan is the ultimate belt-and-suspenders
    /// — if a Settings window already exists from a prior open, we just
    /// bring it forward rather than fire-and-forget.
    static func open() {
        if #available(macOS 14, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }

        let selector = if #available(macOS 14, *) {
            Selector(("showSettingsWindow:"))
        } else {
            Selector(("showPreferencesWindow:"))
        }

        // Try the standard responder chain first; if nobody handles
        // it (LSUIElement quirk), retarget at the app delegate which
        // hosts the SwiftUI Scene tree.
        if !NSApp.sendAction(selector, to: nil, from: nil) {
            NSApp.sendAction(selector, to: NSApp.delegate, from: nil)
        }

        // Some macOS versions create the Settings window async after
        // the action fires. Hop one runloop turn, then make sure the
        // window is actually visible and frontmost.
        DispatchQueue.main.async {
            for window in NSApp.windows
            where window.title == "Settings"
                || window.title == "Preferences"
                || window.title == "Notetaker Settings" {
                window.makeKeyAndOrderFront(nil)
            }
        }
    }
}
