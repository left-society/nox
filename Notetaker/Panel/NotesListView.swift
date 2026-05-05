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
    /// is bound to `editorBody`; we now save on a 0.7s debounce
    /// WHILE typing, plus on exit. Earlier the only save path was
    /// `exitEditor()`, so anything that interrupted the user before
    /// they explicitly closed the editor (panel hover-out, ⎋, app
    /// crash, screen lock) ate the typed content. Debounced save
    /// caps the loss window at ~700ms.
    @State private var editingNoteId: String?
    @State private var editorBody: String = ""
    /// Debounce token for the in-editor auto-save. Each keystroke
    /// cancels the previous task and schedules a new one; the
    /// `noteStore.updateBody` call only fires after the user has
    /// paused for 0.7s. Capped at the value of the @State so
    /// rapid edits don't pile up duplicate writes.
    @State private var editorSaveTask: Task<Void, Never>?
    @State private var focusedNoteId: String?
    /// True when the editor session was for a brand-new note (from
    /// the "+ New note" button). Exit-with-empty-body trashes it
    /// instead of leaving a ghost "Untitled" row.
    @State private var editorIsNewNote: Bool = false
    /// Search text filters the list as you type — empty shows all.
    @State private var searchText: String = ""
    @State private var showClearConfirm: Bool = false

    // 2026-05-03 — UX research surfaced that segmented tabs (All /
    // Notes / Clipboard) require an explicit context switch the
    // user found "too time consuming." Replaced by single-list
    // visual demotion: clipboard rows render at ~50% alpha + smaller
    // font + clipboard glyph, so the eye filters them automatically
    // (Pastebot + Apple Notes pattern). Unified scroll, zero switch
    // cost. The `kindFilter` enum and pill state are gone.

    /// Multi-select state. macOS-native pattern: ⌘-click toggles a
    /// note's membership, ⇧-click does a range select between the
    /// focused note and the clicked one. Once anything is selected,
    /// a contextual toolbar slides in above the list with bulk
    /// actions (Delete / Pin / Cancel). Esc clears, ⌘A selects all
    /// currently visible (post-search-filter), Delete key trashes
    /// everything in the selection.
    ///
    /// Empty set = no selection mode. The bulk toolbar's appearance
    /// gates on `!selectedNoteIds.isEmpty` so the row stays clean
    /// when nothing's picked.
    @State private var selectedNoteIds: Set<String> = []
    /// Gate for the LazyVStack's row insertion animations.
    /// Starts false on every fresh mount of NotesListView so
    /// the initial wave of NoteRow insertions (from
    /// noteStore.notes loading into filteredNotes) doesn't all
    /// animate at once on tab switch — that was the "glitch
    /// upon opening the Notes menu" the user reported. After
    /// `.task` (one runloop tick post-mount) we flip it true,
    /// re-enabling the animation curve so subsequent adds /
    /// removes / search-filter changes still get the smooth
    /// insertion transitions they were designed for.
    @State private var rowAnimationsEnabled: Bool = false

    /// DEV-ONLY: receives a pre-seeded selection from AppDelegate's
    /// `selectNotes` test pill so the multi-select toolbar can be
    /// captured in screenshots without needing a real ⌘-click. No
    /// real-world path triggers this notification.
    private let testSelectionNotification = NSNotification.Name("Notetaker.TestSeedSelection")

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
        .onChange(of: editorBody) { newValue in
            // Debounced auto-save while typing — every keystroke
            // restarts the 0.7s timer; if the user pauses for
            // 0.7s the body persists. Bounds the data-loss
            // window to ~700ms regardless of how the editor
            // exits (panel hover-out, screen lock, crash, ⎋).
            scheduleEditorAutoSave(body: newValue)
        }
        .animation(
            .bouncy(duration: 0.42, extraBounce: 0.18),
            value: editingNoteId
        )
        .background(copyShortcut)
        .onReceive(NotificationCenter.default.publisher(for: testSelectionNotification)) { _ in
            // DEV-ONLY: seed selection from UserDefaults sentinel.
            // Used by the `selectNotes` test pill in AppDelegate
            // to capture the multi-select toolbar in screenshots.
            if let ids = UserDefaults.standard.stringArray(forKey: "Notetaker.testSelectedNoteIds") {
                NSLog("Notetaker: NotesListView received test selection seed, ids=\(ids.count)")
                selectedNoteIds = Set(ids)
            }
        }
        .onAppear {
            // Same path on appear — covers the case where the
            // seed notification fired before the view was on
            // screen.
            if let ids = UserDefaults.standard.stringArray(forKey: "Notetaker.testSelectedNoteIds"),
               !ids.isEmpty,
               selectedNoteIds.isEmpty {
                NSLog("Notetaker: NotesListView onAppear seed, ids=\(ids.count)")
                selectedNoteIds = Set(ids)
            }
        }
        // "Clear all" confirmation. Mirrors the same pattern
        // ImagesGridView uses so the destructive moment feels
        // identical across tabs. Soft-trash (recoverable from
        // the trashed pool) rather than hard-delete.
        .overlay {
            ClearConfirmOverlay(
                isPresented: $showClearConfirm,
                title: "Clear all notes?",
                message: "This moves all \(noteStore.notes.count) note\(noteStore.notes.count == 1 ? "" : "s") to Trash."
            ) {
                try? noteStore.trashAll()
                editingNoteId = nil
                searchText = ""
            }
        }
    }

    // MARK: - List mode

    private var listView: some View {
        VStack(spacing: 0) {
            VStack(spacing: DS.Spacing.xs) {
                // "+ New note" + a sibling popout button. Two paths
                // from the header: type into the slab (left), or
                // pop a fresh note straight out into the slim
                // floating window for note-taking next to a video
                // playing in any other app (right). Per-row popout
                // affordances were noisy — one global button + the
                // editor toolbar's popout button is enough.
                HStack(spacing: 8) {
                    newNoteButton
                    popoutHeaderButton
                }
                // Search row only — no "Clear All" button. Earlier
                // builds had a trash-icon "Clear" button right next
                // to the search field, which read as "clear search
                // query" because that's the universal meaning of a
                // trash/X button next to a search field. Clicking it
                // surfaced a "delete all 222 notes?" confirmation —
                // exactly the footgun the user reported. Per-note
                // delete (in NoteRow's hover trash icon) is the
                // intended path; bulk delete moved to a less-reachable
                // affordance if we ever add one back.
                if !noteStore.notes.isEmpty {
                    searchBar
                }
                // Selection toolbar — appears the moment ⌘-click
                // adds anything to `selectedNoteIds`. Slides down
                // above the list with bulk actions, replaces the
                // search bar visually so the user can't ⌘-A or
                // similar accidentally during selection.
                if !selectedNoteIds.isEmpty {
                    selectionToolbar
                        .transition(.move(edge: .top).combined(with: .opacity))
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
                                isSelected: selectedNoteIds.contains(note.id),
                                isSelectionModeActive: !selectedNoteIds.isEmpty,
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
                                onPopOut: {
                                    PopoutNote.shared.show(noteID: note.id, noteStore: noteStore)
                                },
                                onToggleSelection: {
                                    withAnimation(.rowHover) {
                                        if selectedNoteIds.contains(note.id) {
                                            selectedNoteIds.remove(note.id)
                                        } else {
                                            selectedNoteIds.insert(note.id)
                                        }
                                    }
                                },
                                onRangeSelect: {
                                    rangeSelect(to: note)
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
                    // `.selection` animation is gated on
                    // `rowAnimationsEnabled` so initial mount
                    // doesn't fire a wave of NoteRow insertion
                    // transitions concurrent with the panel's
                    // open animation. `.task` flips the gate
                    // ON one runloop tick after first appear,
                    // so subsequent inserts (new note, search
                    // filter change) still get the smooth
                    // selection animation they were designed
                    // for.
                    .animation(
                        rowAnimationsEnabled ? .selection : nil,
                        value: filteredNotes.map(\.id)
                    )
                }
            }
            .scrollIndicators(.never)
        }
        .task {
            // Wait one runloop tick before enabling row animations,
            // so the initial paint's id-array population doesn't
            // trigger the selection animation on every row.
            rowAnimationsEnabled = true
        }
    }

    /// Frosted-glass "+ New note" button matching the dock-pill
    /// vocabulary the user landed on for the tab bar (2026-04-29).
    /// Same recipe: vibrancy material + 6% white lift + 10% hairline
    /// border, with a clear pressed/hover state. Pill-shaped (capsule)
    /// so it visually echoes the floating dock above.
    private var newNoteButton: some View {
        Button {
            startNewNote()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.85))
                Text("New note")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.95))
                Spacer(minLength: 0)
                // Inline keycap chip — matches the SettingsButton /
                // top-bar ⌥/Space chip vocabulary (rounded 6pt,
                // subtle white fill + thin border).
                HStack(spacing: 2) {
                    Text("⌥")
                    Text("N")
                }
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.75))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.white.opacity(0.10))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
                )
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(
                ZStack {
                    VisualEffectBlur(material: .hudWindow, blendingMode: .withinWindow)
                    Color.white.opacity(0.06)
                }
                .clipShape(Capsule(style: .continuous))
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
            )
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .keyboardShortcut("n", modifiers: .option)
    }

    /// Pop-out icon next to "+ New note". One tap creates a fresh
    /// empty note AND opens it in the slim floating window — the
    /// "I'm about to watch a video, let me start taking notes
    /// immediately" path. If the user already has notes and just
    /// wants to pop the most recent one, falling through to "open
    /// the top of the list" felt magic-but-wrong; explicit "always
    /// new" matches the New Note button's mental model.
    ///
    /// Same dock-pill vocabulary as `newNoteButton` (capsule,
    /// vibrancy fill, hairline border) so the two read as a paired
    /// header action.
    private var popoutHeaderButton: some View {
        Button {
            popOutNewNote()
        } label: {
            Image(systemName: "rectangle.portrait.and.arrow.right")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.85))
                .frame(width: 38, height: 38)
                .background(
                    ZStack {
                        VisualEffectBlur(material: .hudWindow, blendingMode: .withinWindow)
                        Color.white.opacity(0.06)
                    }
                    .clipShape(Capsule(style: .continuous))
                )
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
                )
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .help("New note in pop-out window — take notes alongside any video")
    }

    /// Create a fresh blank note and open it directly in the floating
    /// popout. Skips the "open in slab editor" intermediate step the
    /// regular `+ New note` button takes.
    private func popOutNewNote() {
        do {
            let note = try noteStore.createNote()
            PopoutNote.shared.show(noteID: note.id, noteStore: noteStore)
        } catch {
            NSLog("nox: popOutNewNote failed: \(error)")
        }
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

    /// Frosted-glass search field. Same dock-pill vocabulary as
    /// the tab bar and "+ New note" button — capsule shape,
    /// vibrancy fill, hairline white border. Reads as one cohesive
    /// material across the whole panel chrome.
    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.55))
            TextField("Search notes", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Color.white.opacity(0.95))
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.5))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            ZStack {
                VisualEffectBlur(material: .hudWindow, blendingMode: .withinWindow)
                Color.white.opacity(0.05)
            }
            .clipShape(Capsule(style: .continuous))
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
        )
    }

    private var filteredNotes: [Note] {
        // Single unified list. Sort order: pinned first, then everything
        // else by updated_at desc (which is what NoteStore.notes
        // already gives us). Clipboard rows are visually demoted in
        // the row view itself (~50% alpha, smaller font, glyph), not
        // filtered out — so the eye does the work the segment pill
        // used to do, with zero context-switching cost.
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
        // Shared empty-state family — see DesignSystem/EmptyDropState.swift.
        EmptyDropState(
            icon: "square.and.pencil",
            title: "Capture a thought",
            subtitle: "Click “New note” or hit ⌥N to start writing.",
            keyHint: ("⌥N", "for a new note"),
            accent: Color(red: 0.99, green: 0.80, blue: 0.30)
        )
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

    /// Debounced in-editor auto-save. Each keystroke cancels the
    /// previous task and queues a new write 0.7s out. The chosen
    /// 0.7s value is the same window VS Code, Bear, and Notion use
    /// for live-collaboration writes — long enough that we don't
    /// hammer SQLite for every character, short enough that even
    /// a sudden screen lock loses at most one finished thought.
    /// Empty bodies are NOT persisted via this path; the trash-on-
    /// empty rule still lives in `exitEditor`, since debounce-saving
    /// an empty body would silently delete the in-progress note
    /// every time the user blanked it to retype.
    private func scheduleEditorAutoSave(body: String) {
        guard let id = editingNoteId else { return }
        editorSaveTask?.cancel()
        editorSaveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 700_000_000) // 0.7s
            guard !Task.isCancelled else { return }
            guard editingNoteId == id else { return }  // user moved on
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            try? noteStore.updateBody(id: id, body: body)
        }
    }

    /// Single exit path — auto-save (or trash if empty). Replaces the
    /// previous commit/cancel split. User: "When the user lets just
    /// go into a new node, it should save automatically; they need
    /// to press anything so it will just get saved automatically."
    private func exitEditor() {
        guard let id = editingNoteId else { return }
        // Cancel any pending debounced save — we're about to save
        // synchronously; no point double-writing.
        editorSaveTask?.cancel()
        editorSaveTask = nil
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

    // MARK: - Multi-select

    /// Selection toolbar shown above the list when 1+ notes are
    /// selected. Surfaces the bulk actions (Delete / Pin / Cancel)
    /// inline so the user doesn't have to hunt for a menu. Slides
    /// in/out via the parent's `.transition(.move(edge: .top))`.
    private var selectionToolbar: some View {
        HStack(spacing: DS.Spacing.sm) {
            Text("\(selectedNoteIds.count) selected")
                .font(.nkLabel.weight(.semibold))
                .foregroundStyle(DS.Color.textPrimary)

            // Select All / Deselect All toggle. Same button
            // serves both states — when not all selected, click
            // selects all visible. When all visible are selected,
            // click deselects all. Mirror's macOS Mail's pattern
            // where the toolbar adapts to current state.
            Button {
                if allVisibleSelected {
                    clearSelection()
                } else {
                    selectAllVisible()
                }
            } label: {
                Text(allVisibleSelected ? "Deselect All" : "Select All")
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

            // Pin/Unpin all selected (toggles based on whether
            // the majority of selected are already pinned).
            Button {
                pinSelected()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 10, weight: .medium))
                    Text("Pin")
                        .font(.nkMeta)
                }
                .foregroundStyle(DS.Color.textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(DS.Color.bgSubtle.opacity(0.7))
                )
            }
            .buttonStyle(.plain)
            .help("Pin selected to top")

            // Trash selected (no confirmation — undo via Trash).
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
            .help("Move selected to Trash")
            .keyboardShortcut(.delete, modifiers: [])

            // Done / Deselect-all — exits selection mode by clearing
            // the selection set. "Done" reads more accurately than
            // "Cancel" for this — selection is non-destructive, so
            // there's nothing to cancel; the user is just leaving
            // selection mode. Esc keyboard shortcut also wired here.
            Button {
                clearSelection()
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
            .help("Exit selection mode")
        }
    }

    /// ⇧-click range select-or-deselect. Picks the operation based
    /// on the clicked note's CURRENT state:
    ///   • clicked note already selected → DESELECT the entire range
    ///   • clicked note not selected → SELECT the entire range
    ///
    /// This makes ⇧-click symmetric: the same gesture grows or
    /// shrinks the selection depending on context. Without this,
    /// ⇧-click could only ever add to the selection — the user
    /// reported they couldn't "deselect multiple at once," which
    /// is exactly the case where they had a range selected and
    /// wanted to remove it.
    ///
    /// Anchor preference: most recently focused note → first
    /// selected note → the clicked note itself (no-op range).
    private func rangeSelect(to note: Note) {
        let visible = filteredNotes
        guard let endIdx = visible.firstIndex(where: { $0.id == note.id }) else { return }
        let anchorId = focusedNoteId ?? selectedNoteIds.first
        guard let anchor = anchorId,
              let anchorIdx = visible.firstIndex(where: { $0.id == anchor })
        else {
            // No anchor → just toggle this single note as a fallback.
            if selectedNoteIds.contains(note.id) {
                selectedNoteIds.remove(note.id)
            } else {
                selectedNoteIds.insert(note.id)
            }
            return
        }
        let lo = min(anchorIdx, endIdx)
        let hi = max(anchorIdx, endIdx)
        let shouldDeselect = selectedNoteIds.contains(note.id)
        withAnimation(.rowHover) {
            for idx in lo...hi {
                if shouldDeselect {
                    selectedNoteIds.remove(visible[idx].id)
                } else {
                    selectedNoteIds.insert(visible[idx].id)
                }
            }
        }
    }

    /// Move every selected note to Trash. No confirmation dialog —
    /// Trash is recoverable. Clears the selection state after.
    private func deleteSelected() {
        for id in selectedNoteIds {
            try? noteStore.trash(id: id)
        }
        clearSelection()
    }

    /// Pin all selected notes to the top. Idempotent — already-pinned
    /// notes stay pinned. After acting, exits selection mode.
    private func pinSelected() {
        var ids = UserDefaults.standard.stringArray(forKey: "Notetaker.pinnedNoteIds") ?? []
        for id in selectedNoteIds where !ids.contains(id) {
            ids.append(id)
        }
        UserDefaults.standard.set(ids, forKey: "Notetaker.pinnedNoteIds")
        clearSelection()
    }

    /// Exit multi-select mode by emptying the selection set. Toolbar
    /// slides away automatically because its visibility is gated on
    /// `!selectedNoteIds.isEmpty`.
    private func clearSelection() {
        withAnimation(.rowHover) {
            selectedNoteIds.removeAll()
        }
    }

    /// True iff every currently-visible note (post-search-filter)
    /// is in the selection set. Used by the toolbar's Select All /
    /// Deselect All toggle to flip its label.
    private var allVisibleSelected: Bool {
        let visible = filteredNotes
        guard !visible.isEmpty else { return false }
        return visible.allSatisfy { selectedNoteIds.contains($0.id) }
    }

    /// Add every currently-visible note to the selection set.
    /// "Visible" respects the search filter, so a user can search
    /// to narrow the list, then ⌘A to bulk-select just those.
    private func selectAllVisible() {
        withAnimation(.rowHover) {
            for note in filteredNotes {
                selectedNoteIds.insert(note.id)
            }
        }
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

    @EnvironmentObject var noteStore: NoteStore

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

                // Earlier this read "Auto-saves · 483" which was
                // wildly misleading — 483 was the character count of
                // the note text (`text.count`), not the number of
                // saves. Users (correctly) read "saved 483 times" and
                // panicked. Now reads as "483 chars · saved" which
                // tells them what the number is AND confirms persistence.
                Text("\(text.count) char\(text.count == 1 ? "" : "s")")
                    .font(.nkLabel)
                    .monospacedDigit()
                    .foregroundStyle(DS.Color.textTertiary)
                Text("·")
                    .font(.nkLabel)
                    .foregroundStyle(DS.Color.textTertiary.opacity(0.4))
                Text("saved")
                    .font(.nkLabel)
                    .foregroundStyle(DS.Color.textTertiary)
            }
            .padding(.horizontal, DS.Spacing.md)
            .padding(.top, DS.Spacing.md)
            .padding(.bottom, DS.Spacing.xs)

            // Toolbar talks to the editor via the coordinatorRef.
            // Each button calls a cursor-aware insertion closure that
            // prefixes the current line — same as Notion's slash
            // commands, but driven from a compact icon strip.
            FormattingToolbar(
                coordinator: coordinatorRef,
                noteId: noteId
            )
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
    /// Note ID powers the popout button — the floating note window
    /// uses it to load + save against the right row in the store.
    let noteId: String

    @EnvironmentObject var noteStore: NoteStore

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
            // Pop the note out into a slim, always-on-top floating
            // window so the user can take notes next to a video
            // playing in any other app (browser, WhatsApp, native
            // player). nox doesn't host the video — it just gets
            // out of the way and stays visible.
            ToolbarIconButton(
                icon: "rectangle.portrait.and.arrow.right",
                help: "Pop out — take notes while watching a video in any app"
            ) {
                PopoutNote.shared.show(noteID: noteId, noteStore: noteStore)
            }
            Spacer()
            // Dictation mic — speech-to-text directly into the
            // current note at the caret. Same pipeline as the
            // global Fn-key dictation, but the transcript is
            // routed via DictationRouter.pendingDestination so it
            // lands inside the editor's NSTextView instead of
            // typing into whatever app is frontmost.
            DictationToolbarButton(coordinator: coordinator)
        }
    }
}

/// Mic button for the note-editor toolbar. Tap to start dictating
/// directly into the note; tap again (or use Fn / ⌘⇧D) to stop.
/// Reflects the orchestrator's recording state via the
/// `.notetakerDictationStateChanged` notification.
private struct DictationToolbarButton: View {
    let coordinator: MarkdownTextEditor.CoordinatorRef

    @State private var isRecording = false
    @State private var isHovered = false
    @State private var isPressed = false

    var body: some View {
        Button(action: toggle) {
            Image(systemName: isRecording ? "stop.circle.fill" : "mic.fill")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isRecording
                    ? Color(red: 1.0, green: 0.27, blue: 0.27)
                    : DS.Color.textSecondary)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(backgroundFill)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(borderColor, lineWidth: 0.5)
                )
                .scaleEffect(isPressed ? 0.92 : 1.0)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isRecording ? "Stop dictation" : "Dictate into this note")
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
        .onReceive(NotificationCenter.default.publisher(for: .notetakerDictationStateChanged)) { note in
            if let recording = note.userInfo?["isRecording"] as? Bool {
                withAnimation(.easeOut(duration: 0.18)) {
                    isRecording = recording
                }
            }
        }
    }

    private var backgroundFill: Color {
        if isRecording {
            return Color(red: 1.0, green: 0.27, blue: 0.27).opacity(0.12)
        }
        return Color.white.opacity(isPressed ? 0.10 : isHovered ? 0.06 : 0)
    }

    private var borderColor: Color {
        if isRecording {
            return Color(red: 1.0, green: 0.27, blue: 0.27).opacity(0.35)
        }
        return Color.white.opacity(isHovered ? 0.08 : 0)
    }

    private func toggle() {
        if isRecording {
            // Stop the in-flight recording. Transcript still
            // lands in `pendingDestination` (already set when we
            // started), so the note gets the text on completion.
            NotificationCenter.default.post(name: .notetakerStartDictation, object: nil)
        } else {
            // Claim the next transcript for this note's editor —
            // AppDelegate's `onTranscriptReady` will see this and
            // route here instead of typing globally. The closure
            // captures `coordinator` strongly, which is fine: it
            // lives at the parent NoteEditorView's @State level
            // and outlives this button. The closure itself is
            // held in DictationRouter (static var), not in
            // coordinator, so there's no retain cycle.
            DictationRouter.pendingDestination = { text in
                coordinator.insertText?(text)
            }
            NotificationCenter.default.post(name: .notetakerStartDictation, object: nil)
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
    /// True when this note is in the multi-select set. Drives the
    /// selection-state visual (left accent bar + tinted background).
    var isSelected: Bool = false
    /// True when SOMETHING is selected anywhere in the list — the
    /// list is in "selection mode" and plain clicks should toggle
    /// rather than copy. Allows the user to use the same plain-
    /// click gesture for both select AND deselect once they're in
    /// selection mode.
    var isSelectionModeActive: Bool = false
    let onOpen: () -> Void
    let onDelete: () -> Void
    let onCopy: () -> Void
    /// Open this note in the slim, always-on-top floating popout
    /// window — same path as the editor toolbar's pop-out button,
    /// surfaced here so the user can launch it from the LIST without
    /// first opening the in-slab editor. Optional so existing call
    /// sites that don't pass it keep working.
    var onPopOut: (() -> Void)? = nil
    /// Multi-select toggle — fires on ⌘-click. The parent updates
    /// `selectedNoteIds` and the row re-renders with `isSelected`.
    /// Optional so existing callers without selection support keep
    /// working unchanged.
    var onToggleSelection: (() -> Void)? = nil
    /// Range-select handler — fires on ⇧-click. Parent fills the
    /// selection from the focused note to this one inclusive.
    var onRangeSelect: (() -> Void)? = nil
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
                let isClipboard = note.kind == Note.Kind.clipboard.rawValue
                VStack(spacing: 3) {
                    HStack(spacing: 5) {
                        if isClipboard {
                            // Clipboard glyph BEFORE the title.
                            // Identifies the row as a transient
                            // auto-save at a glance without needing
                            // a filter pill to context-switch.
                            Image(systemName: "doc.on.clipboard")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(DS.Color.textTertiary)
                        }
                        Text(displayTitle)
                            // Clipboard rows: smaller font + regular
                            // weight (vs medium for notes) so they
                            // visually recede.
                            .font(
                                isClipboard
                                ? .nkBody.weight(.regular)
                                : .nkBody.weight(.medium)
                            )
                            .foregroundStyle(DS.Color.textPrimary)
                            .lineLimit(1)
                            .multilineTextAlignment(.center)
                            .truncationMode(.tail)
                            .italic(summaryIsLoading)
                    }
                    // Whole row gets demoted to 50% alpha for clipboard
                    // — enough that intentional notes "pop" against
                    // them in a scan, but not so dim the user can't
                    // read the row when they want to. Pastebot's
                    // pattern. Summary-loading rows still use 70%.
                    .opacity(
                        summaryIsLoading ? 0.7
                        : (isClipboard ? 0.5 : 1)
                    )
                    Text(Self.relativeTime(from: note.updatedAt))
                        .font(.nkLabel)
                        .foregroundStyle(DS.Color.textTertiary)
                        .opacity(isClipboard ? 0.65 : 1)
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
                // Hide hover-trash + pin icons during selection
                // mode — the row's right-side real estate is now
                // taken by the check badge, and click semantics
                // are toggling selection rather than firing the
                // trash button. Bulk delete is via the toolbar.
                .opacity(isHovered && !isSelectionModeActive ? 1 : 0)
                .allowsHitTesting(!isSelectionModeActive)
                .help("Delete")
            }
            .padding(.trailing, 12)
            .allowsHitTesting(isHovered || isPinned)
            .animation(.rowHover, value: isHovered)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(
            // Hover wash matched to the dock-pill / card vocabulary
            // (radius 12pt, subtle vibrancy on hover). Selected
            // state stays accent-tinted so multi-select reads
            // distinctly. Bump from 8pt → 12pt aligns with the
            // wider radius language landing across the panel
            // chrome (DS.Radius.row 10, .card 14).
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.22)
                      : (isFocused ? DS.Color.bgSelected.opacity(0.6)
                      : (isHovered ? DS.Color.bgHover.opacity(0.55) : Color.clear)))
        )
        .overlay(alignment: .leading) {
            // Left accent bar when selected — 6pt wide rounded
            // capsule, accent-colored. Thicker than the prior 3pt
            // stripe and pill-shaped to read clearly. Slides in
            // from the left edge on selection.
            if isSelected {
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: 5)
                    .padding(.vertical, 8)
                    .padding(.leading, 2)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .overlay(alignment: .trailing) {
            // Animated check badge on the right when selected.
            // Replaces the hover trash icon (which is hidden in
            // selection mode anyway since the row's whole click
            // semantics changed). Same circle-check vocabulary as
            // Mail.app's selected message indicator.
            if isSelected {
                ZStack {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 18, height: 18)
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .heavy))
                        .foregroundStyle(.white)
                }
                .padding(.trailing, 16)
                .transition(.scale(scale: 0.5).combined(with: .opacity))
            }
        }
        .scaleEffect(isSelected ? 1.01 : 1.0)
        .animation(.spring(response: 0.32, dampingFraction: 0.78), value: isSelected)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.rowHover) { isHovered = hovering }
        }
        .onTapGesture(count: 2) { onOpen() }
        .onTapGesture(count: 1) {
            // Modifier-aware single tap with selection-mode override.
            //
            //  • In SELECTION MODE (any note already selected):
            //    ANY click toggles. So clicking an unselected row
            //    selects it, clicking a selected row deselects it
            //    — same click does both, no modifier needed. iOS
            //    Mail / Photos use this pattern: once you're in
            //    selection mode, taps are toggles.
            //  • OUTSIDE selection mode:
            //    Plain click = copy (existing).
            //    ⌘-click = enters selection mode by adding this
            //    note to a fresh selection set.
            //    ⇧-click = range select from the focused note.
            //
            // This way, "same button for selecting and deselecting"
            // is just `onToggleSelection` once selection mode is
            // active — no separate deselect affordance needed.
            let mods = NSApp.currentEvent?.modifierFlags ?? []
            if mods.contains(.shift), let range = onRangeSelect {
                range()
            } else if mods.contains(.command), let toggle = onToggleSelection {
                toggle()
            } else if isSelectionModeActive, let toggle = onToggleSelection {
                // Selection mode is "active" when something is
                // already selected — plain click then toggles
                // this row's membership.
                toggle()
            } else {
                handleCopy()
            }
        }
        .onAppear {
            if let url = firstURL { linkPreviewService.ensure(for: url) }
        }
        .contextMenu {
            // Right-click on any row to open it in the floating
            // popout window — handy when you want to take notes
            // alongside a video without first opening the in-slab
            // editor. Open in editor stays the default (double-click).
            if let popOut = onPopOut {
                Button {
                    popOut()
                } label: {
                    Label("Open in Pop-out Window", systemImage: "rectangle.portrait.and.arrow.right")
                }
            }
            Button {
                onOpen()
            } label: {
                Label("Open in Editor", systemImage: "square.and.pencil")
            }
            Button {
                onCopy()
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            Divider()
            Button(role: .destructive) {
                onDelete()
            } label: {
                Label("Delete", systemImage: "trash")
            }
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
