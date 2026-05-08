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
                // Per BUG-049 fix: NORMAL is 5-10× faster on small
                // writes than the default FULL and is still safe
                // when WAL is enabled (durability is preserved
                // across crashes; only an OS-level kernel panic in
                // a sub-millisecond window can lose a transaction).
                // Every note save, screenshot save, and summary
                // backfill goes through this — the FULL cost was
                // measurable and unnecessary.
                try db.execute(sql: "PRAGMA synchronous = NORMAL")
                // Per BUG-050 fix: with no busy_timeout, an external
                // SQLite reader (Xcode DB browser, dev tools)
                // briefly holding a lock causes our writes to
                // throw `SQLITE_BUSY`. 5s gives plenty of headroom
                // for transient lock contention while still
                // surfacing genuinely stuck states as errors.
                try db.execute(sql: "PRAGMA busy_timeout = 5000")
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
        // Folder name resolution lives on AppEnvironment so the
        // legacy-folder migration (Notetaker/ → nox/) has a single
        // source of truth. Database file name stays as `notetaker.db`
        // intentionally — it's never user-visible (lives inside the
        // Application Support folder), and renaming the SQLite file
        // would force another migration step with zero user benefit.
        let dir = try AppEnvironment.applicationSupportDirectory()
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

        m.registerMigration("v4_image_sha256") { db in
            // Content hash for duplicate detection. Nullable so legacy
            // rows from before this migration don't blow up — they
            // simply don't dedup against new pastes (and the next
            // duplicate save will produce one redundant record before
            // it self-heals on subsequent saves of the same content).
            // Composite index `(sha256, status)` matches the lookup
            // shape `WHERE sha256 = ? AND status = 'active'`.
            try db.alter(table: "images") { t in
                t.add(column: "sha256", .text)
            }
            try db.create(
                index: "idx_images_sha256_status",
                on: "images",
                columns: ["sha256", "status"]
            )
        }

        m.registerMigration("v5_note_summary") { db in
            // Gemini-generated one-line summary of the note body. Shown
            // in the list row instead of the raw first-line title, so
            // notes are easier to scan at a glance ("what was this
            // about?" instead of "what were the first 5 words?").
            // Nullable: legacy rows have no summary until they're
            // re-saved or backfilled, and the row falls back to
            // showing the derived title in that case. Backfill is
            // best-effort lazy — `NoteStore.summarize(id:)` fires
            // when a note is opened or saved.
            try db.alter(table: "notes") { t in
                t.add(column: "summary", .text)
            }
        }

        m.registerMigration("v6_note_kind") { db in
            // Tag each note with what KIND of capture it was — either
            // 'handwritten' (user typed in the editor) or 'clipboard'
            // (auto-saved from a copy event). User asked for this
            // separation so the Notes list doesn't drown intentional
            // captures under copied URLs and snippets.
            //
            // Default 'handwritten' for legacy rows: at the time these
            // were created the auto-save feature funneled clipboard
            // captures into the same Note table without flagging them,
            // so we genuinely can't distinguish historically. Treating
            // them all as handwritten keeps the All / Notes filters
            // showing the same content the user is used to seeing,
            // and only NEW clipboard captures get the new tag.
            try db.alter(table: "notes") { t in
                t.add(column: "kind", .text).notNull().defaults(to: "handwritten")
            }
            // Lookup index — list filtering ("show only clipboard")
            // and the active-note query both ORDER BY updated_at DESC
            // and now also FILTER by kind. Index covers both.
            try db.create(
                index: "notes_kind_status_updated_idx",
                on: "notes",
                columns: ["kind", "status", "updated_at"],
                ifNotExists: true
            )
        }

        m.registerMigration("v7_note_video_url") { db in
            // Optional companion-video URL per note. When set, opening
            // the note in the editor also pops a side-panel WKWebView
            // loading this URL — for taking notes alongside a tutorial,
            // lecture, podcast, etc. Nullable; vast majority of notes
            // never set it, so the column cost is a single byte each.
            try db.alter(table: "notes") { t in
                t.add(column: "video_url", .text)
            }
        }

        m.registerMigration("v8_scripts") { db in
            // Teleprompter scripts — pasted text the user wants to
            // read on camera while looking at the notch. Stored
            // alongside notes/images/videos rather than as a special
            // note kind because they have script-specific metadata
            // (WPM, last-read offset for resume) that doesn't fit
            // the notes schema cleanly.
            try db.create(table: "scripts") { t in
                t.column("id", .text).primaryKey()
                t.column("title", .text)
                t.column("body", .text).notNull()
                t.column("wpm", .integer).notNull().defaults(to: 150)
                t.column("last_read_offset", .integer).notNull().defaults(to: 0)
                t.column("created_at", .double).notNull()
                t.column("updated_at", .double).notNull()
                t.column("status", .text).notNull().defaults(to: "active")
                t.column("trashed_at", .double)
            }
            // Same composite index pattern as notes — list query
            // filters by status and orders by updated_at DESC.
            try db.create(
                index: "scripts_status_updated_idx",
                on: "scripts",
                columns: ["status", "updated_at"],
                ifNotExists: true
            )
        }

        return m
    }
}
