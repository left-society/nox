import XCTest
import AppKit
@testable import nox

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
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 10, height: 10).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }

    func test_saveImage_writesFilesAndInsertsRecord() throws {
        let (store, root) = try makeStore()
        let data = tinyPNGData()
        let rec = try store.saveImage(
            data: data,
            mimeType: "image/png",
            noteId: nil,
            source: "paste"
        )

        XCTAssertEqual(store.images.count, 1)
        XCTAssertEqual(store.images.first?.id, rec.id)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(rec.filePath).path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(rec.thumbPath).path
        ))
        XCTAssertEqual(rec.width, 10)
        XCTAssertEqual(rec.height, 10)
    }

    func test_saveImage_thumbnailIsReadable() throws {
        let (store, root) = try makeStore()
        let rec = try store.saveImage(
            data: tinyPNGData(),
            mimeType: "image/png",
            noteId: nil,
            source: "paste"
        )
        let thumb = NSImage(contentsOf: root.appendingPathComponent(rec.thumbPath))
        XCTAssertNotNil(thumb)
    }

    /// Two saves of the same bytes should resolve to the same record —
    /// hash-based dedup short-circuits the second save before any file
    /// or DB write happens.
    func test_saveImage_dedupesByContentHash() throws {
        let (store, _) = try makeStore()
        let data = tinyPNGData()
        let first = try store.saveImage(
            data: data,
            mimeType: "image/png",
            noteId: nil,
            source: "paste"
        )
        let second = try store.saveImage(
            data: data,
            mimeType: "image/png",
            noteId: nil,
            source: "paste"
        )
        XCTAssertEqual(first.id, second.id, "Same bytes must dedup to the same record id")
        XCTAssertEqual(store.images.count, 1, "Library must contain exactly one row for one unique image")
        XCTAssertNotNil(first.sha256)
        XCTAssertEqual(first.sha256?.count, 64, "SHA-256 hex digest is 64 chars")
    }

    func test_saveImage_distinctBytesProduceDistinctRecords() throws {
        let (store, _) = try makeStore()
        let red = tinyPNGData()
        // A tiny blue PNG so the bytes differ from the red one.
        let bluePNG: Data = {
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
            return rep.representation(using: .png, properties: [:])!
        }()
        let r1 = try store.saveImage(
            data: red,
            mimeType: "image/png",
            noteId: nil,
            source: "paste"
        )
        let r2 = try store.saveImage(
            data: bluePNG,
            mimeType: "image/png",
            noteId: nil,
            source: "paste"
        )
        XCTAssertNotEqual(r1.id, r2.id)
        XCTAssertNotEqual(r1.sha256, r2.sha256)
        XCTAssertEqual(store.images.count, 2)
    }
}
