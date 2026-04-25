import Foundation

/// Pure helper for ⌘1–⌘9 quick paste. Given an index and a per-tab
/// payload (either an array of texts or an array of file URLs),
/// returns what should be re-copied to the system clipboard.
///
/// Kept pure so it can be unit-tested without spinning up stores
/// or the panel window. The `PanelWindowController` does the
/// actual ClipboardService dispatch and panel-dismiss feedback —
/// this routine is just the index-bounds + tab-shape decision.
enum QuickPasteRouter {
    enum Item: Equatable {
        case text(String)
        case fileURL(URL)
        case none
    }

    static func itemAt(index: Int, texts: [String]) -> Item {
        guard index >= 0, index < texts.count else { return .none }
        return .text(texts[index])
    }

    static func itemAt(index: Int, urls: [URL]) -> Item {
        guard index >= 0, index < urls.count else { return .none }
        return .fileURL(urls[index])
    }
}
