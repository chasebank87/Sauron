import AppKit
import SwiftUI

struct DashboardMemoryTab: View {
    @Environment(AppState.self) private var appState
    @State private var status = ""
    @State private var busy = false
    @State private var playgroundQuery = ""
    @State private var playgroundHits: [MemoryCitation] = []

    var body: some View {
        @Bindable var settings = appState.settings
        HStack(alignment: .top, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    DashboardScreenHeader(title: "Memory", subtitle: "Local index health and retrieval controls.")

                    indexHealth

                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("Remember past meetings", isOn: $settings.memoryEnabled)
                            .onChange(of: settings.memoryEnabled) { _, _ in
                                appState.syncMemoryMCPServer()
                            }
                        if settings.usesSeparateEmbeddingProvider {
                            Picker("Embeddings backend", selection: $settings.embeddingProviderKind) {
                                ForEach(LLMProviderKind.embeddingBackends) { kind in
                                    Text(kind.displayName).tag(kind)
                                }
                            }
                            Text("Hermes and OpenClaw don’t host embeddings — pick Ollama, LM Studio, or OpenRouter for the memory index. URLs and keys come from Settings → Models.")
                                .font(.system(size: 11))
                                .foregroundStyle(SauronTheme.textTertiary)
                        }
                        DashboardTextField(
                            placeholder: SettingsStore.defaultEmbeddingModel(for: settings.resolvedEmbeddingProviderKind),
                            text: $settings.embeddingModelID
                        )
                        Stepper("Top-k results: \(settings.memoryTopK)", value: $settings.memoryTopK, in: 2...12)
                        Text("≈ \(settings.memoryTopK * 180) tokens per query (estimate)")
                            .font(.system(size: 11))
                            .foregroundStyle(SauronTheme.textTertiary)
                    }
                    .padding(16)
                    .observerSurfaceCard()

                    mcpServerCard

                    privacyCard

                    HStack(spacing: 10) {
                        Button(busy ? "Working…" : "Test embeddings") {
                            Task { await testEmbeddings() }
                        }
                        .observerGlassButton()
                        .disabled(busy)
                        Button(busy ? "Working…" : "Rebuild index") {
                            Task { await rebuild() }
                        }
                        .observerGlassProminentButton()
                        .disabled(busy || !settings.memoryEnabled)
                    }

                    if !status.isEmpty {
                        Text(status)
                            .font(.system(size: 12))
                            .foregroundStyle(SauronTheme.textSecondary)
                    }
                }
                .padding(24)
            }
            .frame(maxWidth: .infinity)

            Divider().overlay(SauronTheme.hairlineStrong)

            playground
                .frame(width: 360)
        }
    }

    private var indexHealth: some View {
        let chunks = MeetingMemoryStore.shared.chunkCount
        let meetings = MeetingMemoryStore.shared.meetingIDs().count
        return HStack(spacing: 16) {
            ZStack {
                Circle()
                    .stroke(SauronTheme.surfaceElevated, lineWidth: 10)
                Circle()
                    .trim(from: 0, to: chunks == 0 ? 0.05 : min(1, Double(chunks) / 500))
                    .stroke(SauronTheme.irisGradient, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 2) {
                    Text("\(chunks)")
                        .font(.system(size: 20, weight: .semibold).monospacedDigit())
                        .foregroundStyle(SauronTheme.textPrimary)
                    Text("chunks")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(SauronTheme.textTertiary)
                }
            }
            .frame(width: 96, height: 96)

            VStack(alignment: .leading, spacing: 8) {
                meta("Meetings covered", "\(meetings)")
                if let rebuilt = MeetingMemoryStore.shared.lastRebuild {
                    meta("Last built", rebuilt.formatted(date: .abbreviated, time: .shortened))
                }
                meta("Model", appState.settings.resolvedEmbeddingModelID)
                if appState.settings.usesSeparateEmbeddingProvider {
                    meta("Embeddings via", appState.settings.resolvedEmbeddingProviderKind.displayName)
                }
            }
            Spacer()
        }
        .padding(16)
        .observerSurfaceCard()
    }

    private var privacyCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "lock.shield")
                .foregroundStyle(SauronTheme.irisSolid)
            Text("The memory index is stored only on this Mac. Embedding requests send short text chunks to your selected provider to compute vectors; Sauron does not host your meetings in the cloud. Retrieved snippets may be sent to your chat model when summarizing or asking. Hermes/OpenClaw use MCP tools instead of prompt injection.")
                .font(.system(size: 12))
                .foregroundStyle(SauronTheme.textSecondary)
        }
        .padding(16)
        .observerSurfaceCard()
    }

    private var mcpServerCard: some View {
        @Bindable var settings = appState.settings
        let token = KeychainStore.mcpServerToken
        let server = appState.memoryMCPServer
        return VStack(alignment: .leading, spacing: 12) {
            Toggle("Expose memory over MCP", isOn: $settings.mcpServerEnabled)
                .disabled(!settings.memoryEnabled)
                .onChange(of: settings.mcpServerEnabled) { _, _ in
                    appState.syncMemoryMCPServer()
                }
            Text(server.state.statusLabel)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(server.state.isListening ? SauronTheme.irisSolid : SauronTheme.textSecondary)
            if let last = server.lastToolCallAt {
                Text("Last tool: \(server.lastToolName ?? "—") · \(last.formatted(date: .omitted, time: .shortened))")
                    .font(.system(size: 11))
                    .foregroundStyle(SauronTheme.textTertiary)
            }
            HStack(spacing: 8) {
                Text("Port")
                    .foregroundStyle(SauronTheme.textSecondary)
                TextField("8787", value: $settings.mcpServerPort, format: .number.grouping(.never))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                    .onSubmit { appState.syncMemoryMCPServer() }
                Button("Apply") { appState.syncMemoryMCPServer() }
                    .observerGlassButton()
            }
            .disabled(!settings.memoryEnabled || !settings.mcpServerEnabled)

            VStack(alignment: .leading, spacing: 6) {
                Text("Endpoint")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(SauronTheme.textTertiary)
                Text(settings.mcpEndpointURL.absoluteString)
                    .font(.system(size: 12).monospaced())
                    .textSelection(.enabled)
                    .foregroundStyle(SauronTheme.textSecondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Bearer token")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(SauronTheme.textTertiary)
                    Spacer()
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(token, forType: .string)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(SauronTheme.irisSolid)
                    Button("Rotate") {
                        KeychainStore.rotateMCPServerToken()
                        appState.syncMemoryMCPServer()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(SauronTheme.irisSolid)
                }
                Text(token)
                    .font(.system(size: 11).monospaced())
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .foregroundStyle(SauronTheme.textSecondary)
            }

            DisclosureGroup("Hermes config snippet") {
                snippetBlock(settings.hermesMCPSnippet(token: token))
            }
            DisclosureGroup("OpenClaw config snippet") {
                snippetBlock(settings.openClawMCPSnippet(token: token))
            }

            Text("Loopback only. Hermes and OpenClaw must be configured to call this MCP URL while Sauron is running. Other providers still receive memory excerpts in the prompt.")
                .font(.system(size: 11))
                .foregroundStyle(SauronTheme.textTertiary)
        }
        .padding(16)
        .observerSurfaceCard()
        .onAppear { appState.syncMemoryMCPServer() }
    }

    private func snippetBlock(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text)
                .font(.system(size: 11).monospaced())
                .textSelection(.enabled)
                .foregroundStyle(SauronTheme.textSecondary)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(SauronTheme.surfaceElevated, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            Button("Copy snippet") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            .observerGlassButton()
        }
        .padding(.top, 6)
    }

    private var playground: some View {
        VStack(alignment: .leading, spacing: 12) {
            DashboardOverline(text: "Retrieval playground")
            Text("Run a query against the local index and inspect ranked chunks.")
                .font(.system(size: 12))
                .foregroundStyle(SauronTheme.textSecondary)
            DashboardSearchField(
                placeholder: "Try a retrieval query…",
                text: $playgroundQuery,
                systemImage: "sparkles"
            )
            Button("Run") {
                Task { await runPlayground() }
            }
            .observerGlassProminentButton()
            .disabled(busy || playgroundQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if playgroundHits.isEmpty {
                        Text("Results appear here.")
                            .font(.system(size: 12))
                            .foregroundStyle(SauronTheme.textTertiary)
                    } else {
                        ForEach(playgroundHits) { hit in
                            SourceCardView(citation: hit) {
                                if let meeting = MeetingStore.meeting(id: hit.meetingID, context: appState.modelContext) {
                                    appState.openReport(meeting)
                                }
                            }
                        }
                    }
                }
            }
            Spacer()
        }
        .padding(20)
        .background(SauronTheme.surfaceSunken)
    }

    private func meta(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(SauronTheme.textTertiary)
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(SauronTheme.textPrimary)
                .lineLimit(1)
        }
    }

    private func testEmbeddings() async {
        busy = true
        defer { busy = false }
        do {
            let (client, model) = try appState.makeEmbeddingClient()
            let vectors = try await client.embed(model: model, texts: ["Sauron memory probe"])
            status = "OK — \(vectors.first?.count ?? 0)-dim vector from \(model) (\(appState.settings.resolvedEmbeddingProviderKind.displayName))"
        } catch {
            status = error.localizedDescription
        }
    }

    private func rebuild() async {
        busy = true
        defer { busy = false }
        await MeetingMemoryIndexer.rebuildAll(appState: appState)
        status = "Rebuilt \(MeetingMemoryStore.shared.chunkCount) chunks."
    }

    private func runPlayground() async {
        busy = true
        defer { busy = false }
        let result = await MeetingMemoryIndexer.retrieveContext(query: playgroundQuery, appState: appState)
        playgroundHits = result.citations
        status = playgroundHits.isEmpty ? "No hits above threshold." : "\(playgroundHits.count) hits."
    }
}

/// Shared Memory settings panel for Settings window.
struct MemorySettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        DashboardMemoryTab()
            .environment(appState)
            .observerDashboardCanvas()
    }
}
