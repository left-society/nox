import XCTest
import AppKit
@testable import Notetaker

final class ClipboardRouterTests: XCTestCase {
    private func freshPasteboard() -> NSPasteboard {
        let pb = NSPasteboard(name: NSPasteboard.Name(rawValue: "Notetaker.RouterTest.\(UUID().uuidString)"))
        pb.clearContents()
        return pb
    }

    func test_emptyPasteboard_returnsNone() {
        let pb = freshPasteboard()
        XCTAssertEqual(ClipboardRouter.decide(pasteboard: pb), .none)
    }

    func test_plainText_routesToNotes() {
        let pb = freshPasteboard()
        pb.setString("hello clipboard", forType: .string)

        if case .notes(let text) = ClipboardRouter.decide(pasteboard: pb) {
            XCTAssertEqual(text, "hello clipboard")
        } else {
            XCTFail("expected .notes")
        }
    }

    func test_whitespaceOnlyText_returnsNone() {
        let pb = freshPasteboard()
        pb.setString("   \n\t  ", forType: .string)
        XCTAssertEqual(ClipboardRouter.decide(pasteboard: pb), .none)
    }

    func test_youtubeURL_routesToVideos() {
        let pb = freshPasteboard()
        pb.setString("https://www.youtube.com/watch?v=dQw4w9WgXcQ", forType: .string)

        if case .videos(let url) = ClipboardRouter.decide(pasteboard: pb) {
            XCTAssertEqual(url.absoluteString, "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
        } else {
            XCTFail("expected .videos")
        }
    }

    func test_pngData_routesToImages() {
        let pb = freshPasteboard()
        let png = Self.makeTinyPNG()
        pb.setData(png, forType: .png)

        if case .images(let data, let mime) = ClipboardRouter.decide(pasteboard: pb) {
            XCTAssertGreaterThan(data.count, 0)
            XCTAssertEqual(mime, "image/png")
        } else {
            XCTFail("expected .images")
        }
    }

    func test_imageFileURL_routesToImages() throws {
        let tmp = try Self.writeTempFile(name: "pic.png", data: Self.makeTinyPNG())
        defer { try? FileManager.default.removeItem(at: tmp) }
        let pb = freshPasteboard()
        pb.writeObjects([tmp as NSURL])

        if case .images = ClipboardRouter.decide(pasteboard: pb) {
            // pass
        } else {
            XCTFail("expected .images for image file URL")
        }
    }

    func test_videoFileURL_routesToVideos() throws {
        let tmp = try Self.writeTempFile(name: "clip.mp4", data: Data([0x00, 0x00, 0x00]))
        defer { try? FileManager.default.removeItem(at: tmp) }
        let pb = freshPasteboard()
        pb.writeObjects([tmp as NSURL])

        if case .videos(let url) = ClipboardRouter.decide(pasteboard: pb) {
            XCTAssertEqual(url.lastPathComponent, "clip.mp4")
        } else {
            XCTFail("expected .videos for video file URL")
        }
    }

    func test_genericFileURL_routesToFiles() throws {
        let tmp = try Self.writeTempFile(name: "doc.pdf", data: Data([0x25, 0x50, 0x44, 0x46]))
        defer { try? FileManager.default.removeItem(at: tmp) }
        let pb = freshPasteboard()
        pb.writeObjects([tmp as NSURL])

        if case .files(let urls) = ClipboardRouter.decide(pasteboard: pb) {
            XCTAssertEqual(urls.first?.lastPathComponent, "doc.pdf")
        } else {
            XCTFail("expected .files for pdf URL")
        }
    }

    func test_multipleFileURLs_routesToFilesWithAll() throws {
        let a = try Self.writeTempFile(name: "a.pdf", data: Data([0x25, 0x50]))
        let b = try Self.writeTempFile(name: "b.zip", data: Data([0x50, 0x4B]))
        defer {
            try? FileManager.default.removeItem(at: a)
            try? FileManager.default.removeItem(at: b)
        }
        let pb = freshPasteboard()
        pb.writeObjects([a as NSURL, b as NSURL])

        if case .files(let urls) = ClipboardRouter.decide(pasteboard: pb) {
            XCTAssertEqual(urls.count, 2)
        } else {
            XCTFail("expected .files for multiple URLs")
        }
    }

    // MARK: - Privacy markers (org.nspasteboard.*)

    func test_concealedType_returnsNone() {
        let pb = freshPasteboard()
        let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
        pb.declareTypes([.string, concealed], owner: nil)
        pb.setString("supersecret", forType: .string)
        pb.setData(Data([0x01]), forType: concealed)
        XCTAssertEqual(ClipboardRouter.decide(pasteboard: pb), .none)
    }

    func test_transientType_returnsNone() {
        let pb = freshPasteboard()
        let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
        pb.declareTypes([.string, transient], owner: nil)
        pb.setString("ephemeral", forType: .string)
        pb.setData(Data([0x01]), forType: transient)
        XCTAssertEqual(ClipboardRouter.decide(pasteboard: pb), .none)
    }

    // MARK: - Helpers

    private static func makeTinyPNG() -> Data {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 4, pixelsHigh: 4,
            bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 16, bitsPerPixel: 32
        )!
        return rep.representation(using: .png, properties: [:]) ?? Data()
    }

    private static func writeTempFile(name: String, data: Data) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }
}
