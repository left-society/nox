# Notetaker v1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a native macOS menu bar note-taking app with text, voice (Whisper), and image capture that copies to clipboard for paste into Claude Code.

**Architecture:** Native Swift app, SwiftUI for views, AppKit for menu bar / panel / hotkeys. Three tiers — AppKit shell, SwiftUI views, plain Swift services — as defined in the spec §4. Local-only, SQLite via GRDB, offline Whisper via whisper.cpp with Core ML acceleration.

**Tech Stack:** Xcode 15+, Swift 5.9+, macOS 13+ deployment target. Dependencies: GRDB.swift, HotKey (soffes), whisper.cpp.

**Reference spec:** [docs/superpowers/specs/2026-04-25-notetaker-design.md](../specs/2026-04-25-notetaker-design.md)

---

## Milestone map

| Phase | Output | Usable for |
|-------|--------|-----------|
| 0 | Project bootstrapped, deps installed, git initialized | — |
| 1 | Menu bar app with animated dropdown panel, hotkey works | Validating panel feel |
| 2 | Design system + empty panel shell with segmented control | Visual review |
| 3 | SQLite + NoteStore + full DB test coverage | DB confidence |
| 4 | Text notes: capture, edit, autosave, copy to clipboard | **Daily driver for text** |
| 5 | Image capture: paste, drag-drop, multi-select, copy | **Daily driver for images** |
| 6 | Voice: push-to-talk, Whisper transcription, recording pill | **Full capture trio** |
| 7 | Auto-recycle + trash section | Production-ready retention |
| 8 | Settings window, launch-at-login, permissions polish | Shippable |
| 9 | App icon, empty states, codesigned DMG | Distributable |

---

## File structure

Created across the phases. Paths relative to the `Notetaker.xcodeproj` root.

```
Notetaker.xcodeproj/
Notetaker/
├── App/
│   ├── NotetakerApp.swift         # @main, SwiftUI App struct
│   ├── AppDelegate.swift          # lifecycle, permissions, login item
│   └── MenuBarController.swift    # NSStatusItem owner
├── Panel/
│   ├── PanelWindowController.swift  # NSPanel subclass, positioning, animation
│   ├── PanelRootView.swift          # SwiftUI root
│   ├── NotesListView.swift
│   ├── NoteEditorView.swift
│   ├── ImagesGridView.swift
│   └── RecordingPillView.swift      # separate floating NSWindow
├── Services/
│   ├── Database.swift               # GRDB setup + migrations
│   ├── NoteStore.swift              # Notes CRUD, @Published
│   ├── ImageStore.swift             # Image file + DB ops
│   ├── AudioRecorder.swift          # AVFoundation mic capture
│   ├── WhisperService.swift         # whisper.cpp wrapper
│   ├── HotkeyService.swift          # global hotkey registration
│   ├── ClipboardService.swift       # NSPasteboard ops
│   └── RetentionService.swift       # retention sweeps
├── DesignSystem/
│   ├── DesignTokens.swift
│   ├── Animations.swift
│   └── Typography.swift
├── Resources/
│   ├── Assets.xcassets
│   ├── Info.plist
│   └── Models/
│       ├── ggml-small.en.bin
│       └── ggml-small.en-encoder.mlmodelc
└── Settings/
    └── SettingsWindow.swift
NotetakerTests/
├── DatabaseTests.swift
├── NoteStoreTests.swift
├── ImageStoreTests.swift
├── RetentionServiceTests.swift
├── ClipboardServiceTests.swift
└── WhisperServiceTests.swift
```

---

## Phase 0 — Project Bootstrap

### Task 0.1: Initialize git repository

**Files:**
- Create: `.gitignore`

- [ ] **Step 1: Run `git init` in project root**

```bash
cd "/Users/apple/Note taker app"
git init
git branch -m main
```

Expected: `Initialized empty Git repository in ...`

- [ ] **Step 2: Create `.gitignore`**

Write `/Users/apple/Note taker app/.gitignore`:

```gitignore
# Xcode
build/
DerivedData/
*.xcworkspace/xcuserdata/
*.xcodeproj/xcuserdata/
*.xcodeproj/project.xcworkspace/xcuserdata/
*.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/

# macOS
.DS_Store

# SwiftPM
.swiftpm/
.build/
Package.resolved

# Superpowers
.superpowers/

# Secrets
*.p12
*.p8
*.mobileprovision
ExportOptions.plist
```

- [ ] **Step 3: Initial commit**

```bash
git add .gitignore docs/
git commit -m "chore: initialize project, add spec and plan"
```

Expected: `[main (root-commit) ...] chore: initialize project, add spec and plan`

---

### Task 0.2: Create Xcode project

- [ ] **Step 1: Create project via Xcode**

Open Xcode → File → New → Project → macOS → App.

Configure:
- Product Name: `Notetaker`
- Team: your Apple ID (personal team is fine for dev)
- Organization Identifier: `com.yourname.notetaker` (pick anything reverse-DNS)
- Interface: **SwiftUI**
- Language: **Swift**
- Storage: **None** (we're using GRDB, not Core Data)
- Include Tests: **Yes**

Save location: `/Users/apple/Note taker app/`. Uncheck "Create Git repository" (we already did it).

- [ ] **Step 2: Verify project structure**

```bash
ls "/Users/apple/Note taker app/Notetaker.xcodeproj"
ls "/Users/apple/Note taker app/Notetaker"
```

Expected: See the `.xcodeproj` bundle and a `Notetaker/` source folder containing `NotetakerApp.swift`, `ContentView.swift`, `Assets.xcassets`.

- [ ] **Step 3: Configure as menu-bar-only app**

Open `Notetaker/Info.plist` (or the generated plist in build settings on newer Xcode). Add:

```xml
<key>LSUIElement</key>
<true/>
<key>NSMicrophoneUsageDescription</key>
<string>Notetaker transcribes your voice offline to create notes. Audio never leaves your Mac.</string>
```

`LSUIElement=true` hides the Dock icon — the app runs as a menu bar agent.

- [ ] **Step 4: Set deployment target**

Xcode → Project → Notetaker target → General → Minimum Deployments → macOS: **13.0**.

- [ ] **Step 5: Build and run**

`⌘R` in Xcode. The default SwiftUI window will appear. We'll replace it in Phase 1.

Expected: App launches, shows a blank window, no Dock icon once we add LSUIElement.

- [ ] **Step 6: Commit**

```bash
git add Notetaker.xcodeproj Notetaker NotetakerTests NotetakerUITests
git commit -m "feat: bootstrap Xcode project (macOS 13+, SwiftUI, menu bar agent)"
```

---

### Task 0.3: Add Swift Package Manager dependencies

- [ ] **Step 1: Add GRDB.swift**

Xcode → File → Add Package Dependencies → paste URL:

`https://github.com/groue/GRDB.swift`

Rules: Up to Next Major Version → `6.0.0`. Add `GRDB` library to the Notetaker target.

- [ ] **Step 2: Add HotKey**

File → Add Package Dependencies → paste URL:

`https://github.com/soffes/HotKey`

Rules: Up to Next Major → `0.2.0`. Add `HotKey` to the Notetaker target.

- [ ] **Step 3: Add whisper.cpp Swift package**

File → Add Package Dependencies → paste URL:

`https://github.com/ggerganov/whisper.cpp`

Rules: Branch → `master` (the package isn't versioned on SwiftPM; using master is standard here). Add the `whisper` product to the Notetaker target.

- [ ] **Step 4: Verify dependencies resolve**

Build the project (`⌘B`). Resolve any prompts. Dependencies should appear in Xcode's left sidebar under Package Dependencies.

Expected: Build succeeds.

- [ ] **Step 5: Commit**

```bash
git add "Notetaker.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
git commit -m "chore: add GRDB, HotKey, whisper.cpp dependencies"
```

---

## Phase 1 — Menu Bar App Shell

Goal of this phase: an installable app that has a menu bar icon, and pressing `Option+Space` drops a blank glass panel from under the icon with spring animation.

### Task 1.1: Replace default window with menu-bar-only AppDelegate

**Files:**
- Modify: `Notetaker/NotetakerApp.swift`
- Create: `Notetaker/App/AppDelegate.swift`
- Delete: `Notetaker/ContentView.swift`

- [ ] **Step 1: Create `AppDelegate.swift`**

```swift
// Notetaker/App/AppDelegate.swift
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    var menuBarController: MenuBarController?
    var panelController: PanelWindowController?
    var hotkeyService: HotkeyService?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Ensure we're an accessory app (no Dock icon). LSUIElement handles this
        // at launch, but setting policy here covers relaunches.
        NSApp.setActivationPolicy(.accessory)

        panelController = PanelWindowController()
        menuBarController = MenuBarController { [weak self] in
            self?.panelController?.toggle()
        }

        hotkeyService = HotkeyService { [weak self] event in
            switch event {
            case .togglePanel:
                self?.panelController?.toggle()
            default:
                break
            }
        }
    }
}
```

- [ ] **Step 2: Rewrite `NotetakerApp.swift`**

```swift
// Notetaker/NotetakerApp.swift
import SwiftUI

@main
struct NotetakerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Empty Settings scene so `@main` compiles; real Settings comes in Phase 8.
        Settings {
            Text("Settings coming in Phase 8")
                .padding()
        }
    }
}
```

- [ ] **Step 3: Delete `ContentView.swift`**

```bash
rm "/Users/apple/Note taker app/Notetaker/ContentView.swift"
```

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "feat: menu-bar-only app shell with AppDelegate"
```

Build will fail (missing `MenuBarController`, `PanelWindowController`, `HotkeyService`) — that's expected. Next tasks create them.

---

### Task 1.2: Implement `MenuBarController`

**Files:**
- Create: `Notetaker/App/MenuBarController.swift`

- [ ] **Step 1: Write `MenuBarController.swift`**

```swift
// Notetaker/App/MenuBarController.swift
import AppKit

final class MenuBarController {
    private let statusItem: NSStatusItem
    private let onClick: () -> Void

    init(onClick: @escaping () -> Void) {
        self.onClick = onClick
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "square.and.pencil",
                                    accessibilityDescription: "Notetaker")
            button.image?.isTemplate = true
            button.target = self
            button.action = #selector(handleClick)
        }
    }

    @objc private func handleClick() {
        onClick()
    }

    /// Returns the screen rect of the menu bar icon — used to position the panel.
    var iconFrame: NSRect? {
        guard let button = statusItem.button,
              let window = button.window else { return nil }
        let frameInWindow = button.convert(button.bounds, to: nil)
        return window.convertToScreen(frameInWindow)
    }
}
```

- [ ] **Step 2: Build**

`⌘B`. Expected: still fails on `PanelWindowController` and `HotkeyService`, but `MenuBarController` itself compiles.

- [ ] **Step 3: Commit**

```bash
git add Notetaker/App/MenuBarController.swift
git commit -m "feat: menu bar status item with pencil icon"
```

---

### Task 1.3: Implement `HotkeyService`

**Files:**
- Create: `Notetaker/Services/HotkeyService.swift`

- [ ] **Step 1: Write `HotkeyService.swift`**

```swift
// Notetaker/Services/HotkeyService.swift
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
        // Option+Space
        toggleHotkey = HotKey(key: .space, modifiers: [.option])
        toggleHotkey?.keyDownHandler = { [weak self] in
            self?.handler(.togglePanel)
        }

        // Option+V
        pttHotkey = HotKey(key: .v, modifiers: [.option])
        pttHotkey?.keyDownHandler = { [weak self] in
            self?.handler(.togglePushToTalk)
        }
    }
}
```

- [ ] **Step 2: Build**

`⌘B`. Expected: still fails on `PanelWindowController` only.

- [ ] **Step 3: Commit**

```bash
git add Notetaker/Services/HotkeyService.swift
git commit -m "feat: global hotkeys Option+Space and Option+V via HotKey"
```

---

### Task 1.4: Implement `PanelWindowController` with blank panel

**Files:**
- Create: `Notetaker/Panel/PanelWindowController.swift`
- Create: `Notetaker/Panel/PanelRootView.swift` (stub)

- [ ] **Step 1: Create stub `PanelRootView.swift`**

```swift
// Notetaker/Panel/PanelRootView.swift
import SwiftUI

struct PanelRootView: View {
    var body: some View {
        ZStack {
            // Placeholder content — full UI in Phase 2.
            Text("Notetaker")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
        }
        .frame(width: 480, height: 640)
    }
}
```

- [ ] **Step 2: Write `PanelWindowController.swift`**

```swift
// Notetaker/Panel/PanelWindowController.swift
import AppKit
import SwiftUI

final class PanelWindowController {
    private let panel: NSPanel
    private var isVisible = false
    weak var menuBarController: MenuBarController?

    init() {
        let contentRect = NSRect(x: 0, y: 0, width: 480, height: 640)

        panel = NSPanel(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isMovableByWindowBackground = false
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hidesOnDeactivate = false

        // Visual effect view for real macOS vibrancy.
        let visualEffect = NSVisualEffectView()
        visualEffect.material = .hudWindow
        visualEffect.blendingMode = .behindWindow
        visualEffect.state = .active
        visualEffect.wantsLayer = true
        visualEffect.layer?.cornerRadius = 10
        visualEffect.layer?.masksToBounds = true

        // Host the SwiftUI root.
        let host = NSHostingView(rootView: PanelRootView())
        host.frame = contentRect
        host.autoresizingMask = [.width, .height]
        visualEffect.addSubview(host)

        panel.contentView = visualEffect
    }

    func toggle() {
        if isVisible {
            hide()
        } else {
            show()
        }
    }

    func show() {
        positionUnderMenuBarIcon()
        panel.alphaValue = 0
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.28
            ctx.timingFunction = CAMediaTimingFunction(
                controlPoints: 0.2, 0.8, 0.2, 1.0) // spring-ish ease
            panel.animator().alphaValue = 1
        }
        isVisible = true
    }

    func hide() {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.panel.orderOut(nil)
        })
        isVisible = false
    }

    private func positionUnderMenuBarIcon() {
        guard let iconFrame = menuBarController?.iconFrame else {
            // Fallback: center top-right of main screen.
            if let screen = NSScreen.main {
                let x = screen.visibleFrame.maxX - 500
                let y = screen.visibleFrame.maxY - 660
                panel.setFrameOrigin(NSPoint(x: x, y: y))
            }
            return
        }
        let panelWidth: CGFloat = 480
        let gap: CGFloat = 8
        let x = iconFrame.midX - panelWidth / 2
        let y = iconFrame.minY - 640 - gap
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
```

- [ ] **Step 3: Wire `menuBarController` reference in AppDelegate**

Modify `Notetaker/App/AppDelegate.swift` — after the two controllers are created:

```swift
panelController?.menuBarController = menuBarController
```

Final `applicationDidFinishLaunching`:

```swift
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
        default:
            break
        }
    }
}
```

- [ ] **Step 4: Build and run**

`⌘R`. Grant accessibility permission when prompted (System Settings → Privacy & Security → Accessibility → enable Notetaker, then relaunch app). Press `Option+Space`.

Expected: Glass panel appears under the menu bar icon with "Notetaker" text. Press `Option+Space` again → panel hides.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: PanelWindowController with NSPanel + NSVisualEffectView + toggle animation"
```

---

### Task 1.5: Click-outside-to-dismiss

**Files:**
- Modify: `Notetaker/Panel/PanelWindowController.swift`

- [ ] **Step 1: Add local event monitor in `PanelWindowController.show()`**

Add a property:

```swift
private var clickOutsideMonitor: Any?
```

Modify `show()`:

```swift
func show() {
    positionUnderMenuBarIcon()
    panel.alphaValue = 0
    panel.orderFrontRegardless()

    NSAnimationContext.runAnimationGroup { ctx in
        ctx.duration = 0.28
        ctx.timingFunction = CAMediaTimingFunction(
            controlPoints: 0.2, 0.8, 0.2, 1.0)
        panel.animator().alphaValue = 1
    }
    isVisible = true

    // Dismiss on outside click.
    clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
        self?.hide()
    }
}
```

Modify `hide()` to remove monitor:

```swift
func hide() {
    if let monitor = clickOutsideMonitor {
        NSEvent.removeMonitor(monitor)
        clickOutsideMonitor = nil
    }
    NSAnimationContext.runAnimationGroup({ ctx in
        ctx.duration = 0.2
        panel.animator().alphaValue = 0
    }, completionHandler: { [weak self] in
        self?.panel.orderOut(nil)
    })
    isVisible = false
}
```

- [ ] **Step 2: Build and run**

`⌘R`. Press `Option+Space` → panel opens. Click anywhere outside the panel → panel closes.

- [ ] **Step 3: Commit**

```bash
git add Notetaker/Panel/PanelWindowController.swift
git commit -m "feat: click-outside dismisses panel"
```

---

### Task 1.6: Escape-to-dismiss

**Files:**
- Modify: `Notetaker/Panel/PanelWindowController.swift`

- [ ] **Step 1: Add key event monitor**

Add a property:

```swift
private var keyMonitor: Any?
```

At end of `show()`:

```swift
keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
    if event.keyCode == 53 { // Escape
        self?.hide()
        return nil
    }
    return event
}
```

In `hide()`:

```swift
if let monitor = keyMonitor {
    NSEvent.removeMonitor(monitor)
    keyMonitor = nil
}
```

- [ ] **Step 2: Build, run, test**

Press `Option+Space` → panel opens. Press `Escape` → panel closes.

- [ ] **Step 3: Commit**

```bash
git add Notetaker/Panel/PanelWindowController.swift
git commit -m "feat: Escape key dismisses panel"
```

**Milestone 1 reached:** installable menu bar app, glass panel opens/closes with `Option+Space`, dismisses on Escape or outside click.

---

## Phase 2 — Design System

Goal: lock in the visual rules as Swift code so every view consumes the same tokens. Replace the placeholder panel text with a real shell (segmented control, empty list).

### Task 2.1: Create `DesignTokens.swift`

**Files:**
- Create: `Notetaker/DesignSystem/DesignTokens.swift`

- [ ] **Step 1: Write the file**

```swift
// Notetaker/DesignSystem/DesignTokens.swift
import SwiftUI

enum DS {
    enum Color {
        static let accent = SwiftUI.Color(nsColor: .systemBlue) // #0A84FF
        static let bgSubtle = SwiftUI.Color.white.opacity(0.04)
        static let bgHover = SwiftUI.Color.white.opacity(0.08)
        static let bgSelected = SwiftUI.Color.white.opacity(0.12)
        static let textPrimary = SwiftUI.Color.white.opacity(1.0)
        static let textSecondary = SwiftUI.Color.white.opacity(0.7)
        static let textTertiary = SwiftUI.Color.white.opacity(0.4)
        static let divider = SwiftUI.Color.white.opacity(0.08)
    }

    enum Spacing {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
    }

    enum Radius {
        static let pill: CGFloat = 5
        static let row: CGFloat = 7
        static let panel: CGFloat = 10
    }

    enum FontSize {
        static let xs: CGFloat = 11
        static let sm: CGFloat = 12
        static let body: CGFloat = 13
        static let title: CGFloat = 15
        static let large: CGFloat = 20
    }
}
```

- [ ] **Step 2: Build**

`⌘B`. Expected: succeeds.

- [ ] **Step 3: Commit**

```bash
git add Notetaker/DesignSystem/DesignTokens.swift
git commit -m "feat: DesignTokens with color/spacing/radius/font scales"
```

---

### Task 2.2: Create `Animations.swift`

**Files:**
- Create: `Notetaker/DesignSystem/Animations.swift`

- [ ] **Step 1: Write the file**

```swift
// Notetaker/DesignSystem/Animations.swift
import SwiftUI

extension Animation {
    static let panelOpen = Animation.spring(response: 0.35, dampingFraction: 0.82)
    static let rowHover = Animation.spring(response: 0.22, dampingFraction: 0.9)
    static let selection = Animation.spring(response: 0.18, dampingFraction: 0.95)
    static let recordingPulse = Animation.easeInOut(duration: 0.8).repeatForever(autoreverses: true)
}
```

- [ ] **Step 2: Build and commit**

```bash
git add Notetaker/DesignSystem/Animations.swift
git commit -m "feat: named spring animation presets"
```

---

### Task 2.3: Create `Typography.swift`

**Files:**
- Create: `Notetaker/DesignSystem/Typography.swift`

- [ ] **Step 1: Write the file**

```swift
// Notetaker/DesignSystem/Typography.swift
import SwiftUI

extension Font {
    static let nkLabel = Font.system(size: DS.FontSize.xs, weight: .medium)
        .leading(.tight)
    static let nkMeta = Font.system(size: DS.FontSize.sm, weight: .regular)
        .leading(.tight)
    static let nkBody = Font.system(size: DS.FontSize.body, weight: .regular)
    static let nkTitle = Font.system(size: DS.FontSize.title, weight: .semibold)
    static let nkLarge = Font.system(size: DS.FontSize.large, weight: .semibold)
}
```

- [ ] **Step 2: Build and commit**

```bash
git add Notetaker/DesignSystem/Typography.swift
git commit -m "feat: typography presets using SF Pro system fonts"
```

---

### Task 2.4: Build `PanelRootView` shell with segmented control

**Files:**
- Modify: `Notetaker/Panel/PanelRootView.swift`

- [ ] **Step 1: Write the updated view**

```swift
// Notetaker/Panel/PanelRootView.swift
import SwiftUI

enum PanelTab: String, CaseIterable, Identifiable {
    case notes, images
    var id: String { rawValue }
    var title: String {
        switch self {
        case .notes: return "Notes"
        case .images: return "Images"
        }
    }
}

struct PanelRootView: View {
    @State private var activeTab: PanelTab = .notes
    @State private var searchText: String = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            segmented
            divider
            content
        }
        .frame(width: 480, height: 640)
    }

    // MARK: - Subviews

    private var header: some View {
        HStack(spacing: DS.Spacing.sm) {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DS.Color.textSecondary)
            Text("Notetaker")
                .font(.nkTitle)
                .foregroundStyle(DS.Color.textPrimary)
            Spacer()
            Text("⌥Space")
                .font(.nkLabel)
                .foregroundStyle(DS.Color.textTertiary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.pill)
                        .fill(DS.Color.bgSubtle)
                )
        }
        .padding(.horizontal, DS.Spacing.md)
        .padding(.top, DS.Spacing.md)
        .padding(.bottom, DS.Spacing.sm)
    }

    private var segmented: some View {
        HStack(spacing: 2) {
            ForEach(PanelTab.allCases) { tab in
                Button {
                    withAnimation(.selection) { activeTab = tab }
                } label: {
                    Text(tab.title)
                        .font(.nkMeta)
                        .foregroundStyle(activeTab == tab ? DS.Color.textPrimary : DS.Color.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: DS.Radius.pill)
                                .fill(activeTab == tab ? DS.Color.bgSelected : .clear)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.row)
                .fill(DS.Color.bgSubtle)
        )
        .padding(.horizontal, DS.Spacing.md)
    }

    private var divider: some View {
        Rectangle()
            .fill(DS.Color.divider)
            .frame(height: 1)
            .padding(.top, DS.Spacing.md)
    }

    @ViewBuilder
    private var content: some View {
        switch activeTab {
        case .notes:
            Text("Notes tab — coming in Phase 4")
                .font(.nkBody)
                .foregroundStyle(DS.Color.textTertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .images:
            Text("Images tab — coming in Phase 5")
                .font(.nkBody)
                .foregroundStyle(DS.Color.textTertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

#Preview {
    PanelRootView()
        .preferredColorScheme(.dark)
}
```

- [ ] **Step 2: Build and run**

`⌘R`. Press `Option+Space`. Expected: panel shows with Notetaker header, `Notes | Images` toggle (click to switch), placeholder content below.

- [ ] **Step 3: Commit**

```bash
git add Notetaker/Panel/PanelRootView.swift
git commit -m "feat: panel shell with header, segmented tab control, content slot"
```

**Milestone 2 reached:** visual shell matches design DNA — glass panel, real segmented control, typography scale, spacing rhythm.

---

## Phase 3 — Data Layer

Goal: working SQLite layer with migrations, `NoteStore`, `ImageStore`, test coverage. No UI yet for any of it — tests prove correctness.

### Task 3.1: Define domain models

**Files:**
- Create: `Notetaker/Services/Models.swift`

- [ ] **Step 1: Write the file**

```swift
// Notetaker/Services/Models.swift
import Foundation
import GRDB

struct Note: Identifiable, Codable, FetchableRecord, MutablePersistableRecord, Equatable {
    var id: String
    var title: String?
    var body: String
    var createdAt: Double
    var updatedAt: Double
    var status: String     // "active" | "trashed"
    var trashedAt: Double?

    static let databaseTableName = "notes"

    enum Columns {
        static let id = Column("id")
        static let title = Column("title")
        static let body = Column("body")
        static let createdAt = Column("created_at")
        static let updatedAt = Column("updated_at")
        static let status = Column("status")
        static let trashedAt = Column("trashed_at")
    }

    enum CodingKeys: String, CodingKey {
        case id, title, body, status
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case trashedAt = "trashed_at"
    }
}

struct ImageRecord: Identifiable, Codable, FetchableRecord, MutablePersistableRecord, Equatable {
    var id: String
    var noteId: String?
    var filePath: String
    var thumbPath: String
    var width: Int?
    var height: Int?
    var mimeType: String?
    var source: String?
    var createdAt: Double
    var status: String
    var trashedAt: Double?

    static let databaseTableName = "images"

    enum CodingKeys: String, CodingKey {
        case id, width, height, source, status
        case noteId = "note_id"
        case filePath = "file_path"
        case thumbPath = "thumb_path"
        case mimeType = "mime_type"
        case createdAt = "created_at"
        case trashedAt = "trashed_at"
    }
}

struct AudioRecording: Identifiable, Codable, FetchableRecord, MutablePersistableRecord, Equatable {
    var id: String
    var noteId: String
    var filePath: String
    var durationSec: Double?
    var createdAt: Double

    static let databaseTableName = "audio_recordings"

    enum CodingKeys: String, CodingKey {
        case id
        case noteId = "note_id"
        case filePath = "file_path"
        case durationSec = "duration_sec"
        case createdAt = "created_at"
    }
}
```

- [ ] **Step 2: Build and commit**

```bash
git add Notetaker/Services/Models.swift
git commit -m "feat: Note, ImageRecord, AudioRecording domain models with GRDB conformance"
```

---

### Task 3.2: Implement `Database` service with migrations

**Files:**
- Create: `Notetaker/Services/Database.swift`

- [ ] **Step 1: Write the file**

```swift
// Notetaker/Services/Database.swift
import Foundation
import GRDB

final class Database {
    let dbQueue: DatabaseQueue

    /// In-memory DB for tests. Real app uses `init(appSupportURL:)`.
    init(inMemory: Bool = false) throws {
        if inMemory {
            dbQueue = try DatabaseQueue()
        } else {
            let url = try Self.defaultDatabaseURL()
            var config = Configuration()
            config.prepareDatabase { db in
                try db.execute(sql: "PRAGMA journal_mode = WAL")
            }
            dbQueue = try DatabaseQueue(path: url.path, configuration: config)
        }
        try migrator.migrate(dbQueue)
    }

    init(url: URL) throws {
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
        }
        dbQueue = try DatabaseQueue(path: url.path, configuration: config)
        try migrator.migrate(dbQueue)
    }

    static func defaultDatabaseURL() throws -> URL {
        let fm = FileManager.default
        let appSupport = try fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = appSupport.appendingPathComponent("Notetaker", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("notetaker.db")
    }

    private var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()

        m.registerMigration("v1_initial") { db in
            try db.create(table: "notes") { t in
                t.column("id", .text).primaryKey()
                t.column("title", .text)
                t.column("body", .text).notNull().defaults(to: "")
                t.column("created_at", .double).notNull()
                t.column("updated_at", .double).notNull()
                t.column("status", .text).notNull().defaults(to: "active")
                t.column("trashed_at", .double)
            }

            try db.create(table: "images") { t in
                t.column("id", .text).primaryKey()
                t.column("note_id", .text).references("notes", onDelete: .cascade)
                t.column("file_path", .text).notNull()
                t.column("thumb_path", .text).notNull()
                t.column("width", .integer)
                t.column("height", .integer)
                t.column("mime_type", .text)
                t.column("source", .text)
                t.column("created_at", .double).notNull()
                t.column("status", .text).notNull().defaults(to: "active")
                t.column("trashed_at", .double)
            }

            try db.create(table: "audio_recordings") { t in
                t.column("id", .text).primaryKey()
                t.column("note_id", .text).notNull()
                    .references("notes", onDelete: .cascade)
                t.column("file_path", .text).notNull()
                t.column("duration_sec", .double)
                t.column("created_at", .double).notNull()
            }

            try db.create(index: "idx_notes_status_updated",
                          on: "notes", columns: ["status", "updated_at"])
            try db.create(index: "idx_images_status_note",
                          on: "images", columns: ["status", "note_id", "created_at"])
        }

        return m
    }
}
```

- [ ] **Step 2: Build**

`⌘B`. Expected: succeeds.

- [ ] **Step 3: Commit**

```bash
git add Notetaker/Services/Database.swift
git commit -m "feat: GRDB Database with WAL + initial migration"
```

---

### Task 3.3: Write `DatabaseTests`

**Files:**
- Create: `NotetakerTests/DatabaseTests.swift`

- [ ] **Step 1: Write the tests**

```swift
// NotetakerTests/DatabaseTests.swift
import XCTest
import GRDB
@testable import Notetaker

final class DatabaseTests: XCTestCase {
    func test_migrations_createTables() throws {
        let db = try Database(inMemory: true)
        try db.dbQueue.read { conn in
            XCTAssertTrue(try conn.tableExists("notes"))
            XCTAssertTrue(try conn.tableExists("images"))
            XCTAssertTrue(try conn.tableExists("audio_recordings"))
        }
    }

    func test_note_roundTrip() throws {
        let db = try Database(inMemory: true)
        let now = Date().timeIntervalSince1970
        var note = Note(
            id: UUID().uuidString,
            title: "Test",
            body: "Hello world",
            createdAt: now,
            updatedAt: now,
            status: "active",
            trashedAt: nil
        )
        try db.dbQueue.write { conn in
            try note.insert(conn)
        }
        let fetched = try db.dbQueue.read { try Note.fetchOne($0, id: note.id) }
        XCTAssertEqual(fetched, note)
    }

    func test_cascadeDelete_notesDeleteAttachedImages() throws {
        let db = try Database(inMemory: true)
        let now = Date().timeIntervalSince1970
        let noteId = UUID().uuidString
        let note = Note(id: noteId, title: nil, body: "", createdAt: now,
                        updatedAt: now, status: "active", trashedAt: nil)
        let image = ImageRecord(
            id: UUID().uuidString, noteId: noteId,
            filePath: "images/x.png", thumbPath: "thumbs/x.jpg",
            width: 10, height: 10, mimeType: "image/png", source: "paste",
            createdAt: now, status: "active", trashedAt: nil
        )
        try db.dbQueue.write { conn in
            try note.insert(conn)
            try image.insert(conn)
        }
        try db.dbQueue.write { conn in
            try Note.deleteOne(conn, id: noteId)
        }
        let remaining = try db.dbQueue.read { try ImageRecord.fetchCount($0) }
        XCTAssertEqual(remaining, 0)
    }
}
```

- [ ] **Step 2: Run tests**

`⌘U` in Xcode, or:

```bash
xcodebuild test -scheme Notetaker -destination 'platform=macOS' -only-testing:NotetakerTests/DatabaseTests
```

Expected: all three tests PASS.

- [ ] **Step 3: Commit**

```bash
git add NotetakerTests/DatabaseTests.swift
git commit -m "test: Database migrations, note round-trip, cascade delete"
```

---

### Task 3.4: Implement `NoteStore`

**Files:**
- Create: `Notetaker/Services/NoteStore.swift`

- [ ] **Step 1: Write the file**

```swift
// Notetaker/Services/NoteStore.swift
import Foundation
import GRDB
import Combine

@MainActor
final class NoteStore: ObservableObject {
    @Published private(set) var notes: [Note] = []
    private let db: Database

    init(db: Database) {
        self.db = db
        reload()
    }

    func reload() {
        do {
            let fetched = try db.dbQueue.read { conn in
                try Note
                    .filter(Note.Columns.status == "active")
                    .order(Note.Columns.updatedAt.desc)
                    .fetchAll(conn)
            }
            self.notes = fetched
        } catch {
            NSLog("NoteStore reload failed: \(error)")
        }
    }

    @discardableResult
    func createNote() throws -> Note {
        let now = Date().timeIntervalSince1970
        var note = Note(
            id: UUID().uuidString,
            title: nil,
            body: "",
            createdAt: now,
            updatedAt: now,
            status: "active",
            trashedAt: nil
        )
        try db.dbQueue.write { try note.insert($0) }
        notes.insert(note, at: 0)
        return note
    }

    func updateBody(id: String, body: String) throws {
        guard let idx = notes.firstIndex(where: { $0.id == id }) else { return }
        var note = notes[idx]
        note.body = body
        note.title = Self.deriveTitle(from: body)
        note.updatedAt = Date().timeIntervalSince1970
        try db.dbQueue.write { try note.update($0) }
        notes.remove(at: idx)
        notes.insert(note, at: 0)
    }

    func trash(id: String) throws {
        guard let idx = notes.firstIndex(where: { $0.id == id }) else { return }
        var note = notes[idx]
        note.status = "trashed"
        note.trashedAt = Date().timeIntervalSince1970
        try db.dbQueue.write { try note.update($0) }
        notes.remove(at: idx)
    }

    static func deriveTitle(from body: String) -> String? {
        let firstLine = body.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(60))
    }
}
```

- [ ] **Step 2: Build**

`⌘B`. Expected: succeeds.

- [ ] **Step 3: Commit**

```bash
git add Notetaker/Services/NoteStore.swift
git commit -m "feat: NoteStore with CRUD, publishes @Published notes array"
```

---

### Task 3.5: Write `NoteStoreTests`

**Files:**
- Create: `NotetakerTests/NoteStoreTests.swift`

- [ ] **Step 1: Write tests**

```swift
// NotetakerTests/NoteStoreTests.swift
import XCTest
@testable import Notetaker

@MainActor
final class NoteStoreTests: XCTestCase {
    private func makeStore() throws -> NoteStore {
        let db = try Database(inMemory: true)
        return NoteStore(db: db)
    }

    func test_createNote_insertsAtTop() throws {
        let store = try makeStore()
        let n1 = try store.createNote()
        let n2 = try store.createNote()
        XCTAssertEqual(store.notes.map(\.id), [n2.id, n1.id])
    }

    func test_updateBody_refreshesTitleAndOrder() throws {
        let store = try makeStore()
        let n1 = try store.createNote()
        let n2 = try store.createNote()
        try store.updateBody(id: n1.id, body: "Hello world")
        XCTAssertEqual(store.notes.first?.id, n1.id)
        XCTAssertEqual(store.notes.first?.title, "Hello world")
    }

    func test_deriveTitle_takesFirstLineTrimmed() {
        XCTAssertEqual(NoteStore.deriveTitle(from: "  First  \nSecond"), "First")
        XCTAssertNil(NoteStore.deriveTitle(from: ""))
        XCTAssertEqual(
            NoteStore.deriveTitle(from: String(repeating: "a", count: 100)),
            String(repeating: "a", count: 60)
        )
    }

    func test_trash_removesFromActiveList() throws {
        let store = try makeStore()
        let n = try store.createNote()
        try store.trash(id: n.id)
        XCTAssertTrue(store.notes.isEmpty)
    }
}
```

- [ ] **Step 2: Run and verify**

Expected: all four tests PASS.

- [ ] **Step 3: Commit**

```bash
git add NotetakerTests/NoteStoreTests.swift
git commit -m "test: NoteStore create/update/trash/deriveTitle"
```

---

### Task 3.6: Implement `ImageStore`

**Files:**
- Create: `Notetaker/Services/ImageStore.swift`

- [ ] **Step 1: Write the file**

```swift
// Notetaker/Services/ImageStore.swift
import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers

@MainActor
final class ImageStore: ObservableObject {
    @Published private(set) var images: [ImageRecord] = []
    private let db: Database
    private let rootURL: URL

    init(db: Database, rootURL: URL? = nil) throws {
        self.db = db
        if let rootURL = rootURL {
            self.rootURL = rootURL
        } else {
            self.rootURL = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask, appropriateFor: nil, create: true
            ).appendingPathComponent("Notetaker", isDirectory: true)
        }
        try FileManager.default.createDirectory(
            at: self.rootURL.appendingPathComponent("images"),
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: self.rootURL.appendingPathComponent("thumbs"),
            withIntermediateDirectories: true)
        reload()
    }

    func reload() {
        do {
            let fetched = try db.dbQueue.read { conn in
                try ImageRecord
                    .filter(Column("status") == "active")
                    .order(Column("created_at").desc)
                    .fetchAll(conn)
            }
            self.images = fetched
        } catch {
            NSLog("ImageStore reload failed: \(error)")
        }
    }

    @discardableResult
    func saveImage(data: Data, mimeType: String, noteId: String?, source: String) throws -> ImageRecord {
        let id = UUID().uuidString
        let ext = Self.ext(for: mimeType)
        let fileRel = "images/\(id).\(ext)"
        let thumbRel = "thumbs/\(id).jpg"

        let fileURL = rootURL.appendingPathComponent(fileRel)
        let thumbURL = rootURL.appendingPathComponent(thumbRel)

        try data.write(to: fileURL)
        try Self.writeThumbnail(from: fileURL, to: thumbURL, maxPixel: 256)

        let (w, h) = Self.dimensions(of: fileURL)
        var record = ImageRecord(
            id: id, noteId: noteId,
            filePath: fileRel, thumbPath: thumbRel,
            width: w, height: h, mimeType: mimeType, source: source,
            createdAt: Date().timeIntervalSince1970,
            status: "active", trashedAt: nil
        )
        try db.dbQueue.write { try record.insert($0) }
        images.insert(record, at: 0)
        return record
    }

    func fullURL(for record: ImageRecord) -> URL {
        rootURL.appendingPathComponent(record.filePath)
    }

    func thumbURL(for record: ImageRecord) -> URL {
        rootURL.appendingPathComponent(record.thumbPath)
    }

    // MARK: - Helpers

    private static func ext(for mime: String) -> String {
        switch mime {
        case "image/png": return "png"
        case "image/jpeg": return "jpg"
        case "image/gif": return "gif"
        case "image/webp": return "webp"
        default: return "bin"
        }
    }

    private static func dimensions(of url: URL) -> (Int?, Int?) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        else { return (nil, nil) }
        let w = props[kCGImagePropertyPixelWidth] as? Int
        let h = props[kCGImagePropertyPixelHeight] as? Int
        return (w, h)
    }

    private static func writeThumbnail(from src: URL, to dst: URL, maxPixel: Int) throws {
        guard let imageSource = CGImageSourceCreateWithURL(src as CFURL, nil) else {
            throw NSError(domain: "ImageStore", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot read source image"])
        }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, opts as CFDictionary) else {
            throw NSError(domain: "ImageStore", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot create thumbnail"])
        }
        guard let outType = UTType.jpeg.identifier as CFString? ,
              let destination = CGImageDestinationCreateWithURL(dst as CFURL, outType, 1, nil) else {
            throw NSError(domain: "ImageStore", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot create thumb destination"])
        }
        CGImageDestinationAddImage(destination, thumb, nil)
        if !CGImageDestinationFinalize(destination) {
            throw NSError(domain: "ImageStore", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot finalize thumb"])
        }
    }
}
```

- [ ] **Step 2: Build and commit**

```bash
git add Notetaker/Services/ImageStore.swift
git commit -m "feat: ImageStore with thumbnail generation and file-system writes"
```

---

### Task 3.7: Write `ImageStoreTests`

**Files:**
- Create: `NotetakerTests/ImageStoreTests.swift`

- [ ] **Step 1: Write tests**

```swift
// NotetakerTests/ImageStoreTests.swift
import XCTest
import AppKit
@testable import Notetaker

@MainActor
final class ImageStoreTests: XCTestCase {
    private func makeStore() throws -> (ImageStore, URL) {
        let db = try Database(inMemory: true)
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotetakerTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let store = try ImageStore(db: db, rootURL: tmp)
        return (store, tmp)
    }

    private func tinyPNGData() -> Data {
        let image = NSImage(size: NSSize(width: 10, height: 10))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 10, height: 10).fill()
        image.unlockFocus()
        let tiff = image.tiffRepresentation!
        let rep = NSBitmapImageRep(data: tiff)!
        return rep.representation(using: .png, properties: [:])!
    }

    func test_saveImage_writesFilesAndInsertsRecord() throws {
        let (store, root) = try makeStore()
        let data = tinyPNGData()
        let rec = try store.saveImage(data: data, mimeType: "image/png",
                                      noteId: nil, source: "paste")

        XCTAssertEqual(store.images.count, 1)
        XCTAssertEqual(store.images.first?.id, rec.id)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(rec.filePath).path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(rec.thumbPath).path))
        XCTAssertEqual(rec.width, 10)
        XCTAssertEqual(rec.height, 10)
    }

    func test_saveImage_thumbnailIsReadable() throws {
        let (store, root) = try makeStore()
        let rec = try store.saveImage(data: tinyPNGData(), mimeType: "image/png",
                                      noteId: nil, source: "paste")
        let thumb = NSImage(contentsOf: root.appendingPathComponent(rec.thumbPath))
        XCTAssertNotNil(thumb)
    }
}
```

- [ ] **Step 2: Run tests and commit**

```bash
git add NotetakerTests/ImageStoreTests.swift
git commit -m "test: ImageStore saves files, generates thumbs, inserts record"
```

**Milestone 3 reached:** working DB layer with tested CRUD.

---

## Phase 4 — Text Notes (capture + copy)

Goal: Notes tab renders the list, has a composer, autosaves, copy-to-clipboard works. This is the first phase where the app is genuinely useful.

### Task 4.1: Wire stores into the app

**Files:**
- Modify: `Notetaker/App/AppDelegate.swift`
- Modify: `Notetaker/Panel/PanelWindowController.swift`

- [ ] **Step 1: Create a shared `AppEnvironment` holder**

Create `Notetaker/App/AppEnvironment.swift`:

```swift
// Notetaker/App/AppEnvironment.swift
import Foundation

@MainActor
final class AppEnvironment: ObservableObject {
    let database: Database
    let noteStore: NoteStore
    let imageStore: ImageStore

    init() throws {
        self.database = try Database()
        self.noteStore = NoteStore(db: database)
        self.imageStore = try ImageStore(db: database)
    }
}
```

- [ ] **Step 2: Modify `AppDelegate`**

```swift
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
            NSLog("Failed to init environment: \(error)")
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
                break // wired in Phase 6
            }
        }
    }
}
```

- [ ] **Step 3: Update `PanelWindowController` to accept env**

```swift
init(environment: AppEnvironment) {
    // ... (existing panel setup code) ...
    let host = NSHostingView(
        rootView: PanelRootView().environmentObject(environment)
    )
    // ... rest unchanged ...
}
```

- [ ] **Step 4: Build and commit**

```bash
git add -A
git commit -m "feat: AppEnvironment holds shared stores, injected into SwiftUI root"
```

---

### Task 4.2: Build `NotesListView` with composer

**Files:**
- Create: `Notetaker/Panel/NotesListView.swift`
- Modify: `Notetaker/Panel/PanelRootView.swift`

- [ ] **Step 1: Write `NotesListView.swift`**

```swift
// Notetaker/Panel/NotesListView.swift
import SwiftUI

struct NotesListView: View {
    @EnvironmentObject var env: AppEnvironment
    @State private var composerText: String = ""
    @State private var composerNoteId: String?

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                composer
                ForEach(env.noteStore.notes) { note in
                    NoteRow(note: note)
                        .padding(.horizontal, DS.Spacing.sm)
                }
            }
            .padding(.horizontal, DS.Spacing.sm)
            .padding(.vertical, DS.Spacing.sm)
        }
    }

    private var composer: some View {
        TextField("New note...", text: $composerText, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.nkBody)
            .foregroundStyle(DS.Color.textPrimary)
            .lineLimit(1...4)
            .padding(DS.Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.row)
                    .fill(DS.Color.bgSubtle)
            )
            .padding(.horizontal, DS.Spacing.sm)
            .onChange(of: composerText) { _, newValue in
                handleComposerChange(newValue)
            }
    }

    private func handleComposerChange(_ newValue: String) {
        if composerNoteId == nil && !newValue.isEmpty {
            do {
                let note = try env.noteStore.createNote()
                composerNoteId = note.id
                try env.noteStore.updateBody(id: note.id, body: newValue)
            } catch {
                NSLog("createNote failed: \(error)")
            }
        } else if let id = composerNoteId {
            if newValue.isEmpty {
                try? env.noteStore.trash(id: id)
                composerNoteId = nil
            } else {
                try? env.noteStore.updateBody(id: id, body: newValue)
            }
        }
    }
}

struct NoteRow: View {
    let note: Note

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(note.title ?? "Untitled")
                .font(.nkBody.weight(.medium))
                .foregroundStyle(DS.Color.textPrimary)
                .lineLimit(1)
            Text(relativeTimeString(from: note.updatedAt))
                .font(.nkLabel)
                .foregroundStyle(DS.Color.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DS.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.row)
                .fill(DS.Color.bgSubtle)
        )
    }

    private func relativeTimeString(from epoch: Double) -> String {
        let date = Date(timeIntervalSince1970: epoch)
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
```

- [ ] **Step 2: Wire into `PanelRootView`**

Replace the `.notes` case in `content`:

```swift
case .notes:
    NotesListView()
```

- [ ] **Step 3: Build, run, test**

`⌘R`. `Option+Space`. Type in the composer — note row should appear below with the title. Clear the composer — row disappears.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "feat: NotesListView with composer and row rendering"
```

---

### Task 4.3: Debounced autosave (polish existing composer)

**Files:**
- Modify: `Notetaker/Panel/NotesListView.swift`

- [ ] **Step 1: Add debounce**

Add property:

```swift
@State private var saveTask: Task<Void, Never>?
```

Modify `handleComposerChange`:

```swift
private func handleComposerChange(_ newValue: String) {
    saveTask?.cancel()
    saveTask = Task {
        try? await Task.sleep(nanoseconds: 500_000_000) // 500ms
        if Task.isCancelled { return }
        await MainActor.run { applyComposerChange(newValue) }
    }
}

private func applyComposerChange(_ newValue: String) {
    if composerNoteId == nil && !newValue.isEmpty {
        do {
            let note = try env.noteStore.createNote()
            composerNoteId = note.id
            try env.noteStore.updateBody(id: note.id, body: newValue)
        } catch { NSLog("createNote failed: \(error)") }
    } else if let id = composerNoteId {
        if newValue.isEmpty {
            try? env.noteStore.trash(id: id)
            composerNoteId = nil
        } else {
            try? env.noteStore.updateBody(id: id, body: newValue)
        }
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add Notetaker/Panel/NotesListView.swift
git commit -m "feat: debounced autosave (500ms idle) in composer"
```

---

### Task 4.4: Implement `ClipboardService` for text

**Files:**
- Create: `Notetaker/Services/ClipboardService.swift`

- [ ] **Step 1: Write**

```swift
// Notetaker/Services/ClipboardService.swift
import AppKit

struct ClipboardService {
    static func copy(text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    static func copy(images: [NSImage], fileURLs: [URL] = []) {
        let pb = NSPasteboard.general
        pb.clearContents()
        var items: [NSPasteboardItem] = []
        for (idx, image) in images.enumerated() {
            let item = NSPasteboardItem()
            if let tiff = image.tiffRepresentation {
                item.setData(tiff, forType: .tiff)
            }
            if let rep = image.representations.first as? NSBitmapImageRep,
               let png = rep.representation(using: .png, properties: [:]) {
                item.setData(png, forType: .png)
            }
            if idx < fileURLs.count {
                item.setString(fileURLs[idx].absoluteString, forType: .fileURL)
            }
            items.append(item)
        }
        pb.writeObjects(items)
    }

    static func copy(note: Note, attachedImages: [(NSImage, URL)]) {
        if attachedImages.isEmpty {
            copy(text: note.body)
            return
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        var items: [NSPasteboardItem] = []

        let textItem = NSPasteboardItem()
        textItem.setString(note.body, forType: .string)
        items.append(textItem)

        for (image, url) in attachedImages {
            let item = NSPasteboardItem()
            if let tiff = image.tiffRepresentation {
                item.setData(tiff, forType: .tiff)
            }
            item.setString(url.absoluteString, forType: .fileURL)
            items.append(item)
        }
        pb.writeObjects(items)
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add Notetaker/Services/ClipboardService.swift
git commit -m "feat: ClipboardService writes text, images (TIFF+PNG), and mixed payloads"
```

---

### Task 4.5: Write `ClipboardServiceTests`

**Files:**
- Create: `NotetakerTests/ClipboardServiceTests.swift`

- [ ] **Step 1: Write**

```swift
// NotetakerTests/ClipboardServiceTests.swift
import XCTest
import AppKit
@testable import Notetaker

final class ClipboardServiceTests: XCTestCase {
    override func tearDown() {
        NSPasteboard.general.clearContents()
    }

    func test_copyText_writesPlainString() {
        ClipboardService.copy(text: "Hello clipboard")
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "Hello clipboard")
    }

    func test_copyImage_writesTIFFAndPNG() {
        let img = NSImage(size: NSSize(width: 10, height: 10))
        img.lockFocus()
        NSColor.blue.setFill()
        NSRect(x: 0, y: 0, width: 10, height: 10).fill()
        img.unlockFocus()

        ClipboardService.copy(images: [img])
        XCTAssertNotNil(NSPasteboard.general.data(forType: .tiff))
        XCTAssertNotNil(NSPasteboard.general.data(forType: .png))
    }
}
```

- [ ] **Step 2: Run and commit**

```bash
git add NotetakerTests/ClipboardServiceTests.swift
git commit -m "test: ClipboardService writes text and image (TIFF+PNG) types"
```

---

### Task 4.6: Add `⌘C` copy behavior to focused note row

**Files:**
- Modify: `Notetaker/Panel/NotesListView.swift`

- [ ] **Step 1: Add focused-row state**

Replace the `body` of `NotesListView`:

```swift
@State private var focusedNoteId: String?

var body: some View {
    ScrollView {
        LazyVStack(spacing: 2) {
            composer
            ForEach(env.noteStore.notes) { note in
                NoteRow(note: note, isFocused: focusedNoteId == note.id)
                    .padding(.horizontal, DS.Spacing.sm)
                    .contentShape(Rectangle())
                    .onTapGesture { focusedNoteId = note.id }
            }
        }
        .padding(.horizontal, DS.Spacing.sm)
        .padding(.vertical, DS.Spacing.sm)
    }
    .onKeyPress(.init("c"), phases: .down) { press in
        guard press.modifiers.contains(.command),
              let id = focusedNoteId,
              let note = env.noteStore.notes.first(where: { $0.id == id })
        else { return .ignored }
        ClipboardService.copy(text: note.body)
        return .handled
    }
}
```

And update `NoteRow` to take `isFocused`:

```swift
struct NoteRow: View {
    let note: Note
    let isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(note.title ?? "Untitled")
                .font(.nkBody.weight(.medium))
                .foregroundStyle(DS.Color.textPrimary)
                .lineLimit(1)
            Text(relativeTimeString(from: note.updatedAt))
                .font(.nkLabel)
                .foregroundStyle(DS.Color.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DS.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.row)
                .fill(isFocused ? DS.Color.bgSelected : DS.Color.bgSubtle)
        )
    }

    private func relativeTimeString(from epoch: Double) -> String {
        let date = Date(timeIntervalSince1970: epoch)
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
```

- [ ] **Step 2: Build, run, test**

Type a note, click it (focus highlight appears), press `⌘C`, paste into any text field — body appears.

- [ ] **Step 3: Commit**

```bash
git add Notetaker/Panel/NotesListView.swift
git commit -m "feat: tap to focus note row, ⌘C copies body to clipboard"
```

**Milestone 4 reached:** you can open the panel, type a note, click it, copy with ⌘C, paste into Claude Code. This is the first genuinely useful state.

---

## Phase 5 — Images Tab

Goal: Images tab shows a grid of saved images with paste, drag-drop, multi-select, and copy.

### Task 5.1: Build `ImagesGridView` with paste support

**Files:**
- Create: `Notetaker/Panel/ImagesGridView.swift`
- Modify: `Notetaker/Panel/PanelRootView.swift`

- [ ] **Step 1: Write `ImagesGridView.swift`**

```swift
// Notetaker/Panel/ImagesGridView.swift
import SwiftUI
import AppKit

struct ImagesGridView: View {
    @EnvironmentObject var env: AppEnvironment
    @State private var selected: Set<String> = []

    private let columns = [
        GridItem(.flexible(), spacing: 6),
        GridItem(.flexible(), spacing: 6)
    ]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(env.imageStore.images) { record in
                    ImageCell(
                        record: record,
                        isSelected: selected.contains(record.id),
                        onTap: { toggleSelection(record.id, shift: NSEvent.modifierFlags.contains(.shift),
                                                  command: NSEvent.modifierFlags.contains(.command)) }
                    )
                }
            }
            .padding(DS.Spacing.sm)
        }
        .onKeyPress(.init("v"), phases: .down) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            handlePaste()
            return .handled
        }
        .onKeyPress(.init("c"), phases: .down) { press in
            guard press.modifiers.contains(.command), !selected.isEmpty else { return .ignored }
            copySelected()
            return .handled
        }
    }

    private func toggleSelection(_ id: String, shift: Bool, command: Bool) {
        if command {
            if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
        } else {
            selected = [id]
        }
    }

    private func handlePaste() {
        let pb = NSPasteboard.general
        guard let data = pb.data(forType: .tiff) ?? pb.data(forType: .png) else { return }
        let mime = pb.data(forType: .png) != nil ? "image/png" : "image/tiff"
        do {
            try env.imageStore.saveImage(data: data, mimeType: mime, noteId: nil, source: "paste")
        } catch { NSLog("paste save failed: \(error)") }
    }

    private func copySelected() {
        let records = env.imageStore.images.filter { selected.contains($0.id) }
        let imagesAndURLs: [(NSImage, URL)] = records.compactMap { rec in
            let url = env.imageStore.fullURL(for: rec)
            guard let img = NSImage(contentsOf: url) else { return nil }
            return (img, url)
        }
        ClipboardService.copy(images: imagesAndURLs.map(\.0), fileURLs: imagesAndURLs.map(\.1))
    }
}

struct ImageCell: View {
    let record: ImageRecord
    let isSelected: Bool
    let onTap: () -> Void
    @EnvironmentObject var env: AppEnvironment

    var body: some View {
        let url = env.imageStore.thumbURL(for: record)
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let img):
                img.resizable().aspectRatio(contentMode: .fill)
            default:
                Rectangle().fill(DS.Color.bgHover)
            }
        }
        .frame(height: 110)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.row))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.row)
                .stroke(isSelected ? DS.Color.accent : .clear, lineWidth: 2)
        )
        .overlay(alignment: .topTrailing) {
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(DS.Color.accent)
                    .background(Circle().fill(.black).padding(2))
                    .padding(4)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
    }
}
```

- [ ] **Step 2: Wire into `PanelRootView`**

Replace `.images` case:

```swift
case .images:
    ImagesGridView()
```

- [ ] **Step 3: Run and test**

Open panel → Images tab → copy an image from anywhere (e.g. a screenshot with `Cmd+Shift+4`) → `⌘V` inside the panel → image appears in grid. Click to select, `⌘C`, paste into any app.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "feat: ImagesGridView with paste-to-save, multi-select, ⌘C copy"
```

---

### Task 5.2: Drag-and-drop ingestion

**Files:**
- Modify: `Notetaker/Panel/ImagesGridView.swift`

- [ ] **Step 1: Add `.onDrop` modifier**

Add before `.onKeyPress`:

```swift
.onDrop(of: [.image, .fileURL], isTargeted: nil) { providers in
    Task {
        for provider in providers {
            if let data = try? await provider.loadDataRepresentation(for: .png) {
                try? env.imageStore.saveImage(data: data, mimeType: "image/png",
                                              noteId: nil, source: "drop")
            } else if let url = try? await provider.loadItem(forTypeIdentifier: "public.file-url") as? URL,
                      let data = try? Data(contentsOf: url) {
                let mime = url.pathExtension.lowercased() == "jpg" ? "image/jpeg" : "image/png"
                try? env.imageStore.saveImage(data: data, mimeType: mime,
                                              noteId: nil, source: "drop")
            }
        }
    }
    return true
}
```

Add helper extension at bottom of file:

```swift
private extension NSItemProvider {
    func loadDataRepresentation(for type: UTType) async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            self.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, err in
                if let data = data { cont.resume(returning: data) }
                else { cont.resume(throwing: err ?? NSError(domain: "drop", code: 1)) }
            }
        }
    }
}
```

- [ ] **Step 2: Run and test**

Drag an image from Finder onto the panel → appears in grid.

- [ ] **Step 3: Commit**

```bash
git add Notetaker/Panel/ImagesGridView.swift
git commit -m "feat: drag-and-drop images from Finder into Images tab"
```

**Milestone 5 reached:** full image capture + copy loop working.

---

## Phase 6 — Voice Capture

Goal: press `Option+V` → record mic → Whisper transcribes → new note appears.

### Task 6.1: Download and bundle Whisper model

- [ ] **Step 1: Download `small.en` GGML model**

```bash
cd "/Users/apple/Note taker app/Notetaker/Resources"
mkdir -p Models
curl -L -o Models/ggml-small.en.bin \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.en.bin
```

Expected: ~470MB downloaded.

- [ ] **Step 2: Download Core ML encoder**

```bash
curl -L -o Models/ggml-small.en-encoder.mlmodelc.zip \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.en-encoder.mlmodelc.zip
cd Models && unzip ggml-small.en-encoder.mlmodelc.zip && rm ggml-small.en-encoder.mlmodelc.zip
```

- [ ] **Step 3: Add files to Xcode project**

In Xcode, right-click `Resources` group → Add Files to Notetaker → select `Models/` folder → ensure "Copy items if needed" is **off** (we want them referenced in place), ensure the Notetaker target is checked.

- [ ] **Step 4: Verify bundled**

Build app, right-click the built `.app` in `~/Library/Developer/Xcode/DerivedData` → Show Package Contents → `Contents/Resources/Models/` should contain the files.

- [ ] **Step 5: Commit model placeholder (NOT the model binary)**

```bash
# Add .gitignore rule for the model files — they're too big for git
echo "Notetaker/Resources/Models/ggml-small.en.bin" >> .gitignore
echo "Notetaker/Resources/Models/ggml-small.en-encoder.mlmodelc/" >> .gitignore
git add .gitignore
git commit -m "chore: ignore Whisper model binaries (too large for git, downloaded via setup script)"
```

- [ ] **Step 6: Write setup script for future checkouts**

Create `scripts/fetch-whisper-model.sh`:

```bash
#!/usr/bin/env bash
set -e
cd "$(dirname "$0")/../Notetaker/Resources/Models"
if [ ! -f "ggml-small.en.bin" ]; then
  curl -L -o ggml-small.en.bin \
    https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.en.bin
fi
if [ ! -d "ggml-small.en-encoder.mlmodelc" ]; then
  curl -L -o encoder.zip \
    https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.en-encoder.mlmodelc.zip
  unzip encoder.zip && rm encoder.zip
fi
echo "Whisper models ready."
```

```bash
chmod +x scripts/fetch-whisper-model.sh
git add scripts/fetch-whisper-model.sh
git commit -m "chore: setup script to fetch Whisper models for fresh checkouts"
```

---

### Task 6.2: Implement `AudioRecorder`

**Files:**
- Create: `Notetaker/Services/AudioRecorder.swift`

- [ ] **Step 1: Write**

```swift
// Notetaker/Services/AudioRecorder.swift
import Foundation
import AVFoundation

final class AudioRecorder {
    private var audioEngine: AVAudioEngine?
    private var outputFile: AVAudioFile?
    private(set) var currentFileURL: URL?

    func startRecording() throws -> URL {
        let engine = AVAudioEngine()
        self.audioEngine = engine

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)

        // Target: 16kHz mono Int16 PCM for Whisper.
        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16000,
            channels: 1,
            interleaved: true
        )!

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ntk-\(UUID().uuidString).wav")
        let file = try AVAudioFile(forWriting: tmp,
                                   settings: targetFormat.settings,
                                   commonFormat: .pcmFormatInt16,
                                   interleaved: true)
        self.outputFile = file
        self.currentFileURL = tmp

        let converter = AVAudioConverter(from: inputFormat, to: targetFormat)!
        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            let out = AVAudioPCMBuffer(pcmFormat: targetFormat,
                                       frameCapacity: AVAudioFrameCount(targetFormat.sampleRate))!
            var err: NSError?
            converter.convert(to: out, error: &err) { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }
            if err == nil {
                try? self?.outputFile?.write(from: out)
            }
        }

        engine.prepare()
        try engine.start()
        return tmp
    }

    func stopRecording() -> URL? {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        outputFile = nil
        let url = currentFileURL
        currentFileURL = nil
        return url
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add Notetaker/Services/AudioRecorder.swift
git commit -m "feat: AudioRecorder captures mic → 16kHz mono WAV for Whisper"
```

---

### Task 6.3: Implement `WhisperService` wrapper

**Files:**
- Create: `Notetaker/Services/WhisperService.swift`

- [ ] **Step 1: Write**

```swift
// Notetaker/Services/WhisperService.swift
import Foundation
import whisper

final class WhisperService {
    private var ctx: OpaquePointer?

    func loadModel() throws {
        guard ctx == nil else { return }
        guard let modelURL = Bundle.main.url(
            forResource: "ggml-small.en",
            withExtension: "bin",
            subdirectory: "Models"
        ) else {
            throw NSError(domain: "Whisper", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Model not bundled"])
        }
        var params = whisper_context_default_params()
        params.use_gpu = true
        ctx = whisper_init_from_file_with_params(modelURL.path, params)
        if ctx == nil {
            throw NSError(domain: "Whisper", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to load model"])
        }
    }

    func transcribe(wavURL: URL) throws -> String {
        try loadModel()
        guard let ctx else { throw NSError(domain: "Whisper", code: 3) }

        let samples = try Self.readPCMSamples(from: wavURL)
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.print_progress = false
        params.print_special = false
        params.print_realtime = false
        params.language = ("en" as NSString).utf8String
        params.n_threads = Int32(max(1, ProcessInfo.processInfo.activeProcessorCount - 1))

        return try samples.withUnsafeBufferPointer { buf in
            let result = whisper_full(ctx, params, buf.baseAddress, Int32(buf.count))
            if result != 0 {
                throw NSError(domain: "Whisper", code: 4,
                              userInfo: [NSLocalizedDescriptionKey: "whisper_full failed \(result)"])
            }
            var text = ""
            let n = whisper_full_n_segments(ctx)
            for i in 0..<n {
                if let s = whisper_full_get_segment_text(ctx, i) {
                    text += String(cString: s)
                }
            }
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    static func readPCMSamples(from url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: 16000, channels: 1, interleaved: false)!
        guard let buf = AVAudioPCMBuffer(pcmFormat: format,
                                         frameCapacity: AVAudioFrameCount(file.length)) else {
            throw NSError(domain: "Whisper", code: 5)
        }
        try file.read(into: buf)
        let ptr = buf.floatChannelData![0]
        return Array(UnsafeBufferPointer(start: ptr, count: Int(buf.frameLength)))
    }
}
```

- [ ] **Step 2: Add `import AVFoundation` at top**

Top of file:

```swift
import AVFoundation
```

- [ ] **Step 3: Commit**

```bash
git add Notetaker/Services/WhisperService.swift
git commit -m "feat: WhisperService wraps whisper.cpp with en-only small model"
```

---

### Task 6.4: Build `RecordingPillView` as floating window

**Files:**
- Create: `Notetaker/Panel/RecordingPillView.swift`
- Create: `Notetaker/Panel/RecordingPillController.swift`

- [ ] **Step 1: Write `RecordingPillView.swift`**

```swift
// Notetaker/Panel/RecordingPillView.swift
import SwiftUI

enum RecordingState {
    case recording(elapsedSec: Int)
    case transcribing
    case done
}

struct RecordingPillView: View {
    let state: RecordingState

    var body: some View {
        HStack(spacing: 8) {
            icon
            label
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 22)
                .fill(.black.opacity(0.85))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22)
                .stroke(.white.opacity(0.1), lineWidth: 1)
        )
        .shadow(radius: 20)
    }

    @ViewBuilder
    private var icon: some View {
        switch state {
        case .recording:
            Circle()
                .fill(DS.Color.accent)
                .frame(width: 10, height: 10)
                .scaleEffect(1)
                .animation(.recordingPulse, value: UUID())
        case .transcribing:
            ProgressView().controlSize(.small)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        }
    }

    @ViewBuilder
    private var label: some View {
        switch state {
        case .recording(let secs):
            Text("Listening · \(secs)s").font(.nkMeta).foregroundStyle(.white)
        case .transcribing:
            Text("Transcribing…").font(.nkMeta).foregroundStyle(.white)
        case .done:
            Text("Saved").font(.nkMeta).foregroundStyle(.white)
        }
    }
}
```

- [ ] **Step 2: Write `RecordingPillController.swift`**

```swift
// Notetaker/Panel/RecordingPillController.swift
import AppKit
import SwiftUI

@MainActor
final class RecordingPillController {
    private var window: NSPanel?
    private var host: NSHostingView<AnyView>?
    private var currentState: RecordingState = .transcribing

    func show(state: RecordingState) {
        currentState = state
        if window == nil { createWindow() }
        host?.rootView = AnyView(RecordingPillView(state: state))
        window?.orderFrontRegardless()
    }

    func hide() {
        window?.orderOut(nil)
    }

    private func createWindow() {
        let size = NSSize(width: 180, height: 44)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered, defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true

        let host = NSHostingView(rootView: AnyView(RecordingPillView(state: currentState)))
        host.frame = NSRect(origin: .zero, size: size)
        panel.contentView = host

        if let screen = NSScreen.main {
            let x = screen.visibleFrame.midX - size.width / 2
            let y = screen.visibleFrame.maxY - size.height - 40
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        self.window = panel
        self.host = host
    }
}
```

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "feat: RecordingPillView + floating panel controller"
```

---

### Task 6.5: Wire push-to-talk into AppDelegate

**Files:**
- Modify: `Notetaker/App/AppDelegate.swift`

- [ ] **Step 1: Add services + state**

```swift
final class AppDelegate: NSObject, NSApplicationDelegate {
    var environment: AppEnvironment?
    var menuBarController: MenuBarController?
    var panelController: PanelWindowController?
    var hotkeyService: HotkeyService?

    let recorder = AudioRecorder()
    let whisper = WhisperService()
    let pill = RecordingPillController()
    private var isRecording = false
    private var recordStartTime: Date?
    private var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        do {
            let env = try AppEnvironment()
            self.environment = env
            panelController = PanelWindowController(environment: env)
        } catch {
            NSLog("Failed to init environment: \(error)")
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
                Task { @MainActor in self?.togglePTT() }
            }
        }
    }

    @MainActor
    private func togglePTT() {
        if isRecording {
            stopRecordingAndTranscribe()
        } else {
            startRecording()
        }
    }

    @MainActor
    private func startRecording() {
        do {
            _ = try recorder.startRecording()
            isRecording = true
            recordStartTime = Date()
            pill.show(state: .recording(elapsedSec: 0))
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let start = self.recordStartTime else { return }
                    let secs = Int(Date().timeIntervalSince(start))
                    self.pill.show(state: .recording(elapsedSec: secs))
                }
            }
        } catch {
            NSLog("startRecording failed: \(error)")
        }
    }

    @MainActor
    private func stopRecordingAndTranscribe() {
        timer?.invalidate(); timer = nil
        guard let wav = recorder.stopRecording() else { return }
        isRecording = false
        pill.show(state: .transcribing)

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                let text = try self.whisper.transcribe(wavURL: wav)
                await MainActor.run {
                    self.saveVoiceNote(text: text, wavURL: wav)
                    self.pill.show(state: .done)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        self.pill.hide()
                    }
                }
            } catch {
                NSLog("transcribe failed: \(error)")
                await MainActor.run { self.pill.hide() }
            }
        }
    }

    @MainActor
    private func saveVoiceNote(text: String, wavURL: URL) {
        guard let env = environment, !text.isEmpty else { return }
        do {
            let note = try env.noteStore.createNote()
            try env.noteStore.updateBody(id: note.id, body: text)
            // (Audio file persistence to audio_recordings table deferred to Task 6.6.)
        } catch {
            NSLog("saveVoiceNote failed: \(error)")
        }
    }
}
```

- [ ] **Step 2: Build, run, test**

Press `Option+V`, say something, press `Option+V` again. Pill shows Listening → Transcribing → Saved. New note appears in Notes tab with transcription.

- [ ] **Step 3: Commit**

```bash
git add Notetaker/App/AppDelegate.swift
git commit -m "feat: Option+V push-to-talk flow (record, Whisper, create note)"
```

---

### Task 6.6: Persist audio file for replay

**Files:**
- Modify: `Notetaker/App/AppDelegate.swift`
- Modify: `Notetaker/Services/NoteStore.swift` (add helper)

- [ ] **Step 1: Add helper to `NoteStore`**

```swift
func addAudioRecording(noteId: String, wavSource: URL, durationSec: Double?) throws {
    let id = UUID().uuidString
    let fm = FileManager.default
    let root = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                          appropriateFor: nil, create: true)
        .appendingPathComponent("Notetaker", isDirectory: true)
        .appendingPathComponent("audio", isDirectory: true)
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    let dst = root.appendingPathComponent("\(id).wav")
    if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
    try fm.moveItem(at: wavSource, to: dst)

    var rec = AudioRecording(
        id: id, noteId: noteId,
        filePath: "audio/\(id).wav",
        durationSec: durationSec,
        createdAt: Date().timeIntervalSince1970
    )
    try db.dbQueue.write { try rec.insert($0) }
}
```

- [ ] **Step 2: Call from `saveVoiceNote`**

```swift
private func saveVoiceNote(text: String, wavURL: URL) {
    guard let env = environment, !text.isEmpty else { return }
    do {
        let note = try env.noteStore.createNote()
        try env.noteStore.updateBody(id: note.id, body: text)
        try env.noteStore.addAudioRecording(noteId: note.id, wavSource: wavURL, durationSec: nil)
    } catch {
        NSLog("saveVoiceNote failed: \(error)")
    }
}
```

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "feat: persist voice-note audio to audio/ and audio_recordings table"
```

**Milestone 6 reached:** full capture trio — text, image, voice.

---

## Phase 7 — Auto-Recycle

Goal: notes/images past their retention window move to trash; past trash window get permanently deleted (rows + files).

### Task 7.1: Implement `RetentionService`

**Files:**
- Create: `Notetaker/Services/RetentionService.swift`

- [ ] **Step 1: Write**

```swift
// Notetaker/Services/RetentionService.swift
import Foundation
import GRDB

@MainActor
final class RetentionService {
    private let db: Database
    private let imageRoot: URL
    private var timer: Timer?
    private let clock: () -> Date

    var retentionSeconds: Double = 2 * 24 * 3600     // 2 days default
    var trashRetentionSeconds: Double = 7 * 24 * 3600 // 7 days default

    init(db: Database, imageRoot: URL, clock: @escaping () -> Date = Date.init) {
        self.db = db
        self.imageRoot = imageRoot
        self.clock = clock
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in try? self?.sweep() }
        }
        try? sweep() // initial sweep at launch
    }

    func sweep() throws {
        let now = clock().timeIntervalSince1970
        try db.dbQueue.write { conn in
            // Pass 1: active → trashed
            try conn.execute(sql: """
                UPDATE notes SET status = 'trashed', trashed_at = ?
                WHERE status = 'active' AND updated_at < ?
            """, arguments: [now, now - retentionSeconds])
            try conn.execute(sql: """
                UPDATE images SET status = 'trashed', trashed_at = ?
                WHERE status = 'active' AND created_at < ?
            """, arguments: [now, now - retentionSeconds])

            // Pass 2: trashed → permanent delete
            let expiredImages = try ImageRecord
                .filter(Column("status") == "trashed"
                        && Column("trashed_at") != nil
                        && Column("trashed_at") < (now - trashRetentionSeconds))
                .fetchAll(conn)
            for img in expiredImages {
                let full = imageRoot.appendingPathComponent(img.filePath)
                let thumb = imageRoot.appendingPathComponent(img.thumbPath)
                try? FileManager.default.removeItem(at: full)
                try? FileManager.default.removeItem(at: thumb)
            }
            try conn.execute(sql: """
                DELETE FROM images WHERE status = 'trashed' AND trashed_at < ?
            """, arguments: [now - trashRetentionSeconds])
            try conn.execute(sql: """
                DELETE FROM notes WHERE status = 'trashed' AND trashed_at < ?
            """, arguments: [now - trashRetentionSeconds])
        }
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add Notetaker/Services/RetentionService.swift
git commit -m "feat: RetentionService sweeps active→trashed→deleted on 30min timer"
```

---

### Task 7.2: Test `RetentionService` with injected clock

**Files:**
- Create: `NotetakerTests/RetentionServiceTests.swift`

- [ ] **Step 1: Write**

```swift
// NotetakerTests/RetentionServiceTests.swift
import XCTest
import GRDB
@testable import Notetaker

@MainActor
final class RetentionServiceTests: XCTestCase {
    func test_sweep_movesOldActiveToTrashed() throws {
        let db = try Database(inMemory: true)
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        let fakeNow = Date(timeIntervalSince1970: 10_000_000)
        let threeDaysAgo = fakeNow.addingTimeInterval(-3 * 24 * 3600).timeIntervalSince1970
        var oldNote = Note(id: "old", title: nil, body: "x",
                           createdAt: threeDaysAgo, updatedAt: threeDaysAgo,
                           status: "active", trashedAt: nil)
        var newNote = Note(id: "new", title: nil, body: "y",
                           createdAt: fakeNow.timeIntervalSince1970,
                           updatedAt: fakeNow.timeIntervalSince1970,
                           status: "active", trashedAt: nil)
        try db.dbQueue.write {
            try oldNote.insert($0)
            try newNote.insert($0)
        }

        let svc = RetentionService(db: db, imageRoot: tmp, clock: { fakeNow })
        try svc.sweep()

        let fetchedOld = try db.dbQueue.read { try Note.fetchOne($0, id: "old") }
        let fetchedNew = try db.dbQueue.read { try Note.fetchOne($0, id: "new") }
        XCTAssertEqual(fetchedOld?.status, "trashed")
        XCTAssertEqual(fetchedNew?.status, "active")
    }

    func test_sweep_hardDeletesOldTrashed() throws {
        let db = try Database(inMemory: true)
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        let fakeNow = Date(timeIntervalSince1970: 10_000_000)
        let tenDaysAgo = fakeNow.addingTimeInterval(-10 * 24 * 3600).timeIntervalSince1970
        var oldTrash = Note(id: "t", title: nil, body: "", createdAt: tenDaysAgo,
                            updatedAt: tenDaysAgo, status: "trashed", trashedAt: tenDaysAgo)
        try db.dbQueue.write { try oldTrash.insert($0) }

        let svc = RetentionService(db: db, imageRoot: tmp, clock: { fakeNow })
        try svc.sweep()

        let fetched = try db.dbQueue.read { try Note.fetchOne($0, id: "t") }
        XCTAssertNil(fetched)
    }
}
```

- [ ] **Step 2: Run tests, commit**

```bash
git add NotetakerTests/RetentionServiceTests.swift
git commit -m "test: RetentionService sweeps active→trashed and hard-deletes trashed"
```

---

### Task 7.3: Start retention on launch

**Files:**
- Modify: `Notetaker/App/AppEnvironment.swift`
- Modify: `Notetaker/App/AppDelegate.swift`

- [ ] **Step 1: Add to environment**

```swift
@MainActor
final class AppEnvironment: ObservableObject {
    let database: Database
    let noteStore: NoteStore
    let imageStore: ImageStore
    let retentionService: RetentionService

    init() throws {
        self.database = try Database()
        self.noteStore = NoteStore(db: database)
        self.imageStore = try ImageStore(db: database)
        let imageRoot = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ).appendingPathComponent("Notetaker", isDirectory: true)
        self.retentionService = RetentionService(db: database, imageRoot: imageRoot)
    }
}
```

- [ ] **Step 2: Start service in AppDelegate**

After `self.environment = env`:

```swift
env.retentionService.start()
```

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "feat: start RetentionService on app launch"
```

**Milestone 7 reached:** auto-recycle is live.

---

## Phase 8 — Settings + Launch at Login

### Task 8.1: Settings window with retention controls

**Files:**
- Create: `Notetaker/Settings/SettingsWindow.swift`
- Modify: `Notetaker/NotetakerApp.swift`

- [ ] **Step 1: Write `SettingsWindow.swift`**

```swift
// Notetaker/Settings/SettingsWindow.swift
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
                .onChange(of: retentionDays) { _, new in
                    env.retentionService.retentionSeconds = Double(new) * 24 * 3600
                }
                Picker("Trash kept for", selection: $trashRetentionDays) {
                    Text("Immediate").tag(0)
                    Text("7 days").tag(7)
                    Text("14 days").tag(14)
                    Text("30 days").tag(30)
                }
                .onChange(of: trashRetentionDays) { _, new in
                    env.retentionService.trashRetentionSeconds = Double(new) * 24 * 3600
                }
            }
            Section("Launch") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
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
        }
        .padding(20)
        .frame(width: 360)
    }
}
```

- [ ] **Step 2: Wire into `NotetakerApp`**

```swift
@main
struct NotetakerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            if let env = appDelegate.environment {
                SettingsView().environmentObject(env)
            } else {
                Text("Loading…").padding()
            }
        }
    }
}
```

- [ ] **Step 3: Build, run, open Settings via `⌘,`**

Test the retention pickers — sweep behavior updates.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "feat: Settings window with retention pickers and launch-at-login"
```

---

## Phase 9 — Polish + Ship

### Task 9.1: App icon

- [ ] **Step 1: Generate / use icon**

Open `Assets.xcassets/AppIcon`. Add 1024×1024 PNG for macOS. Use SF Symbols-style minimal pencil-in-notebook design, or generate via Pixelmator. Xcode auto-derives smaller sizes.

- [ ] **Step 2: Build, verify icon appears**

In Finder, see `.app` bundle icon.

- [ ] **Step 3: Commit**

```bash
git add Notetaker/Resources/Assets.xcassets/AppIcon.appiconset
git commit -m "chore: add app icon"
```

---

### Task 9.2: Empty states

**Files:**
- Modify: `Notetaker/Panel/NotesListView.swift`
- Modify: `Notetaker/Panel/ImagesGridView.swift`

- [ ] **Step 1: Add empty state to `NotesListView`**

Inside the `ScrollView`, after composer:

```swift
if env.noteStore.notes.isEmpty {
    VStack(spacing: 8) {
        Image(systemName: "square.and.pencil")
            .font(.system(size: 36))
            .foregroundStyle(DS.Color.textTertiary)
        Text("Nothing yet. Start typing above.")
            .font(.nkMeta)
            .foregroundStyle(DS.Color.textTertiary)
    }
    .frame(maxWidth: .infinity)
    .padding(.top, 60)
}
```

- [ ] **Step 2: Add to `ImagesGridView`**

```swift
if env.imageStore.images.isEmpty {
    VStack(spacing: 8) {
        Image(systemName: "photo.on.rectangle.angled")
            .font(.system(size: 36))
            .foregroundStyle(DS.Color.textTertiary)
        Text("Nothing caught your eye yet. Paste or drop an image.")
            .font(.nkMeta)
            .foregroundStyle(DS.Color.textTertiary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 40)
    }
    .frame(maxWidth: .infinity)
    .padding(.top, 60)
}
```

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "feat: warm empty states for Notes and Images tabs"
```

---

### Task 9.3: Accessibility permission prompt on first launch

**Files:**
- Modify: `Notetaker/App/AppDelegate.swift`

- [ ] **Step 1: Add check + prompt**

Top of `applicationDidFinishLaunching`:

```swift
if !AXIsProcessTrusted() {
    let opts = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true] as CFDictionary
    _ = AXIsProcessTrustedWithOptions(opts)
}
```

(Import `ApplicationServices` at top of file.)

- [ ] **Step 2: Commit**

```bash
git add Notetaker/App/AppDelegate.swift
git commit -m "feat: prompt for Accessibility permission on first launch"
```

---

### Task 9.4: Codesign + DMG

- [ ] **Step 1: Set up signing in Xcode**

Project → Notetaker target → Signing & Capabilities → choose your Personal Team. Automatic signing.

- [ ] **Step 2: Archive**

Product → Archive. Wait. Organizer opens.

- [ ] **Step 3: Export as Developer ID-signed app**

If you have a paid Developer ID: Export → Developer ID → proceed through notarization. Otherwise "Copy App" exports an ad-hoc signed app (self-install only).

- [ ] **Step 4: Create DMG (optional for personal use)**

```bash
hdiutil create -volname Notetaker -srcfolder ~/Desktop/Notetaker.app -ov -format UDZO ~/Desktop/Notetaker.dmg
```

- [ ] **Step 5: Install and verify**

Drag `Notetaker.app` into `/Applications`. Launch. Grant permissions. Press `Option+Space` → app works.

- [ ] **Step 6: Tag v1.0**

```bash
git tag v1.0 -m "Notetaker v1.0 — text + voice + images + retention"
git log --oneline | head -20
```

**Milestone 9 reached (ship):** installable, signed, daily-driver-ready macOS app.

---

## Self-review checklist (run before executing)

Spec coverage vs tasks:

| Spec section | Task(s) |
|---|---|
| §2 In scope — menu bar panel | Phase 1 |
| §2 — Notes tab | Phase 4 |
| §2 — Images tab | Phase 5 |
| §2 — Whisper voice | Phase 6 |
| §2 — Global hotkeys | Task 1.3 |
| §2 — Clipboard copy | Tasks 4.4-4.5, 5.1 |
| §2 — Auto-recycle | Phase 7 |
| §2 — Settings | Task 8.1 |
| §2 — Launch at login | Task 8.1 |
| §2 — Local SQLite | Phase 3 |
| §2 — Codesigned DMG | Task 9.4 |
| §3 Design DNA rules | Phase 2 (DesignTokens, Animations, Typography) |
| §4 Architecture layers | Phase 1 (shell) → Phase 4+5+6 (features) |
| §5 Data model | Phase 3 |
| §6 F1-F6 flows | Phases 1, 4, 5, 6, 7 |
| §9 Testing | Tests appear in Tasks 3.3, 3.5, 3.7, 4.5, 7.2 |

Gaps: WhisperService test is not written (noted in spec §9.1 but omitted from plan because model is too large to check into git). Acceptable — we add a local-only smoke test after the model is downloaded.

No placeholders, no "TBD", no "similar to Task N". Type names used consistently across tasks (`Note`, `ImageRecord`, `AudioRecording`, `Database`, `NoteStore`, `ImageStore`, `WhisperService`, `AudioRecorder`, `ClipboardService`, `RetentionService`, `HotkeyService`, `MenuBarController`, `PanelWindowController`, `PanelRootView`, `NotesListView`, `ImagesGridView`, `NoteEditorView`, `RecordingPillView`).

Ready for execution.
