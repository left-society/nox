import Foundation
import GRDB

struct Note: Identifiable, Codable, FetchableRecord, MutablePersistableRecord, Equatable {
    var id: String
    var title: String?
    var body: String
    /// Gemini-generated one-line summary. Populated asynchronously
    /// after the note is saved; until it lands, the list row falls
    /// back to the derived title (first line of body). Nullable so
    /// legacy rows from before the v5 migration display cleanly.
    var summary: String?
    var createdAt: Double
    var updatedAt: Double
    var status: String
    var trashedAt: Double?
    /// What KIND of note this is. Two flavours coexist in the same
    /// list / DB:
    ///   • `handwritten` — user typed it in the editor (intentional).
    ///   • `clipboard`   — auto-saved from a copy event (transient).
    /// The Notes tab UI shows a 3-way filter pill ("All / Notes /
    /// Clipboard") that segments on this column. Default is
    /// `handwritten` so legacy rows from before the v6 migration
    /// (everything that existed before this feature) read as
    /// "real notes" — which is what the user expected them to be
    /// since the feature didn't exist yet.
    var kind: String  // "handwritten" | "clipboard"
    /// Optional video companion URL. When set, opening the note in
    /// the editor also opens a side-panel WKWebView that loads this
    /// URL — for taking notes alongside a YouTube tutorial, lecture,
    /// podcast, etc. Persisted per-note so re-opening the note
    /// reattaches the same video without retyping the link. Nullable
    /// so the vast majority of notes (no video) cost a single byte
    /// each.
    var videoURL: String?

    static let databaseTableName = "notes"

    /// Strongly-typed kind enum for in-memory use. Stored as TEXT
    /// in SQLite (via the `kind: String` column above) so we can
    /// add new variants without a schema migration.
    enum Kind: String {
        case handwritten
        case clipboard
    }

    enum Columns {
        static let id = Column("id")
        static let title = Column("title")
        static let body = Column("body")
        static let summary = Column("summary")
        static let createdAt = Column("created_at")
        static let updatedAt = Column("updated_at")
        static let status = Column("status")
        static let trashedAt = Column("trashed_at")
        static let kind = Column("kind")
        static let videoURL = Column("video_url")
    }

    enum CodingKeys: String, CodingKey {
        case id, title, body, summary, status, kind
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case trashedAt = "trashed_at"
        case videoURL = "video_url"
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
