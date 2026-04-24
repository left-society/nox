import SwiftUI

struct NotesListView: View {
    @EnvironmentObject var env: AppEnvironment
    @State private var composerText: String = ""
    @State private var composerNoteId: String?
    @State private var saveTask: Task<Void, Never>?
    @FocusState private var composerFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            composer
                .padding(.horizontal, DS.Spacing.md)
                .padding(.top, DS.Spacing.md)
                .padding(.bottom, DS.Spacing.sm)

            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(env.noteStore.notes) { note in
                        NoteRow(note: note)
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
            .scrollIndicators(.never)
        }
        .onAppear { composerFocused = true }
    }

    // MARK: - Composer

    private var composer: some View {
        HStack(alignment: .top, spacing: DS.Spacing.sm) {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(DS.Color.textTertiary)
                .padding(.top, 3)

            TextField("New note", text: $composerText, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.nkBody)
                .foregroundStyle(DS.Color.textPrimary)
                .lineLimit(1...4)
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
    @State private var isHovered = false

    var body: some View {
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
        .padding(.horizontal, DS.Spacing.md)
        .padding(.vertical, DS.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous)
                .fill(isHovered ? DS.Color.bgHover : Color.clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: DS.Radius.row))
        .onHover { hovering in
            withAnimation(.rowHover) { isHovered = hovering }
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
