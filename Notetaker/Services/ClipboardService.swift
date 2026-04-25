import AppKit

enum ClipboardService {
    static func copy(text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        ClipboardMonitor.shared?.acknowledge()
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
        ClipboardMonitor.shared?.acknowledge()
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
        ClipboardMonitor.shared?.acknowledge()
    }
}

// MARK: - Drag Monitor

// Polls the system's drag pasteboard so we can detect when the user has
// started dragging something. When the drag contains image-like data we
// pop the panel open on the Images tab so they can drop into it.
final class DragMonitor {
    private var timer: Timer?
    private var lastCount: Int
    private let onImageDrag: () -> Void
    private let onVideoDrag: () -> Void

    init(onImageDrag: @escaping () -> Void, onVideoDrag: @escaping () -> Void) {
        self.lastCount = NSPasteboard(name: .drag).changeCount
        self.onImageDrag = onImageDrag
        self.onVideoDrag = onVideoDrag
    }

    func start() {
        timer?.invalidate()
        lastCount = NSPasteboard(name: .drag).changeCount
        let timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            self?.check()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func check() {
        let pb = NSPasteboard(name: .drag)
        let current = pb.changeCount
        guard current != lastCount else { return }
        lastCount = current

        if VideoDropScanner.looksLikeVideo(in: pb) {
            onVideoDrag()
            return
        }

        let imageTypes: [NSPasteboard.PasteboardType] = [
            .png, .tiff, .fileURL,
            NSPasteboard.PasteboardType("public.image"),
            NSPasteboard.PasteboardType("public.jpeg"),
            NSPasteboard.PasteboardType("com.compuserve.gif"),
            NSPasteboard.PasteboardType("org.webmproject.webp")
        ]
        if pb.availableType(from: imageTypes) != nil {
            onImageDrag()
        }
    }
}

// MARK: - Screenshot Watcher

// Uses Spotlight to detect new screenshots anywhere on the system (works
// regardless of the user's configured screenshot location). When one
// appears we pop the panel on Images tab and auto-save the file.
@MainActor
final class ScreenshotWatcher: NSObject {
    private let query = NSMetadataQuery()
    private var seenPaths: Set<String> = []
    private let onNewScreenshot: (URL) -> Void

    init(onNewScreenshot: @escaping (URL) -> Void) {
        self.onNewScreenshot = onNewScreenshot
        super.init()
    }

    func start() {
        query.predicate = NSPredicate(format: "kMDItemIsScreenCapture = 1")
        query.searchScopes = [NSMetadataQueryLocalComputerScope]

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(didFinishGathering),
            name: .NSMetadataQueryDidFinishGathering,
            object: query
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(didUpdate),
            name: .NSMetadataQueryDidUpdate,
            object: query
        )

        query.start()
    }

    func stop() {
        query.stop()
    }

    @objc private func didFinishGathering(_ notification: Notification) {
        query.disableUpdates()
        for i in 0..<query.resultCount {
            if let item = query.result(at: i) as? NSMetadataItem,
               let path = item.value(forAttribute: NSMetadataItemPathKey) as? String {
                seenPaths.insert(path)
            }
        }
        query.enableUpdates()
    }

    @objc private func didUpdate(_ notification: Notification) {
        guard let added = notification.userInfo?[NSMetadataQueryUpdateAddedItemsKey] as? [NSMetadataItem] else {
            return
        }
        for item in added {
            guard let path = item.value(forAttribute: NSMetadataItemPathKey) as? String else { continue }
            if seenPaths.contains(path) { continue }
            seenPaths.insert(path)
            onNewScreenshot(URL(fileURLWithPath: path))
        }
    }
}

// MARK: - Clipboard Monitor

final class ClipboardMonitor {
    static weak var shared: ClipboardMonitor?

    private var timer: Timer?
    private var lastCount: Int
    private let onExternalChange: () -> Void

    init(onExternalChange: @escaping () -> Void) {
        self.lastCount = NSPasteboard.general.changeCount
        self.onExternalChange = onExternalChange
        ClipboardMonitor.shared = self
    }

    func start() {
        timer?.invalidate()
        lastCount = NSPasteboard.general.changeCount
        let timer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in
            self?.check()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func acknowledge() {
        lastCount = NSPasteboard.general.changeCount
    }

    private func check() {
        let current = NSPasteboard.general.changeCount
        guard current != lastCount else { return }
        lastCount = current
        onExternalChange()
    }
}
