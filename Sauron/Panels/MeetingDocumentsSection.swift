import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Shared Attach / Reveal / Remove UI for meeting-scoped documents.
struct MeetingDocumentsSection: View {
    @Environment(AppState.self) private var appState
    let meeting: Meeting
    var compact: Bool = false

    @State private var documents: [MeetingDocument] = []
    @State private var isBusy = false
    @State private var statusMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 10) {
            if !compact {
                // Title is provided by Report `reportBlock`.
                EmptyView()
            } else {
                HStack {
                    DashboardOverline(text: "Documents")
                    Spacer()
                    if isBusy {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            }

            if documents.isEmpty {
                Text(compact ? "No attached files." : "Attach PDF, text, Markdown, or RTF files to include them in searchable meeting memory.")
                    .font(compact ? .system(size: 12) : .callout)
                    .foregroundStyle(compact ? SauronTheme.textSecondary : .secondary)
            } else {
                ForEach(documents) { document in
                    documentRow(document)
                }
            }

            HStack(spacing: 8) {
                Button(compact ? "Attach…" : "Attach documents…") {
                    chooseAndAttach()
                }
                .disabled(isBusy)
                if compact {
                    Spacer(minLength: 0)
                }
                if isBusy, !compact {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if let statusMessage, !statusMessage.isEmpty {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(compact ? SauronTheme.textSecondary : .secondary)
            }
        }
        .onAppear { reload() }
        .onChange(of: meeting.id) { _, _ in reload() }
    }

    @ViewBuilder
    private func documentRow(_ document: MeetingDocument) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "doc.text")
                .foregroundStyle(compact ? SauronTheme.textSecondary : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(document.originalName)
                    .font(compact ? .system(size: 12, weight: .medium) : .subheadline.weight(.medium))
                    .lineLimit(1)
                    .foregroundStyle(compact ? SauronTheme.textPrimary : .primary)
                Text(byteLabel(document.byteCount))
                    .font(compact ? .system(size: 11) : .caption)
                    .foregroundStyle(compact ? SauronTheme.textSecondary : .secondary)
            }
            Spacer(minLength: 4)
            Button {
                reveal(document)
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
            .help("Reveal in Finder")
            .disabled(isBusy)
            Button(role: .destructive) {
                remove(document)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Remove")
            .disabled(isBusy)
        }
        .padding(.vertical, compact ? 2 : 4)
    }

    private func reload() {
        documents = appState.meetingDocuments(for: meeting)
    }

    private func chooseAndAttach() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = DocumentTextExtractor.supportedContentTypes
        panel.prompt = "Attach"
        panel.message = "Choose PDF, text, Markdown, or RTF files to attach to this meeting."
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let urls = panel.urls
        isBusy = true
        statusMessage = "Indexing attached documents…"
        Task {
            defer {
                isBusy = false
                reload()
            }
            do {
                let attached = try await appState.attachDocuments(to: meeting, urls: urls)
                statusMessage = attached.isEmpty
                    ? nil
                    : "Attached \(attached.count) file\(attached.count == 1 ? "" : "s")."
            } catch {
                statusMessage = error.localizedDescription
            }
        }
    }

    private func remove(_ document: MeetingDocument) {
        isBusy = true
        statusMessage = "Updating memory index…"
        Task {
            defer {
                isBusy = false
                reload()
            }
            do {
                try await appState.removeDocument(document, from: meeting)
                statusMessage = nil
            } catch {
                statusMessage = error.localizedDescription
            }
        }
    }

    private func reveal(_ document: MeetingDocument) {
        let url = MeetingDocumentStore.fileURL(for: document, meetingID: meeting.id)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func byteLabel(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
