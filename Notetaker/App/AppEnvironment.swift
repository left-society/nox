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
    let retentionService: RetentionService

    init() throws {
        self.database = try Database()
        self.noteStore = NoteStore(db: database)
        self.imageStore = try ImageStore(db: database)
        self.videoStore = try VideoStore(db: database)
        let imageRoot = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("Notetaker", isDirectory: true)
        self.retentionService = RetentionService(db: database, imageRoot: imageRoot)
    }
}
