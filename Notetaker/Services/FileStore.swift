import AppKit
import Combine
import Foundation

/// In-memory clipboard staging. The Files tab is a "scratch pad" —
/// nothing is persisted to disk, nothing is moved or copied on the
/// filesystem. We just hold the user's URLs so they can pile a few
/// items up and copy them all out later. When the panel app quits,
/// the list is gone.
///
/// Dedup uses standardisedFileURL.path so re-staging the same file
/// (drop twice in a row, or paste the same URL twice) is a no-op
/// rather than producing duplicate cards.
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

    func stage(urls: [URL]) {
        var existingPaths = Set(files.map { $0.url.standardizedFileURL.path })
        var changed = false
        for url in urls {
            let path = url.standardizedFileURL.path
            guard !existingPaths.contains(path) else { continue }
            existingPaths.insert(path)
            let attrs = try? FileManager.default.attributesOfItem(atPath: path)
            let size = (attrs?[.size] as? NSNumber)?.int64Value
            let staged = StagedFile(
                id: UUID().uuidString,
                url: url.standardizedFileURL,
                displayName: url.lastPathComponent,
                sizeBytes: size,
                stagedAt: Date()
            )
            files.append(staged)
            changed = true
        }
        if changed {
            // Newest at top — feels right for a scratch-pad list.
            files.sort { $0.stagedAt > $1.stagedAt }
        }
    }

    func remove(id: String) {
        files.removeAll { $0.id == id }
    }

    func clearAll() {
        files.removeAll()
    }

    /// Cheap existence check used by the UI to fade out cards whose
    /// underlying file was deleted/moved while staged.
    func isStillResolvable(_ file: StagedFile) -> Bool {
        FileManager.default.fileExists(atPath: file.url.standardizedFileURL.path)
    }
}
