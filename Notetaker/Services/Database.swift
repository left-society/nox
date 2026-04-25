import Foundation
import GRDB

final class Database {
    let dbQueue: DatabaseQueue

    init(inMemory: Bool = false) throws {
        if inMemory {
            dbQueue = try DatabaseQueue()
        } else {
            let url = try Self.defaultDatabaseURL()
            var config = Configuration()
            config.foreignKeysEnabled = true
            config.prepareDatabase { db in
                try db.execute(sql: "PRAGMA journal_mode = WAL")
            }
            dbQueue = try DatabaseQueue(path: url.path, configuration: config)
        }
        try migrator.migrate(dbQueue)
    }

    init(url: URL) throws {
        var config = Configuration()
        config.foreignKeysEnabled = true
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
        }
        dbQueue = try DatabaseQueue(path: url.path, configuration: config)
        try migrator.migrate(dbQueue)
    }

    static func defaultDatabaseURL() throws -> URL {
        let fm = FileManager.default
        let appSupport = try fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = appSupport.appendingPathComponent("Notetaker", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("notetaker.db")
    }

    private var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()

        m.registerMigration("v1_initial") { db in
            try db.create(table: "notes") { t in
                t.column("id", .text).primaryKey()
                t.column("title", .text)
                t.column("body", .text).notNull().defaults(to: "")
                t.column("created_at", .double).notNull()
                t.column("updated_at", .double).notNull()
                t.column("status", .text).notNull().defaults(to: "active")
                t.column("trashed_at", .double)
            }

            try db.create(table: "images") { t in
                t.column("id", .text).primaryKey()
                t.column("note_id", .text).references("notes", onDelete: .cascade)
                t.column("file_path", .text).notNull()
                t.column("thumb_path", .text).notNull()
                t.column("width", .integer)
                t.column("height", .integer)
                t.column("mime_type", .text)
                t.column("source", .text)
                t.column("created_at", .double).notNull()
                t.column("status", .text).notNull().defaults(to: "active")
                t.column("trashed_at", .double)
            }

            try db.create(table: "audio_recordings") { t in
                t.column("id", .text).primaryKey()
                t.column("note_id", .text).notNull()
                    .references("notes", onDelete: .cascade)
                t.column("file_path", .text).notNull()
                t.column("duration_sec", .double)
                t.column("created_at", .double).notNull()
            }

            try db.create(
                index: "idx_notes_status_updated",
                on: "notes",
                columns: ["status", "updated_at"]
            )
            try db.create(
                index: "idx_images_status_note",
                on: "images",
                columns: ["status", "note_id", "created_at"]
            )
        }

        m.registerMigration("v2_videos") { db in
            try db.create(table: "videos") { t in
                t.column("id", .text).primaryKey()
                t.column("note_id", .text).references("notes", onDelete: .cascade)
                t.column("file_path", .text).notNull()
                t.column("thumb_path", .text).notNull()
                t.column("source_url", .text)
                t.column("title", .text)
                t.column("width", .integer)
                t.column("height", .integer)
                t.column("duration_sec", .double)
                t.column("size_bytes", .integer)
                t.column("mime_type", .text)
                t.column("source", .text)
                t.column("created_at", .double).notNull()
                t.column("status", .text).notNull().defaults(to: "active")
                t.column("trashed_at", .double)
            }
            try db.create(
                index: "idx_videos_status_created",
                on: "videos",
                columns: ["status", "created_at"]
            )
            try db.create(
                index: "idx_videos_source_url",
                on: "videos",
                columns: ["source_url"]
            )
        }

        m.registerMigration("v3_image_expiry") { db in
            try db.alter(table: "images") { t in
                t.add(column: "expires_at", .double)
            }
            try db.create(
                index: "idx_images_expires_at",
                on: "images",
                columns: ["expires_at"]
            )
        }

        return m
    }
}
