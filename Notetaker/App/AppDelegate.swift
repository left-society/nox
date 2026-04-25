import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Static handle so callers (e.g. `SettingsWindow.open`, NSAlert
    /// callbacks) can reach us without going through `NSApp.delegate`.
    /// SwiftUI's `@NSApplicationDelegateAdaptor` sometimes wraps the
    /// delegate behind its own forwarder, which makes the
    /// `NSApp.delegate as? AppDelegate` cast unreliable.
    static private(set) var shared: AppDelegate?

    var environment: AppEnvironment?
    var menuBarController: MenuBarController?
    var panelController: PanelWindowController?
    var hotkeyService: HotkeyService?
    var clipboardMonitor: ClipboardMonitor?
    var dragMonitor: DragMonitor?
    var screenshotWatcher: ScreenshotWatcher?
    /// Cursor-on-notch auto-open. Mirrors Alcove's hover gesture so the
    /// panel is reachable without remembering ⌥Space.
    var hoverActivator: HoverActivator?
    /// Owns the separate notch HUD pills (charging, music, etc.) that
    /// auto-bloom on system events independent of the notes panel.
    var notchOrchestrator: NotchOrchestrator?

    /// Reusable Settings window. We manage this ourselves rather than
    /// relying on the SwiftUI `Settings { }` scene because that scene's
    /// open mechanism (`SettingsLink`, `\.openSettings`, or
    /// `NSApp.sendAction("showSettingsWindow:", …)`) is unreliable when
    /// the only visible UI is an `NSPanel` hosted via
    /// `NSHostingController`. The hosting controller's SwiftUI tree
    /// doesn't share the App scene's environment, so `\.openSettings`
    /// is unbound there; and with `LSUIElement = true` there's no main
    /// window in the responder chain to handle the action selector
    /// either. Net result: the gear icon was a dead pixel. Owning the
    /// window directly here makes "click gear → Settings appears" a
    /// straight call into AppKit, which Just Works.
    private var settingsWindow: NSWindow?

    /// Sliding window of recent screenshots for burst detection. A "burst"
    /// (≥2 shots within `burstWindow`) opens the panel; otherwise the shot
    /// is auto-saved with a 1-hour TTL and the panel stays hidden.
    private var recentScreenshots: [(time: TimeInterval, id: String)] = []
    private let burstWindow: TimeInterval = 3.0
    private let burstCount = 2
    // "few hours" per user spec — auto-saved screenshots without a follow-up
    // burst evaporate after 4 hours so the panel doesn't slowly fill with
    // every screenshot the user ever took.
    private let soloTTL: TimeInterval = 14400

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self
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

        // Cursor-into-notch → two-stage hover gesture, matching what
        // the user described from Alcove / Elkhob: "when I'm going to
        // the cursor into that thing, it just moves a little bit; it
        // doesn't open the whole thing. When I'm placing the cursor
        // for like 0.2 seconds or a little bit longer, it opens."
        //
        // - onTeaseStart: cursor entered the hot zone → tease the
        //   panel (small pre-bloom pill, no content tree). Gives
        //   immediate visual feedback so the entry feels acknowledged.
        // - onTeaseEnd: cursor left before the dwell completed →
        //   collapse the tease and order out. The panel returns to
        //   hidden; nothing else happens.
        // - onActivate: cursor stayed for the dwell window → promote
        //   to a full slab open. show() detects we're already teasing
        //   and lets animateOpen blend smoothly from the tease frame
        //   into the slab without a setFrame snap.
        //
        // Pass `mode: .hover` so the panel installs cursor-leave
        // monitors and auto-dismisses when the user moves away — the
        // user explicitly asked for "when i move my cursor from the
        // thing it should just close automatically" for hover-opened
        // panels, while click/hotkey-opened panels stay sticky until
        // an explicit click-outside.
        let hover = HoverActivator(
            onTeaseStart: { [weak self] in
                self?.panelController?.tease()
            },
            onTeaseEnd: { [weak self] in
                self?.panelController?.dismissTease()
            },
            onActivate: { [weak self] in
                guard let self, let panel = self.panelController else { return }
                if !panel.isVisible {
                    panel.show(mode: .hover)
                }
            }
        )
        hover.start()
        self.hoverActivator = hover

        // Notch HUD subsystem — independent of the notes panel. Pops
        // a charging pill on plug-in / unplug, ready to grow with
        // music/AirPods/focus presentations later.
        let orchestrator = NotchOrchestrator()

        // Bridge MediaRemote → PanelPresenter so the panel's music
        // page (MusicPanelView) can observe the same now-playing
        // stream that drives the resting pill. We fire on every
        // snapshot (including nil) so the presenter's `visibleTabs`
        // and the "auto-bounce off .music when playback stops" logic
        // stay in sync without polling.
        //
        // This callback is also where the unified pill+panel toggles
        // its resting state. Whenever there's a current track (info
        // non-nil — playing or paused, matching Alcove's "ambient
        // indicator" behavior) we ask the panel controller to enter
        // resting mode: the NSPanel is ordered front at closed-pill
        // geometry and stays there until the user hovers (which morphs
        // it into the full slab) or music stops. When info goes nil
        // we exit resting mode and the panel orders out — but only if
        // it isn't currently visible/teasing in another mode, so a
        // music-stop mid-session doesn't yank a panel out from under
        // the user's cursor.
        orchestrator.onNowPlayingChange = { [weak self] info in
            guard let self, let panel = self.panelController else { return }
            panel.presenter.nowPlaying = info
            if info != nil {
                panel.enterRestingMode()
            } else {
                panel.exitRestingMode()
            }
        }

        // Reverse bridge: MusicPanelView's transport buttons (prev /
        // play-pause / next) route through PanelPresenter.onMediaCommand,
        // which we point at the orchestrator's MediaRemoteService. This
        // closure is captured for the lifetime of the panel controller —
        // both objects live for the whole app lifetime, so a strong
        // reference here is fine and avoids a [weak] dance during
        // every button tap.
        panelController?.presenter.onMediaCommand = { [weak orchestrator] command in
            orchestrator?.sendMediaCommand(command)
        }

        orchestrator.start()
        self.notchOrchestrator = orchestrator

        // Dev-only: auto-show the panel on launch for visual verification.
        if ProcessInfo.processInfo.environment["NOTETAKER_AUTOSHOW"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.panelController?.show()
            }
        }

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

    /// Opens (or refocuses) the Settings window. Builds the SwiftUI tree
    /// directly with `NSHostingController` and hands its environmentObject
    /// the same `AppEnvironment` the panel uses, so the API key field,
    /// retention toggles, etc. all read/write the live state. The window
    /// is cached so repeated clicks just bring the existing one forward
    /// instead of stacking duplicates.
    ///
    /// Two non-obvious bits:
    ///
    /// 1. **Dismiss the panel.** It runs at `.popUpMenu` level (101) so a
    ///    plain `.normal`-level window opens BEHIND it and looks like
    ///    nothing happened. Hiding the panel first gives the Settings
    ///    window a clean field of view; the user just left the panel
    ///    anyway by clicking the gear.
    ///
    /// 2. **Bump activation policy to `.regular`.** With LSUIElement we
    ///    launch as `.accessory`, which means new windows don't get
    ///    real keyboard focus / Dock presence. Flipping to `.regular`
    ///    while Settings is up gets us a proper foreground window;
    ///    we revert to `.accessory` on close so the Dock icon doesn't
    ///    linger.
    func openSettings() {
        NSLog("Notetaker: openSettings() entered, env=\(environment != nil), cached=\(settingsWindow != nil)")
        panelController?.hide()

        NSApp.setActivationPolicy(.regular)
        if #available(macOS 14, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }

        if let window = settingsWindow {
            window.makeKeyAndOrderFront(nil)
            return
        }

        guard let env = environment else {
            NSLog("Notetaker: openSettings called before environment ready")
            return
        }

        let host = NSHostingController(rootView: SettingsView().environmentObject(env))
        let window = NSWindow(contentViewController: host)
        window.title = "Notetaker Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("NotetakerSettingsWindow")
        // Drop back to menu-bar-only when the user closes Settings, so
        // we don't strand a Dock icon for an `LSUIElement` app.
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { _ in
            Task { @MainActor in
                NSApp.setActivationPolicy(.accessory)
            }
        }
        settingsWindow = window
        window.makeKeyAndOrderFront(nil)
        NSLog("Notetaker: settings window ordered front, level=\(window.level.rawValue) visible=\(window.isVisible)")
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
        NSLog("Notetaker: handleNewScreenshot fired for \(url.path)")
        guard let env = environment, let panel = panelController else {
            NSLog("Notetaker: handleNewScreenshot bail — env or panel nil")
            return
        }
        guard let data = try? Data(contentsOf: url) else {
            NSLog("Notetaker: handleNewScreenshot bail — couldn't read data at \(url.path)")
            return
        }
        let mime = Self.mime(forExtension: url.pathExtension.lowercased())

        let now = Date().timeIntervalSince1970
        recentScreenshots.removeAll { now - $0.time > burstWindow }

        // Deferred save — the inflight cell + spinner appears in the grid
        // synchronously while the file write + thumbnail run on a detached
        // task. Synchronous saves froze the panel for 200-400ms on big
        // retina screenshots, which read as "did anything happen?" to the
        // user. Returns the id immediately so we can wire the eventual
        // record into the burst detector before the save lands.
        let id = env.imageStore.saveImageDeferred(
            data: data,
            mimeType: mime,
            noteId: nil,
            source: "screenshot",
            expiresAt: now + soloTTL
        )
        recentScreenshots.append((time: now, id: id))

        if recentScreenshots.count >= burstCount {
            // Burst detected — the user is intentionally collecting
            // screenshots, so promote them from solo-TTL to permanent.
            for entry in recentScreenshots {
                env.imageStore.clearExpiryDeferred(id: entry.id)
            }
        }
        // Always pop the panel so the user gets immediate visual feedback
        // (placeholder cell + spinner) for the in-flight save. Solo
        // screenshots still evaporate via TTL if the user doesn't engage,
        // so showing the panel is non-destructive.
        panel.showOnTab(.images)
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

        // If WE are frontmost — i.e. the user is interacting with our own
        // Settings window or panel and just pasted into a SecureField /
        // TextField — auto-saving that paste as a note would leak whatever
        // they typed (e.g. a Gemini API key) into the notes list as plain
        // text. The clipboard monitor's whole point is to capture content
        // the user copied for later reference; pastes INTO our own UI are
        // not that. Bail.
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Bundle.main.bundleIdentifier {
            return
        }

        // Copying inside an editor / IDE / terminal / writing app is just
        // normal editing — the user isn't capturing something to save. Popping
        // the panel here steals focus and breaks Enter / arrow keys in the
        // app they're working in. So we bail early when the frontmost app is
        // one of those.
        if Self.isEditorContext() { return }

        let pb = NSPasteboard.general

        // Text FIRST. Browser text copies (and most rich-text copies)
        // ride on the pasteboard with a TIFF preview attached as a
        // rich-text fallback — if we check images first we'd misroute
        // a normal Cmd+C into the slow image-save path, which is what
        // made copies feel sluggish and "not registered." Only fall
        // through to the image branch when there's no meaningful text.
        let text = pb.string(forType: .string)
        let hasText = text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false

        if hasText, let text = text {
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
            if !panel.isVisible { panel.show() }
            return
        }

        // No text on the pasteboard → either Ctrl+Shift+Cmd+3/4 (macOS
        // clipboard screenshot) or "Copy Image" from a browser. Both
        // give us image data with no string companion, so this branch
        // is safe.
        if let pngData = pb.data(forType: .png) {
            saveClipboardImage(env: env, data: pngData, mime: "image/png")
            panel.showOnTab(.images)
            return
        }
        if let tiffData = pb.data(forType: .tiff),
           let pngData = Self.tiffToPNG(tiffData) {
            saveClipboardImage(env: env, data: pngData, mime: "image/png")
            panel.showOnTab(.images)
            return
        }

        if !panel.isVisible {
            panel.show()
        }
    }

    /// Routes a clipboard image into the same deferred-save path that
    /// file screenshots use, so the user gets the inflight cell + spinner
    /// regardless of how the screenshot was captured.
    private func saveClipboardImage(env: AppEnvironment, data: Data, mime: String) {
        let now = Date().timeIntervalSince1970
        let id = env.imageStore.saveImageDeferred(
            data: data,
            mimeType: mime,
            noteId: nil,
            source: "screenshot-clipboard",
            expiresAt: now + soloTTL
        )
        // Treat clipboard screenshots as part of the same burst window
        // as file screenshots — two captures in 3s either way means the
        // user is intentionally collecting and we should drop the TTL.
        recentScreenshots.removeAll { now - $0.time > burstWindow }
        recentScreenshots.append((time: now, id: id))
        if recentScreenshots.count >= burstCount {
            for entry in recentScreenshots {
                env.imageStore.clearExpiryDeferred(id: entry.id)
            }
        }
    }

    private static func tiffToPNG(_ data: Data) -> Data? {
        guard let rep = NSBitmapImageRep(data: data) else { return nil }
        return rep.representation(using: .png, properties: [:])
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
