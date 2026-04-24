import Foundation

@MainActor
final class AppEnvironment: ObservableObject {
    let database: Database
    let noteStore: NoteStore
    let imageStore: ImageStore
    let retentionService: RetentionService

    init() throws {
        self.database = try Database()
        self.noteStore = NoteStore(db: database)
        self.imageStore = try ImageStore(db: database)
        let imageRoot = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("Notetaker", isDirectory: true)
        self.retentionService = RetentionService(db: database, imageRoot: imageRoot)
    }
}
