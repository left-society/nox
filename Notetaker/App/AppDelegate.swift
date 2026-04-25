import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var environment: AppEnvironment?
    var menuBarController: MenuBarController?
    var panelController: PanelWindowController?
    var hotkeyService: HotkeyService?
    var clipboardMonitor: ClipboardMonitor?
    var dragMonitor: DragMonitor?
    var screenshotWatcher: ScreenshotWatcher?

    /// Sliding window of recent screenshots for burst detection. A "burst"
    /// (≥2 shots within `burstWindow`) opens the panel; otherwise the shot
    /// is auto-saved with a 1-hour TTL and the panel stays hidden.
    private var recentScreenshots: [(time: TimeInterval, id: String)] = []
    private let burstWindow: TimeInterval = 3.0
    private let burstCount = 2
    private let soloTTL: TimeInterval = 3600

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        do {
            let env = try AppEnvironment()
            self.environment = env
            env.retentionService.start()
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
                NSLog("Notetaker: toggle() called, panel=\(self?.panelController != nil ? "exists" : "nil")")
                self?.panelController?.toggle()
            case .grabCurrentTab:
                Task { @MainActor in self?.grabCurrentBrowserTab() }
            }
        }

        let monitor = ClipboardMonitor { [weak self] in
            Task { @MainActor in
                self?.handleExternalClipboardChange()
            }
        }
        monitor.start()
        self.clipboardMonitor = monitor

        let drag = DragMonitor(
            onImageDrag: { [weak self] in
                Task { @MainActor in
                    self?.panelController?.showOnTab(.images)
                }
            },
            onVideoDrag: { [weak self] in
                Task { @MainActor in
                    self?.panelController?.showOnTab(.videos)
                }
            }
        )
        drag.start()
        self.dragMonitor = drag

        let screenshots = ScreenshotWatcher { [weak self] url in
            self?.handleNewScreenshot(at: url)
        }
        screenshots.start()
        self.screenshotWatcher = screenshots

        // Dev-only: self-trigger a download so we can verify the pipeline
        // without having to drive a browser hotkey. Set NOTETAKER_TEST_URL
        // in the Xcode scheme or launch env to exercise the code path.
        if let testURL = ProcessInfo.processInfo.environment["NOTETAKER_TEST_URL"],
           !testURL.isEmpty {
            NSLog("Notetaker: NOTETAKER_TEST_URL set — firing startDownload in 1.5s for \(testURL)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.environment?.videoStore.startDownload(url: testURL)
                self?.panelController?.showOnTab(.videos)
            }
        }
    }

    private func grabCurrentBrowserTab() {
        NSLog("Notetaker: ⌥⌘V fired")
        guard let env = environment, let panel = panelController else {
            NSLog("Notetaker: env or panel nil")
            return
        }
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil"
        NSLog("Notetaker: frontmost=\(front)")
        if let urlString = BrowserURLService.currentTabURL() {
            NSLog("Notetaker: got URL=\(urlString)")
            env.videoStore.startDownload(url: urlString)
        } else {
            NSLog("Notetaker: currentTabURL returned nil")
        }
        panel.showOnTab(.videos)
    }

    private func handleNewScreenshot(at url: URL) {
        guard let env = environment, let panel = panelController else { return }
        guard let data = try? Data(contentsOf: url) else { return }
        let mime = Self.mime(forExtension: url.pathExtension.lowercased())

        let now = Date().timeIntervalSince1970
        recentScreenshots.removeAll { now - $0.time > burstWindow }

        let saved: ImageRecord
        do {
            saved = try env.imageStore.saveImage(
                data: data,
                mimeType: mime,
                noteId: nil,
                source: "screenshot",
                expiresAt: now + soloTTL
            )
        } catch {
            NSLog("Auto-save screenshot failed: \(error)")
            return
        }
        recentScreenshots.append((time: now, id: saved.id))

        if recentScreenshots.count >= burstCount {
            for entry in recentScreenshots {
                env.imageStore.clearExpiry(id: entry.id)
            }
            panel.showOnTab(.images)
        }
    }

    private static func mime(forExtension ext: String) -> String {
        switch ext {
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "tiff", "tif": return "image/tiff"
        default: return "image/png"
        }
    }

    private func handleExternalClipboardChange() {
        guard let env = environment, let panel = panelController else { return }

        // Copying inside an editor / IDE / terminal / writing app is just
        // normal editing — the user isn't capturing something to save. Popping
        // the panel here steals focus and breaks Enter / arrow keys in the
        // app they're working in. So we bail early when the frontmost app is
        // one of those.
        if Self.isEditorContext() { return }

        let text = NSPasteboard.general.string(forType: .string)
        if let text = text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if env.noteStore.notes.contains(where: { $0.body == text }) {
                if !panel.isVisible { panel.show() }
                return
            }
            do {
                let note = try env.noteStore.createNote()
                try env.noteStore.updateBody(id: note.id, body: text)
            } catch {
                NSLog("Auto-save clipboard failed: \(error)")
            }
        }
        if !panel.isVisible {
            panel.show()
        }
    }

    private static func isEditorContext() -> Bool {
        guard let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else {
            return false
        }
        if editorBundleIDs.contains(bundleID) { return true }
        // JetBrains ships a whole family under com.jetbrains.* — catch all.
        if bundleID.hasPrefix("com.jetbrains.") { return true }
        return false
    }

    /// Apps where Cmd+C is almost always "move/duplicate text I'm editing"
    /// rather than "capture something interesting." We suppress the panel
    /// auto-open when any of these is frontmost.
    private static let editorBundleIDs: Set<String> = [
        // Code editors / IDEs
        "com.apple.dt.Xcode",
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.todesktop.230313mzl4w4u92",   // Cursor
        "dev.zed.Zed",
        "dev.zed.Zed-Preview",
        "com.sublimetext.4",
        "com.sublimetext.3",
        "com.panic.Nova",
        "com.barebones.bbedit",
        "com.github.atom",
        "com.macromates.TextMate",
        "io.vscodium.VSCodium",

        // Terminals
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "co.zeit.hyper",
        "com.mitchellh.ghostty",
        "org.alacritty",
        "net.kovidgoyal.kitty",
        "com.github.Tabby",

        // Writing / notes
        "com.apple.TextEdit",
        "com.apple.iWork.Pages",
        "com.apple.Notes",
        "com.microsoft.Word",
        "md.obsidian",
        "notion.id",
        "net.shinyfrog.bear",
        "com.ulyssesapp.mac",
        "pro.writer.mac",                   // iA Writer
        "com.agiletortoise.Drafts-OSX",
        "abnerworks.Typora",
        "com.logseq.logseq",
        "com.luki.craft",

        // Email (Cmd+C here is usually editing a reply)
        "com.apple.mail",
        "com.readdle.smartemail-Mac",       // Spark
        "it.bloop.airmail3",
        "com.microsoft.Outlook",

        // AI desktop apps
        "com.anthropic.claudefordesktop",

        // Design
        "com.figma.Desktop",
        "com.bohemiancoding.sketch3",
        "com.pixelmatorteam.pixelmator.pro",
        "com.adobe.Photoshop",
        "com.adobe.illustrator"
    ]
}
