import SwiftUI

@MainActor
final class PanelPresenter: ObservableObject {
    @Published var isShown: Bool = false
    @Published var activeTab: PanelTab = .notes
    /// Driven by PanelDropContainer (the contentView wrapper) when a drag
    /// hovers over the panel. Used by PanelRootView to draw an accent ring.
    @Published var isDropTargeted: Bool = false
}
