import LinkPresentation
import Foundation
import AppKit

/// Memoizing wrapper around `LPMetadataProvider`, the same machinery
/// Messages/Notes use for inline link previews. SwiftUI views observe
/// `previews[url]` and re-render when an async fetch lands.
///
/// Two layers of memoization:
/// - In-memory `previews: [URL: LPLinkMetadata]` — what SwiftUI binds to.
/// - `NSCache<NSURL, LPLinkMetadata>` — survives app-state churn that
///   would otherwise drop the @Published map (e.g. retention sweeps).
///
/// `inflight` set deduplicates concurrent `ensure(for:)` calls for
/// the same URL — the notes list calls it from every row's `.onAppear`
/// so a single URL pasted 5 times shouldn't kick off 5 fetches.
@MainActor
final class LinkPreviewService: ObservableObject {
    @Published private(set) var previews: [URL: LPLinkMetadata] = [:]
    private var inflight: Set<URL> = []
    private let cache = NSCache<NSURL, LPLinkMetadata>()

    func ensure(for url: URL) {
        if previews[url] != nil { return }
        if let cached = cache.object(forKey: url as NSURL) {
            previews[url] = cached
            return
        }
        guard !inflight.contains(url) else { return }
        inflight.insert(url)

        let provider = LPMetadataProvider()
        provider.startFetchingMetadata(for: url) { [weak self] meta, _ in
            // Hop to the main actor before touching state — completion
            // handler fires on a private queue.
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.inflight.remove(url)
                if let meta {
                    self.cache.setObject(meta, forKey: url as NSURL)
                    self.previews[url] = meta
                }
            }
        }
        // 2026-05-08 audit H11: watchdog so a hung LP fetch
        // (network problem, OS bug, server stalling forever) can't
        // permanently trap the URL in `inflight`. Without this,
        // ensure() would silent-no-op for that URL forever — the
        // user gets one bad fetch, never sees a preview again.
        // 12s is well past the typical LPMetadataProvider timeout
        // (~10s) but short enough to clear quickly when something
        // actually wedges.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 12 * 1_000_000_000)
            guard let self, self.inflight.contains(url) else { return }
            self.inflight.remove(url)
        }
    }
}
