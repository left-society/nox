import SwiftUI
import AppKit

struct NotesListView: View {
    @EnvironmentObject var env: AppEnvironment
    @State private var composerText: String = ""
    @State private var composerNoteId: String?
    @State private var saveTask: Task<Void, Never>?
    @State private var focusedNoteId: String?
    @State private var editingNoteId: String?
    @State private var editingText: String = ""
    @FocusState private var composerFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            composer
                .padding(.horizontal, DS.Spacing.md)
                .padding(.top, DS.Spacing.md)
                .padding(.bottom, DS.Spacing.sm)

            ScrollView {
                if env.noteStore.notes.isEmpty {
                    emptyState
                } else {
                    LazyVStack(spacing: 1) {
                        ForEach(env.noteStore.notes) { note in
                            NoteRow(
                                note: note,
                                isFocused: focusedNoteId == note.id,
                                isEditing: editingNoteId == note.id,
                                editingText: $editingText,
                                onEdit: { startEditing(note) },
                                onCommit: { commitEditing() },
                                onCancel: { cancelEditing() },
                                onDelete: { deleteNote(note) },
                                onCopy: { copyNote(note) }
                            )
                            .onTapGesture {
                                if editingNoteId == note.id { return }
                                withAnimation(.rowHover) {
                                    focusedNoteId = note.id
                                }
                                composerFocused = false
                            }
                            .onDrag {
                                NSItemProvider(object: note.body as NSString)
                            }
                            .transition(.asymmetric(
                                insertion: .opacity.combined(with: .scale(scale: 0.98, anchor: .top)),
                                removal: .opacity
                            ))
                        }
                    }
                    .padding(.horizontal, DS.Spacing.sm)
                    .padding(.bottom, DS.Spacing.md)
                    .animation(.selection, value: env.noteStore.notes.map(\.id))
                }
            }
            .scrollIndicators(.never)
        }
        .background(copyShortcut)
        .onAppear { composerFocused = true }
    }

    private func startEditing(_ note: Note) {
        editingText = note.body
        editingNoteId = note.id
        focusedNoteId = note.id
        composerFocused = false
    }

    private func commitEditing() {
        guard let id = editingNoteId else { return }
        let trimmed = editingText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try? env.noteStore.trash(id: id)
        } else {
            try? env.noteStore.updateBody(id: id, body: editingText)
        }
        editingNoteId = nil
        editingText = ""
    }

    private func cancelEditing() {
        editingNoteId = nil
        editingText = ""
    }

    private func copyNote(_ note: Note) {
        ClipboardService.copy(text: note.body)
    }

    private func deleteNote(_ note: Note) {
        if editingNoteId == note.id {
            editingNoteId = nil
            editingText = ""
        }
        if focusedNoteId == note.id {
            focusedNoteId = nil
        }
        if composerNoteId == note.id {
            composerNoteId = nil
            composerText = ""
        }
        try? env.noteStore.trash(id: note.id)
    }

    private var emptyState: some View {
        VStack(spacing: DS.Spacing.sm) {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(DS.Color.textTertiary)
            Text("Nothing yet")
                .font(.nkBody.weight(.medium))
                .foregroundStyle(DS.Color.textSecondary)
            Text("Start typing above to capture a thought.")
                .font(.nkMeta)
                .foregroundStyle(DS.Color.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 72)
    }

    private var copyShortcut: some View {
        Button(action: copyFocusedNote) { EmptyView() }
            .keyboardShortcut("c", modifiers: .command)
            .disabled(focusedNoteId == nil || composerFocused)
            .opacity(0)
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
    }

    private func copyFocusedNote() {
        guard let id = focusedNoteId,
              let note = env.noteStore.notes.first(where: { $0.id == id })
        else { return }
        ClipboardService.copy(text: note.body)
    }

    // MARK: - Composer

    private var composer: some View {
        HStack(alignment: .top, spacing: DS.Spacing.sm) {
            Image(systemName: "plus")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(DS.Color.textTertiary)
                .padding(.top, 2)

            TextField("New note", text: $composerText, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.nkBody)
                .foregroundStyle(DS.Color.textPrimary)
                .lineLimit(1...3)
                .focused($composerFocused)
                .onChange(of: composerText) { newValue in
                    handleComposerChange(newValue)
                }
        }
        .padding(.horizontal, DS.Spacing.md)
        .padding(.vertical, DS.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous)
                .fill(composerFocused ? DS.Color.bgHover : DS.Color.bgSubtle)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous)
                .strokeBorder(
                    composerFocused ? Color.white.opacity(0.08) : Color.clear,
                    lineWidth: 0.5
                )
        )
        .animation(.easeOut(duration: 0.15), value: composerFocused)
        .onTapGesture { composerFocused = true }
    }

    private func handleComposerChange(_ newValue: String) {
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            if Task.isCancelled { return }
            applyComposerChange(newValue)
        }
    }

    private func applyComposerChange(_ newValue: String) {
        if composerNoteId == nil && !newValue.isEmpty {
            do {
                let note = try env.noteStore.createNote()
                composerNoteId = note.id
                try env.noteStore.updateBody(id: note.id, body: newValue)
            } catch {
                NSLog("createNote failed: \(error)")
            }
        } else if let id = composerNoteId {
            if newValue.isEmpty {
                try? env.noteStore.trash(id: id)
                composerNoteId = nil
            } else {
                try? env.noteStore.updateBody(id: id, body: newValue)
            }
        }
    }
}

// MARK: - NoteRow

struct NoteRow: View {
    let note: Note
    let isFocused: Bool
    let isEditing: Bool
    @Binding var editingText: String
    let onEdit: () -> Void
    let onCommit: () -> Void
    let onCancel: () -> Void
    let onDelete: () -> Void
    let onCopy: () -> Void

    @State private var isHovered = false
    @State private var justCopied = false
    @FocusState private var editorFocused: Bool

    var body: some View {
        Group {
            if isEditing {
                editorView
            } else {
                displayView
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, DS.Spacing.md)
        .padding(.vertical, DS.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous)
                .fill(backgroundFill)
        )
        .contentShape(RoundedRectangle(cornerRadius: DS.Radius.row))
        .onHover { hovering in
            withAnimation(.rowHover) { isHovered = hovering }
        }
    }

    private var displayView: some View {
        HStack(alignment: .top, spacing: DS.Spacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(note.title ?? "Untitled")
                    .font(.nkBody.weight(.medium))
                    .foregroundStyle(DS.Color.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Text(Self.relativeTime(from: note.updatedAt))
                    .font(.nkLabel)
                    .foregroundStyle(DS.Color.textTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 4) {
                Button(action: onEdit) {
                    Image(systemName: "pencil")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(isHovered ? DS.Color.textSecondary : DS.Color.textTertiary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(isHovered || isFocused ? 1 : 0)

                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(isHovered ? DS.Color.textSecondary : DS.Color.textTertiary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(isHovered || isFocused ? 1 : 0)

                Button(action: handleCopy) {
                    HStack(spacing: 3) {
                        Image(systemName: justCopied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 9, weight: .semibold))
                        Text(justCopied ? "Copied" : "Copy")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(justCopied ? DS.Color.accent : DS.Color.textPrimary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(justCopied ? DS.Color.bgSelected : DS.Color.bgHover)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .animation(.selection, value: justCopied)
            }
            .animation(.rowHover, value: isHovered || isFocused)
        }
    }

    private var editorView: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            TextField("", text: $editingText, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.nkBody)
                .foregroundStyle(DS.Color.textPrimary)
                .lineLimit(2...10)
                .focused($editorFocused)
                .onSubmit { onCommit() }
                .onAppear { editorFocused = true }
                .onExitCommand { onCancel() }

            HStack(spacing: DS.Spacing.xs) {
                Spacer()
                Button(action: onCancel) {
                    Text("Cancel")
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

                Button(action: onCommit) {
                    Text("Save")
                        .font(.nkMeta.weight(.semibold))
                        .foregroundStyle(DS.Color.textPrimary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(DS.Color.bgSelected)
                        )
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
    }

    private func handleCopy() {
        onCopy()
        justCopied = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            justCopied = false
        }
    }

    private var backgroundFill: Color {
        if isEditing { return DS.Color.bgHover }
        if isFocused { return DS.Color.bgSelected }
        if isHovered { return DS.Color.bgHover }
        return .clear
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
