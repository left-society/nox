import Foundation

@MainActor
final class AppEnvironment: ObservableObject {
    let database: Database
    let noteStore: NoteStore
    let imageStore: ImageStore

    init() throws {
        self.database = try Database()
        self.noteStore = NoteStore(db: database)
        self.imageStore = try ImageStore(db: database)
    }
}
