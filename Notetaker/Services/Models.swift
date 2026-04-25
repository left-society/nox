import Foundation
import GRDB

struct Note: Identifiable, Codable, FetchableRecord, MutablePersistableRecord, Equatable {
    var id: String
    var title: String?
    var body: String
    var createdAt: Double
    var updatedAt: Double
    var status: String
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
    var expiresAt: Double?
    /// Content hash (SHA-256, lowercase hex) for duplicate detection.
    /// Optional because rows created before migration v4 won't have it
    /// — those rows simply don't participate in dedup until rewritten.
    var sha256: String?

    static let databaseTableName = "images"

    enum Columns {
        static let id = Column("id")
        static let noteId = Column("note_id")
        static let filePath = Column("file_path")
        static let thumbPath = Column("thumb_path")
        static let status = Column("status")
        static let createdAt = Column("created_at")
        static let trashedAt = Column("trashed_at")
        static let expiresAt = Column("expires_at")
        static let sha256 = Column("sha256")
    }

    enum CodingKeys: String, CodingKey {
        case id, width, height, source, status, sha256
        case noteId = "note_id"
        case filePath = "file_path"
        case thumbPath = "thumb_path"
        case mimeType = "mime_type"
        case createdAt = "created_at"
        case trashedAt = "trashed_at"
        case expiresAt = "expires_at"
    }
}

struct VideoRecord: Identifiable, Codable, FetchableRecord, MutablePersistableRecord, Equatable {
    var id: String
    var noteId: String?
    var filePath: String
    var thumbPath: String
    var sourceUrl: String?
    var title: String?
    var width: Int?
    var height: Int?
    var durationSec: Double?
    var sizeBytes: Int?
    var mimeType: String?
    var source: String?
    var createdAt: Double
    var status: String
    var trashedAt: Double?

    static let databaseTableName = "videos"

    enum Columns {
        static let id = Column("id")
        static let noteId = Column("note_id")
        static let filePath = Column("file_path")
        static let thumbPath = Column("thumb_path")
        static let sourceUrl = Column("source_url")
        static let status = Column("status")
        static let createdAt = Column("created_at")
        static let trashedAt = Column("trashed_at")
    }

    enum CodingKeys: String, CodingKey {
        case id, title, width, height, source, status
        case noteId = "note_id"
        case filePath = "file_path"
        case thumbPath = "thumb_path"
        case sourceUrl = "source_url"
        case durationSec = "duration_sec"
        case sizeBytes = "size_bytes"
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
