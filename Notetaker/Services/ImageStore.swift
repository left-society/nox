import Foundation
import AppKit
import GRDB
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
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            ).appendingPathComponent("Notetaker", isDirectory: true)
        }
        try FileManager.default.createDirectory(
            at: self.rootURL.appendingPathComponent("images"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: self.rootURL.appendingPathComponent("thumbs"),
            withIntermediateDirectories: true
        )
        reload()
    }

    func reload() {
        do {
            let fetched = try db.dbQueue.read { conn in
                try ImageRecord
                    .filter(ImageRecord.Columns.status == "active")
                    .order(ImageRecord.Columns.createdAt.desc)
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
            id: id,
            noteId: noteId,
            filePath: fileRel,
            thumbPath: thumbRel,
            width: w,
            height: h,
            mimeType: mimeType,
            source: source,
            createdAt: Date().timeIntervalSince1970,
            status: "active",
            trashedAt: nil
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
            throw NSError(
                domain: "ImageStore",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Cannot read source image"]
            )
        }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, opts as CFDictionary) else {
            throw NSError(
                domain: "ImageStore",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Cannot create thumbnail"]
            )
        }
        guard let destination = CGImageDestinationCreateWithURL(
            dst as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw NSError(
                domain: "ImageStore",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Cannot create thumb destination"]
            )
        }
        CGImageDestinationAddImage(destination, thumb, nil)
        if !CGImageDestinationFinalize(destination) {
            throw NSError(
                domain: "ImageStore",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Cannot finalize thumb"]
            )
        }
    }
}
