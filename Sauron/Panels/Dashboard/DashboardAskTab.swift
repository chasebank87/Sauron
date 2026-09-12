import SwiftUI

struct DashboardAskTab: View {
    @Environment(AppState.self) private var appState
    var initialQuery: String? = nil

    @State private var threads: [DashboardChatThread] = []
    @State private var selectedID: UUID?
    @State private var draft = ""
    @State private var isSending = false
    @State private var streamBuffer = ""
    @State private var retrievalLine = ""
    @State private var liveCitations: [MemoryCitation] = []
    @State private var errorText = ""
    @State private var showSources = true
    @State private var scopeDays: Int = 0
    @State private var isSelectingThreads = false
    @State private var checkedThreadIDs: Set<UUID> = []
    @State private var pendingDeleteThreadIDs: Set<UUID> = []
    @State private var showDeleteThreadsConfirm = false
    @State private var renamingThreadID: UUID?
    @State private var renameDraft = ""
    @State private var showRenameSheet = false

    var body: some View {
        HStack(spacing: 0) {
            threadRail
                .frame(width: 220)
            Divider().overlay(SauronTheme.hairlineStrong)
            conversation
            if showSources {
                Divider().overlay(SauronTheme.hairlineStrong)
                sourcesRail
                    .frame(width: 280)
            }
        }
        .onAppear {
            reload()
            if let initialQuery, !initialQuery.isEmpty {
                draft = initialQuery
                Task { await send() }
            }
        }
        .onChange(of: isSelectingThreads) { _, selecting in
            if !selecting { checkedThreadIDs = [] }
        }
        .confirmationDialog(
            pendingDeleteThreadIDs.count == 1 ? "Delete this thread?" : "Delete \(pendingDeleteThreadIDs.count) threads?",
            isPresented: $showDeleteThreadsConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete \(pendingDeleteThreadIDs.count) thread\(pendingDeleteThreadIDs.count == 1 ? "" : "s")", role: .destructive) {
                confirmDeleteThreads()
            }
            Button("Cancel", role: .cancel) {
                pendingDeleteThreadIDs = []
            }
        } message: {
            Text("Chat history for these threads will be removed from this Mac. This can’t be undone.")
        }
        .sheet(isPresented: $showRenameSheet) {
            renameSheet
        }
    }

    private var renameSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename thread")
                .font(.headline)
            TextField("Title", text: $renameDraft)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") {
                    showRenameSheet = false
                    renamingThreadID = nil
                }
                .observerGlassButton()
                Button("Save") {
                    if let id = renamingThreadID {
                        DashboardChatStore.shared.rename(id: id, title: renameDraft)
                        reload()
                    }
                    showRenameSheet = false
                    renamingThreadID = nil
                }
                .observerGlassProminentButton()
                .disabled(renameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    private var selected: DashboardChatThread? {
        threads.first { $0.id == selectedID } ?? threads.first
    }

    private var threadRail: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("Threads")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(SauronTheme.textPrimary)
                Spacer()
                if isSelectingThreads {
                    Button("Done") {
                        isSelectingThreads = false
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(SauronTheme.irisSolid)
                } else {
                    Button {
                        isSelectingThreads = true
                    } label: {
                        Image(systemName: "checkmark.circle")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(SauronTheme.textSecondary)
                    .disabled(threads.isEmpty)
                    .help("Select threads")

                    Button {
                        let thread = DashboardChatThread()
                        DashboardChatStore.shared.upsert(thread)
                        reload()
                        selectedID = thread.id
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(SauronTheme.irisSolid)
                    .help("New thread")
                }
            }
            .padding(16)

            if isSelectingThreads {
                HStack(spacing: 8) {
                    Button("Select all") {
                        checkedThreadIDs = Set(threads.map(\.id))
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(SauronTheme.irisSolid)
                    .disabled(threads.isEmpty || checkedThreadIDs.count == threads.count)

                    Spacer()

                    Button("Delete", role: .destructive) {
                        requestDeleteThreads(checkedThreadIDs)
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(SauronTheme.red)
                    .disabled(checkedThreadIDs.isEmpty)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)

                Text(checkedThreadIDs.isEmpty
                     ? "Select threads to delete."
                     : "\(checkedThreadIDs.count) selected")
                    .font(.system(size: 11))
                    .foregroundStyle(SauronTheme.textTertiary)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }

            if !appState.settings.memoryEnabled {
                Text("Memory is off — answers won’t cite past meetings.")
                    .font(.system(size: 11))
                    .foregroundStyle(SauronTheme.amber)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }

            List {
                ForEach(threads) { thread in
                    threadRow(thread)
                        .tag(thread.id)
                        .listRowBackground(
                            (!isSelectingThreads && selectedID == thread.id)
                                ? SauronTheme.surfaceElevated
                                : SauronTheme.surface.opacity(0.001)
                        )
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
        .background(SauronTheme.surfaceSunken)
    }

    private func threadRow(_ thread: DashboardChatThread) -> some View {
        let checked = checkedThreadIDs.contains(thread.id)
        return HStack(spacing: 8) {
            if isSelectingThreads {
                Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(checked ? SauronTheme.irisSolid : SauronTheme.textTertiary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(thread.title)
                    .lineLimit(1)
                    .foregroundStyle(SauronTheme.textPrimary)
                Text(thread.updatedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 10))
                    .foregroundStyle(SauronTheme.textTertiary)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if isSelectingThreads {
                toggleThreadCheck(thread.id)
            } else {
                selectedID = thread.id
            }
        }
        .contextMenu {
            if !isSelectingThreads {
                Button("Rename…") { beginRename(thread.id) }
                Button("Delete…", role: .destructive) { requestDeleteThreads([thread.id]) }
            }
        }
    }

    private func toggleThreadCheck(_ id: UUID) {
        if checkedThreadIDs.contains(id) {
            checkedThreadIDs.remove(id)
        } else {
            checkedThreadIDs.insert(id)
        }
    }

    private func beginRename(_ id: UUID) {
        guard let thread = threads.first(where: { $0.id == id }) else { return }
        renamingThreadID = id
        renameDraft = thread.title
        showRenameSheet = true
    }

    private func requestDeleteThreads(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        pendingDeleteThreadIDs = ids
        showDeleteThreadsConfirm = true
    }

    private func requestDeleteThreads(_ ids: [UUID]) {
        requestDeleteThreads(Set(ids))
    }

    private func confirmDeleteThreads() {
        let ids = pendingDeleteThreadIDs
        pendingDeleteThreadIDs = []
        DashboardChatStore.shared.delete(ids: ids)
        checkedThreadIDs.subtract(ids)
        if let selectedID, ids.contains(selectedID) {
            self.selectedID = nil
        }
        reload()
        if checkedThreadIDs.isEmpty {
            isSelectingThreads = false
        }
    }

    private var conversation: some View {
        VStack(spacing: 0) {
            HStack {
                DashboardScreenHeader(title: "Ask")
                Spacer()
                if let selected {
                    Menu {
                        Button("Rename…") { beginRename(selected.id) }
                        Button("Delete thread…", role: .destructive) {
                            requestDeleteThreads([selected.id])
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .observerGlassButton()
                }
                Button {
                    showSources.toggle()
                } label: {
                    Label(showSources ? "Hide sources" : "Sources", systemImage: "sidebar.right")
                }
                .observerGlassButton()
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        if let selected, selected.messages.isEmpty, streamBuffer.isEmpty {
                            starterPrompts
                        }
                        if let selected {
                            ForEach(selected.messages) { message in
                                messageBlock(message)
                                    .id(message.id)
                            }
                        }
                        if isSending || !streamBuffer.isEmpty {
                            streamingBlock
                                .id("stream")
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: 760)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: streamBuffer) { _, _ in
                    proxy.scrollTo("stream", anchor: .bottom)
                }
            }

            if !errorText.isEmpty {
                Text(errorText)
                    .font(.system(size: 12))
                    .foregroundStyle(SauronTheme.amber)
                    .padding(.horizontal, 24)
            }

            composer
        }
    }

    private var starterPrompts: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Start with intent")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(SauronTheme.textPrimary)
            ForEach([
                ("Recall", "What did we decide recently?"),
                ("Commitments", "What did I promise this week?"),
                ("Prep", "Brief me from my last meeting")
            ], id: \.0) { group in
                Button {
                    draft = group.1
                    Task { await send() }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(group.0)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(SauronTheme.irisSolid)
                            Text(group.1)
                                .font(.system(size: 13))
                                .foregroundStyle(SauronTheme.textPrimary)
                        }
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .foregroundStyle(SauronTheme.textTertiary)
                    }
                    .padding(14)
                    .observerSurfaceCard()
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func messageBlock(_ message: DashboardChatMessage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(message.role == "user" ? "You" : "Sauron")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(SauronTheme.textTertiary)
            if message.role == "user" {
                Text(message.content)
                    .font(.system(size: 13))
                    .foregroundStyle(SauronTheme.textPrimary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .frame(maxWidth: .infinity, alignment: .trailing)
            } else {
                if !message.citations.isEmpty {
                    Text("Retrieved \(message.citations.count) chunks from \(Set(message.citations.map(\.meetingID)).count) meetings")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(SauronTheme.textSecondary)
                }
                Text(message.content)
                    .font(.system(size: 13))
                    .foregroundStyle(SauronTheme.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !message.citations.isEmpty {
                    FlowCitationChips(citations: message.citations)
                }
            }
        }
    }

    private var streamingBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Sauron")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(SauronTheme.textTertiary)
            if !retrievalLine.isEmpty {
                Label(retrievalLine, systemImage: "sparkles")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(SauronTheme.irisSolid)
            }
            if streamBuffer.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(0..<3, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 4)
                            .fill(SauronTheme.surfaceElevated)
                            .frame(height: 10)
                            .overlay(SauronTheme.irisGradient.opacity(0.25))
                    }
                }
            } else {
                Text(streamBuffer)
                    .font(.system(size: 13))
                    .foregroundStyle(SauronTheme.textPrimary)
            }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                scopeChip("All meetings", days: 0)
                scopeChip("Last 30 days", days: 30)
                Spacer()
                if isSending {
                    Button("Stop") {
                        // Soft stop: clear sending UI; in-flight task ends naturally.
                        isSending = false
                        streamBuffer = ""
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(SauronTheme.red)
                    .buttonStyle(.plain)
                }
            }
            HStack(alignment: .bottom, spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(SauronTheme.irisGradient)
                    .padding(.bottom, 8)
                TextField("Ask about past meetings…", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...6)
                    .font(.system(size: 14))
                    .foregroundStyle(SauronTheme.textPrimary)
                Button(action: { Task { await send() } }) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(SauronTheme.irisGradient, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(isSending || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(SauronTheme.surfaceElevated, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(SauronTheme.irisSolid.opacity(isSending ? 0.55 : 0.35), lineWidth: 1)
            )
        }
        .padding(16)
        .background(SauronTheme.canvas.opacity(0.85))
    }

    private func scopeChip(_ title: String, days: Int) -> some View {
        Button(title) { scopeDays = days }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(scopeDays == days ? SauronTheme.textPrimary : SauronTheme.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                scopeDays == days ? SauronTheme.irisSolid.opacity(0.25) : SauronTheme.surface,
                in: Capsule()
            )
            .buttonStyle(.plain)
    }

    private var sourcesRail: some View {
        VStack(alignment: .leading, spacing: 12) {
            DashboardOverline(text: "Sources")
            let citations = liveCitations.isEmpty
                ? (selected?.messages.last(where: { !$0.citations.isEmpty })?.citations ?? [])
                : liveCitations
            if citations.isEmpty {
                Text("Cited meetings appear here after an answer.")
                    .font(.system(size: 12))
                    .foregroundStyle(SauronTheme.textSecondary)
            } else {
                ForEach(deduped(citations)) { citation in
                    SourceCardView(citation: citation) {
                        if let meeting = MeetingStore.meeting(id: citation.meetingID, context: appState.modelContext) {
                            appState.openReport(meeting)
                        }
                    }
                }
            }
            Spacer()
        }
        .padding(16)
        .background(SauronTheme.surfaceSunken)
    }

    private func deduped(_ citations: [MemoryCitation]) -> [MemoryCitation] {
        var seen = Set<UUID>()
        return citations.filter { seen.insert($0.meetingID).inserted }
    }

    private func reload() {
        threads = DashboardChatStore.shared.allThreads()
        if selectedID == nil {
            selectedID = threads.first?.id
        }
    }

    private func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        var thread = selected ?? DashboardChatThread()
        if selected == nil {
            DashboardChatStore.shared.upsert(thread)
            selectedID = thread.id
        }
        draft = ""
        errorText = ""
        isSending = true
        streamBuffer = ""
        liveCitations = []
        defer { isSending = false }

        thread.messages.append(DashboardChatMessage(role: "user", content: text))
        if thread.title == "New chat" {
            thread.title = String(text.prefix(48))
        }
        thread.updatedAt = .now
        DashboardChatStore.shared.upsert(thread)
        reload()

        let injectMemory = appState.settings.shouldInjectMemoryIntoPrompts
        let memory: (context: String, citations: [MemoryCitation])
        if injectMemory {
            retrievalLine = "Searching memory…"
            memory = await MeetingMemoryIndexer.retrieveContext(query: text, appState: appState)
            liveCitations = memory.citations
            retrievalLine = memory.citations.isEmpty
                ? "No strong matches — answering carefully"
                : "Reading \(memory.citations.count) excerpts…"
        } else {
            memory = ("", [])
            liveCitations = []
            retrievalLine = appState.settings.memoryEnabled
                ? "Agent may search memory via MCP…"
                : "Memory off — answering without past meetings"
        }
        do {
            let (client, modelID) = try appState.makeClient()
            let models = (try? await client.listModels()) ?? []
            let model = modelID.isEmpty ? (models.first?.id ?? OpenRouterProvider.suggestedModel) : modelID
            var system: String
            if injectMemory {
                system = """
                You are Sauron's meeting memory assistant. Answer using the provided past-meeting excerpts when available.
                Cite meeting titles when you rely on them. If excerpts are empty, say you don't have indexed meeting memory yet.
                """
                if !memory.context.isEmpty {
                    system += "\n\nExcerpts:\n\(memory.context)"
                }
            } else {
                system = """
                You are Sauron's meeting memory assistant.
                \(MemoryMCPHints.systemPromptAddon)
                Cite meeting titles when you rely on them. If you cannot search memory, say so.
                """
            }
            var messages = [ChatMessage(role: "system", content: system)]
            for prior in thread.messages.suffix(12) {
                messages.append(ChatMessage(role: prior.role, content: prior.content))
            }
            retrievalLine = "Writing…"
            var answer = ""
            for try await chunk in client.streamChat(model: model, messages: messages) {
                guard isSending else { break }
                answer += chunk
                streamBuffer = answer
            }
            streamBuffer = ""
            retrievalLine = ""
            guard !answer.isEmpty else { return }
            thread.messages.append(
                DashboardChatMessage(role: "assistant", content: answer, citations: memory.citations)
            )
            thread.updatedAt = .now
            DashboardChatStore.shared.upsert(thread)
            reload()
        } catch {
            errorText = error.localizedDescription
            streamBuffer = ""
            retrievalLine = ""
        }
    }
}

private struct FlowCitationChips: View {
    let citations: [MemoryCitation]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(citations.prefix(4).enumerated()), id: \.element.id) { index, citation in
                Text("\(index + 1)  \(citation.meetingTitle)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(SauronTheme.textSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(SauronTheme.surfaceElevated, in: Capsule())
                    .lineLimit(1)
            }
        }
    }
}
