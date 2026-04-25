import AppKit
import CoreServices

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

// Watches the user's screenshot directory via FSEvents. The previous
// NSMetadataQuery-based approach silently failed in the sandboxed
// app — didFinishGathering never fires and the Spotlight scope returns
// nothing. FSEvents on a specific user-readable directory is fast
// (sub-second), reliable, and doesn't need Spotlight access.
@MainActor
final class ScreenshotWatcher: NSObject {
    private var stream: FSEventStreamRef?
    private var seenPaths: Set<String> = []
    private let onNewScreenshot: (URL) -> Void
    private let watchedDir: URL

    init(onNewScreenshot: @escaping (URL) -> Void) {
        self.onNewScreenshot = onNewScreenshot
        self.watchedDir = Self.screenshotDirectory()
        super.init()
    }

    /// Honors the user's configured `com.apple.screencapture location`
    /// preference. Falls back to ~/Desktop, the macOS default.
    private static func screenshotDirectory() -> URL {
        if let configured = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location") {
            let expanded = (configured as NSString).expandingTildeInPath
            return URL(fileURLWithPath: expanded)
        }
        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Desktop")
    }

    func start() {
        // Seed seenPaths with everything currently in the watched
        // directory so we don't fire onNewScreenshot for pre-existing
        // files when the stream warms up.
        if let existing = try? FileManager.default.contentsOfDirectory(atPath: watchedDir.path) {
            for name in existing {
                seenPaths.insert((watchedDir.path as NSString).appendingPathComponent(name))
            }
        }
        NSLog("Notetaker: ScreenshotWatcher watching \(watchedDir.path), seeded \(seenPaths.count) existing files")

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = {
            _, clientCallBackInfo, numEvents, eventPaths, eventFlags, _ in
            guard let info = clientCallBackInfo else { return }
            let watcher = Unmanaged<ScreenshotWatcher>.fromOpaque(info).takeUnretainedValue()
            // With kFSEventStreamCreateFlagUseCFTypes the eventPaths arg is a
            // CFArray<CFString>, toll-free bridged to NSArray.
            let nsArray = unsafeBitCast(eventPaths, to: NSArray.self)
            guard let paths = nsArray as? [String] else { return }
            for i in 0..<numEvents {
                let flags = eventFlags[i]
                let path = paths[i]
                let isFile = (flags & UInt32(kFSEventStreamEventFlagItemIsFile)) != 0
                let isCreated = (flags & UInt32(kFSEventStreamEventFlagItemCreated)) != 0
                let isRenamed = (flags & UInt32(kFSEventStreamEventFlagItemRenamed)) != 0
                let isModified = (flags & UInt32(kFSEventStreamEventFlagItemModified)) != 0
                if isFile && (isCreated || isRenamed || isModified) {
                    DispatchQueue.main.async {
                        watcher.handleEvent(path: path)
                    }
                }
            }
        }

        let pathsToWatch = [watchedDir.path] as CFArray
        let createFlags = UInt32(
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagUseCFTypes |
            kFSEventStreamCreateFlagNoDefer
        )
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.3,
            createFlags
        ) else {
            NSLog("Notetaker: ScreenshotWatcher FSEventStreamCreate failed")
            return
        }
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        FSEventStreamStart(stream)
        self.stream = stream
        NSLog("Notetaker: ScreenshotWatcher started FSEvents stream")
    }

    func stop() {
        if let stream = stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
    }

    private func handleEvent(path: String) {
        guard !seenPaths.contains(path) else { return }
        let ext = (path as NSString).pathExtension.lowercased()
        let imageExts: Set<String> = ["png", "jpg", "jpeg", "tiff", "tif", "gif", "webp", "heic", "heif"]
        guard imageExts.contains(ext) else { return }
        guard FileManager.default.fileExists(atPath: path) else { return }
        guard Self.looksLikeScreenshot(path: path) else { return }
        seenPaths.insert(path)
        NSLog("Notetaker: ScreenshotWatcher new screenshot at \(path)")
        onNewScreenshot(URL(fileURLWithPath: path))
    }

    /// Filename prefix OR Spotlight xattr — covers macOS English-locale
    /// screenshots (the common case) and localized variants where macOS
    /// sets `kMDItemIsScreenCapture` regardless of language. Also accepts
    /// CleanShot which prefixes its filenames identifiably.
    private static func looksLikeScreenshot(path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        if name.hasPrefix("Screenshot ") || name.hasPrefix("Screen Shot ") {
            return true
        }
        if name.hasPrefix("CleanShot ") {
            return true
        }
        let attr = "com.apple.metadata:kMDItemIsScreenCapture"
        return getxattr(path, attr, nil, 0, 0, 0) > 0
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
