import AppKit
import SwiftUI

private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class PanelWindowController {
    static let panelWidth: CGFloat = 340
    static let panelHeight: CGFloat = 620
    private static let cornerRadius: CGFloat = 8
    private static let edgeGap: CGFloat = 10
    private static let topGap: CGFloat = 40

    static func panelSize(for screen: NSScreen?) -> NSSize {
        let available = (screen ?? NSScreen.main)?.visibleFrame.height ?? 800
        return NSSize(width: panelWidth, height: min(panelHeight, available - topGap - 24))
    }

    private let panel: NSPanel
    private let presenter: PanelPresenter
    private let environment: AppEnvironment
    private(set) var isVisible = false
    private var clickOutsideMonitor: Any?
    private var keyMonitor: Any?
    private var hideWorkItem: DispatchWorkItem?

    weak var menuBarController: MenuBarController?

    init(environment: AppEnvironment) {
        self.environment = environment
        let presenter = PanelPresenter()
        self.presenter = presenter
        let size = PanelWindowController.panelSize(for: NSScreen.main)
        let contentRect = NSRect(origin: .zero, size: size)

        panel = KeyablePanel(
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

        let host = NSHostingView(
            rootView: PanelRootView()
                .environmentObject(environment)
                .environmentObject(presenter)
        )
        host.frame = contentRect
        host.autoresizingMask = [.width, .height]

        // Wrap the SwiftUI host in an NSView that handles drag-destination
        // routing at the contentView level. This bypasses SwiftUI's
        // hit-testing entirely, so drops land regardless of which tab is
        // active or whether a child SwiftUI view registered the drag types.
        let container = PanelDropContainer(
            hosting: host,
            onVideo: { [weak presenter, weak environment] candidate in
                guard let presenter, let environment else { return }
                switch candidate {
                case .localFile(let url):
                    _ = try? environment.videoStore.saveLocalFile(url)
                case .remoteURL(let s):
                    _ = environment.videoStore.startDownload(url: s)
                }
                presenter.activeTab = .videos
            },
            onImage: { [weak presenter, weak environment] data, mime in
                guard let presenter, let environment else { return }
                _ = try? environment.imageStore.saveImage(
                    data: data,
                    mimeType: mime,
                    noteId: nil,
                    source: "drop"
                )
                presenter.activeTab = .images
            },
            onTargeted: { [weak presenter] flag in
                presenter?.isDropTargeted = flag
            }
        )
        container.frame = contentRect
        container.autoresizingMask = [.width, .height]

        panel.contentView = container
    }

    func toggle() {
        if isVisible {
            hide()
        } else {
            show()
        }
    }

    func showOnTab(_ tab: PanelTab) {
        presenter.activeTab = tab
        if !isVisible { show() }
    }

    func show() {
        hideWorkItem?.cancel()
        hideWorkItem = nil

        let size = PanelWindowController.panelSize(for: NSScreen.main)
        panel.setContentSize(size)
        panel.setFrameOrigin(originOnRightEdge(for: size))
        panel.alphaValue = 1
        presenter.isShown = false
        panel.orderFrontRegardless()
        panel.makeKey()
        let screens = NSScreen.screens.map { "\($0.frame)" }.joined(separator: " | ")
        NSLog("Notetaker: show() panel.frame=\(panel.frame) main=\(NSScreen.main?.frame ?? .zero) screens=\(screens)")

        // Flip on the next runloop tick so SwiftUI sees false→true and animates the spring.
        DispatchQueue.main.async { [weak self] in
            self?.presenter.isShown = true
        }
        isVisible = true

        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            guard let self else { return }
            // Don't yank the panel away while a download is still running —
            // the user needs to see the progress bar to trust that the
            // hotkey actually worked. The jobs list auto-clears itself once
            // everything is in a terminal state, so this is self-resetting.
            let activeDownload = self.environment.videoStore.jobs
                .contains { !$0.state.isTerminal }
            if activeDownload {
                NSLog("Notetaker: global mouse-down → keep panel up (download in flight)")
                return
            }
            NSLog("Notetaker: global mouse-down → hide")
            self.hide()
        }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                self?.hide()
                return nil
            }
            return event
        }
    }

    func hide() {
        NSLog("Notetaker: hide() called, isVisible=\(isVisible)")
        guard isVisible else { return }
        removeMonitors()
        presenter.isShown = false
        isVisible = false

        let item = DispatchWorkItem { [weak self] in
            self?.panel.orderOut(nil)
        }
        hideWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.24, execute: item)
    }

    private func removeMonitors() {
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
            clickOutsideMonitor = nil
        }
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }

    private func originOnRightEdge(for size: NSSize) -> NSPoint {
        let screen = NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let x = visible.maxX - size.width - PanelWindowController.edgeGap
        let y = visible.maxY - size.height - PanelWindowController.topGap
        return NSPoint(x: x, y: y)
    }
}
