import SwiftUI
import AppKit
import AVKit
import UniformTypeIdentifiers

struct VideosGridView: View {
    @EnvironmentObject var env: AppEnvironment
    @State private var showClearConfirm = false
    /// The video currently being played inline at the top of the tab. nil
    /// means the panel is back in its normal "grid of thumbnails" mode.
    @State private var playingRecord: VideoRecord?

    private let columns = [
        GridItem(.flexible(), spacing: 6),
        GridItem(.flexible(), spacing: 6)
    ]

    var body: some View {
        VStack(spacing: 0) {
            if !env.videoStore.videos.isEmpty {
                toolbar
            }

            ScrollView {
                VStack(spacing: DS.Spacing.sm) {
                    if let record = playingRecord {
                        InlineVideoPlayer(
                            record: record,
                            fileURL: env.videoStore.fullURL(for: record),
                            onClose: {
                                withAnimation(.selection) { playingRecord = nil }
                            }
                        )
                        .id(record.id) // rebuild when user switches videos
                        .padding(.horizontal, DS.Spacing.sm)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }

                    if !env.videoStore.jobs.isEmpty {
                        jobsSection
                    }

                    if env.videoStore.videos.isEmpty && env.videoStore.jobs.isEmpty {
                        emptyState
                    } else if !env.videoStore.videos.isEmpty {
                        LazyVGrid(columns: columns, spacing: 6) {
                            ForEach(env.videoStore.videos) { record in
                                VideoCell(record: record)
                                    .overlay(playingBadge(for: record))
                                    .overlay(
                                        MultiFileDragSource(
                                            fileURLs: [env.videoStore.fullURL(for: record)],
                                            dragImageURLs: [env.videoStore.thumbURL(for: record)],
                                            onClick: {
                                                // Tapping the cell that's already playing
                                                // collapses the player — saves a trip to
                                                // the close button when you just want to
                                                // back out.
                                                withAnimation(.selection) {
                                                    if playingRecord?.id == record.id {
                                                        playingRecord = nil
                                                    } else {
                                                        playingRecord = record
                                                    }
                                                }
                                            }
                                        )
                                    )
                                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                            }
                        }
                        .padding(.horizontal, DS.Spacing.sm)
                        .padding(.bottom, DS.Spacing.sm)
                        .animation(.selection, value: env.videoStore.videos.map(\.id))
                    }
                }
                .padding(.top, DS.Spacing.xs)
            }
            .scrollIndicators(.never)
        }
        .background(shortcuts)
        .alert("Clear all videos?", isPresented: $showClearConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) {
                try? env.videoStore.trashAll()
            }
        } message: {
            Text("This removes all \(env.videoStore.videos.count) videos from the panel.")
        }
    }

    private var toolbar: some View {
        HStack(spacing: DS.Spacing.sm) {
            Text("\(env.videoStore.videos.count) video\(env.videoStore.videos.count == 1 ? "" : "s")")
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
        .padding(.horizontal, DS.Spacing.sm)
        .padding(.top, DS.Spacing.xs)
        .padding(.bottom, DS.Spacing.xxs)
    }

    private var jobsSection: some View {
        let jobs = env.videoStore.jobs
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
                            .foregroundStyle(DS.Color.accent)
                    }
                    Spacer()
                }
                .padding(.horizontal, 2)
                .padding(.bottom, 2)
            }

            ForEach(jobs) { job in
                DownloadJobRow(
                    job: job,
                    onCancel: { env.videoStore.cancelJob(job) },
                    onRetry: { env.videoStore.retryJob(job) },
                    onDismiss: { env.videoStore.dismissJob(job) }
                )
            }
        }
        .padding(.horizontal, DS.Spacing.sm)
    }

    private var emptyState: some View {
        VStack(spacing: DS.Spacing.sm) {
            Image(systemName: "film.stack")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(DS.Color.textTertiary)
            Text("No videos yet")
                .font(.nkBody.weight(.medium))
                .foregroundStyle(DS.Color.textSecondary)
            Text("Drag a video link (Instagram, YouTube, TikTok, X) or a video file here.")
                .font(.nkMeta)
                .foregroundStyle(DS.Color.textTertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 72)
        .padding(.horizontal, 32)
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
        env.videoStore.startDownload(url: url.absoluteString)
    }

    /// Draws an accent ring around whichever thumbnail is currently playing
    /// inline at the top of the tab, so the connection between "the video
    /// playing up there" and "which cell in the grid" stays obvious.
    @ViewBuilder
    private func playingBadge(for record: VideoRecord) -> some View {
        if playingRecord?.id == record.id {
            RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous)
                .strokeBorder(DS.Color.accent, lineWidth: 2)
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
                    .tint(DS.Color.accent)
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
                .foregroundStyle(DS.Color.accent)
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
        case .finished: return DS.Color.accent
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
    @EnvironmentObject var env: AppEnvironment
    @State private var isHovered = false

    var body: some View {
        let url = env.videoStore.thumbURL(for: record)
        ZStack(alignment: .bottomTrailing) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let img):
                    img.resizable().aspectRatio(contentMode: .fill)
                default:
                    ZStack {
                        Rectangle().fill(DS.Color.bgSubtle)
                        Image(systemName: "film")
                            .font(.system(size: 22, weight: .light))
                            .foregroundStyle(DS.Color.textTertiary)
                    }
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
                .strokeBorder(isHovered ? Color.white.opacity(0.18) : Color.clear, lineWidth: 1)
        )
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
            let p = AVPlayer(url: fileURL)
            p.play()
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
        return v
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player {
            nsView.player = player
        }
    }
}

