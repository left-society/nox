import SwiftUI
import AppKit
import LinkPresentation

/// Notes tab — the genuinely-useful version.
///
/// Design goals (user spec, this iteration):
/// 1. **Auto-save, never "Untitled"** — typing IS saving. Exiting
///    the editor with empty content trashes the draft instead of
///    persisting an empty placeholder row.
/// 2. **Useful structure** — formatting shortcuts (H1, bullet,
///    todo) at the editor's top. Markdown is the underlying
///    representation; preview rows render it inline so the list
///    reads as structured content, not raw `# H1`.
/// 3. **Interactive checklists** — tap a `- [ ]` in any row to flip
///    it to `- [x]`. The body persists. Means a quick tap from the
///    list keeps your todos current without ever opening the editor.
/// 4. **Instant filter** — search bar at the top of the list filters
///    by body content (not just title), so a forgotten phrase finds
///    the right note.
/// 5. **Pin to top** — pinned notes float above unpinned, so the
///    permanent "what am I working on" notes don't get buried by
///    today's quick captures.
/// 6. **Gemini one-line summary** in each row (added previously) so
///    the list scans as "what was this about?"
struct NotesListView: View {
    @EnvironmentObject var noteStore: NoteStore

    /// When non-nil, editor mode is shown. Setting this triggers the
    /// open animation; nil-ing triggers the close. The editor body
    /// is bound to `editorBody`; on exit we either persist (non-empty)
    /// or trash (empty) — no explicit save action required.
    @State private var editingNoteId: String?
    @State private var editorBody: String = ""
    @State private var focusedNoteId: String?
    /// True when the editor session was for a brand-new note (from
    /// the "+ New note" button). Exit-with-empty-body trashes it
    /// instead of leaving a ghost "Untitled" row.
    @State private var editorIsNewNote: Bool = false
    /// Search text filters the list as you type — empty shows all.
    @State private var searchText: String = ""
    @State private var showClearConfirm: Bool = false

    var body: some View {
        ZStack {
            listView
                .opacity(editingNoteId == nil ? 1 : 0)
                .scaleEffect(editingNoteId == nil ? 1 : 0.96, anchor: .top)
                .offset(y: editingNoteId == nil ? 0 : 8)

            if let id = editingNoteId {
                NoteEditorView(
                    noteId: id,
                    text: $editorBody,
                    onExit: { exitEditor() }
                )
                .transition(.asymmetric(
                    insertion: .opacity.combined(
                        with: .scale(scale: 0.97, anchor: .top)
                    ).combined(with: .offset(y: 12)),
                    removal: .opacity.combined(
                        with: .scale(scale: 0.97, anchor: .top)
                    ).combined(with: .offset(y: 12))
                ))
            }
        }
        .animation(
            .bouncy(duration: 0.42, extraBounce: 0.18),
            value: editingNoteId
        )
        .background(copyShortcut)
        // "Clear all" confirmation. Mirrors the same pattern
        // ImagesGridView uses so the destructive moment feels
        // identical across tabs. Soft-trash (recoverable from
        // the trashed pool) rather than hard-delete.
        .alert("Clear all notes?", isPresented: $showClearConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) {
                try? noteStore.trashAll()
                editingNoteId = nil
                searchText = ""
            }
        } message: {
            Text("This moves all \(noteStore.notes.count) notes to Trash.")
        }
    }

    // MARK: - List mode

    private var listView: some View {
        VStack(spacing: 0) {
            VStack(spacing: DS.Spacing.xs) {
                newNoteButton
                if !noteStore.notes.isEmpty {
                    HStack(spacing: DS.Spacing.xs) {
                        searchBar
                        clearButton
                    }
                }
            }
            .padding(.horizontal, DS.Spacing.md)
            .padding(.top, DS.Spacing.md)
            .padding(.bottom, DS.Spacing.sm)

            ScrollView {
                if noteStore.notes.isEmpty {
                    emptyState
                } else if filteredNotes.isEmpty {
                    noResultsState
                } else {
                    LazyVStack(spacing: 1) {
                        ForEach(filteredNotes) { note in
                            NoteRow(
                                note: note,
                                isFocused: focusedNoteId == note.id,
                                onOpen: { openEditor(for: note) },
                                onDelete: { deleteNote(note) },
                                onCopy: {
                                    // Single-tap-to-copy ALSO focuses the
                                    // row so ⌘C and visual selection
                                    // stay in sync.
                                    copyNote(note)
                                    withAnimation(.rowHover) {
                                        focusedNoteId = note.id
                                    }
                                },
                                onTogglePin: { togglePin(note) },
                                onToggleTodo: { lineIndex in toggleTodo(note: note, lineIndex: lineIndex) }
                            )
                            .onDrag { NSItemProvider(object: note.body as NSString) }
                            .transition(.asymmetric(
                                insertion: .opacity.combined(with: .scale(scale: 0.98, anchor: .top)),
                                removal: .opacity
                            ))
                        }
                    }
                    .padding(.horizontal, DS.Spacing.sm)
                    .padding(.bottom, DS.Spacing.md)
                    .animation(.selection, value: filteredNotes.map(\.id))
                }
            }
            .scrollIndicators(.never)
        }
    }

    private var newNoteButton: some View {
        Button {
            startNewNote()
        } label: {
            HStack(spacing: DS.Spacing.sm) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DS.Color.textSecondary)
                Text("New note")
                    .font(.nkBody.weight(.medium))
                    .foregroundStyle(DS.Color.textPrimary)
                Spacer()
                Text("⌥N")
                    .font(.nkLabel.monospacedDigit())
                    .foregroundStyle(DS.Color.textTertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.white.opacity(0.05))
                    )
            }
            .padding(.horizontal, DS.Spacing.md)
            .padding(.vertical, DS.Spacing.sm + 2)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous)
                    .fill(DS.Color.bgSubtle)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.06), lineWidth: 0.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.row))
        }
        .buttonStyle(.plain)
        .keyboardShortcut("n", modifiers: .option)
    }

    /// "Clear all" affordance for the Notes tab. Mirrors the
    /// trash-pill Images and Files already have so the tab set
    /// is consistent — every content tab can be wiped in one
    /// tap. Soft-trashes via NoteStore.trashAll (notes go to
    /// the trashed pool, not hard-deleted).
    private var clearButton: some View {
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
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(DS.Color.bgSubtle.opacity(0.7))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.04), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .help("Move all notes to Trash")
    }

    private var searchBar: some View {
        HStack(spacing: DS.Spacing.xs) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(DS.Color.textTertiary)
            TextField("Search notes", text: $searchText)
                .textFieldStyle(.plain)
                .font(.nkLabel)
                .foregroundStyle(DS.Color.textPrimary)
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(DS.Color.textTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, DS.Spacing.sm)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(DS.Color.bgSubtle.opacity(0.7))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.white.opacity(0.04), lineWidth: 0.5)
        )
    }

    private var filteredNotes: [Note] {
        let pinned = noteStore.notes.filter { isPinned($0) }
        let unpinned = noteStore.notes.filter { !isPinned($0) }
        let combined = pinned + unpinned
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return combined }
        return combined.filter {
            $0.body.lowercased().contains(q)
                || ($0.summary?.lowercased().contains(q) ?? false)
                || ($0.title?.lowercased().contains(q) ?? false)
        }
    }

    private var emptyState: some View {
        VStack(spacing: DS.Spacing.sm) {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(DS.Color.textTertiary)
            Text("Nothing yet")
                .font(.nkBody.weight(.medium))
                .foregroundStyle(DS.Color.textSecondary)
            Text("Tap “New note” or hit ⌥N to capture a thought.")
                .font(.nkMeta)
                .foregroundStyle(DS.Color.textTertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 56)
    }

    private var noResultsState: some View {
        VStack(spacing: DS.Spacing.xs) {
            Text("No matches")
                .font(.nkBody.weight(.medium))
                .foregroundStyle(DS.Color.textSecondary)
            Text("Nothing in your notes contains “\(searchText)”.")
                .font(.nkMeta)
                .foregroundStyle(DS.Color.textTertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 48)
    }

    // MARK: - Mode transitions

    private func startNewNote() {
        do {
            let note = try noteStore.createNote()
            editorBody = ""
            editorIsNewNote = true
            editingNoteId = note.id
        } catch {
            NSLog("createNote failed: \(error)")
        }
    }

    private func openEditor(for note: Note) {
        editorBody = note.body
        editorIsNewNote = false
        editingNoteId = note.id
    }

    /// Single exit path — auto-save (or trash if empty). Replaces the
    /// previous commit/cancel split. User: "When the user lets just
    /// go into a new node, it should save automatically; they need
    /// to press anything so it will just get saved automatically."
    private func exitEditor() {
        guard let id = editingNoteId else { return }
        let trimmed = editorBody.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            // Empty body → trash unconditionally. Brand-new notes
            // never become "Untitled" rows; existing notes that were
            // emptied get trashed (matches the user's mental model
            // of "I deleted everything → it's gone").
            try? noteStore.trash(id: id)
        } else {
            // Persist + fire async Gemini summary. The summary lands
            // a couple seconds later via `updateSummary`.
            try? noteStore.updateBody(id: id, body: editorBody)
            scheduleSummarize(id: id, body: editorBody)
        }
        editingNoteId = nil
        editorBody = ""
        editorIsNewNote = false
    }

    private func scheduleSummarize(id: String, body: String) {
        Task { @MainActor in
            let result = await GeminiSummaryService.summarize(body: body)
            switch result {
            case .success(let summary):
                try? noteStore.updateSummary(id: id, summary: summary)
            case .missingAPIKey:
                NSLog("Notetaker: skipping summarize — no Gemini key")
            case .failure(let reason):
                NSLog("Notetaker: summarize failed for \(id): \(reason)")
            }
        }
    }

    // MARK: - Pinning (preference-backed, no schema migration needed)

    /// Pinned-note IDs stored in UserDefaults — keeps the v5 schema
    /// migration simple (no new column) while still giving the user
    /// a "keep this on top" gesture. The set is small (handful of
    /// IDs at most) so the .stringArray storage is fine.
    private static let pinnedKey = "Notetaker.pinnedNoteIds"

    private func isPinned(_ note: Note) -> Bool {
        let ids = UserDefaults.standard.stringArray(forKey: Self.pinnedKey) ?? []
        return ids.contains(note.id)
    }

    private func togglePin(_ note: Note) {
        var ids = UserDefaults.standard.stringArray(forKey: Self.pinnedKey) ?? []
        if let i = ids.firstIndex(of: note.id) {
            ids.remove(at: i)
        } else {
            ids.append(note.id)
        }
        UserDefaults.standard.set(ids, forKey: Self.pinnedKey)
        // Force a body refresh so pinned notes re-sort to the top.
        // Triggering an objectWillChange via reload is overkill;
        // bumping focusedNoteId effectively re-evaluates filteredNotes.
        let cur = focusedNoteId
        focusedNoteId = nil
        focusedNoteId = cur
    }

    // MARK: - Interactive todos

    /// Toggle the checkbox on the Nth `- [ ]` / `- [x]` line in the
    /// note's body. Persists immediately. The list row reflects the
    /// change without re-opening the editor — the user can knock
    /// off todos straight from the list view.
    private func toggleTodo(note: Note, lineIndex: Int) {
        var lines = note.body.components(separatedBy: "\n")
        var todoSeen = 0
        for i in 0..<lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            let isUnchecked = trimmed.hasPrefix("- [ ]") || trimmed.hasPrefix("* [ ]")
            let isChecked = trimmed.hasPrefix("- [x]") || trimmed.hasPrefix("- [X]")
                            || trimmed.hasPrefix("* [x]") || trimmed.hasPrefix("* [X]")
            guard isUnchecked || isChecked else { continue }
            if todoSeen == lineIndex {
                if isUnchecked {
                    lines[i] = lines[i].replacingOccurrences(of: "- [ ]", with: "- [x]")
                                       .replacingOccurrences(of: "* [ ]", with: "* [x]")
                } else {
                    lines[i] = lines[i].replacingOccurrences(of: "- [x]", with: "- [ ]")
                                       .replacingOccurrences(of: "- [X]", with: "- [ ]")
                                       .replacingOccurrences(of: "* [x]", with: "* [ ]")
                                       .replacingOccurrences(of: "* [X]", with: "* [ ]")
                }
                let newBody = lines.joined(separator: "\n")
                try? noteStore.updateBody(id: note.id, body: newBody)
                return
            }
            todoSeen += 1
        }
    }

    // MARK: - Row actions

    private func copyNote(_ note: Note) {
        ClipboardService.copy(text: note.body)
        // Tactile confirmation that the copy landed — pairs with
        // the visual "Copied" badge. `.alignment` reads as a snap
        // (matches the affordance "this thing is now in your
        // clipboard").
        HapticFeedback.alignment()
    }

    private func deleteNote(_ note: Note) {
        if focusedNoteId == note.id { focusedNoteId = nil }
        try? noteStore.trash(id: note.id)
    }

    private var copyShortcut: some View {
        Button(action: copyFocusedNote) { EmptyView() }
            .keyboardShortcut("c", modifiers: .command)
            .disabled(focusedNoteId == nil || editingNoteId != nil)
            .opacity(0)
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
    }

    private func copyFocusedNote() {
        guard let id = focusedNoteId,
              let note = noteStore.notes.first(where: { $0.id == id })
        else { return }
        ClipboardService.copy(text: note.body)
    }
}

// MARK: - NoteEditorView (full-page Notion-style writing surface)

/// Full-slab text editor with a compact formatting toolbar at the
/// top (H1, bullet, todo, divider) and an auto-save model: anything
/// you type is preserved when you exit, and an empty exit just
/// trashes the draft. No explicit Save button — typing IS saving.
struct NoteEditorView: View {
    let noteId: String
    @Binding var text: String
    let onExit: () -> Void

    /// Bridge object that lets the toolbar talk to the underlying
    /// NSTextView for cursor-aware insertion. The MarkdownTextEditor
    /// populates the closures on appearance; the toolbar invokes them
    /// when the user taps a button.
    @State private var coordinatorRef = MarkdownTextEditor.CoordinatorRef()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: DS.Spacing.sm) {
                Button(action: onExit) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Notes")
                            .font(.nkLabel)
                    }
                    .foregroundStyle(DS.Color.textSecondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.escape, modifiers: [])
                .keyboardShortcut(.return, modifiers: .command)

                Spacer()

                Text("Auto-saves")
                    .font(.nkLabel)
                    .foregroundStyle(DS.Color.textTertiary)
                Text("·")
                    .font(.nkLabel)
                    .foregroundStyle(DS.Color.textTertiary.opacity(0.4))
                Text("\(text.count)")
                    .font(.nkLabel)
                    .monospacedDigit()
                    .foregroundStyle(DS.Color.textTertiary)
            }
            .padding(.horizontal, DS.Spacing.md)
            .padding(.top, DS.Spacing.md)
            .padding(.bottom, DS.Spacing.xs)

            // Toolbar talks to the editor via the coordinatorRef.
            // Each button calls a cursor-aware insertion closure that
            // prefixes the current line — same as Notion's slash
            // commands, but driven from a compact icon strip.
            FormattingToolbar(coordinator: coordinatorRef)
                .padding(.horizontal, DS.Spacing.md)
                .padding(.bottom, 6)

            // WYSIWYG editor — text is stored as plain markdown but
            // rendered with live styling: headings get bigger fonts,
            // todo / bullet / quote markers get dimmed so the content
            // dominates visually. Replaces the previous TextEditor
            // which dumped raw `- [ ]` strings at the user.
            MarkdownTextEditor(text: $text, coordinatorRef: coordinatorRef)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("Type your note… Use the toolbar to add a heading, bullet, or to-do.")
                            .font(.system(size: 14))
                            .foregroundStyle(DS.Color.textTertiary)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .allowsHitTesting(false)
                    }
                }
        }
    }
}

// MARK: - FormattingToolbar

/// Compact horizontal toolbar that inserts markdown formatting at
/// the current line. Kept small (5 icons × 28pt = ~150pt wide)
/// so it sits inside the editor without crowding it.
///
/// Each button inserts the shortcut at the START of the current
/// line via a string-manipulation helper — matches Notion's
/// behavior where typing `# ` or clicking the H1 button both put
/// you in heading mode at the line cursor sits on.
private struct FormattingToolbar: View {
    let coordinator: MarkdownTextEditor.CoordinatorRef

    var body: some View {
        HStack(spacing: 4) {
            ToolbarIconButton(icon: "textformat.size.larger", help: "Heading") {
                coordinator.insertHeading?()
            }
            ToolbarIconButton(icon: "list.bullet", help: "Bullet list") {
                coordinator.insertBullet?()
            }
            ToolbarIconButton(icon: "checklist", help: "To-do") {
                coordinator.insertTodo?()
            }
            ToolbarIconButton(icon: "text.quote", help: "Quote") {
                coordinator.insertQuote?()
            }
            ToolbarIconButton(icon: "minus", help: "Divider") {
                coordinator.insertDivider?()
            }
            Spacer()
        }
    }
}

private struct ToolbarIconButton: View {
    let icon: String
    let help: String
    let action: () -> Void

    @State private var isHovered = false
    @State private var isPressed = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(DS.Color.textSecondary)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.white.opacity(isPressed ? 0.10 : isHovered ? 0.06 : 0))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(Color.white.opacity(isHovered ? 0.08 : 0), lineWidth: 0.5)
                )
                .scaleEffect(isPressed ? 0.92 : 1.0)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { isHovered = hovering }
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !isPressed {
                        withAnimation(.easeOut(duration: 0.06)) { isPressed = true }
                    }
                }
                .onEnded { _ in
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.5)) {
                        isPressed = false
                    }
                }
        )
    }
}

// MARK: - NoteRow (list mode)

struct NoteRow: View {
    let note: Note
    let isFocused: Bool
    let onOpen: () -> Void
    let onDelete: () -> Void
    let onCopy: () -> Void
    let onTogglePin: () -> Void
    let onToggleTodo: (Int) -> Void

    @EnvironmentObject private var linkPreviewService: LinkPreviewService
    @State private var isHovered = false
    @State private var justCopied = false

    private var firstURL: URL? {
        URLExtractor.firstHTTPURL(in: note.body)
    }

    /// Title shown above the body preview. Uses Gemini summary if
    /// available, else first non-empty body line, else "Untitled".
    private var displayTitle: String {
        if let summary = note.summary, !summary.isEmpty {
            return summary
        }
        if let title = note.title, !title.isEmpty {
            return title
        }
        return "Untitled"
    }

    private var summaryIsLoading: Bool {
        guard note.summary == nil else { return false }
        let age = Date().timeIntervalSince1970 - note.updatedAt
        return age < 30
    }

    private var isPinned: Bool {
        let ids = UserDefaults.standard.stringArray(forKey: "Notetaker.pinnedNoteIds") ?? []
        return ids.contains(note.id)
    }

    /// Parsed structured preview — pulls out heading / todo / bullet
    /// lines from the first ~6 lines of body so the row shows
    /// rendered markdown, not raw `# heading`.
    private var structuredPreview: [PreviewLine] {
        MarkdownPreview.parse(note.body, maxLines: 4)
    }

    // Clean, centered, scannable. Title + timestamp stacked
    // and centered horizontally; no card background, no inline
    // body preview, no metadata clutter. Action buttons (pin,
    // delete) reveal on hover as a subtle right-edge overlay so
    // the steady-state row reads as pure typography. Matches the
    // landing-page mockup the user shared and Apple Notes' own
    // sparse list style.
    var body: some View {
        ZStack {
            // Centered title + timestamp — the visible row content
            // when nothing is being copied.
            if !justCopied {
                VStack(spacing: 4) {
                    Text(displayTitle)
                        .font(.nkBody.weight(.medium))
                        .foregroundStyle(DS.Color.textPrimary)
                        .lineLimit(1)
                        .multilineTextAlignment(.center)
                        .truncationMode(.tail)
                        .italic(summaryIsLoading)
                        .opacity(summaryIsLoading ? 0.7 : 1)
                    Text(Self.relativeTime(from: note.updatedAt))
                        .font(.nkLabel)
                        .foregroundStyle(DS.Color.textTertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 64) // reserve space for hover actions
            }

            // "Copied" badge overlays the entire row when the user
            // single-taps. Replaces the title for ~1.4s — same
            // affordance as before, just centered now to match the
            // new layout.
            if justCopied {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Copied")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(DS.Color.accent)
                .transition(.scale(scale: 0.85).combined(with: .opacity))
            }

            // Hover-only action buttons, anchored to the trailing
            // edge. Invisible in steady state so the row stays
            // clean; fade in when the cursor lands. Pin stays
            // visible if pinned.
            HStack(spacing: 2) {
                Spacer()
                Button(action: onTogglePin) {
                    Image(systemName: isPinned ? "pin.fill" : "pin")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(isPinned ? DS.Color.accent : DS.Color.textTertiary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(isHovered || isPinned ? 1 : 0)
                .help(isPinned ? "Unpin" : "Pin to top")

                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(DS.Color.textTertiary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(isHovered ? 1 : 0)
                .help("Delete")
            }
            .padding(.trailing, 12)
            .allowsHitTesting(isHovered || isPinned)
            .animation(.rowHover, value: isHovered)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(
            // Very subtle hover wash — no boxy card. Focus state
            // (keyboard navigation) gets a slightly stronger tone.
            Rectangle()
                .fill(isFocused ? DS.Color.bgSelected.opacity(0.6)
                      : (isHovered ? DS.Color.bgHover.opacity(0.4) : Color.clear))
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.rowHover) { isHovered = hovering }
        }
        .onTapGesture(count: 2) { onOpen() }
        .onTapGesture(count: 1) { handleCopy() }
        .onAppear {
            if let url = firstURL { linkPreviewService.ensure(for: url) }
        }
    }

    private func handleCopy() {
        onCopy()
        withAnimation(.bouncy(duration: 0.3, extraBounce: 0.2)) {
            justCopied = true
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            withAnimation(.easeOut(duration: 0.2)) {
                justCopied = false
            }
        }
    }

    private var backgroundFill: Color {
        if isFocused { return DS.Color.bgSelected }
        if isHovered { return DS.Color.bgHover }
        return .clear
    }

    @ViewBuilder
    private var metaLine: some View {
        if let url = firstURL {
            HStack(spacing: 5) {
                FaviconView(url: url)
                    .frame(width: 12, height: 12)
                Text(url.host ?? url.absoluteString)
                    .font(.nkLabel)
                    .foregroundStyle(DS.Color.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("·")
                    .font(.nkLabel)
                    .foregroundStyle(DS.Color.textTertiary)
                Text(Self.relativeTime(from: note.updatedAt))
                    .font(.nkLabel)
                    .foregroundStyle(DS.Color.textTertiary)
            }
        } else {
            Text(Self.relativeTime(from: note.updatedAt))
                .font(.nkLabel)
                .foregroundStyle(DS.Color.textTertiary)
        }
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    private static func relativeTime(from epoch: Double) -> String {
        let date = Date(timeIntervalSince1970: epoch)
        return relativeFormatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Markdown preview (lightweight)

/// Minimal markdown line types we render in row previews. Full
/// markdown isn't worth the complexity for a 4-line preview — we
/// just call out headings, todos, and bullets so the row is visually
/// structured, not a wall of `# H1\n- [ ] task`.
enum PreviewLine {
    case heading(String)
    case todo(text: String, checked: Bool, index: Int)
    case bullet(String)
    case plain(String)
}

enum MarkdownPreview {
    /// Parse the body into the first `maxLines` non-empty preview
    /// lines. Stops early if the body is shorter than `maxLines`.
    static func parse(_ body: String, maxLines: Int) -> [PreviewLine] {
        var out: [PreviewLine] = []
        var todoIdx = 0
        for raw in body.components(separatedBy: "\n") {
            if out.count >= maxLines { break }
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("# ") {
                let txt = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                if !txt.isEmpty {
                    // Skip — already shown as the row title (Gemini summary
                    // or first line). Avoids visual repetition.
                    continue
                }
            }
            if line.hasPrefix("- [ ]") || line.hasPrefix("* [ ]") {
                let txt = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                out.append(.todo(text: txt, checked: false, index: todoIdx))
                todoIdx += 1
                continue
            }
            if line.hasPrefix("- [x]") || line.hasPrefix("- [X]")
                || line.hasPrefix("* [x]") || line.hasPrefix("* [X]") {
                let txt = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                out.append(.todo(text: txt, checked: true, index: todoIdx))
                todoIdx += 1
                continue
            }
            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                out.append(.bullet(String(line.dropFirst(2))))
                continue
            }
            // Skip the very first non-structured line — it's the
            // title we already showed at the top of the row.
            if out.isEmpty {
                continue
            }
            out.append(.plain(line))
        }
        return out
    }
}

private struct PreviewLineView: View {
    let line: PreviewLine
    let onToggle: (Int) -> Void

    var body: some View {
        switch line {
        case .heading(let txt):
            Text(txt)
                .font(.nkLabel.weight(.semibold))
                .foregroundStyle(DS.Color.textPrimary)
                .lineLimit(1)
        case .todo(let txt, let checked, let idx):
            HStack(alignment: .center, spacing: 5) {
                Button {
                    onToggle(idx)
                } label: {
                    Image(systemName: checked ? "checkmark.square.fill" : "square")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(checked ? DS.Color.accent : DS.Color.textTertiary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Text(txt)
                    .font(.nkLabel)
                    .foregroundStyle(checked ? DS.Color.textTertiary : DS.Color.textSecondary)
                    .strikethrough(checked, color: DS.Color.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        case .bullet(let txt):
            HStack(alignment: .center, spacing: 5) {
                Circle()
                    .fill(DS.Color.textTertiary)
                    .frame(width: 3, height: 3)
                Text(txt)
                    .font(.nkLabel)
                    .foregroundStyle(DS.Color.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        case .plain(let txt):
            Text(txt)
                .font(.nkLabel)
                .foregroundStyle(DS.Color.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }
}

/// Renders a 12pt favicon for a URL, sourced from
/// `LinkPreviewService.previews[url].iconProvider`. Loading is async
/// (`NSItemProvider.loadObject`), so the view starts blank and fades in
/// when the icon arrives. Falls back to an SF Symbol globe if metadata
/// hasn't landed yet.
private struct FaviconView: View {
    @EnvironmentObject private var service: LinkPreviewService
    let url: URL
    @State private var image: NSImage?
    @State private var attemptedProviderID: ObjectIdentifier?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "globe")
                    .font(.system(size: 9, weight: .regular))
                    .foregroundStyle(DS.Color.textTertiary)
            }
        }
        .onAppear { tryLoad() }
        .onChange(of: service.previews[url]) { _ in tryLoad() }
    }

    private func tryLoad() {
        guard image == nil else { return }
        guard let provider = service.previews[url]?.iconProvider else { return }
        let id = ObjectIdentifier(provider)
        if attemptedProviderID == id { return }
        attemptedProviderID = id

        guard provider.canLoadObject(ofClass: NSImage.self) else { return }
        provider.loadObject(ofClass: NSImage.self) { obj, _ in
            guard let img = obj as? NSImage else { return }
            Task { @MainActor in self.image = img }
        }
    }
}
