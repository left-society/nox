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

    // Wider gutter (10pt) so each tile's hard drop-shadow has room
    // to breathe before bleeding into its neighbors. With shadows
    // packed against each other the grid read as a flat patchwork;
    // the extra few points of negative space is what sells the
    // "discrete elevated cards" look.
    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10)
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

                        LazyVGrid(columns: columns, spacing: 10) {
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
                                // Single-file drag is the baseline. SwiftUI's
                                // `.onDrag` only emits one NSItemProvider, so
                                // for multi-selection we layer a different
                                // drag source on top — see the overlay below.
                                .onDrag { dragProvider(for: record) }
                                .overlay(multiSelectDragOverlay(for: record))
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

    /// Top-of-grid summary card. Two distinct states:
    ///
    /// 1. **No selection** — shows the full image stack, "N images"
    ///    title, and a "Copy all" CTA. Drag-out hands every image.
    /// 2. **Selection active** — the stack collapses to just the
    ///    selected items (up to 4 visible), title flips to "N
    ///    selected", and the CTA becomes "Copy selected". Drag-out
    ///    only carries the selected URLs.
    ///
    /// This is the user-facing answer to "if they click in one photo
    /// it should get to the selection button" — clicking a photo flips
    /// this hero into selection mode immediately, and the prominent
    /// CTA changes to match. Without this view-level adaptation, the
    /// selection toolbar at the top reads "5 selected" while the big
    /// hero card right below it still says "Copy all" — exactly the
    /// confusion the user reported.
    private var stackHero: some View {
        let isSelectionMode = !selected.isEmpty
        let sourceRecords: [ImageRecord] = isSelectionMode
            ? imageStore.images.filter { selected.contains($0.id) }
            : imageStore.images
        let displayedThumbs = Array(sourceRecords.prefix(4))
        let dragURLs = sourceRecords.map { imageStore.fullURL(for: $0) }
        let rotations: [Double] = [-6, -2, 3, 7]
        let offsets: [(CGFloat, CGFloat)] = [(-14, -4), (-5, 2), (5, -3), (14, 4)]

        let titleText = isSelectionMode
            ? "\(sourceRecords.count) selected"
            : "\(imageStore.images.count) images"
        let subtitleText = isSelectionMode
            ? "Copy or drag the selection"
            : "Copy or drag the stack"
        let buttonLabel = isSelectionMode ? "Copy selected" : "Copy all"
        let buttonAction: () -> Void = isSelectionMode ? copySelected : copyAll

        return HStack(spacing: DS.Spacing.md) {
            ZStack {
                ForEach(Array(displayedThumbs.enumerated().reversed()), id: \.element.id) { idx, record in
                    stackThumb(record: record)
                        .rotationEffect(.degrees(rotations[min(idx, rotations.count - 1)]))
                        .offset(
                            x: offsets[min(idx, offsets.count - 1)].0,
                            y: offsets[min(idx, offsets.count - 1)].1
                        )
                        .zIndex(Double(displayedThumbs.count - idx))
                }
            }
            .frame(width: 92, height: 84)
            .overlay(MultiFileDragSource(fileURLs: dragURLs))

            VStack(alignment: .leading, spacing: 4) {
                Text(titleText)
                    .font(.nkBody.weight(.semibold))
                    .foregroundStyle(DS.Color.textPrimary)
                    .contentTransition(.numericText())
                Text(subtitleText)
                    .font(.nkMeta)
                    .foregroundStyle(DS.Color.textTertiary)

                Button(action: buttonAction) {
                    HStack(spacing: 5) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 10, weight: .semibold))
                        Text(buttonLabel)
                            .font(.nkMeta.weight(.semibold))
                    }
                    .foregroundStyle(DS.Color.textPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(isSelectionMode ? DS.Color.accent.opacity(0.85) : DS.Color.bgSelected)
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
                .strokeBorder(
                    isSelectionMode
                        ? DS.Color.accent.opacity(0.32)
                        : Color.white.opacity(0.06),
                    lineWidth: 0.5
                )
        )
        .animation(.selection, value: isSelectionMode)
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
        VStack(spacing: DS.Spacing.md) {
            // Soft accent blob behind the icon — the empty state used
            // to be a flat icon + two lines of text on a dark void,
            // which read as "feature broken" more than "ready for
            // your stuff". The radial gives the illusion of warmth
            // even when the panel is empty.
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                DS.Color.accent.opacity(0.32),
                                DS.Color.accent.opacity(0.08),
                                Color.clear
                            ],
                            center: .center,
                            startRadius: 0,
                            endRadius: 56
                        )
                    )
                    .frame(width: 112, height: 112)
                    .blur(radius: 8)

                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(DS.Color.textSecondary)
                    .shadow(color: DS.Color.accent.opacity(0.4), radius: 6, y: 1)
            }

            VStack(spacing: 4) {
                Text("Nothing here yet")
                    .font(.nkBody.weight(.semibold))
                    .foregroundStyle(DS.Color.textPrimary)
                Text("Paste with ⌘V, drop here, or take a screenshot.")
                    .font(.nkMeta)
                    .foregroundStyle(DS.Color.textTertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
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

    /// Click semantics: every click TOGGLES this cell's selection. The
    /// user's complaint was that the panel only ever offered "copy all"
    /// even after clicking individual images — they expected an
    /// Instagram-/iOS-Photos-style flow where clicking a photo enters
    /// "selection mode" and subsequent clicks add or remove items.
    /// Cmd-click is treated identically (kept for muscle memory from
    /// macOS Finder); to clear the whole selection use the "Deselect"
    /// button in the toolbar or click the same image again.
    ///
    /// The previous behavior (`selected = [id]` on plain click) was
    /// actually hostile here — it meant clicking a second image
    /// SILENTLY threw away the first one's selection, which is the
    /// opposite of what a user trying to "pick a few" expects.
    private func toggleSelection(_ id: String, command: Bool) {
        _ = command  // semantic hook retained for future shift-range support
        if selected.contains(id) {
            selected.remove(id)
        } else {
            selected.insert(id)
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

    /// When 2+ images are selected and the user drags one of them,
    /// every selected image should travel together (Finder-style). The
    /// SwiftUI `.onDrag` modifier only ever vends a single
    /// NSItemProvider, so we overlay an AppKit-backed `NSDraggingSource`
    /// on top of cells that are part of a multi-selection. The overlay
    /// swallows mouse events when active, so we forward bare clicks
    /// back into `toggleSelection` so the user can still tap a cell to
    /// pull it out of the selection.
    ///
    /// Cells outside the selection — and the lone-selected case — fall
    /// through to the standard `.onDrag` path. That keeps per-cell
    /// trash and copy overlays reachable in the common single-image
    /// flow; multi-select is treated as a "batch operation mode" where
    /// individual hover affordances yield to the bulk drag.
    @ViewBuilder
    private func multiSelectDragOverlay(for record: ImageRecord) -> some View {
        if selected.count > 1 && selected.contains(record.id) {
            MultiFileDragSource(
                fileURLs: selectedFullURLs,
                dragImageURLs: selectedThumbURLs,
                onClick: {
                    toggleSelection(record.id, command: false)
                }
            )
        }
    }

    /// Selected records, in the same order they appear in the grid —
    /// so the receiving Finder/Mail/iMessage drop site sees them in
    /// visual order rather than insertion-set hash order.
    private var selectedRecords: [ImageRecord] {
        imageStore.images.filter { selected.contains($0.id) }
    }

    private var selectedFullURLs: [URL] {
        selectedRecords.map { imageStore.fullURL(for: $0) }
    }

    /// Thumbs (not the full-size images) for the dragging preview.
    /// `MultiFileDragSourceNSView` falls back to the full file when
    /// these are absent, but loading 4K screenshots just to render a
    /// 64pt drag chip is expensive — preferring the cached thumb keeps
    /// the drag start instantaneous.
    private var selectedThumbURLs: [URL] {
        selectedRecords.map { imageStore.thumbURL(for: $0) }
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
    /// Mirrors `justCopied` for the sibling "Copy Text" button: flips
    /// true the moment a smart-extract lands the transcript on the
    /// clipboard, drops back to false ~1.2s later. Same visual idiom
    /// (icon + label swap, accent tint) so both actions read as one
    /// family.
    @State private var justExtractedText = false
    /// Set while a Gemini / Vision round-trip is in flight so the
    /// button can show a spinner instead of the static glyph. Without
    /// this the user gets no feedback during the ~1-2s the model
    /// takes to respond and might tap the button repeatedly.
    @State private var isExtractingText = false

    /// Pillowy 14pt — bigger than `DS.Radius.row` (6) because these
    /// are full-bleed image cards now, not table rows. The previous
    /// 6pt radius made cells look like miniature thumbs slapped onto
    /// a flat surface; 14 turns them into proper cards.
    private static let cornerRadius: CGFloat = 14
    /// 96 instead of 84 — the extra 12pt makes the hard shadow's lift
    /// register without crowding the trash/copy overlays.
    private static let cellHeight: CGFloat = 96

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)

        return LocalThumbnailView(
            id: record.id,
            url: imageStore.thumbURL(for: record)
        )
        .frame(height: Self.cellHeight)
        .frame(maxWidth: .infinity)
        .clipShape(shape)
        // Glass-pane sheen: the top edge of every card catches a
        // brighter rim and fades to nothing at the bottom. Mimics the
        // way real photo prints catch light — the eye reads it as a
        // physical object resting on a surface, not a flat picture
        // glued to the panel. 0.8pt stroke is wide enough to read but
        // not heavy enough to look like a button border.
        .overlay(
            shape.strokeBorder(
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.32),
                        Color.white.opacity(0.06)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                lineWidth: 0.8
            )
        )
        // Selection ring sits above the gradient sheen so the accent
        // wins visually when a card is checked. Thicker than the
        // sheen (1.6pt) so it pops at small sizes too.
        .overlay(
            shape.strokeBorder(
                isSelected ? DS.Color.accent : Color.clear,
                lineWidth: 1.6
            )
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
            HStack(spacing: 4) {
                extractTextButton
                copyButton
            }
            .padding(6)
            .opacity(isHovered || justCopied || justExtractedText || isExtractingText ? 1 : 0)
            .animation(.rowHover, value: isHovered || justCopied || justExtractedText || isExtractingText)
        }
        // Lift on hover: -3pt offset + scale 1.02. Small numbers but
        // when the springed shadow underneath grows alongside, the
        // tile reads as physically rising off the surface.
        .scaleEffect(isHovered ? 1.02 : 1.0)
        .offset(y: isHovered ? -3 : 0)
        // Double-shadow language matches the stackHero up top so the
        // whole tab reads as one consistent "premium card stack"
        // aesthetic. Tight inner shadow gives every tile a crisp
        // contact edge against whatever's behind it; soft outer
        // shadow does the depth work. Selection bumps the soft
        // shadow into accent-tinted territory so checked cards
        // visibly hover above the pack.
        .shadow(
            color: shadowFar,
            radius: isHovered ? 16 : 11,
            y: isHovered ? 12 : 8
        )
        .shadow(
            color: Color.black.opacity(0.55),
            radius: 1.5,
            y: 1
        )
        .contentShape(shape)
        .onTapGesture { onTap() }
        .contextMenu {
            // Vision-based OCR — fast, offline, every line as-is.
            // Right tool for "give me the words on this poster".
            Button("Copy Text from Image") {
                handleOCR()
            }
            // Gemini-based extraction tuned for chat screenshots.
            // Strips timestamps/reactions/UI chrome, attributes
            // multi-sender threads. Right tool for "I screenshotted
            // an Instagram conversation, paste it as plain text".
            Button("Extract Messages → Clipboard") {
                handleGeminiExtract()
            }
        }
        .onHover { hovering in
            withAnimation(.rowHover) { isHovered = hovering }
        }
        .animation(.rowHover, value: isSelected)
        .animation(.rowHover, value: isHovered)
    }

    private func handleOCR() {
        let url = imageStore.fullURL(for: record)
        Task {
            if let text = await ImageOCRService.extractText(from: url) {
                await MainActor.run {
                    ClipboardService.copy(text: text)
                    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                }
            } else {
                // Quiet failure — Vision found no text, or the image
                // couldn't be loaded. A levelChange haptic feels right
                // for "tried but nothing happened" without yelling at
                // the user.
                await MainActor.run {
                    NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
                }
            }
        }
    }

    /// Pull chat messages out of the screenshot via Gemini and drop
    /// the result on the clipboard. Three buckets of outcome:
    ///
    /// * **Success** — clipboard gets the transcript, alignment haptic
    ///   plays so the user feels the operation land.
    /// * **No API key** — pop a one-time NSAlert that walks the user
    ///   to Settings. This is the *only* error path that's actionable,
    ///   so it earns a real dialog rather than a silent haptic. Once
    ///   configured the alert never fires again.
    /// * **Anything else** — levelChange haptic and NSLog. Includes
    ///   "Gemini said NO_MESSAGES", network failures, malformed
    ///   response. The panel deliberately avoids stealing focus for
    ///   transient errors; the haptic is the user's cue to retry or
    ///   pick a different image.
    private func handleGeminiExtract() {
        let url = imageStore.fullURL(for: record)
        Task {
            let result = await GeminiOCRService.extractMessages(from: url)
            await MainActor.run {
                switch result {
                case .success(let text) where !text.isEmpty:
                    ClipboardService.copy(text: text)
                    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                case .success:
                    NSLog("Notetaker: Gemini extract returned no messages for \(record.id)")
                    NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
                case .missingAPIKey:
                    promptForGeminiKey()
                case .failure(let message):
                    NSLog("Notetaker: Gemini extract failed: \(message)")
                    NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
                }
            }
        }
    }

    /// One-shot dialog steering the user to Settings the first time
    /// they invoke chat extraction without configuring a key. Modal
    /// against `nil` so it floats above whatever's frontmost — the
    /// notes panel can't host an attached sheet because it's a
    /// borderless `NSPanel` rather than a real window with a title bar.
    private func promptForGeminiKey() {
        let alert = NSAlert()
        alert.messageText = "Gemini API key required"
        alert.informativeText = "Add a key in Notetaker Settings to extract chat messages from screenshots."
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            SettingsWindow.open()
        }
    }

    /// Far-shadow color picks up the accent tint when the card is
    /// selected so the "lifted" feeling is reinforced — the user
    /// reads accent-colored shadow as "this one's chosen" before
    /// they even spot the corner check.
    private var shadowFar: Color {
        if isSelected {
            return DS.Color.accent.opacity(isHovered ? 0.55 : 0.42)
        }
        return Color.black.opacity(isHovered ? 0.55 : 0.42)
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

    /// Sibling of `copyButton` that pulls TEXT out of the image (chat
    /// transcript via Gemini if a key is configured, falling back to
    /// Vision OCR for posters / signs / random screenshots) and drops
    /// it on the clipboard. One click — no right-click discovery, no
    /// engine choice. The user just wants the words.
    private var extractTextButton: some View {
        Button(action: handleSmartExtract) {
            HStack(spacing: 4) {
                if isExtractingText {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.55)
                        .frame(width: 9, height: 9)
                } else {
                    Image(systemName: justExtractedText ? "checkmark" : "doc.text")
                        .font(.system(size: 9, weight: .semibold))
                }
                Text(isExtractingText ? "…" : (justExtractedText ? "Copied" : "Text"))
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(justExtractedText ? DS.Color.accent : Color.white)
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
        .disabled(isExtractingText)
        .animation(.selection, value: justExtractedText)
        .animation(.rowHover, value: isExtractingText)
        .help("Extract text (chat-aware)")
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

    /// Single-click "give me the text" — chooses the right engine for
    /// the user instead of asking. Logic:
    ///
    /// 1. **Gemini key present** → try chat extraction first. It strips
    ///    UI chrome, attributes senders, returns clean transcripts.
    ///    Best for the common case of "I screenshotted a conversation".
    /// 2. **Gemini returned NO_MESSAGES, errored, or no key** → fall
    ///    back to Vision OCR. Offline, instant, raw text — fine for
    ///    posters, signs, code, any non-chat text.
    /// 3. **Both empty** → levelChange haptic, no clipboard write.
    ///
    /// The button never bails to a confusing dialog; the only modal
    /// path is "no Gemini key AND a chat-looking image" → quietly
    /// uses Vision so the user still gets text. The Settings prompt
    /// for setting up Gemini is reserved for the explicit
    /// right-click "Extract Messages" path where the user opted in.
    private func handleSmartExtract() {
        let url = imageStore.fullURL(for: record)
        isExtractingText = true
        Task {
            // Step 1 — try Gemini if a key is configured. Skip
            // outright if no key so we don't pay the round-trip just
            // to learn we don't have one.
            let hasGeminiKey = !(UserDefaults.standard.string(forKey: GeminiOCRService.apiKeyDefaultsKey) ?? "").isEmpty

            var extracted: String?
            if hasGeminiKey {
                let result = await GeminiOCRService.extractMessages(from: url)
                if case .success(let text) = result, !text.isEmpty {
                    extracted = text
                }
            }

            // Step 2 — fall back to Vision OCR if Gemini didn't give
            // us anything usable.
            if extracted == nil {
                extracted = await ImageOCRService.extractText(from: url)
            }

            await MainActor.run {
                isExtractingText = false
                if let text = extracted, !text.isEmpty {
                    ClipboardService.copy(text: text)
                    justExtractedText = true
                    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 1_200_000_000)
                        justExtractedText = false
                    }
                } else {
                    NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
                }
            }
        }
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

    /// Match ImageCell — same 14pt pillow corners + 96pt height so
    /// the inflight placeholder doesn't visually pop when it swaps
    /// out for the real cell on save completion.
    private static let cornerRadius: CGFloat = 14
    private static let cellHeight: CGFloat = 96

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)

        return ZStack {
            if let preview = upload.preview {
                Image(nsImage: preview)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(DS.Color.bgSubtle)
            }
        }
        .frame(height: Self.cellHeight)
        .frame(maxWidth: .infinity)
        .clipShape(shape)
        .overlay(loadingScrim)
        .overlay(
            shape.strokeBorder(DS.Color.accent.opacity(0.62), lineWidth: 1.4)
        )
        // Same double-shadow as the finished cell, but tinted accent
        // so the still-saving tile glows in a way that's clearly
        // "in flight, not done yet".
        .shadow(color: DS.Color.accent.opacity(0.42), radius: 14, y: 6)
        .shadow(color: Color.black.opacity(0.5), radius: 1.5, y: 1)
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
            .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
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

