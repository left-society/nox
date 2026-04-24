import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ImagesGridView: View {
    @EnvironmentObject var env: AppEnvironment
    @State private var selected: Set<String> = []

    private let columns = [
        GridItem(.flexible(), spacing: 6),
        GridItem(.flexible(), spacing: 6)
    ]

    var body: some View {
        ScrollView {
            if env.imageStore.images.isEmpty {
                emptyState
            } else {
                LazyVGrid(columns: columns, spacing: 6) {
                    ForEach(env.imageStore.images) { record in
                        ImageCell(
                            record: record,
                            isSelected: selected.contains(record.id),
                            onTap: {
                                toggleSelection(
                                    record.id,
                                    command: NSEvent.modifierFlags.contains(.command)
                                )
                            }
                        )
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    }
                }
                .padding(DS.Spacing.sm)
                .animation(.selection, value: env.imageStore.images.map(\.id))
            }
        }
        .scrollIndicators(.never)
        .background(shortcuts)
        .onDrop(of: [.image, .fileURL], isTargeted: nil) { providers in
            handleDrop(providers: providers)
            return true
        }
    }

    private var emptyState: some View {
        VStack(spacing: DS.Spacing.sm) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(DS.Color.textTertiary)
            Text("No images yet")
                .font(.nkBody.weight(.medium))
                .foregroundStyle(DS.Color.textSecondary)
            Text("Paste with ⌘V or drop an image here.")
                .font(.nkMeta)
                .foregroundStyle(DS.Color.textTertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 72)
        .padding(.horizontal, 40)
    }

    // MARK: - Keyboard shortcuts (hidden buttons)

    private var shortcuts: some View {
        ZStack {
            Button(action: handlePaste) { EmptyView() }
                .keyboardShortcut("v", modifiers: .command)
            Button(action: copySelected) { EmptyView() }
                .keyboardShortcut("c", modifiers: .command)
                .disabled(selected.isEmpty)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .allowsHitTesting(false)
    }

    // MARK: - Actions

    private func toggleSelection(_ id: String, command: Bool) {
        if command {
            if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
        } else {
            selected = [id]
        }
    }

    private func handlePaste() {
        let pb = NSPasteboard.general
        if let pngData = pb.data(forType: .png) {
            _ = try? env.imageStore.saveImage(data: pngData, mimeType: "image/png",
                                          noteId: nil, source: "paste")
        } else if let tiffData = pb.data(forType: .tiff) {
            _ = try? env.imageStore.saveImage(data: tiffData, mimeType: "image/tiff",
                                          noteId: nil, source: "paste")
        }
    }

    private func copySelected() {
        let records = env.imageStore.images.filter { selected.contains($0.id) }
        let imagesAndURLs: [(NSImage, URL)] = records.compactMap { rec in
            let url = env.imageStore.fullURL(for: rec)
            guard let img = NSImage(contentsOf: url) else { return nil }
            return (img, url)
        }
        ClipboardService.copy(
            images: imagesAndURLs.map(\.0),
            fileURLs: imagesAndURLs.map(\.1)
        )
    }

    private func handleDrop(providers: [NSItemProvider]) {
        Task { @MainActor in
            for provider in providers {
                if let data = try? await provider.loadData(for: .png) {
                    _ = try? env.imageStore.saveImage(data: data, mimeType: "image/png",
                                                  noteId: nil, source: "drop")
                } else if let url = try? await provider.loadURL(),
                          let data = try? Data(contentsOf: url) {
                    let mime = Self.mime(for: url)
                    _ = try? env.imageStore.saveImage(data: data, mimeType: mime,
                                                  noteId: nil, source: "drop")
                }
            }
        }
    }

    private static func mime(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        default: return "image/png"
        }
    }
}

// MARK: - Cell

struct ImageCell: View {
    let record: ImageRecord
    let isSelected: Bool
    let onTap: () -> Void
    @EnvironmentObject var env: AppEnvironment
    @State private var isHovered = false

    var body: some View {
        let url = env.imageStore.thumbURL(for: record)
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let img):
                img.resizable().aspectRatio(contentMode: .fill)
            default:
                Rectangle().fill(DS.Color.bgSubtle)
            }
        }
        .frame(height: 110)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous)
                .strokeBorder(strokeColor, lineWidth: strokeWidth)
        )
        .overlay(alignment: .topTrailing) {
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(DS.Color.accent)
                    .background(Circle().fill(.black).padding(2))
                    .padding(4)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .onHover { hovering in
            withAnimation(.rowHover) { isHovered = hovering }
        }
        .animation(.rowHover, value: isSelected)
    }

    private var strokeColor: Color {
        if isSelected { return DS.Color.accent }
        if isHovered { return Color.white.opacity(0.15) }
        return .clear
    }

    private var strokeWidth: CGFloat {
        isSelected ? 2 : 1
    }
}

// MARK: - NSItemProvider helpers

private extension NSItemProvider {
    func loadData(for type: UTType) async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            self.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, err in
                if let data = data {
                    cont.resume(returning: data)
                } else {
                    cont.resume(throwing: err ?? NSError(domain: "drop", code: 1))
                }
            }
        }
    }

    func loadURL() async throws -> URL {
        try await withCheckedThrowingContinuation { cont in
            self.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, err in
                if let url = item as? URL {
                    cont.resume(returning: url)
                } else if let data = item as? Data,
                          let str = String(data: data, encoding: .utf8),
                          let url = URL(string: str) {
                    cont.resume(returning: url)
                } else {
                    cont.resume(throwing: err ?? NSError(domain: "drop", code: 2))
                }
            }
        }
    }
}
