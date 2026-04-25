import SwiftUI
import AppKit

struct FilesGridView: View {
    @EnvironmentObject var fileStore: FileStore

    var body: some View {
        VStack(spacing: 0) {
            if fileStore.files.isEmpty {
                emptyState
            } else {
                toolbar
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: DS.Spacing.sm) {
                        ForEach(fileStore.files) { file in
                            FileRow(file: file) {
                                fileStore.remove(id: file.id)
                                NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
                            }
                            .transition(.asymmetric(
                                insertion: .scale(scale: 0.92).combined(with: .opacity),
                                removal: .opacity.combined(with: .scale(scale: 0.96))
                            ))
                        }
                    }
                    .padding(.horizontal, DS.Spacing.md)
                    .padding(.vertical, DS.Spacing.sm)
                    .animation(.spring(response: 0.32, dampingFraction: 0.74), value: fileStore.files.map(\.id))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: DS.Spacing.md) {
            ZStack {
                RadialGradient(
                    colors: [
                        DS.Color.accent.opacity(0.18),
                        DS.Color.accent.opacity(0.02),
                        Color.clear
                    ],
                    center: .center,
                    startRadius: 0,
                    endRadius: 70
                )
                .frame(width: 140, height: 140)
                Image(systemName: "tray.full")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(DS.Color.textSecondary)
            }
            Text("Drop files here")
                .font(.nkBody)
                .foregroundStyle(DS.Color.textSecondary)
            Text("Stage anything you need to paste later — nothing is saved.")
                .font(.nkMeta)
                .foregroundStyle(DS.Color.textTertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, DS.Spacing.xl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var toolbar: some View {
        HStack(spacing: DS.Spacing.sm) {
            Text("\(fileStore.files.count) staged")
                .font(.nkMeta)
                .foregroundStyle(DS.Color.textTertiary)
            Spacer()
            Button {
                ClipboardService.copy(fileURLs: fileStore.files.map(\.url))
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            } label: {
                Label("Copy all", systemImage: "doc.on.doc")
                    .font(.nkMeta.weight(.medium))
                    .foregroundStyle(DS.Color.textPrimary)
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.plain)
            Button {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.74)) {
                    fileStore.clearAll()
                }
                NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
            } label: {
                Label("Clear", systemImage: "xmark.circle")
                    .font(.nkMeta.weight(.medium))
                    .foregroundStyle(DS.Color.textSecondary)
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, DS.Spacing.md)
        .padding(.top, DS.Spacing.sm)
        .padding(.bottom, DS.Spacing.xs)
    }
}

private struct FileRow: View {
    let file: FileStore.StagedFile
    let onRemove: () -> Void

    @State private var hovered = false

    var body: some View {
        HStack(spacing: DS.Spacing.md) {
            // Finder icon — exact same Quick Look icon the user sees
            // when looking at the file in Finder. Cheap to fetch
            // and keeps the row instantly recognisable.
            Image(nsImage: NSWorkspace.shared.icon(forFile: file.url.path))
                .resizable()
                .interpolation(.high)
                .frame(width: 28, height: 28)
                .shadow(color: .black.opacity(0.25), radius: 1.5, y: 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(file.displayName)
                    .font(.nkBody.weight(.medium))
                    .foregroundStyle(DS.Color.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(meta)
                    .font(.nkMeta)
                    .foregroundStyle(DS.Color.textTertiary)
            }
            Spacer(minLength: 0)
            if hovered {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(DS.Color.textSecondary)
                }
                .buttonStyle(.plain)
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .padding(.horizontal, DS.Spacing.md)
        .padding(.vertical, DS.Spacing.sm)
        .frame(minHeight: 56)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(hovered ? 0.07 : 0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(0.18), Color.white.opacity(0.04)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 0.6
                )
        )
        .shadow(color: .black.opacity(0.45), radius: hovered ? 12 : 8, x: 0, y: hovered ? 6 : 4)
        .shadow(color: .black.opacity(0.18), radius: 1, x: 0, y: 1)
        .offset(y: hovered ? -2 : 0)
        .onHover { isHovering in
            withAnimation(.spring(response: 0.32, dampingFraction: 0.74)) {
                hovered = isHovering
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onDrag {
            // Lets the user pick a card up and drag it back out into
            // Finder, an upload field, etc. — the whole point of the
            // tab is to be a re-paste source.
            NSItemProvider(contentsOf: file.url) ?? NSItemProvider()
        }
    }

    private var meta: String {
        var bits: [String] = [file.url.pathExtension.uppercased()]
            .filter { !$0.isEmpty }
        if let bytes = file.sizeBytes {
            bits.append(Self.formatSize(bytes))
        }
        return bits.joined(separator: " · ")
    }

    private static func formatSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
