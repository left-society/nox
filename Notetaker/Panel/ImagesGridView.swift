import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ImagesGridView: View {
    @EnvironmentObject var env: AppEnvironment
    @State private var selected: Set<String> = []
    @State private var showClearConfirm = false

    private let columns = [
        GridItem(.flexible(), spacing: 6),
        GridItem(.flexible(), spacing: 6)
    ]

    var body: some View {
        VStack(spacing: 0) {
            if !env.imageStore.images.isEmpty || !env.imageStore.inflight.isEmpty {
                toolbar
            }

            ScrollView {
                if env.imageStore.images.isEmpty && env.imageStore.inflight.isEmpty {
                    emptyState
                } else {
                    VStack(spacing: DS.Spacing.sm) {
                        if env.imageStore.images.count >= 2 {
                            stackHero
                                .padding(.horizontal, DS.Spacing.sm)
                                .padding(.top, DS.Spacing.xs)
                        }

                        LazyVGrid(columns: columns, spacing: 6) {
                            // Inflight uploads first — placeholder cells with
                            // a spinner. They flow into real ImageCells as
                            // saves complete, so the grid shifts gracefully
                            // rather than popping the cell in from nowhere.
                            ForEach(env.imageStore.inflight) { upload in
                                InflightImageCell(upload: upload)
                                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                            }
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
                                .onDrag { dragProvider(for: record) }
                                .transition(.opacity.combined(with: .scale(scale: 0.96)))
                            }
                        }
                        .padding(DS.Spacing.sm)
                        .animation(.selection, value: env.imageStore.images.map(\.id))
                        .animation(.selection, value: env.imageStore.inflight.map(\.id))
                    }
                }
            }
            .scrollIndicators(.never)
        }
        .background(shortcuts)
        // Drag-and-drop handling lives at PanelRootView level now (see
        // PanelDropCatcher) so users can drop onto any tab and the panel
        // routes to the correct store + switches to the right tab.
        .alert("Clear all images?", isPresented: $showClearConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) {
                try? env.imageStore.trashAll()
                selected.removeAll()
            }
        } message: {
            Text("This removes all \(env.imageStore.images.count) images from the panel.")
        }
    }

    private var toolbar: some View {
        HStack(spacing: DS.Spacing.sm) {
            Text("\(env.imageStore.images.count) image\(env.imageStore.images.count == 1 ? "" : "s")")
                .font(.nkMeta)
                .foregroundStyle(DS.Color.textTertiary)

            // Inflight chip — shows "· Saving 1…" / "Saving 2…" while
            // detached drop saves are finishing. Disappears when all
            // saves land.
            if !env.imageStore.inflight.isEmpty {
                HStack(spacing: 4) {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(DS.Color.accent)
                    Text("Saving \(env.imageStore.inflight.count)…")
                        .font(.nkMeta)
                        .foregroundStyle(DS.Color.accent)
                }
                .transition(.opacity)
            }

            if !selected.isEmpty {
                Text("· \(selected.count) selected")
                    .font(.nkMeta)
                    .foregroundStyle(DS.Color.textSecondary)
            }

            Spacer()

            if !selected.isEmpty {
                Button {
                    selected.removeAll()
                } label: {
                    Text("Deselect")
                        .font(.nkMeta)
                        .foregroundStyle(DS.Color.textSecondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(DS.Color.bgSubtle)
                        )
                }
                .buttonStyle(.plain)
            }

            Button {
                showClearConfirm = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "trash")
                        .font(.system(size: 10, weight: .medium))
                    Text("Clear")
                        .font(.nkMeta)
                }
                .foregroundStyle(DS.Color.textSecondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(DS.Color.bgSubtle)
                )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, DS.Spacing.sm)
        .padding(.top, DS.Spacing.xs)
        .padding(.bottom, DS.Spacing.xxs)
    }

    private var stackHero: some View {
        let images = Array(env.imageStore.images.prefix(4))
        let rotations: [Double] = [-6, -2, 3, 7]
        let offsets: [(CGFloat, CGFloat)] = [(-14, -4), (-5, 2), (5, -3), (14, 4)]

        let allURLs = env.imageStore.images.map { env.imageStore.fullURL(for: $0) }

        return HStack(spacing: DS.Spacing.md) {
            ZStack {
                ForEach(Array(images.enumerated().reversed()), id: \.element.id) { idx, record in
                    stackThumb(record: record)
                        .rotationEffect(.degrees(rotations[min(idx, rotations.count - 1)]))
                        .offset(
                            x: offsets[min(idx, offsets.count - 1)].0,
                            y: offsets[min(idx, offsets.count - 1)].1
                        )
                        .zIndex(Double(images.count - idx))
                }
            }
            .frame(width: 92, height: 84)
            .overlay(MultiFileDragSource(fileURLs: allURLs))

            VStack(alignment: .leading, spacing: 4) {
                Text("\(env.imageStore.images.count) images")
                    .font(.nkBody.weight(.semibold))
                    .foregroundStyle(DS.Color.textPrimary)
                Text("Copy or drag the stack")
                    .font(.nkMeta)
                    .foregroundStyle(DS.Color.textTertiary)

                Button(action: copyAll) {
                    HStack(spacing: 5) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Copy all")
                            .font(.nkMeta.weight(.semibold))
                    }
                    .foregroundStyle(DS.Color.textPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(DS.Color.bgSelected)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }

            Spacer(minLength: 0)
        }
        .padding(DS.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous)
                .fill(DS.Color.bgSubtle)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous)
                .strokeBorder(Color.white.opacity(0.06), lineWidth: 0.5)
        )
    }

    private func stackThumb(record: ImageRecord) -> some View {
        AsyncImage(url: env.imageStore.thumbURL(for: record)) { phase in
            switch phase {
            case .success(let img):
                img.resizable().aspectRatio(contentMode: .fill)
            default:
                Rectangle().fill(DS.Color.bgSubtle)
            }
        }
        .frame(width: 60, height: 60)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.white.opacity(0.22), lineWidth: 0.8)
        )
        .shadow(color: Color.black.opacity(0.35), radius: 3, y: 1)
    }

    private var emptyState: some View {
        VStack(spacing: DS.Spacing.sm) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(DS.Color.textTertiary)
            Text("No images yet")
                .font(.nkBody.weight(.medium))
                .foregroundStyle(DS.Color.textSecondary)
            Text("Paste with ⌘V, drop here, or take a screenshot.")
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
            Button(action: selectAll) { EmptyView() }
                .keyboardShortcut("a", modifiers: .command)
            Button(action: deleteSelected) { EmptyView() }
                .keyboardShortcut(.delete, modifiers: [])
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

    private func selectAll() {
        selected = Set(env.imageStore.images.map(\.id))
    }

    private func deleteSelected() {
        let ids = selected
        selected.removeAll()
        // Mark each as trashed. We don't have a bulk API; reuse trashAll path per id
        // via a direct mutation on imageStore is cleanest, but we avoid adding a
        // method for now — GRDB direct update is simpler:
        for id in ids {
            try? markImageTrashed(id: id)
        }
    }

    private func markImageTrashed(id: String) throws {
        guard let idx = env.imageStore.images.firstIndex(where: { $0.id == id }) else { return }
        let record = env.imageStore.images[idx]
        _ = record // keeping reference until store API exists
        try env.database.dbQueue.write { conn in
            try conn.execute(
                sql: "UPDATE images SET status = 'trashed', trashed_at = ? WHERE id = ?",
                arguments: [Date().timeIntervalSince1970, id]
            )
        }
        env.imageStore.reload()
    }

    private func handlePaste() {
        let pb = NSPasteboard.general
        if let pngData = pb.data(forType: .png) {
            _ = try? env.imageStore.saveImage(data: pngData, mimeType: "image/png",
                                          noteId: nil, source: "paste")
        } else if let tiffData = pb.data(forType: .tiff),
                  let pngData = Self.tiffToPNG(tiffData) {
            _ = try? env.imageStore.saveImage(data: pngData, mimeType: "image/png",
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

    private func copyAll() {
        let imagesAndURLs: [(NSImage, URL)] = env.imageStore.images.compactMap { rec in
            let url = env.imageStore.fullURL(for: rec)
            guard let img = NSImage(contentsOf: url) else { return nil }
            return (img, url)
        }
        ClipboardService.copy(
            images: imagesAndURLs.map(\.0),
            fileURLs: imagesAndURLs.map(\.1)
        )
    }

    // MARK: - Drag-out

    private func dragProvider(for record: ImageRecord) -> NSItemProvider {
        let url = env.imageStore.fullURL(for: record)
        return NSItemProvider(contentsOf: url) ?? NSItemProvider()
    }

    // MARK: - Helpers

    private static func mime(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "tiff", "tif": return "image/tiff"
        default: return "image/png"
        }
    }

    private static func tiffToPNG(_ data: Data) -> Data? {
        guard let rep = NSBitmapImageRep(data: data) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

// MARK: - Cell

struct ImageCell: View {
    let record: ImageRecord
    let isSelected: Bool
    let onTap: () -> Void
    @EnvironmentObject var env: AppEnvironment
    @State private var isHovered = false
    @State private var justCopied = false

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
        .frame(height: 84)
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
        .overlay(alignment: .bottomTrailing) {
            copyButton
                .padding(6)
                .opacity(isHovered || justCopied ? 1 : 0)
                .animation(.rowHover, value: isHovered || justCopied)
        }
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .onHover { hovering in
            withAnimation(.rowHover) { isHovered = hovering }
        }
        .animation(.rowHover, value: isSelected)
    }

    private var copyButton: some View {
        Button(action: handleCopy) {
            HStack(spacing: 4) {
                Image(systemName: justCopied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 9, weight: .semibold))
                Text(justCopied ? "Copied" : "Copy")
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(justCopied ? DS.Color.accent : Color.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.black.opacity(0.72))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.selection, value: justCopied)
    }

    private func handleCopy() {
        let url = env.imageStore.fullURL(for: record)
        guard let image = NSImage(contentsOf: url) else { return }
        ClipboardService.copy(images: [image], fileURLs: [url])
        justCopied = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            justCopied = false
        }
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

// MARK: - Inflight cell

/// Placeholder cell shown while an async drop save is finishing on a
/// background task. Renders the user's dropped bytes via NSImage(data:)
/// so the cell looks like the real thumbnail will, plus a small spinner
/// pinned to the corner so it's obvious the save is still in flight.
struct InflightImageCell: View {
    let upload: ImageStore.InflightUpload

    var body: some View {
        ZStack {
            if let preview = upload.preview {
                Image(nsImage: preview)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(DS.Color.bgSubtle)
            }
        }
        .frame(height: 84)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous))
        .overlay(
            // Dim + spinner so the cell reads as "still working" without
            // hiding the preview entirely.
            ZStack {
                Color.black.opacity(0.32)
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
            }
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous)
                .strokeBorder(DS.Color.accent.opacity(0.45), lineWidth: 1)
        )
        .allowsHitTesting(false)
    }
}

