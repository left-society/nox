import XCTest
import AppKit
@testable import Notetaker

final class ImageOCRServiceTests: XCTestCase {
    func test_extractsRenderedText() async throws {
        let url = try Self.renderTestImage(text: "Hello Notetaker")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let result = await ImageOCRService.extractText(from: url)
        let extracted = try XCTUnwrap(
            result,
            "Vision returned nil — recognizer did not produce any candidates"
        )
        XCTAssertTrue(
            extracted.localizedCaseInsensitiveContains("hello"),
            "expected the substring 'hello' in OCR output, got: \(extracted)"
        )
    }

    func test_returnsNilForUnreadableURL() async {
        let url = URL(fileURLWithPath: "/tmp/this-file-definitely-does-not-exist-\(UUID().uuidString).png")
        let result = await ImageOCRService.extractText(from: url)
        XCTAssertNil(result, "expected nil when image cannot be loaded")
    }

    private static func renderTestImage(text: String) throws -> URL {
        let size = NSSize(width: 480, height: 120)
        let img = NSImage(size: size)
        img.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 48, weight: .semibold),
            .foregroundColor: NSColor.black
        ]
        NSAttributedString(string: text, attributes: attrs)
            .draw(at: NSPoint(x: 20, y: 30))
        img.unlockFocus()

        let tiff = try XCTUnwrap(img.tiffRepresentation)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("ocr.png")
        try png.write(to: url)
        return url
    }
}
