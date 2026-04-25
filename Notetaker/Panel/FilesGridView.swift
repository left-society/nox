import SwiftUI

struct FilesGridView: View {
    @EnvironmentObject var fileStore: FileStore

    var body: some View {
        // Real UI lands in Task 5.
        VStack {
            Text("Files")
                .font(.nkBody)
                .foregroundStyle(DS.Color.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
