import SwiftUI

/// Editable freeform notes for a meeting (separate from AI summary notes).
struct MeetingUserNotesEditor: View {
    @Environment(AppState.self) private var appState
    @Bindable var meeting: Meeting
    var compact: Bool = false

    @State private var draft: String = ""
    @State private var saveTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 8) {
            if compact {
                DashboardOverline(text: "Your notes")
            }
            TextEditor(text: $draft)
                .font(compact ? .system(size: 12) : .body)
                .frame(minHeight: compact ? 72 : 120, maxHeight: compact ? 120 : 220)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(compact ? SauronTheme.surfaceElevated.opacity(0.6) : Color.primary.opacity(0.04))
                )
                .onChange(of: draft) { _, _ in
                    scheduleSave()
                }

            if !compact {
                Text("Private notes for this meeting. Included in searchable memory when Memory is on.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear {
            draft = meeting.userNotes ?? ""
        }
        .onChange(of: meeting.id) { _, _ in
            draft = meeting.userNotes ?? ""
        }
        .onDisappear {
            saveTask?.cancel()
            commit()
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            commit()
        }
    }

    private func commit() {
        let current = meeting.userNotes ?? ""
        guard draft != current else { return }
        appState.saveUserNotes(draft, for: meeting)
    }
}
