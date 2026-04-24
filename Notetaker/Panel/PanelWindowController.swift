import AppKit
import SwiftUI

private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class PanelWindowController {
    static let panelSize = NSSize(width: 480, height: 640)
    private static let cornerRadius: CGFloat = 10
    private static let gapBelowMenuBar: CGFloat = 8
    private static let dropRise: CGFloat = 6

    private let panel: NSPanel
    private var isVisible = false
    private var clickOutsideMonitor: Any?
    private var keyMonitor: Any?

    weak var menuBarController: MenuBarController?

    init() {
        let contentRect = NSRect(origin: .zero, size: PanelWindowController.panelSize)

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

        let visualEffect = NSVisualEffectView()
        visualEffect.material = .hudWindow
        visualEffect.blendingMode = .behindWindow
        visualEffect.state = .active
        visualEffect.wantsLayer = true
        visualEffect.layer?.cornerRadius = PanelWindowController.cornerRadius
        visualEffect.layer?.cornerCurve = .continuous
        visualEffect.layer?.masksToBounds = true

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
        let finalOrigin = originUnderMenuBarIcon()
        panel.setFrameOrigin(NSPoint(x: finalOrigin.x, y: finalOrigin.y + PanelWindowController.dropRise))
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.makeKey()

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.28
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1.0)
            ctx.allowsImplicitAnimation = true
            panel.animator().setFrameOrigin(finalOrigin)
            panel.animator().alphaValue = 1
        }
        isVisible = true

        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            self?.hide()
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
        removeMonitors()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.panel.orderOut(nil)
        })
        isVisible = false
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

    private func originUnderMenuBarIcon() -> NSPoint {
        let size = PanelWindowController.panelSize
        if let iconFrame = menuBarController?.iconFrame {
            let x = iconFrame.midX - size.width / 2
            let y = iconFrame.minY - size.height - PanelWindowController.gapBelowMenuBar
            return NSPoint(x: x, y: y)
        }
        if let screen = NSScreen.main {
            let x = screen.visibleFrame.maxX - size.width - 20
            let y = screen.visibleFrame.maxY - size.height - 20
            return NSPoint(x: x, y: y)
        }
        return .zero
    }
}
