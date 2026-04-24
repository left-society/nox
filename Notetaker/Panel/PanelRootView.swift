import SwiftUI

struct PanelRootView: View {
    var body: some View {
        ZStack {
            Text("Notetaker")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
        }
        .frame(width: 480, height: 640)
    }
}
