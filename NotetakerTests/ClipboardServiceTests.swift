import XCTest
import AppKit
@testable import nox

final class ClipboardServiceTests: XCTestCase {
    override func tearDown() {
        NSPasteboard.general.clearContents()
        super.tearDown()
    }

    func test_copyText_writesPlainString() {
        ClipboardService.copy(text: "Hello clipboard")
        XCTAssertEqual(
            NSPasteboard.general.string(forType: .string),
            "Hello clipboard"
        )
    }

    func test_copyImage_writesTIFFAndPNG() {
        let img = Self.makeTestImage()
        ClipboardService.copy(images: [img])
        XCTAssertNotNil(NSPasteboard.general.data(forType: .tiff))
        XCTAssertNotNil(NSPasteboard.general.data(forType: .png))
    }

    func test_copyFileURLs_writesURLsToPasteboard() {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("CopyTest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let a = tmp.appendingPathComponent("one.pdf")
        let b = tmp.appendingPathComponent("two.zip")
        try? Data([0x25, 0x50]).write(to: a)
        try? Data([0x50, 0x4B]).write(to: b)
        defer { try? FileManager.default.removeItem(at: tmp) }

        ClipboardService.copy(fileURLs: [a, b])

        let urls = NSPasteboard.general.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []
        XCTAssertEqual(urls.count, 2)
        XCTAssertEqual(urls.map { $0.lastPathComponent }, ["one.pdf", "two.zip"])
    }

    private static func makeTestImage() -> NSImage {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 10,
            pixelsHigh: 10,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 40,
            bitsPerPixel: 32
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.blue.setFill()
        NSRect(x: 0, y: 0, width: 10, height: 10).fill()
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: NSSize(width: 10, height: 10))
        image.addRepresentation(rep)
        return image
    }
}
