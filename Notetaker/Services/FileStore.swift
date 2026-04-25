import Foundation
import Combine

@MainActor
final class FileStore: ObservableObject {
    struct StagedFile: Identifiable, Equatable {
        let id: String
        let url: URL
        let displayName: String
        let sizeBytes: Int64?
        let stagedAt: Date

        static func == (lhs: StagedFile, rhs: StagedFile) -> Bool {
            lhs.id == rhs.id
        }
    }

    @Published private(set) var files: [StagedFile] = []

    /// Real impl arrives in Task 3.
    func stage(urls: [URL]) {}
    func remove(id: String) {}
    func clearAll() {}
    func isStillResolvable(_ file: StagedFile) -> Bool { true }
}
