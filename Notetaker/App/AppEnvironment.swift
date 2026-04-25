import Foundation
import Combine

@MainActor
final class AppEnvironment: ObservableObject {
    let database: Database
    let noteStore: NoteStore
    let imageStore: ImageStore
    let videoStore: VideoStore
    let retentionService: RetentionService

    /// Forwards each child store's `objectWillChange` through this
    /// environment so `@EnvironmentObject var env: AppEnvironment`
    /// consumers actually re-render when a store mutates. Without this,
    /// SwiftUI subscribes to `env` but NOT to nested ObservableObjects
    /// accessed via `env.imageStore.images`, so deletes/edits silently
    /// no-op until some unrelated change (panel re-show, tab switch)
    /// forces a re-render. That manifested as "delete buttons don't
    /// work — image only disappears after closing and reopening the
    /// panel" — pastes worked only because `panel.showOnTab` already
    /// flipped a presenter @Published as a side effect.
    private var storeSubscriptions: Set<AnyCancellable> = []

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

        // Re-publish nested-store changes through this environment.
        noteStore.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &storeSubscriptions)
        imageStore.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &storeSubscriptions)
        videoStore.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &storeSubscriptions)
    }
}
