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

        // 460pt wide × full visible-frame height, docked flush to
        // the right edge. The width hosts a SPLIT view (editor +
        // preview), so each pane gets ~225pt — comfortable for
        // ~40-char columns at 13pt serif, the right reading width
        // for both writing and rendered output. Full height makes
        // the popout feel like a real sidebar attached to the
        // screen edge rather than a floating widget.
        let screen = NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let width: CGFloat = 460
        let height: CGFloat = visible.height
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
        // Flush to the right edge (no 16pt gap) and full visible
        // height — the popout reads as a docked sidebar attached
        // to the screen edge, not a free-floating window. Earlier
        // we kept a 16pt margin and 75% height; user feedback was
        // that "it doesn't actually open on the right side" because
        // the window felt detached from the edge. Going edge-to-edge
        // fixes that perceptually.
        let width: CGFloat = 460
        let height: CGFloat = visible.height
        let frame = NSRect(
            x: visible.maxX - width,
            y: visible.minY,
            width: width,
            height: height
        )
        win.setFrame(frame, display: true)
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
    /// Right-pane visibility. User 2026-05-06: "i should be able to
    /// close the note section if i want which will give me more
    /// room to write." Toggled by the sidebar button in the title
    /// bar; when false, the editor expands to fill the entire
    /// popout width.
    @State private var notesListVisible: Bool = true

    var body: some View {
        VStack(spacing: 0) {
            // Reserve ~38pt at the top for the title-bar zone
            // (system traffic lights live there + our Summarize
            // button on the trailing edge). Reads as one toolbar.
            titleBar
            // Hairline blue divider — sits between the title bar
            // and the page surface. Matches the blue rule color
            // used in the editor.
            Rectangle()
                .fill(rulesColor)
                .frame(height: 0.5)

            HStack(spacing: 0) {
                // Editor flexes — that's the writing surface, the
                // protagonist of the window. When the notes list is
                // hidden, the editor takes the full popout width.
                editorPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if notesListVisible {
                    Rectangle()
                        .fill(rulesColor)
                        .frame(width: 0.5)
                    notesListPane
                        .frame(width: 180)
                        .frame(maxHeight: .infinity)
                        .transition(
                            .move(edge: .trailing).combined(with: .opacity)
                        )
                }
            }
            .animation(.easeOut(duration: 0.22), value: notesListVisible)
        }
        .background(paperColor)
        // Force light appearance so system traffic-light glyphs
        // tint dark on the white paper background instead of
        // appearing washed-out against the cream.
        .preferredColorScheme(.light)
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

    // MARK: - Paper palette

    /// Off-white school-notebook paper. Slight warmth (R/G slightly
    /// above B) keeps it from reading as "cold lab white" — just
    /// enough to feel like paper, not cold enough to feel cream.
    private var paperColor: Color {
        Color(red: 0.992, green: 0.992, blue: 0.973)
    }
    /// Saturated blue for the horizontal rule lines and divider.
    private var rulesColor: Color {
        Color(red: 0.0, green: 0.31, blue: 0.63).opacity(0.22)
    }
    /// Red vertical margin line.
    private var marginColor: Color {
        Color(red: 0.85, green: 0.20, blue: 0.20).opacity(0.45)
    }
    /// Body ink — deep navy rather than pure black so the page
    /// reads as written-on rather than printed.
    private var inkColor: Color {
        Color(red: 0.10, green: 0.12, blue: 0.20)
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

            // Sidebar toggle — collapses / expands the right-pane
            // notes list. SF Symbol pair clearly signals state:
            // `sidebar.right` (filled-tinted) when visible,
            // outlined when hidden.
            sidebarToggleButton

            summarizeButton
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
    }

    private var sidebarToggleButton: some View {
        Button {
            withAnimation(.easeOut(duration: 0.22)) {
                notesListVisible.toggle()
            }
        } label: {
            Image(systemName: notesListVisible
                  ? "sidebar.right"
                  : "sidebar.right")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(notesListVisible
                                 ? Color.primary.opacity(0.8)
                                 : Color.primary.opacity(0.4))
        }
        .buttonStyle(.borderless)
        .help(notesListVisible ? "Hide notes list" : "Show notes list")
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

    /// Left pane — the writing surface. White paper with horizontal
    /// blue rule lines every 20pt and a red vertical margin line at
    /// 32pt. The MarkdownTextEditor draws on top with its leading
    /// edge offset past the margin so text doesn't run through the
    /// red line.
    private var editorPane: some View {
        ZStack(alignment: .topLeading) {
            ruledBackground
            MarkdownTextEditor(
                text: $text,
                coordinatorRef: coordinatorRef,
                // Force dark ink. The default is DS.Color.textPrimary
                // (lavender-tinted white) which renders near-invisible
                // on the white paper background — user 2026-05-06:
                // "writing should be in black, it's getting on white."
                bodyTextColor: inkColor
            )
                .padding(.leading, 36)
                .padding(.trailing, 12)
                .padding(.top, 6)
                .padding(.bottom, 12)
            if text.isEmpty {
                // Placeholder origin matches the actual editor's first-
                // glyph origin so it reads as ghost text where you'll
                // start typing. Editor leading = 36 (padding) + 12
                // (textContainerInset.width) = 48pt. Editor top = 6
                // (padding) + 8 (textContainerInset.height) = 14pt.
                // Earlier I had .leading 40 / .top 14, which placed
                // the placeholder 8pt LEFT of where the cursor lands —
                // user reported it as "missplaced."
                Text("Type while you watch.")
                    .font(.system(size: 14))
                    .foregroundStyle(inkColor.opacity(0.30))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 48)
                    .padding(.top, 14)
                    .allowsHitTesting(false)
            }
        }
    }

    /// Static-position rules + margin line. Drawn behind the
    /// MarkdownTextEditor's clear background. Lines don't scroll
    /// with content (the page IS the lines, not the text); for short
    /// notes this reads exactly like a page of ruled paper. If the
    /// note grows past one screen the editor's own scroll behavior
    /// takes over and the rules stay anchored to the viewport — a
    /// known compromise that's still preferable to drawing the
    /// rules inside the NSTextView's text container (which would
    /// require subclassing for a primarily decorative concern).
    private var ruledBackground: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                // Horizontal blue rules every 19pt, starting 30pt
                // from the top. The 30pt anchor aligns the first
                // rule with the BASELINE of the first line of text:
                // editor top inset is 14pt (padding 6 + container 8),
                // 14pt SF body has ~16pt ascender, so the baseline
                // sits at ~30pt. Subsequent rules at 19pt match SF's
                // natural body line-height — text rides the rules
                // like writing on real notebook paper instead of
                // floating between them.
                ForEach(0..<max(1, Int(geo.size.height / 19) + 1), id: \.self) { i in
                    Rectangle()
                        .fill(rulesColor)
                        .frame(height: 0.5)
                        .offset(y: 30 + CGFloat(i) * 19)
                }
                // Red vertical margin line at 38pt — sits 10pt left
                // of where text begins (editor leading = 48pt). The
                // gap reads as the space between margin and writing
                // in a real American school notebook.
                Rectangle()
                    .fill(marginColor)
                    .frame(width: 1)
                    .offset(x: 38)
            }
        }
        .allowsHitTesting(false)
    }

    /// Right pane — list of previously saved notes. User feedback
    /// 2026-05-06: "I need to see my typing so preview is no need
    /// — what we can do is in the right side there should be
    /// previously saved projects (only real projects no copies)."
    /// Tapping a row force-saves the current note and swaps the
    /// popout to the selected one (full container rebuild via
    /// `PopoutNote.shared.show`). The active note's row is
    /// highlighted with a soft band + a red margin tab on the
    /// leading edge — same visual vocabulary as the editor's
    /// margin line.
    private var notesListPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Section heading — italic serif, low contrast, sits
            // directly on the paper. No card chrome around it.
            Text("Notes")
                .font(.system(size: 11))
                .italic()
                .foregroundStyle(inkColor.opacity(0.45))
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 6)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    let list = realNotes
                    if list.isEmpty {
                        Text("No saved notes yet.")
                            .font(.system(size: 11))
                            .italic()
                            .foregroundStyle(inkColor.opacity(0.3))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                    } else {
                        ForEach(list) { note in
                            noteRow(note)
                            // Hairline separator between rows in
                            // the same blue as the editor rules.
                            Rectangle()
                                .fill(rulesColor.opacity(0.5))
                                .frame(height: 0.5)
                                .padding(.horizontal, 14)
                        }
                    }
                }
            }
            .scrollIndicators(.never)
        }
    }

    /// Filter the store down to "real" notes — non-empty body, no
    /// duplicates (clipboard auto-save creates a fresh note every
    /// time the same text is copied, so the unfiltered list shows
    /// the same title many times). Already excludes trashed
    /// (NoteStore filters status='active' at the SQL layer).
    ///
    /// Dedup strategy: walk newest-first and keep the first note
    /// per normalized-title bucket. Title is the first non-empty
    /// line with markdown markers stripped, lowercased and trimmed
    /// — so "Wistoria: Wand and Sword" copied twelve times shows
    /// up as a single row (the most recently touched one).
    private var realNotes: [Note] {
        let allActive = noteStore.notes
            .filter { !$0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.updatedAt > $1.updatedAt }
        var seen = Set<String>()
        var unique: [Note] = []
        for note in allActive {
            let key = noteTitle(note)
                .lowercased()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // The currently-edited note ALWAYS gets through, even
            // if a duplicate with the same title was saved earlier
            // — so the user never sees their active edit vanish
            // from the list under another row.
            if note.id == noteID {
                if !unique.contains(where: { $0.id == noteID }) {
                    unique.append(note)
                }
                continue
            }
            if seen.insert(key).inserted {
                unique.append(note)
            }
        }
        return unique
    }

    /// One row in the notes-list pane. Title + first-line preview
    /// + relative date. Tapping it switches the popout to that
    /// note after force-saving the current one.
    @ViewBuilder
    private func noteRow(_ note: Note) -> some View {
        let isActive = note.id == noteID
        Button {
            switchTo(note: note)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                // Active-row indicator stripe. Same red as the
                // editor margin so it reads as part of the paper
                // rather than a UI accent. Reserved 2pt of width
                // when inactive so the text doesn't shift on
                // selection.
                Rectangle()
                    .fill(isActive ? marginColor : Color.clear)
                    .frame(width: 2)

                VStack(alignment: .leading, spacing: 2) {
                    Text(noteTitle(note))
                        .font(.system(size: 12,
                                      weight: isActive ? .semibold : .regular))
                        .foregroundStyle(inkColor.opacity(isActive ? 1 : 0.85))
                        .lineLimit(1)
                        .truncationMode(.tail)

                    if let preview = notePreview(note) {
                        Text(preview)
                            .font(.system(size: 11))
                            .foregroundStyle(inkColor.opacity(0.55))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }

                    Text(relativeDate(note.updatedAt))
                        .font(.system(size: 9))
                        .foregroundStyle(inkColor.opacity(0.4))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.trailing, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isActive
                    ? rulesColor.opacity(0.35)
                    : Color.clear
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Display title for a row — explicit title, or the first
    /// non-empty line of the body with markdown headers stripped,
    /// or "Untitled" as a final fallback.
    private func noteTitle(_ note: Note) -> String {
        if let title = note.title?.trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty {
            return title
        }
        let firstLine = note.body
            .split(whereSeparator: { $0 == "\n" })
            .first
            .map(String.init) ?? ""
        // Strip leading `#`, `##`, `###` markers so headings
        // appear as their text in the list.
        let stripped = firstLine
            .replacingOccurrences(of: #"^#+\s*"#,
                                  with: "",
                                  options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return stripped.isEmpty ? "Untitled" : stripped
    }

    /// Second-line preview snippet, or nil if the note is a
    /// single line.
    private func notePreview(_ note: Note) -> String? {
        let lines = note.body.split(whereSeparator: { $0 == "\n" })
        guard lines.count > 1 else { return nil }
        // Skip blank lines between title and body.
        for line in lines.dropFirst() {
            let trimmed = String(line).trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    private func relativeDate(_ timestamp: Double) -> String {
        let date = Date(timeIntervalSince1970: timestamp)
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    /// Force-save the current note, then ask the shared popout
    /// controller to swap us to the new note. The shared
    /// controller rebuilds the SwiftUI container with the new
    /// noteID, which triggers `loadFromStore()` on the new
    /// instance and pulls the fresh body into the editor.
    private func switchTo(note: Note) {
        guard note.id != noteID else { return }
        saveTask?.cancel()
        if !noteID.isEmpty,
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try? noteStore.updateBody(id: noteID, body: text)
        }
        PopoutNote.shared.show(noteID: note.id, noteStore: noteStore)
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
