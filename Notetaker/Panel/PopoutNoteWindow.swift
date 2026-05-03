import AppKit
import SwiftUI

/// Slim, floating, always-on-top note editor that lives at the right
/// edge of the screen — designed to be opened ALONGSIDE a video
/// playing anywhere else (browser tab, WhatsApp call, native player,
/// any app). nox doesn't host or know about the video. The user
/// watches the video on the rest of their screen and types here.
///
/// Why a separate window (not part of the slab):
///   • The slab is anchored to the notch and is wide (530pt content).
///     For long-form note-taking next to a video that has its own
///     pixels, the user wants something narrow and persistent.
///   • Always-on-top + non-activating = stays visible while the user
///     keeps focus in YouTube / WhatsApp / their browser. The slab
///     itself can't do this — it auto-dismisses on focus-out.
///   • Independent lifecycle: opening doesn't disturb whatever the
///     slab is currently showing; closing doesn't kick the user out
///     of their flow.
///
/// Bonus: a "✨ Summarize" button at the top calls Gemini with the
/// user's own API key (already stored in Keychain via SecureKeyStore)
/// and prepends a structured summary to the note. The user mentioned
/// "the customer will add their own private key for their own AI" —
/// that's the existing Gemini key path, so the popout reuses it
/// without forcing a second key entry.
@MainActor
final class PopoutNote {
    static let shared = PopoutNote()
    private init() {}

    private var window: PopoutNotePanel?
    private var hostingView: NSHostingView<PopoutNoteContainer>?

    /// Currently shown note ID. Used so a second `show(noteID:)`
    /// call for the SAME note just focuses the existing window
    /// instead of recreating it (avoids losing in-flight summarize
    /// requests or scroll position).
    private var currentNoteID: String?

    /// Tracks whether we've parked the panel at the right edge yet.
    /// First show → park. After that, leave the panel wherever the
    /// user dragged it. Earlier we used `frame.origin == .zero` as
    /// the "untouched" signal, but NSPanel auto-positions itself on
    /// creation, so the origin was already non-zero by the time we
    /// checked — and the panel never got parked at all (it ended
    /// up wherever AppKit's auto-placement decided, which on this
    /// user's setup was the LEFT side of the screen).
    private var hasBeenPositioned = false

    // MARK: - Public API

    /// Open / focus the popout for `noteID`. Reuses the same window
    /// across calls — switching notes swaps the editor's bound
    /// content but keeps the window position the user dragged it to.
    func show(noteID: String, noteStore: NoteStore) {
        ensureWindow()

        if currentNoteID != noteID {
            currentNoteID = noteID
            let view = PopoutNoteContainer(
                noteID: noteID,
                noteStore: noteStore,
                onClose: { [weak self] in self?.hide() }
            )
            hostingView?.rootView = view
        }

        positionAtRightEdgeIfNew()
        window?.orderFrontRegardless()
        window?.makeKey()
    }

    func hide() {
        window?.orderOut(nil)
        currentNoteID = nil
        // Re-park on next show so the user always gets the
        // right-edge dock unless they explicitly dragged it.
        hasBeenPositioned = false
    }

    // MARK: - Window setup

    private func ensureWindow() {
        guard window == nil else { return }

        // 360pt wide × 75% of screen height, anchored to the right.
        // 360 is the canonical iOS-/macOS-sidebar width — wide enough
        // for a 60-65 char text column at 14pt body, narrow enough to
        // leave the bulk of the screen for whatever the user is
        // watching. Bear's compose-window, Notion's right sidebar,
        // and Apple Notes' floating window all land within 320-380pt.
        let screen = NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let width: CGFloat = 360
        let height: CGFloat = max(420, visible.height * 0.75)
        let frame = NSRect(x: 0, y: 0, width: width, height: height)

        // Native chrome per Apple's floating-panel pattern (Notes
        // float window, Stickies, Reminders detached note):
        //   • Full traffic-light cluster — close, minimize, zoom
        //   • `.titled` + `.fullSizeContentView` so SwiftUI fills
        //     edge-to-edge but the title-bar gutter still works
        //   • System material (NSVisualEffectView `.sidebar`) does
        //     the actual glass — no custom scrim / border / sheen,
        //     because real Apple panels don't use those. The
        //     material IS the edge.
        let panel = PopoutNotePanel(
            contentRect: frame,
            styleMask: [
                .titled,
                .closable,
                .miniaturizable,
                .resizable,
                .fullSizeContentView,
                .nonactivatingPanel
            ],
            backing: .buffered,
            defer: false
        )
        panel.title = ""
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovable = true
        // Drag-by-background OFF — the title bar IS the drag handle
        // (matches every other macOS app). Drag-by-background steals
        // text-selection drags inside the editor body.
        panel.isMovableByWindowBackground = false
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        // Let the material show through; the panel itself draws nothing.
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        // Closing the X tears the window down; clear our reference
        // so the next `show` rebuilds rather than trying to revive a
        // dead window.
        panel.onClose = { [weak self] in
            self?.window = nil
            self?.hostingView = nil
            self?.currentNoteID = nil
        }

        let placeholder = PopoutNoteContainer(
            noteID: "",
            noteStore: NoteStore.placeholder,
            onClose: { [weak self] in self?.hide() }
        )
        let host = NSHostingView(rootView: placeholder)
        host.frame = frame
        host.autoresizingMask = [.width, .height]
        host.translatesAutoresizingMaskIntoConstraints = true
        panel.contentView = host

        self.window = panel
        self.hostingView = host
    }

    /// Park the panel at the right edge of the screen on first
    /// open per session. Subsequent shows leave the user's drag
    /// position alone. Picks the screen the slab is currently on
    /// (multi-monitor users want the popout next to the slab they
    /// just clicked, not on whichever screen has keyboard focus).
    private func positionAtRightEdgeIfNew() {
        guard let win = window else { return }
        guard !hasBeenPositioned else { return }

        // Prefer the screen containing the main slab panel — that's
        // the screen the user is actively using. Fall back to
        // NSScreen.main, then to the first attached screen.
        let slabScreen = NSApp.windows.first {
            $0.isVisible && $0 is NSPanel && !($0 is PopoutNotePanel)
        }?.screen
        let screen = slabScreen ?? NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = win.frame.size
        let origin = NSPoint(
            // 16pt gap from the right edge so the window doesn't
            // visually merge with the screen border.
            x: visible.maxX - size.width - 16,
            // Vertically centered on the screen.
            y: visible.midY - size.height / 2
        )
        win.setFrameOrigin(origin)
        hasBeenPositioned = true
    }
}

/// NSPanel subclass that becomes key (so the editor can take
/// keystrokes) but never main (which would steal focus from the
/// frontmost video app on every click). Mirrors the pattern used by
/// the slab's main panel.
private final class PopoutNotePanel: NSPanel {
    var onClose: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func close() {
        super.close()
        onClose?()
    }
}

// MARK: - SwiftUI content

/// Top-level SwiftUI view inside the popout window. Wraps the
/// editor + summarize button + close in a vertical stack.
private struct PopoutNoteContainer: View {
    let noteID: String
    @ObservedObject var noteStore: NoteStore
    let onClose: () -> Void

    @State private var text: String = ""
    /// Debounce token for auto-save — same 0.7s window the in-slab
    /// editor uses, same rationale (cap data-loss to one paused
    /// thought regardless of how the window goes away).
    @State private var saveTask: Task<Void, Never>?
    @State private var isSummarizing = false
    @State private var summarizeError: String?
    @State private var showMissingKeyAlert = false

    @State private var coordinatorRef = MarkdownTextEditor.CoordinatorRef()

    var body: some View {
        ZStack {
            // System material does ALL the glass work. No scrim,
            // no border, no sheen — those are tells of a "fake"
            // glass panel. Apple's real panels (Notes float
            // window, Stickies, Reminders detached) use
            // VisualEffectView + nothing else. The window's own
            // `titled` style draws the rounded corners + the
            // traffic-light cluster.
            VisualEffectBlur(material: .sidebar, blendingMode: .behindWindow)

            VStack(spacing: 0) {
                // Reserve ~52pt at the top for the title-bar zone
                // (where the traffic lights sit). We anchor the
                // AI button INTO that zone on the right so the
                // toolbar reads as one row with the close button.
                titleBar
                editor
            }
        }
        .onAppear { loadFromStore() }
        .onChange(of: noteID) { _ in loadFromStore() }
        .onChange(of: text) { newValue in scheduleSave(text: newValue) }
        .alert("AI key missing", isPresented: $showMissingKeyAlert) {
            Button("Open Settings") {
                NotificationCenter.default.post(
                    name: NSNotification.Name("Notetaker.OpenSettings"),
                    object: nil
                )
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Add your Gemini API key in Settings to enable AI Summarize.")
        }
    }

    /// macOS-native glass panel — `.behindWindow` blur samples the
    /// desktop / video / whatever's actually behind us, and a dark
    /// scrim keeps the white text readable on bright frames.
    ///
    /// We tried layering the project's `liquidGlass` Metal shader on
    /// top for the lensing / chromatic-aberration effect, but that
    /// shader is a `.layerEffect` — it refracts SOURCE pixels inside
    /// the SwiftUI layer, not pixels behind the window. With nothing
    /// opaque in the layer to refract, it crashed out into a yellow
    /// fallback. The system blur IS the right tool for a free-floating
    /// glass panel: same approach Apple Notes' float window, Stickies,
    /// and Notification Center take.
    /// Title-bar row. The leading 78pt is left empty for the
    /// traffic-light cluster (AppKit draws close/min/zoom there in
    /// `titled` panels). The AI Summarize button + char count sit
    /// at the trailing edge so the row reads as one toolbar.
    /// Height matches the standard macOS title bar (~28pt).
    private var titleBar: some View {
        HStack(spacing: 8) {
            // Traffic-light gutter — leave 78pt clear so the system
            // close/min/zoom buttons have room. Apple Notes float
            // window uses the same offset.
            Spacer()
                .frame(width: 78)

            if let err = summarizeError {
                Text(err)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.red)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer()

            // Char count chip — only shown once the user starts
            // typing. Quiet by design (not the protagonist of the
            // title bar).
            if text.count > 0 {
                Text("\(text.count)")
                    .font(.system(size: 10, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            summarizeButton
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
    }

    /// Native bordered toolbar button — the same style Mail's "Reply"
    /// and Notes' "Aa" toolbar items use. Lavender sparkles tint is
    /// the only nox flourish; the chrome is system. Reads as part
    /// of the title bar's toolbar zone, not a custom CTA.
    private var summarizeButton: some View {
        Button(action: summarize) {
            HStack(spacing: 5) {
                if isSummarizing {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.6)
                        .frame(width: 12, height: 12)
                } else {
                    Image(systemName: "sparkles")
                        .foregroundStyle(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.85, green: 0.75, blue: 1.0),
                                    Color(red: 0.60, green: 0.45, blue: 0.92)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
                Text(isSummarizing ? "Summarizing…" : "Summarize")
            }
            .font(.system(size: 12, weight: .medium))
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(isSummarizing || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private var editor: some View {
        MarkdownTextEditor(text: $text, coordinatorRef: coordinatorRef)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text("Type while you watch.")
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .allowsHitTesting(false)
                }
            }
    }

    // MARK: - State sync

    /// Pull the latest body from the store. Called on .onAppear
    /// AND when noteID changes (the popout swaps notes when the
    /// user opens a different one without closing first).
    private func loadFromStore() {
        guard !noteID.isEmpty else { return }
        if let n = noteStore.notes.first(where: { $0.id == noteID }) {
            text = n.body
        }
    }

    private func scheduleSave(text: String) {
        guard !noteID.isEmpty else { return }
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            try? noteStore.updateBody(id: noteID, body: text)
        }
    }

    // MARK: - AI Summarize

    /// Call Gemini with the user's stored key and prepend a
    /// structured summary block to the top of the note. Existing
    /// content stays untouched below a `---` separator so the user
    /// can still see what they wrote.
    private func summarize() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSummarizing else { return }

        isSummarizing = true
        summarizeError = nil

        Task { @MainActor in
            let result = await GeminiSummaryService.summarizeDetail(body: trimmed)
            isSummarizing = false
            switch result {
            case .success(let summary):
                let prefix = "## ✨ Summary\n\n\(summary)\n\n---\n\n"
                text = prefix + text
                // Force-save right now (don't wait for debounce)
                // so the AI work isn't accidentally lost if the
                // user closes the window the next second.
                try? noteStore.updateBody(id: noteID, body: text)
            case .missingAPIKey:
                showMissingKeyAlert = true
            case .failure(let reason):
                summarizeError = reason
            }
        }
    }
}

// MARK: - NoteStore placeholder for early-init render

/// The hosting view needs a NoteStore at construction time, but the
/// real one only arrives via `show(noteID:noteStore:)`. This stub
/// keeps SwiftUI happy for the one frame between `ensureWindow()` and
/// the first `show` call. It points at an in-memory database so any
/// stray writes are harmless and discarded.
private extension NoteStore {
    static let placeholder: NoteStore = {
        // Force-try because the in-memory DB constructor is
        // infallible in practice (no I/O) — and if SQLite refuses to
        // open even a memory queue, every other code path is already
        // dead.
        let db = try! Database(inMemory: true)
        return NoteStore(db: db)
    }()
}
