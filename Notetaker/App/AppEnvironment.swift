import Foundation

/// Owns the app's long-lived stores. Doesn't forward their
/// `objectWillChange` signals — each store is injected into SwiftUI
/// as its own `EnvironmentObject`, so a mutation in one store only
/// re-renders views that actually depend on it. (Earlier this class
/// re-broadcast every child store's change through its own
/// `objectWillChange`, which made a single yt-dlp progress tick or
/// screenshot save re-evaluate every view subscribed to `env` — the
/// panel hitched at ~10Hz during downloads.)
@MainActor
final class AppEnvironment: ObservableObject {
    let database: Database
    let noteStore: NoteStore
    let imageStore: ImageStore
    let videoStore: VideoStore
    let fileStore: FileStore
    let scriptStore: ScriptStore
    let retentionService: RetentionService
    let linkPreviewService: LinkPreviewService
    let bluetoothDeviceService: BluetoothDeviceService

    init() throws {
        // One-time rename migration. Runs BEFORE any store is built —
        // they all live inside this folder, so by the time Database /
        // ImageStore / VideoStore initialize, they need the new path
        // to exist with all the user's data already moved.
        try AppEnvironment.migrateLegacyNotetakerFolderIfNeeded()

        self.database = try Database()
        self.noteStore = NoteStore(db: database)
        self.imageStore = try ImageStore(db: database)
        self.videoStore = try VideoStore(db: database)
        self.fileStore = FileStore()
        self.scriptStore = ScriptStore(db: database)
        let imageRoot = try AppEnvironment.applicationSupportDirectory()
        self.retentionService = RetentionService(db: database, imageRoot: imageRoot)
        self.linkPreviewService = LinkPreviewService()
        self.bluetoothDeviceService = BluetoothDeviceService()
    }

    /// Single source of truth for the app's Application Support
    /// folder. Used by Database, ImageStore, VideoStore, and the
    /// retention service. Renamed from "Notetaker" → "nox" in
    /// 1.8 to align the on-disk footprint with the brand. Existing
    /// installs are migrated transparently by
    /// `migrateLegacyNotetakerFolderIfNeeded()` which runs before
    /// any store is built.
    ///
    /// `nonisolated` so non-MainActor callers (Database in particular,
    /// which is built from a default-isolated context) can invoke it
    /// without forcing main-actor hops. The body only touches
    /// FileManager, which is itself thread-safe.
    nonisolated static func applicationSupportDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = base.appendingPathComponent("nox", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        return dir
    }

    /// Move `~/Library/Application Support/Notetaker/` →
    /// `~/Library/Application Support/nox/` if the old folder exists
    /// and the new one doesn't. Idempotent: safe to call on every
    /// launch. Bails on every "already done" condition without
    /// touching the filesystem.
    ///
    /// Why a real move (not a copy + delete): `FileManager.moveItem`
    /// is atomic on the same volume — either the rename succeeds
    /// fully or it doesn't happen at all. A copy + delete leaves a
    /// half-state if the copy succeeds and the delete fails, which
    /// would mean two folders holding the same notes / images,
    /// each diverging on next write.
    ///
    /// Why this needs to run before any store init: Database,
    /// ImageStore, VideoStore all read paths inside this folder.
    /// If they create the new `nox/` folder fresh (with new empty
    /// SQLite schema, etc.) before this migration runs, the user's
    /// old data is orphaned and the app looks freshly installed.
    nonisolated private static func migrateLegacyNotetakerFolderIfNeeded() throws {
        let fm = FileManager.default
        let base = try fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let oldDir = base.appendingPathComponent("Notetaker", isDirectory: true)
        let newDir = base.appendingPathComponent("nox", isDirectory: true)

        let oldExists = fm.fileExists(atPath: oldDir.path)
        let newExists = fm.fileExists(atPath: newDir.path)

        // Already migrated, or fresh install: nothing to do.
        if !oldExists { return }
        // New folder already exists alongside the old one — assume an
        // earlier migration ran and the user has been writing to the
        // new path since. Don't merge folders here; that gets ugly
        // fast (which copy of `notetaker.db` wins?). Leave the legacy
        // folder in place for the user to inspect manually.
        if newExists {
            NSLog("nox: legacy Notetaker/ folder still exists alongside nox/. Skipping merge — user can clean up manually.")
            return
        }

        try fm.moveItem(at: oldDir, to: newDir)
        NSLog("nox: migrated Application Support/Notetaker → Application Support/nox")
    }
}
