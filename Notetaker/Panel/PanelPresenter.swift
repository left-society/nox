import SwiftUI

@MainActor
final class PanelPresenter: ObservableObject {
    @Published var isShown: Bool = false
    @Published var activeTab: PanelTab = .notes
}
