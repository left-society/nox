import SwiftUI
import AppKit

struct FilesGridView: View {
    @EnvironmentObject var fileStore: FileStore
    @EnvironmentObject var presenter: PanelPresenter

    /// Multi-select state — same pattern as Notes/Images/Videos.
    /// ⌘-click toggles, ⇧-click does smart range toggle, plain
    /// click in selection mode also toggles.
    @State private var selectedIds: Set<String> = []
    @State private var lastClickedId: String? = nil

    /// Dynamic accent for the empty-state glow. Pulls the dominant
    /// color from the current track's artwork so the panel's
    /// chromatic identity stays unified with whatever's playing —
    /// the user reported the static system-accent green felt
    /// disconnected from the rest of the UI ("multiple things"
    /// using it). When no music is playing, falls back to white
    /// for a neutral soft glow.
    private var dynamicAccent: Color {
        if let data = presenter.nowPlaying?.artworkData,
           let color = ArtworkColor.dominant(from: data) {
            return color
        }
        return .white
    }

    var body: some View {
        VStack(spacing: 0) {
            if fileStore.files.isEmpty {
                emptyState
            } else {
                toolbar
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: DS.Spacing.sm) {
                        ForEach(fileStore.files) { file in
                            FileRow(
                                file: file,
                                isSelected: selectedIds.contains(file.id),
                                isSelectionModeActive: !selectedIds.isEmpty,
                                onRemove: {
                                    fileStore.remove(id: file.id)
                                    HapticFeedback.levelChange()
                                },
                                onClick: {
                                    handleRowClick(file)
                                }
                            )
                            .transition(.dropLanding)
                            // FileStore uses `stagedAt: Date` instead of
                            // the `createdAt: Double` (Unix epoch) the
                            // image and video stores use. Bridge to the
                            // modifier's expected type.
                            .celebrateIfRecent(file.stagedAt.timeIntervalSince1970)
                        }
                    }
                    .padding(.horizontal, DS.Spacing.md)
                    .padding(.vertical, DS.Spacing.sm)
                    .animation(.dropSpring, value: fileStore.files.map(\.id))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        // Layered empty state with breathing halo + clear hierarchy
        // — replaced the previous 26pt-thin-glyph-in-a-void per
        // user feedback ("this thing still looks weird"). Uses the
        // shared `EmptyDropState` component (DesignSystem/) so all
        // four drop-target tabs share one visual identity.
        EmptyDropState(
            icon: "tray.full",
            title: "Drop files here",
            subtitle: "Stage anything you need to paste later. Nothing is saved.",
            keyHint: ("⌘V", "to paste from clipboard"),
            accent: dynamicAccent
        )
    }

    private var toolbar: some View {
        Group {
            if !selectedIds.isEmpty {
                selectionToolbar
            } else {
                defaultToolbar
            }
        }
    }

    private var selectionToolbar: some View {
        HStack(spacing: DS.Spacing.sm) {
            Text("\(selectedIds.count) selected")
                .font(.nkLabel.weight(.semibold))
                .foregroundStyle(DS.Color.textPrimary)

            Button {
                let allSelected = selectedIds.count == fileStore.files.count
                if allSelected {
                    selectedIds.removeAll()
                } else {
                    selectedIds = Set(fileStore.files.map(\.id))
                }
            } label: {
                Text(selectedIds.count == fileStore.files.count ? "Deselect All" : "Select All")
                    .font(.nkMeta)
                    .foregroundStyle(DS.Color.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(DS.Color.bgSubtle.opacity(0.7))
                    )
            }
            .buttonStyle(.plain)
            .keyboardShortcut("a", modifiers: .command)

            Spacer()

            Button {
                deleteSelected()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "trash")
                        .font(.system(size: 10, weight: .medium))
                    Text("Delete")
                        .font(.nkMeta)
                }
                .foregroundStyle(.red)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.red.opacity(0.12))
                )
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.delete, modifiers: [])

            Button {
                selectedIds.removeAll()
            } label: {
                Text("Done")
                    .font(.nkMeta.weight(.semibold))
                    .foregroundStyle(DS.Color.textPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(DS.Color.bgSubtle.opacity(0.7))
                    )
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, DS.Spacing.md)
        .padding(.vertical, DS.Spacing.sm)
    }

    private func handleRowClick(_ file: FileStore.StagedFile) {
        let mods = NSEvent.modifierFlags
        if mods.contains(.shift) {
            shiftRangeToggle(to: file.id)
            return
        }
        if mods.contains(.command) || !selectedIds.isEmpty {
            toggleSelection(file.id)
        }
        // Plain click outside selection mode is no-op for files —
        // there's no "open" action; users drag or use Copy all.
    }

    private func toggleSelection(_ id: String) {
        if selectedIds.contains(id) {
            selectedIds.remove(id)
        } else {
            selectedIds.insert(id)
        }
        lastClickedId = id
    }

    private func shiftRangeToggle(to id: String) {
        let visible = fileStore.files.map(\.id)
        guard let endIdx = visible.firstIndex(of: id) else { return }
        let anchorId = lastClickedId ?? selectedIds.first
        guard let anchor = anchorId,
              let anchorIdx = visible.firstIndex(of: anchor)
        else {
            toggleSelection(id)
            return
        }
        let lo = min(anchorIdx, endIdx)
        let hi = max(anchorIdx, endIdx)
        let shouldDeselect = selectedIds.contains(id)
        for idx in lo...hi {
            if shouldDeselect {
                selectedIds.remove(visible[idx])
            } else {
                selectedIds.insert(visible[idx])
            }
        }
        lastClickedId = id
    }

    private func deleteSelected() {
        for id in selectedIds {
            fileStore.remove(id: id)
        }
        selectedIds.removeAll()
        HapticFeedback.levelChange()
    }

    private var defaultToolbar: some View {
        HStack(spacing: DS.Spacing.sm) {
            Text("\(fileStore.files.count) staged")
                .font(.nkMeta)
                .foregroundStyle(DS.Color.textTertiary)
            Spacer()
            // AirDrop — closes the gap with NotchNook ("AirDrop on
            // drop" was their headline feature). NSSharingServicePicker
            // shows the standard AirDrop picker popover anchored to
            // this button.
            Button {
                shareViaAirDrop()
                HapticFeedback.alignment()
            } label: {
                Label("AirDrop", systemImage: "shareplay")
                    .font(.nkMeta.weight(.medium))
                    .foregroundStyle(DS.Color.textPrimary)
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.plain)
            Button {
                ClipboardService.copy(fileURLs: fileStore.files.map(\.url))
                HapticFeedback.alignment()
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
                HapticFeedback.levelChange()
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

    /// Share the staged files via AirDrop. NSSharingServicePicker
    /// shows the standard popover the user already knows from
    /// Finder's right-click → Share. We anchor it to the panel's
    /// content view; macOS positions the popover sensibly near
    /// the source button automatically when the rect is small.
    private func shareViaAirDrop() {
        let urls = fileStore.files.map(\.url)
        guard !urls.isEmpty else { return }
        let picker = NSSharingServicePicker(items: urls)
        // Floating NSPanel doesn't reliably become keyWindow even
        // on click, so `NSApp.keyWindow` is sometimes nil here.
        // Walk the visible-window list and prefer our NSPanel as
        // the anchor — falls through to keyWindow / mainWindow if
        // not found.
        let anchorWindow = NSApp.windows.first(where: { $0.isVisible && $0 is NSPanel })
            ?? NSApp.keyWindow
            ?? NSApp.mainWindow
        guard let view = anchorWindow?.contentView else { return }
        // Anchor to the center-bottom of the panel content view
        // so the popover appears below the visible silhouette
        // rather than offscreen above the menu bar (which `.zero`
        // could pick on a flipped coordinate system).
        let bounds = view.bounds
        let anchor = NSRect(x: bounds.midX, y: bounds.minY, width: 1, height: 1)
        picker.show(relativeTo: anchor, of: view, preferredEdge: .minY)
    }
}

private struct FileRow: View {
    let file: FileStore.StagedFile
    var isSelected: Bool = false
    var isSelectionModeActive: Bool = false
    let onRemove: () -> Void
    var onClick: (() -> Void)? = nil

    @State private var hovered = false

    var body: some View {
        HStack(spacing: DS.Spacing.md) {
            // Finder icon — pre-resolved at stage time and cached
            // on the StagedFile struct. Reading the cached NSImage
            // is a property access; the previous version called
            // `NSWorkspace.shared.icon(forFile:)` synchronously
            // inside body() which for PDFs and other Quick-Look-
            // rendered types could take 50-200ms per body
            // evaluation, stalling the panel-open animation every
            // time the user re-opened with a fresh file in the list.
            Image(nsImage: file.icon)
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
            if hovered && !isSelectionModeActive && !isSelected {
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
                .fill(isSelected ? Color.accentColor.opacity(0.22)
                      : Color.white.opacity(hovered ? 0.07 : 0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    isSelected ? AnyShapeStyle(Color.accentColor)
                                : AnyShapeStyle(LinearGradient(
                                    colors: [Color.white.opacity(0.18), Color.white.opacity(0.04)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                  )),
                    lineWidth: isSelected ? 2 : 0.6
                )
        )
        .overlay(alignment: .trailing) {
            if isSelected {
                ZStack {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 22, height: 22)
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .heavy))
                        .foregroundStyle(.white)
                }
                .padding(.trailing, 14)
                .transition(.scale(scale: 0.5).combined(with: .opacity))
            }
        }
        .onTapGesture {
            onClick?()
        }
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
            //
            // 2026-05-01 v2 fix. The previous approach (NSItemProvider
            // contentsOf: + suggestedName) didn't fix the temp-filename
            // bug — receivers like WhatsApp got
            // ".com.apple.Foundation.NSItemProvider.<random>.pdf"
            // and ignored suggestedName. Reason:
            // `NSItemProvider(contentsOf:)` creates a CONTENT-based
            // provider; when the receiver calls
            // `loadFileRepresentation`, macOS materializes the bytes
            // into a NEW temp file whose name is auto-generated. The
            // receiver uses the temp file's name verbatim.
            //
            // Right way: register the file URL itself. NSURL conforms
            // to `NSItemProviderWriting`, so `NSItemProvider(object:
            // url as NSURL)` puts a public.file-url on the pasteboard.
            // Receivers see "I have a URL pointing to /path/to/Invoice-
            // BNBBlueprint-098.pdf" and use the real file directly,
            // including the original filename. This is the same path
            // Finder uses when you drag from a Finder window.
            NSItemProvider(object: file.url as NSURL)
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
