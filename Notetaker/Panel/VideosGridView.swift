import SwiftUI
import AppKit
import AVKit
import UniformTypeIdentifiers

struct VideosGridView: View {
    @EnvironmentObject var videoStore: VideoStore
    @EnvironmentObject var presenter: PanelPresenter
    @Environment(\.panelAccent) private var panelAccent: Color
    @State private var showClearConfirm = false
    /// The video currently being played inline at the top of the tab. nil
    /// means the panel is back in its normal "grid of thumbnails" mode.
    @State private var playingRecord: VideoRecord?

    /// Multi-select state. Same pattern as Notes/Images: ⌘-click
    /// toggles, ⇧-click does smart range toggle, plain click in
    /// selection mode also toggles. Outside selection mode, plain
    /// click PLAYS the video (existing behavior).
    @State private var selectedIds: Set<String> = []
    @State private var lastClickedId: String? = nil

    private let columns = [
        GridItem(.flexible(), spacing: 6),
        GridItem(.flexible(), spacing: 6)
    ]

    var body: some View {
        VStack(spacing: 0) {
            if !videoStore.videos.isEmpty {
                toolbar
            }

            ScrollView {
                VStack(spacing: DS.Spacing.sm) {
                    if let record = playingRecord {
                        InlineVideoPlayer(
                            record: record,
                            fileURL: videoStore.fullURL(for: record),
                            onClose: {
                                withAnimation(.selection) { playingRecord = nil }
                            }
                        )
                        .id(record.id) // rebuild when user switches videos
                        .padding(.horizontal, DS.Spacing.sm)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }

                    if !videoStore.jobs.isEmpty {
                        jobsSection
                    }

                    if videoStore.videos.isEmpty && videoStore.jobs.isEmpty {
                        emptyState
                    } else if !videoStore.videos.isEmpty {
                        LazyVGrid(columns: columns, spacing: 6) {
                            ForEach(videoStore.videos) { record in
                                VideoCell(
                                    record: record,
                                    isSelected: selectedIds.contains(record.id)
                                )
                                    .overlay(playingBadge(for: record))
                                    .overlay(
                                        MultiFileDragSource(
                                            fileURLs: [videoStore.fullURL(for: record)],
                                            dragImageURLs: [videoStore.thumbURL(for: record)],
                                            onClick: {
                                                handleCellClick(record)
                                            }
                                        )
                                    )
                                    // Trash overlay layered AFTER the drag source so
                                    // SwiftUI hit-tests it first — otherwise the
                                    // MultiFileDragSource NSView swallows the click
                                    // and the trash button never fires.
                                    .overlay(alignment: .topLeading) {
                                        videoTrashButton(for: record)
                                    }
                                    .transition(.dropLanding)
                                    .celebrateIfRecent(record.createdAt)
                            }
                        }
                        .padding(.horizontal, DS.Spacing.sm)
                        .padding(.bottom, DS.Spacing.sm)
                        .animation(.dropSpring, value: videoStore.videos.map(\.id))
                    }
                }
                .padding(.top, DS.Spacing.xs)
            }
            .scrollIndicators(.never)
        }
        .background(shortcuts)
        // Collapse the inline player if the video being played got
        // deleted (per-cell trash, bulk Clear, retention purge…).
        // Without this the player keeps showing a stale frame for a
        // record that no longer exists.
        .onChange(of: videoStore.videos.map(\.id)) { ids in
            if let playing = playingRecord, !ids.contains(playing.id) {
                withAnimation(.selection) { playingRecord = nil }
            }
        }
        .overlay {
            ClearConfirmOverlay(
                isPresented: $showClearConfirm,
                title: "Clear all videos?",
                message: "This removes all \(videoStore.videos.count) video\(videoStore.videos.count == 1 ? "" : "s") from the panel."
            ) {
                try? videoStore.trashAll()
            }
        }
    }

    // MARK: - Multi-select helpers (mirror Notes/Images pattern)

    /// Click handler for video cells. In selection mode, all clicks
    /// toggle selection. Outside selection mode, ⌘-click enters
    /// selection mode by toggling, ⇧-click does range toggle, plain
    /// click PLAYS the video (existing behavior preserved).
    private func handleCellClick(_ record: VideoRecord) {
        let mods = NSEvent.modifierFlags
        if mods.contains(.shift) {
            shiftRangeToggle(to: record.id)
            return
        }
        if mods.contains(.command) {
            toggleSelection(record.id)
            return
        }
        // In selection mode, plain click toggles (no play).
        if !selectedIds.isEmpty {
            toggleSelection(record.id)
            return
        }
        // Default: play / pause inline.
        withAnimation(.selection) {
            if playingRecord?.id == record.id {
                playingRecord = nil
            } else {
                playingRecord = record
            }
        }
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
        let visible = videoStore.videos.map(\.id)
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
            try? videoStore.trash(id: id)
        }
        selectedIds.removeAll()
    }

    private func videoTrashButton(for record: VideoRecord) -> some View {
        Button {
            try? videoStore.trash(id: record.id)
        } label: {
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
        .help("Delete video")
    }

    private var toolbar: some View {
        // Two states: when items are selected, the toolbar
        // becomes a SELECTION toolbar with bulk actions. Otherwise
        // it's the count label + Clear-all action. Mirrors how
        // Notes' toolbar swaps in selection mode.
        Group {
            if !selectedIds.isEmpty {
                selectionToolbar
            } else {
                defaultToolbar
            }
        }
        .padding(.horizontal, DS.Spacing.sm)
        .padding(.top, DS.Spacing.xs)
        .padding(.bottom, DS.Spacing.xxs)
    }

    private var defaultToolbar: some View {
        HStack(spacing: DS.Spacing.sm) {
            Text("\(videoStore.videos.count) video\(videoStore.videos.count == 1 ? "" : "s")")
                .font(.nkMeta)
                .foregroundStyle(DS.Color.textTertiary)

            Spacer()

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
    }

    private var selectionToolbar: some View {
        HStack(spacing: DS.Spacing.sm) {
            Text("\(selectedIds.count) selected")
                .font(.nkLabel.weight(.semibold))
                .foregroundStyle(DS.Color.textPrimary)

            Button {
                let allSelected = selectedIds.count == videoStore.videos.count
                if allSelected {
                    selectedIds.removeAll()
                } else {
                    selectedIds = Set(videoStore.videos.map(\.id))
                }
            } label: {
                Text(selectedIds.count == videoStore.videos.count ? "Deselect All" : "Select All")
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
    }

    private var jobsSection: some View {
        let jobs = videoStore.jobs
        let active = jobs.filter { !$0.state.isTerminal }.count

        return VStack(alignment: .leading, spacing: 4) {
            if jobs.count > 1 {
                // Header is the cheap fix for "wait, is it only downloading
                // one at a time?" — now users see the count even when the
                // first row is the only one fully visible on screen.
                HStack(spacing: 4) {
                    Text("Downloads")
                        .font(.nkMeta.weight(.medium))
                        .foregroundStyle(DS.Color.textSecondary)
                    if active > 0 {
                        Text("· \(active) active")
                            .font(.nkMeta)
                            .foregroundStyle(panelAccent)
                    }
                    Spacer()
                }
                .padding(.horizontal, 2)
                .padding(.bottom, 2)
            }

            ForEach(jobs) { job in
                DownloadJobRow(
                    job: job,
                    onCancel: { videoStore.cancelJob(job) },
                    onRetry: { videoStore.retryJob(job) },
                    onDismiss: { videoStore.dismissJob(job) }
                )
            }
        }
        .padding(.horizontal, DS.Spacing.sm)
    }

    private var emptyState: some View {
        // Shared empty-state family — see DesignSystem/EmptyDropState.swift.
        EmptyDropState(
            icon: "film.stack",
            title: "Drop videos here",
            subtitle: "Drag a video link (Instagram, YouTube, TikTok, X) or a video file.",
            keyHint: ("⌘V", "to paste a link"),
            accent: Color(red: 0.95, green: 0.40, blue: 0.55)
        )
    }

    private var shortcuts: some View {
        Button(action: handlePasteURL) { EmptyView() }
            .keyboardShortcut("v", modifiers: .command)
            .opacity(0)
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
    }

    private func handlePasteURL() {
        guard let text = NSPasteboard.general.string(forType: .string),
              let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "http" || url.scheme == "https" else { return }
        // Gate on the downloadable-host allowlist before surfacing
        // the pill. Without this, pasting any URL while focused on
        // the Videos tab popped a "Download this video" affordance
        // for plain web pages, which then failed when tapped (no
        // yt-dlp extractor matches). User report 2026-05-09: "video
        // section sometimes it's getting download somethings which
        // are really not a downlaod thing."
        guard VideoDropScanner.isDownloadableURL(url) else { return }
        // ⌘V on the videos tab: surface the URL via the pending-
        // video pill (with a Download button) rather than auto-
        // downloading. Per the user's spec: NOTHING downloads
        // until they click Download on the pill.
        presenter.setPendingVideo(url)
    }

    /// Draws an accent ring around whichever thumbnail is currently playing
    /// inline at the top of the tab, so the connection between "the video
    /// playing up there" and "which cell in the grid" stays obvious.
    @ViewBuilder
    private func playingBadge(for record: VideoRecord) -> some View {
        if playingRecord?.id == record.id {
            RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous)
                .strokeBorder(panelAccent, lineWidth: 2)
                .allowsHitTesting(false)
        }
    }
}

// MARK: - Download job row

struct DownloadJobRow: View {
    let job: DownloadJob
    let onCancel: () -> Void
    let onRetry: () -> Void
    let onDismiss: () -> Void
    @Environment(\.panelAccent) private var panelAccent: Color

    var body: some View {
        HStack(spacing: DS.Spacing.sm) {
            Image(systemName: iconName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(iconColor)
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(DS.Color.bgSubtle)
                )

            VStack(alignment: .leading, spacing: 3) {
                Text(displayTitle)
                    .font(.nkMeta.weight(.medium))
                    .foregroundStyle(DS.Color.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                progressContent
            }

            Spacer(minLength: 0)

            trailingButton
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous)
                .fill(DS.Color.bgSubtle)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous)
                .strokeBorder(borderColor, lineWidth: 0.5)
        )
    }

    private var displayTitle: String {
        job.title ?? job.titleFallback
    }

    @ViewBuilder
    private var progressContent: some View {
        switch job.state {
        case .queued:
            Text("Queued…")
                .font(.nkLabel)
                .foregroundStyle(DS.Color.textTertiary)
        case .downloading:
            VStack(alignment: .leading, spacing: 2) {
                ProgressView(value: job.progress)
                    .progressViewStyle(.linear)
                    .tint(panelAccent)
                    .frame(maxWidth: .infinity)
                HStack(spacing: 4) {
                    Text(progressLabel)
                        .font(.nkLabel)
                        .foregroundStyle(DS.Color.textTertiary)
                }
            }
        case .finished:
            Text("Saved")
                .font(.nkLabel)
                .foregroundStyle(panelAccent)
        case .failed(let message):
            Text(message)
                .font(.nkLabel)
                .foregroundStyle(Color.red.opacity(0.9))
                .lineLimit(1)
                .truncationMode(.tail)
        case .cancelled:
            Text("Cancelled")
                .font(.nkLabel)
                .foregroundStyle(DS.Color.textTertiary)
        }
    }

    private var progressLabel: String {
        let pct = Int((job.progress * 100).rounded())
        if let total = job.totalBytes, total > 0, let downloaded = job.downloadedBytes {
            return "\(pct)% · \(Self.format(bytes: downloaded)) / \(Self.format(bytes: total))"
        }
        return "\(pct)%"
    }

    @ViewBuilder
    private var trailingButton: some View {
        switch job.state {
        case .queued, .downloading:
            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(DS.Color.textSecondary)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(DS.Color.bgHover))
            }
            .buttonStyle(.plain)
        case .failed:
            HStack(spacing: 4) {
                Button(action: onRetry) {
                    Text("Retry")
                        .font(.nkLabel.weight(.semibold))
                        .foregroundStyle(DS.Color.textPrimary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(DS.Color.bgSelected)
                        )
                }
                .buttonStyle(.plain)
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(DS.Color.textSecondary)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(DS.Color.bgHover))
                }
                .buttonStyle(.plain)
            }
        case .cancelled, .finished:
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(DS.Color.textSecondary)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(DS.Color.bgHover))
            }
            .buttonStyle(.plain)
        }
    }

    private var iconName: String {
        switch job.state {
        case .queued, .downloading: return "arrow.down.circle"
        case .finished: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .cancelled: return "xmark.circle"
        }
    }

    private var iconColor: Color {
        switch job.state {
        case .failed: return Color.red.opacity(0.85)
        case .finished: return panelAccent
        default: return DS.Color.textSecondary
        }
    }

    private var borderColor: Color {
        switch job.state {
        case .failed: return Color.red.opacity(0.35)
        default: return Color.white.opacity(0.06)
        }
    }

    private static func format(bytes: Int64) -> String {
        let fmt = ByteCountFormatter()
        fmt.allowedUnits = [.useKB, .useMB, .useGB]
        fmt.countStyle = .file
        return fmt.string(fromByteCount: bytes)
    }
}

// MARK: - Video cell

struct VideoCell: View {
    let record: VideoRecord
    /// True when this cell is part of the multi-select set.
    /// Drives the selection-state visual (accent ring + check
    /// badge), matching the Notes/Images selection vocabulary.
    var isSelected: Bool = false
    @Environment(\.panelAccent) private var panelAccent: Color
    @EnvironmentObject var videoStore: VideoStore
    @State private var isHovered = false

    var body: some View {
        let url = videoStore.thumbURL(for: record)
        ZStack(alignment: .bottomTrailing) {
            // Cached thumbnail — same NSCache as images. The film-icon
            // placeholder paints synchronously on cache miss while the
            // file decodes off-main, then swaps in.
            LocalThumbnailView(id: record.id, url: url) {
                ZStack {
                    Rectangle().fill(DS.Color.bgSubtle)
                    Image(systemName: "film")
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(DS.Color.textTertiary)
                }
            }
            .frame(height: 96)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous))

            if let duration = record.durationSec {
                Text(Self.format(duration: duration))
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.black.opacity(0.68))
                    )
                    .padding(6)
            }

            Image(systemName: "play.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.9))
                .shadow(color: .black.opacity(0.4), radius: 3)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .allowsHitTesting(false)
        }
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous)
                .strokeBorder(
                    isSelected ? Color.accentColor
                        : (isHovered ? Color.white.opacity(0.18) : Color.clear),
                    lineWidth: isSelected ? 2.5 : 1
                )
        )
        .overlay(alignment: .topLeading) {
            // Animated check badge when selected — same visual
            // vocabulary as Notes' selection state. Sits in the
            // top-left where the trash button isn't (trash is
            // typically top-leading too — when in selection mode,
            // the trash hides per the parent's gating).
            if isSelected {
                ZStack {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 22, height: 22)
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .heavy))
                        .foregroundStyle(.white)
                }
                .padding(8)
                .transition(.scale(scale: 0.5).combined(with: .opacity))
            }
        }
        .overlay(alignment: .topTrailing) {
            if let title = record.title {
                Text(title)
                    .font(.nkLabel.weight(.medium))
                    .foregroundStyle(Color.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.black.opacity(0.62))
                    )
                    .padding(6)
                    .opacity(isHovered ? 1 : 0)
                    .animation(.rowHover, value: isHovered)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.rowHover) { isHovered = hovering }
        }
    }

    private static func format(duration: Double) -> String {
        let total = Int(duration)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}

// MARK: - Inline video player

/// Plays a video in-place at the top of the Videos tab instead of spawning
/// a floating window. The frame is aspect-ratio aware so portrait reels
/// stack tall and landscape clips stay wide — with a cap so the player
/// never eats the whole panel and hides the jobs list / grid below.
///
/// AVPlayer holds a file handle on the underlying mp4, so we explicitly
/// pause + drop the item in `onDisappear`. Without that, a later "Clear"
/// / trash would fail with EBUSY.
private struct InlineVideoPlayer: View {
    let record: VideoRecord
    let fileURL: URL
    let onClose: () -> Void

    @State private var player: AVPlayer?

    /// Portrait cap — tall enough for a reel to feel like a reel, short
    /// enough to leave room for the grid below in a 620pt panel.
    private static let portraitMaxHeight: CGFloat = 360
    /// Landscape cap — YouTube-style clips don't need the full panel
    /// height, and keeping them short makes the grid feel less hidden.
    private static let landscapeMaxHeight: CGFloat = 200

    var body: some View {
        let aspect = aspectRatio
        let maxH = aspect >= 1 ? Self.landscapeMaxHeight : Self.portraitMaxHeight

        ZStack(alignment: .topTrailing) {
            Group {
                if let player {
                    // We host AVPlayerView via NSViewRepresentable instead
                    // of using SwiftUI's `VideoPlayer`. On macOS 26.4 the
                    // runtime crashes inside `VideoPlayer` with "failed to
                    // demangle superclass of VideoPlayerView from mangled
                    // name 'So12AVPlayerViewC'" — nothing in our binary
                    // references AVPlayerView directly, so the metadata
                    // chain doesn't resolve. Owning the AVPlayerView
                    // ourselves links the symbol and dodges the crash.
                    AVPlayerHost(player: player)
                } else {
                    Rectangle().fill(Color.black)
                }
            }
            .aspectRatio(aspect, contentMode: .fit)
            .frame(maxWidth: .infinity, maxHeight: maxH)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
            )

            Button(action: handleClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.white)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.black.opacity(0.6)))
            }
            .buttonStyle(.plain)
            .padding(8)
            .help("Close player")
        }
        .onAppear {
            // Build the player synchronously here. We deliberately do
            // NOT call play() yet — the AVPlayer has no render target
            // until SwiftUI re-renders, mounts AVPlayerHost, and
            // makeNSView attaches the AVPlayerView. Calling play()
            // before that race resolves used to result in the cell
            // tap collapsing to a frozen first frame on macOS 26.x —
            // the user reported "video player is not playing", which
            // is exactly that symptom. We now kick off playback inside
            // AVPlayerHost.makeNSView, the moment the player has a
            // view to render into. Idempotent if SwiftUI re-mounts.
            let p = AVPlayer(url: fileURL)
            p.isMuted = false
            p.volume = 1.0
            player = p
        }
        .onDisappear(perform: teardown)
    }

    private func handleClose() {
        teardown()
        onClose()
    }

    private func teardown() {
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
    }

    /// Falls back to 16:9 when width/height aren't known — better than
    /// collapsing to zero-height while the metadata loads.
    private var aspectRatio: CGFloat {
        let w = CGFloat(record.width ?? 0)
        let h = CGFloat(record.height ?? 0)
        guard w > 0, h > 0 else { return 16.0 / 9.0 }
        return w / h
    }
}

/// Hosts an `AVPlayerView` directly so SwiftUI's `VideoPlayer`-induced
/// metadata crash on macOS 26.4 is avoided. See call site for the full
/// crash signature; the short version is that owning an `AVPlayerView`
/// instance from our own code forces the linker to retain the class
/// symbol and the runtime can demangle the superclass.
private struct AVPlayerHost: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.player = player
        v.controlsStyle = .inline
        v.videoGravity = .resizeAspect
        v.allowsPictureInPicturePlayback = false
        v.showsFullScreenToggleButton = false
        v.showsTimecodes = false
        // Kick off playback once the AVPlayerView is fully attached.
        // Calling play() here (instead of in the parent's onAppear)
        // guarantees the player has a render target at the moment
        // playback starts — without that ordering, AVPlayer can land
        // in a state where the audio plays but the video frame stays
        // black on first present. We jump to .zero defensively so a
        // remounted cell (e.g. switching between videos) restarts
        // from the beginning instead of resuming where the previous
        // viewing left off.
        v.player?.seek(to: .zero)
        v.player?.play()
        return v
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player {
            nsView.player = player
            // Re-arm playback whenever the underlying player changes —
            // matches the makeNSView semantics so a swap-in starts
            // playing without requiring a manual click on the controls.
            player.play()
        }
    }
}

