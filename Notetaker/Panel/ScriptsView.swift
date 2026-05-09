import SwiftUI

/// Script tab — manage teleprompter scripts (paste, edit, save,
/// configure WPM, hit Start to read at the notch).
///
/// Layout (Phase 2 — "Library Spine + Live Preview" combo):
///   • LEFT (220pt): list of saved scripts. Each row shows title,
///     word count, estimated reading time. "+ New script" pinned
///     to the bottom. Same as Phase 1.
///   • RIGHT (fill), top→bottom:
///       1. Title field
///       2. Live preview pill — auto-loops a snippet of the script
///          at the chosen WPM using the same geometry the real
///          teleprompter pill will use. Updates in real time as the
///          user drags the slider.
///       3. Speed slider (WPM) + reading-time estimate
///       4. TextEditor (script body)
///       5. "Start reading" CTA
///
/// The preview pill sits between the title and the slider on
/// purpose: dragging the slider visibly speeds/slows the preview, so
/// the user sees the answer to "is this WPM right for me?" without
/// having to commit and step back.
///
/// Phase 2 status: editor + preview shipped. Hitting Start still
/// only logs (Phase 3 wires the floating teleprompter pill).
struct ScriptsView: View {
    @EnvironmentObject var presenter: PanelPresenter
    @ObservedObject private var store: ScriptStore

    /// Currently-selected script ID. nil → no selection (empty
    /// state). On first appear, defaults to the most-recently-
    /// updated script if one exists.
    @State private var selectedID: String?

    /// Local edit-buffer mirrors the selected script's body so
    /// keystrokes don't re-write the DB on every character. We
    /// flush to the store on focus loss + on a 1.5s debounce.
    @State private var editingBody: String = ""
    @State private var editingTitle: String = ""
    @State private var editingWPM: Int = 150
    @State private var saveDebounce: Task<Void, Never>?

    /// True for the brief window during which `loadEditingBuffers`
    /// is mutating the editing-* state vars in response to the user
    /// switching scripts. SwiftUI's `.onChange` modifiers fire on
    /// EVERY state change including programmatic ones, so without
    /// this guard, clicking a row in the left rail would:
    ///   1. Set editingBody/Title/WPM to the new script's values
    ///   2. .onChange handlers fire → scheduleFlush()
    ///   3. 1.5s later: store.update() rewrites the new script with
    ///      the SAME values it already had — bumping updatedAt
    ///   4. The list re-sorts (most-recent-first) and the row jumps
    ///      to the top
    /// User perceives this as "left rail buttons aren't working" —
    /// they click row 3, the editor flashes its content, then the
    /// row teleports to position 1. Setting this flag during the
    /// load makes scheduleFlush() a no-op for those programmatic
    /// changes; user typing still flushes normally.
    @State private var isLoadingBuffers: Bool = false

    /// Drives the live preview pill. Defaults to playing — users
    /// landing on the tab should see motion immediately. Hover on the
    /// preview surfaces a pause toggle if they want it still.
    @State private var previewPlaying: Bool = true

    /// True while the TextEditor (script body) has keyboard focus.
    /// When true we collapse the live preview pill so the writing
    /// surface gets the full available column height — much more
    /// comfortable for actually drafting a script. The pill returns
    /// the moment focus leaves, so the user can still see the
    /// preview when fiddling with WPM. User direction 2026-05-09:
    /// "When someone is writing only that one should be big."
    @FocusState private var bodyFieldFocused: Bool

    init() {
        // Defer to AppEnvironment so the store is shared across the
        // app (same instance feeding any future search / spotlight
        // surface). Resolved via AppDelegate.shared since
        // EnvironmentObject doesn't reach AppEnvironment cleanly.
        guard let store = AppDelegate.shared?.environment?.scriptStore else {
            // Build-time defensive fallback — should never happen at
            // runtime since AppDelegate spins up the environment in
            // `applicationDidFinishLaunching`. If it does, render an
            // empty store so the view doesn't crash; the user just
            // sees "no scripts yet."
            fatalError("ScriptStore must be available via AppEnvironment")
        }
        self.store = store
    }

    var body: some View {
        HStack(spacing: 0) {
            scriptList
                .frame(width: 180)
            Divider()
                .background(Color.white.opacity(0.06))
            scriptEditor
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, DS.Spacing.md)
        .padding(.top, DS.Spacing.md)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            // Default selection: most-recently-updated script. nil if
            // the user has none yet — falls through to the empty
            // editor state.
            if selectedID == nil, let first = store.scripts.first {
                selectedID = first.id
                loadEditingBuffers(for: first)
            }
        }
    }

    // MARK: - Left column: list

    private var scriptList: some View {
        VStack(spacing: 0) {
            if store.scripts.isEmpty {
                emptyListPlaceholder
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(store.scripts) { script in
                            scriptRow(script)
                        }
                    }
                    .padding(6)
                }
            }
            Divider().background(Color.white.opacity(0.06))
            newScriptButton
        }
    }

    private var emptyListPlaceholder: some View {
        VStack(spacing: 6) {
            Spacer()
            Image(systemName: "text.alignleft")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.white.opacity(0.30))
            Text("No scripts yet")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.50))
            Text("Paste your first script below.")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.30))
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 10)
    }

    private func scriptRow(_ script: Script) -> some View {
        let isSelected = script.id == selectedID
        let title = script.title?.isEmpty == false ? script.title! : "Untitled"
        let words = ScriptStore.wordCount(script.body)
        let duration = ScriptStore.estimatedReadingTime(script)
        let durationLabel: String = {
            if duration < 60 { return "~\(Int(duration))s" }
            let m = Int(duration / 60)
            return "~\(m)m"
        }()
        return Button {
            // Avoid no-op work if the user re-clicked the active row —
            // prevents an unnecessary load + onChange burst.
            if script.id != selectedID {
                selectedID = script.id
                loadEditingBuffers(for: script)
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? .white : .white.opacity(0.78))
                    .lineLimit(1)
                Text("\(words) words · \(durationLabel)")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? DS.Color.accent.opacity(0.18) : .clear)
            )
            // Make the FULL row hit-testable, not just the text. By
            // default `.buttonStyle(.plain)` only registers taps on
            // visible label content; transparent areas (gaps between
            // text and the row's edges) drop through to the
            // underlying ScrollView and read as no-ops.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Rename…") { /* phase 1 stub */ }
            Button(role: .destructive, action: {
                try? store.trash(id: script.id)
                if selectedID == script.id {
                    selectedID = store.scripts.first?.id
                    if let next = store.scripts.first { loadEditingBuffers(for: next) }
                    else { resetEditingBuffers() }
                }
            }) { Text("Move to Trash") }
        }
    }

    private var newScriptButton: some View {
        Button {
            do {
                let s = try store.create(title: nil, body: "")
                selectedID = s.id
                loadEditingBuffers(for: s)
            } catch {
                NSLog("nox: ScriptsView — create failed: \(error)")
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                Text("New script")
                    .font(.system(size: 12.5, weight: .medium))
                Spacer()
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .foregroundStyle(DS.Color.accent)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Right column: editor

    @ViewBuilder
    private var scriptEditor: some View {
        if let id = selectedID,
           let script = store.scripts.first(where: { $0.id == id }) {
            editorContent(for: script)
        } else {
            editorEmptyState
        }
    }

    private func editorContent(for script: Script) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            titleRow
            // Hide the preview pill while the TextEditor is focused
            // so the editor expands into the freed vertical space.
            // The spring curve below drives BOTH the pill's
            // appearance/disappearance AND the surrounding VStack's
            // layout reflow in lockstep — the editor grows into the
            // freed space at the same cadence the pill fades away,
            // so the user reads it as one continuous motion rather
            // than two competing animations.
            if !bodyFieldFocused {
                ScriptPreviewPill(
                    text: editingBody,
                    wpm: editingWPM,
                    isPlaying: $previewPlaying
                )
                // Pure opacity transition — no .move/.slide. The
                // VStack's layout animation handles the geometry;
                // adding a translate on top fights it and reads as
                // a stutter at the midpoint. Opacity-only lets the
                // spring drive every visible vector cleanly.
                .transition(.opacity)
            }
            wpmRow
            textArea
            startRow(for: script)
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 12)
        // Spring curve matched to the rest of the app's content
        // reveals (response 0.45, damping 0.85). Feels organic —
        // a touch of settle at the end without overshoot.
        .animation(.spring(response: 0.45, dampingFraction: 0.86),
                   value: bodyFieldFocused)
    }

    private var editorEmptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "text.alignleft")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.white.opacity(0.25))
            Text("Pick a script on the left, or create one.")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.55))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var titleRow: some View {
        // Compact eyebrow-style title — sits above the preview pill
        // without competing with it for visual weight.
        HStack(spacing: 8) {
            TextField("Untitled script", text: $editingTitle)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.92))
                .onSubmit { flushNow() }
                .onChange(of: editingTitle) { _ in scheduleFlush() }
            Spacer()
        }
        .padding(.bottom, 2)
    }

    /// WPM + live reading-time estimate for the FULL script body
    /// (the preview only shows a snippet). Slider gets the full row
    /// width so it's actually drag-grabbable; metadata lives in a
    /// compact pill on the right.
    private var wpmRow: some View {
        let words = ScriptStore.wordCount(editingBody)
        let durationSec = (Double(words) / max(1.0, Double(editingWPM))) * 60.0
        let durationLabel: String = {
            if words == 0 { return "—" }
            if durationSec < 60 { return "\(Int(durationSec))s" }
            let m = Int(durationSec / 60)
            let s = Int(durationSec.truncatingRemainder(dividingBy: 60))
            return s > 0 ? "\(m)m \(s)s" : "\(m)m"
        }()
        return HStack(spacing: 14) {
            Slider(
                value: Binding(
                    get: { Double(editingWPM) },
                    set: {
                        editingWPM = Int($0)
                        scheduleFlush()
                    }
                ),
                in: 80...250,
                step: 5
            )
            .tint(DS.Color.accent)
            .frame(maxWidth: .infinity)

            // Compact metadata cluster — WPM number prominent,
            // reading-time muted on the right.
            HStack(spacing: 6) {
                Text("\(editingWPM)")
                    .font(.system(size: 12.5, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.92))
                Text("WPM")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.40))
                    .padding(.trailing, 4)
                Image(systemName: "clock")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.40))
                Text(durationLabel)
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.55))
            }
            .layoutPriority(1)
        }
    }

    private var textArea: some View {
        ZStack(alignment: .topLeading) {
            if editingBody.isEmpty {
                Text("Paste your script here…")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.30))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)
                    .allowsHitTesting(false)
            }
            TextEditor(text: $editingBody)
                .font(.system(size: 13, weight: .regular))
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 4)
                .padding(.vertical, 4)
                .focused($bodyFieldFocused)
                .onChange(of: editingBody) { _ in scheduleFlush() }
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.black.opacity(0.30))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(.white.opacity(0.06), lineWidth: 0.5)
                )
        )
        .frame(maxWidth: .infinity, minHeight: 110, maxHeight: .infinity)
    }

    private func startRow(for script: Script) -> some View {
        HStack {
            Spacer()
            Button {
                // Persist edits FIRST so the script the teleprompter
                // reads matches what's on screen — the button might
                // be tapped before the 1.5s debounce has flushed.
                flushNow()
                // Re-fetch post-flush so the teleprompter sees the
                // latest body/title/wpm AND the saved-position
                // (`lastReadOffset`, set by TeleprompterPillBody on ×
                // / auto-stop). Treat the offset as elapsed seconds.
                let latest = store.scripts.first(where: { $0.id == script.id }) ?? script
                let resumeFrom = TimeInterval(latest.lastReadOffset)
                presenter.startTeleprompter(latest, resumeFromElapsed: resumeFrom)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 10, weight: .heavy))
                    Text("Start reading")
                        .font(.system(size: 13, weight: .semibold))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .foregroundStyle(Color.black)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(DS.Color.accent)
                )
            }
            .buttonStyle(.plain)
            .disabled(editingBody.isEmpty)
            .opacity(editingBody.isEmpty ? 0.4 : 1.0)
        }
    }

    // MARK: - Edit buffer plumbing

    private func loadEditingBuffers(for script: Script) {
        // Suppress flushes triggered by the buffer mutations below.
        // The onChange handlers run synchronously while SwiftUI is
        // still applying state, then we clear the flag on the next
        // runloop tick. User-typed changes after that point flush
        // normally.
        isLoadingBuffers = true
        editingTitle = script.title ?? ""
        editingBody = script.body
        editingWPM = script.wpm
        saveDebounce?.cancel()
        saveDebounce = nil
        DispatchQueue.main.async {
            self.isLoadingBuffers = false
        }
    }

    private func resetEditingBuffers() {
        editingTitle = ""
        editingBody = ""
        editingWPM = 150
        saveDebounce?.cancel()
        saveDebounce = nil
    }

    /// Persist edits 1.5s after the last keystroke. Cheaper than
    /// writing to SQLite on every character, slow enough to feel
    /// "instant save" to the user. No-op while `loadEditingBuffers`
    /// is mid-load — see the doc on `isLoadingBuffers`.
    private func scheduleFlush() {
        if isLoadingBuffers { return }
        saveDebounce?.cancel()
        saveDebounce = Task { [editingBody, editingTitle, editingWPM, selectedID] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled, let id = selectedID else { return }
            await MainActor.run {
                let titleOptional: String?
                let trimmed = editingTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                titleOptional = trimmed.isEmpty ? nil : trimmed
                try? store.update(
                    id: id,
                    title: .some(titleOptional),
                    body: editingBody,
                    wpm: editingWPM
                )
            }
        }
    }

    /// Flush immediately (used on Return / focus loss / Start tap).
    private func flushNow() {
        saveDebounce?.cancel()
        guard let id = selectedID else { return }
        let trimmed = editingTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let titleOptional: String? = trimmed.isEmpty ? nil : trimmed
        try? store.update(
            id: id,
            title: .some(titleOptional),
            body: editingBody,
            wpm: editingWPM
        )
    }
}
