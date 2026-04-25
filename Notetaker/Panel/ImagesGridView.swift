import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ImagesGridView: View {
    // Direct EnvironmentObject for the store this view actually
    // depends on. Replaces `@EnvironmentObject var env` so an
    // unrelated `videoStore.jobs[i].progress` tick doesn't trigger
    // this view's body to re-evaluate.
    @EnvironmentObject var imageStore: ImageStore
    @State private var selected: Set<String> = []
    @State private var showClearConfirm = false

    private let columns = [
        GridItem(.flexible(), spacing: 6),
        GridItem(.flexible(), spacing: 6)
    ]

    var body: some View {
        VStack(spacing: 0) {
            if !imageStore.images.isEmpty || !imageStore.inflight.isEmpty {
                toolbar
            }

            ScrollView {
                if imageStore.images.isEmpty && imageStore.inflight.isEmpty {
                    emptyState
                } else {
                    VStack(spacing: DS.Spacing.sm) {
                        if imageStore.images.count >= 2 {
                            stackHero
                                .padding(.horizontal, DS.Spacing.sm)
                                .padding(.top, DS.Spacing.xs)
                        }

                        LazyVGrid(columns: columns, spacing: 6) {
                            // Inflight uploads first — placeholder cells with
                            // a spinner. They flow into real ImageCells as
                            // saves complete, so the grid shifts gracefully
                            // rather than popping the cell in from nowhere.
                            ForEach(imageStore.inflight) { upload in
                                InflightImageCell(upload: upload)
                                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                            }
                            ForEach(imageStore.images) { record in
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
                        .animation(.selection, value: imageStore.images.map(\.id))
                        .animation(.selection, value: imageStore.inflight.map(\.id))
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
                try? imageStore.trashAll()
                selected.removeAll()
            }
        } message: {
            Text("This removes all \(imageStore.images.count) images from the panel.")
        }
    }

    private var toolbar: some View {
        HStack(spacing: DS.Spacing.sm) {
            Text("\(imageStore.images.count) image\(imageStore.images.count == 1 ? "" : "s")")
                .font(.nkMeta)
                .foregroundStyle(DS.Color.textTertiary)

            // Inflight chip — shows "· Saving 1…" / "Saving 2…" while
            // detached drop saves are finishing. Disappears when all
            // saves land.
            if !imageStore.inflight.isEmpty {
                HStack(spacing: 4) {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(DS.Color.accent)
                    Text("Saving \(imageStore.inflight.count)…")
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
        let images = Array(imageStore.images.prefix(4))
        let rotations: [Double] = [-6, -2, 3, 7]
        let offsets: [(CGFloat, CGFloat)] = [(-14, -4), (-5, 2), (5, -3), (14, 4)]

        let allURLs = imageStore.images.map { imageStore.fullURL(for: $0) }

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
                Text("\(imageStore.images.count) images")
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
        LocalThumbnailView(
            id: record.id,
            url: imageStore.thumbURL(for: record)
        )
        .frame(width: 60, height: 60)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            // Brighter rim helps the top edge of each card pop against
            // the card directly underneath it — without it, the cards
            // visually melt into each other once shadows get heavy.
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.white.opacity(0.32), lineWidth: 0.8)
        )
        // Doubled-up shadow: a soft far one for depth + a tight close
        // one for that "card resting on a card" contact edge. Single
        // shadows looked muddy here because each card's blur landed on
        // top of the card below, washing it out.
        .shadow(color: Color.black.opacity(0.55), radius: 7, y: 4)
        .shadow(color: Color.black.opacity(0.35), radius: 1.5, y: 1)
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
        selected = Set(imageStore.images.map(\.id))
    }

    private func deleteSelected() {
        let ids = selected
        selected.removeAll()
        // Single DB write + single SwiftUI re-render via the bulk
        // trash API. Was previously O(N) reloads — selecting 20
        // images and pressing Delete hitched the panel for ~200ms
        // because each per-id call did a full DB reload.
        try? imageStore.trashMany(ids: ids)
    }

    private func handlePaste() {
        let pb = NSPasteboard.general
        if let pngData = pb.data(forType: .png) {
            _ = try? imageStore.saveImage(data: pngData, mimeType: "image/png",
                                          noteId: nil, source: "paste")
        } else if let tiffData = pb.data(forType: .tiff),
                  let pngData = Self.tiffToPNG(tiffData) {
            _ = try? imageStore.saveImage(data: pngData, mimeType: "image/png",
                                          noteId: nil, source: "paste")
        }
    }

    private func copySelected() {
        let records = imageStore.images.filter { selected.contains($0.id) }
        let imagesAndURLs: [(NSImage, URL)] = records.compactMap { rec in
            let url = imageStore.fullURL(for: rec)
            guard let img = NSImage(contentsOf: url) else { return nil }
            return (img, url)
        }
        ClipboardService.copy(
            images: imagesAndURLs.map(\.0),
            fileURLs: imagesAndURLs.map(\.1)
        )
    }

    private func copyAll() {
        let imagesAndURLs: [(NSImage, URL)] = imageStore.images.compactMap { rec in
            let url = imageStore.fullURL(for: rec)
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
        let url = imageStore.fullURL(for: record)
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
    @EnvironmentObject var imageStore: ImageStore
    @State private var isHovered = false
    @State private var justCopied = false

    var body: some View {
        LocalThumbnailView(
            id: record.id,
            url: imageStore.thumbURL(for: record)
        )
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
        // Per-cell trash sits in the top-left so it never overlaps the
        // selection check at top-right. Kept always slightly visible
        // (opacity 0.55 off-hover, 1.0 on-hover) so clicks register the
        // instant the cursor lands on it — SwiftUI doesn't have to wait
        // for a fade-in animation to finish before the hit-test counts.
        .overlay(alignment: .topLeading) {
            cellTrashButton
        }
        .overlay(alignment: .bottomTrailing) {
            copyButton
                .padding(6)
                .opacity(isHovered || justCopied ? 1 : 0)
                .animation(.rowHover, value: isHovered || justCopied)
        }
        // Subtle per-tile drop shadow so a grid full of images reads as
        // discrete elevated cards instead of a flat patchwork. Hover
        // bumps the shadow a touch to confirm the tile is interactive.
        .shadow(
            color: Color.black.opacity(isHovered ? 0.40 : 0.28),
            radius: isHovered ? 6 : 4,
            y: isHovered ? 3 : 2
        )
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .onHover { hovering in
            withAnimation(.rowHover) { isHovered = hovering }
        }
        .animation(.rowHover, value: isSelected)
        .animation(.rowHover, value: isHovered)
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

    private var cellTrashButton: some View {
        Button(action: handleTrash) {
            Image(systemName: "trash.fill")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Color.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.black.opacity(0.72)))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .padding(6)
        // No animation on opacity — the button needs to be hittable the
        // instant the cursor lands on it. Animated fade-ins delay the
        // visual but not the hit-test, which felt unresponsive in
        // testing ("clicked but nothing happened").
        .opacity(isHovered ? 1.0 : 0.55)
        .help("Delete")
    }

    private func handleTrash() {
        try? imageStore.trash(id: record.id)
    }

    private func handleCopy() {
        let url = imageStore.fullURL(for: record)
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

/// Placeholder cell shown while an async save is finishing on a
/// background task. Behavior is staged so a paste feels native-fast:
///
/// * **Frame 0** — `preview == nil`: heavy dim + center spinner. There's
///   nothing to show yet (NSImage decode is happening off-main), so a
///   strong "loading" cue replaces the empty space.
/// * **~30-100ms in** — preview decoded off-main and pushed back: dim
///   vanishes, the user sees their pasted image at full fidelity. The
///   accent border + soft accent halo are the only "still inflight"
///   cues remaining.
/// * **~100-300ms in** — disk save + DB write completes, cell flips to a
///   real `ImageCell`.
///
/// The earlier version held a 55% dim + "Saving…" caption over the
/// preview for the entire inflight duration, which made pastes look
/// "slow to load" even though the bytes had landed — the image was
/// just hidden behind the dim. Dropping the dim the moment the preview
/// arrives is what makes the paste feel as instant as the user expects.
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
        .overlay(loadingScrim)
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous)
                .strokeBorder(DS.Color.accent.opacity(0.55), lineWidth: 1)
        )
        // Soft accent halo so the inflight cell pops out of a grid full
        // of finished images — important when the panel opens straight
        // to images and you need to find which cell is still saving.
        .shadow(color: DS.Color.accent.opacity(0.35), radius: 5, y: 0)
        .animation(.easeInOut(duration: 0.18), value: upload.preview != nil)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var loadingScrim: some View {
        if upload.preview == nil {
            ZStack {
                Color.black.opacity(0.45)
                ProgressView()
                    .controlSize(.regular)
                    .tint(.white)
            }
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous))
            .transition(.opacity)
        } else {
            // Preview is showing — the accent border + halo carry the
            // "still inflight" cue, no dark overlay needed. This is
            // what makes the paste feel instant the moment the off-main
            // decode lands.
            Color.clear
        }
    }
}

