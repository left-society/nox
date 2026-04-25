import SwiftUI

@MainActor
final class PanelPresenter: ObservableObject {
    @Published var isShown: Bool = false
    @Published var activeTab: PanelTab = .notes
    /// Driven by PanelDropContainer (the contentView wrapper) when a drag
    /// hovers over the panel. Used by PanelRootView to draw an accent ring.
    @Published var isDropTargeted: Bool = false

    /// Latest now-playing snapshot from MediaRemoteService, forwarded
    /// here by NotchOrchestrator so SwiftUI views inside the panel
    /// (specifically MusicPanelView and the segmented bar) can observe
    /// it without having to know about the orchestrator. Nil means
    /// nothing is playing — when this flips from non-nil to nil, the
    /// segmented bar drops the .music tab and the active tab auto-
    /// rotates back to .notes if it was .music.
    @Published var nowPlaying: NowPlayingInfo? {
        didSet {
            // Auto-collapse: if music stops mid-session and we were
            // showing the music tab, hop to notes. Without this the
            // user is stuck staring at an empty music page until they
            // manually switch tabs — bad UX, and the segmented bar
            // would also drop the .music segment, making the active
            // tab effectively orphaned.
            if nowPlaying == nil && activeTab == .music {
                activeTab = .notes
            }
        }
    }

    /// Forwards play/pause/skip taps from MusicPanelView to whoever
    /// owns MediaRemoteService (currently NotchOrchestrator, wired up
    /// by AppDelegate at launch). Optional because the presenter is
    /// constructed before the orchestrator exists; the delegate
    /// installs this closure once both have been built.
    var onMediaCommand: ((MediaRemoteService.Command) -> Void)?

    /// Tabs to show in the segmented bar, in display order. Music
    /// only appears when something is actively playing — when nothing
    /// is playing the bar is the original 4-tab strip and the user
    /// never sees a "Music" segment that does nothing.
    var visibleTabs: [PanelTab] {
        var tabs: [PanelTab] = []
        if nowPlaying != nil { tabs.append(.music) }
        tabs.append(contentsOf: [.notes, .images, .videos, .files])
        return tabs
    }
}
