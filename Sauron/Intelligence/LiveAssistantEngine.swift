import Foundation

/// Extracts insights / claims / questions from the live transcript and optionally
/// fact-checks or researches them with Tavily.
@MainActor
final class LiveAssistantEngine {
    private(set) var cards: [LiveAssistCard] = []

    var onCardsChanged: (@MainActor ([LiveAssistCard]) -> Void)?

    private var pendingFinals: [LiveSegment] = []
    private var lastExtractionAt: Date = .distantPast
    private var lastSearchAt: Date = .distantPast
    private var searchCount = 0
    private var seenFingerprints = Set<String>()
    private var runningTask: Task<Void, Never>?
    private var isRunning = false

    private let extractionInterval: TimeInterval = 45
    private let minFinalsBeforeExtract = 3

    func start() {
        stop()
        cards = []
        pendingFinals = []
        lastExtractionAt = .distantPast
        lastSearchAt = .distantPast
        searchCount = 0
        seenFingerprints = []
        isRunning = true
        onCardsChanged?([])
    }

    func stop() -> [LiveAssistCard] {
        isRunning = false
        runningTask?.cancel()
        runningTask = nil
        let snapshot = cards
        pendingFinals = []
        onCardsChanged?(snapshot)
        return snapshot
    }

    func ingest(final segment: LiveSegment, appState: AppState) {
        guard isRunning else { return }
        guard segment.isFinal else { return }
        let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        pendingFinals.append(segment)
        if pendingFinals.count >= minFinalsBeforeExtract,
           Date().timeIntervalSince(lastExtractionAt) >= extractionInterval {
            scheduleExtraction(appState: appState)
        }
    }

    private func scheduleExtraction(appState: AppState) {
        guard runningTask == nil else { return }
        let window = Array(pendingFinals.suffix(12))
        pendingFinals.removeAll()
        lastExtractionAt = .now
        runningTask = Task { [weak self] in
            defer {
                Task { @MainActor in
                    self?.runningTask = nil
                }
            }
            await self?.extract(from: window, appState: appState)
        }
    }

    private func extract(from segments: [LiveSegment], appState: AppState) async {
        guard isRunning, !segments.isEmpty else { return }
        let transcript = segments.map { segment in
            let name = SpeakerProfileStore.shared.displayName(for: segment.speakerKey)
            return "\(name): \(segment.text)"
        }.joined(separator: "\n")

        let memory = await MeetingMemoryIndexer.retrieveContext(query: transcript, appState: appState)
        if let top = memory.citations.first, top.score >= 0.42 {
            let snippet = String(top.text.prefix(280))
            append(
                LiveAssistCard(
                    kind: .memory,
                    title: "From past meetings",
                    body: "\(top.meetingTitle)\n\n\(snippet)",
                    sources: [
                        LiveAssistSource(title: top.meetingTitle, url: "observer://meeting/\(top.meetingID.uuidString)")
                    ]
                )
            )
        }

        let injectMemory = appState.settings.shouldInjectMemoryIntoPrompts
        var systemContent = """
                You assist during a live meeting. From the recent transcript, extract at most 2 items.
                Return JSON only: {"items":[{"type":"insight"|"claim"|"question","text":"...","speaker":null}]}
                - insight: short helpful note (no web needed)
                - claim: a factual assertion worth checking
                - question: a research-worthy question
                Do not invent content. If nothing useful, return {"items":[]}.
                """
        if injectMemory, !memory.context.isEmpty {
            systemContent += "\nPast meeting context (optional continuity):\n\(memory.context)"
        } else if !injectMemory, appState.settings.memoryEnabled {
            systemContent += "\n\(MemoryMCPHints.systemPromptAddon)"
        }

        let messages = [
            ChatMessage(role: "system", content: systemContent),
            ChatMessage(role: "user", content: transcript)
        ]

        do {
            let (client, modelID) = try appState.makeClient()
            let models = (try? await client.listModels()) ?? []
            let model = modelID.isEmpty ? (models.first?.id ?? OpenRouterProvider.suggestedModel) : modelID
            let raw = try await client.complete(model: model, messages: messages)
            let items = Self.parseItems(raw)
            for item in items {
                await publish(item: item, appState: appState)
            }
        } catch {
            // Soft-fail: live assist is optional.
        }
    }

    private func publish(item: ExtractedItem, appState: AppState) async {
        let fingerprint = item.type + "|" + item.text.lowercased()
        guard !seenFingerprints.contains(fingerprint) else { return }
        seenFingerprints.insert(fingerprint)

        switch item.type {
        case "insight":
            append(
                LiveAssistCard(
                    kind: .insight,
                    title: "Insight",
                    body: item.text,
                    speakerKey: item.speakerKey
                )
            )
        case "claim":
            await factCheck(claim: item.text, speakerKey: item.speakerKey, appState: appState)
        case "question":
            await research(question: item.text, speakerKey: item.speakerKey, appState: appState)
        default:
            break
        }
    }

    private func factCheck(claim: String, speakerKey: String?, appState: AppState) async {
        let settings = appState.settings
        guard settings.liveResearchEnabled,
              searchCount < settings.maxResearchQueriesPerMeeting,
              Date().timeIntervalSince(lastSearchAt) >= settings.researchCooldownSeconds
        else {
            append(
                LiveAssistCard(
                    kind: .factCheck,
                    title: "Claim",
                    body: claim,
                    verdict: .unclear,
                    speakerKey: speakerKey
                )
            )
            return
        }

        if settings.providerKind.providesBuiltInWebResearch {
            await agentResearch(
                prompt: claim,
                mode: .factCheck,
                speakerKey: speakerKey,
                appState: appState
            )
            return
        }

        guard let key = KeychainStore.tavilyAPIKey, !key.isEmpty else {
            append(
                LiveAssistCard(
                    kind: .factCheck,
                    title: "Claim",
                    body: claim,
                    verdict: .unclear,
                    speakerKey: speakerKey
                )
            )
            return
        }

        do {
            let client = TavilyClient(apiKey: key)
            if settings.tavilyAPIMode == .research {
                let response = try await client.research(query: claim, options: settings.tavilyResearchOptions)
                searchCount += 1
                lastSearchAt = .now
                let sources = response.sources.prefix(3).map {
                    LiveAssistSource(title: $0.title, url: $0.url)
                }
                let report = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
                append(
                    LiveAssistCard(
                        kind: .factCheck,
                        title: "Fact-check",
                        body: report.isEmpty ? claim : "\(claim)\n\n\(report)",
                        sources: Array(sources),
                        verdict: Self.verdict(fromText: report, hasSources: !sources.isEmpty),
                        speakerKey: speakerKey
                    )
                )
            } else {
                let response = try await client.search(query: claim, options: settings.tavilySearchOptions)
                searchCount += 1
                lastSearchAt = .now
                let sources = response.results.prefix(min(3, settings.tavilyMaxResults)).map {
                    LiveAssistSource(title: $0.title, url: $0.url)
                }
                let answer = response.answer?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                append(
                    LiveAssistCard(
                        kind: .factCheck,
                        title: "Fact-check",
                        body: answer.isEmpty ? claim : "\(claim)\n\n\(answer)",
                        sources: Array(sources),
                        verdict: Self.verdict(fromText: answer, hasSources: !sources.isEmpty),
                        speakerKey: speakerKey
                    )
                )
            }
        } catch {
            append(
                LiveAssistCard(
                    kind: .factCheck,
                    title: "Claim",
                    body: claim,
                    verdict: .unclear,
                    speakerKey: speakerKey
                )
            )
        }
    }

    private func research(question: String, speakerKey: String?, appState: AppState) async {
        let settings = appState.settings
        guard settings.liveResearchEnabled,
              searchCount < settings.maxResearchQueriesPerMeeting,
              Date().timeIntervalSince(lastSearchAt) >= settings.researchCooldownSeconds
        else {
            append(
                LiveAssistCard(
                    kind: .research,
                    title: "Question",
                    body: question,
                    speakerKey: speakerKey
                )
            )
            return
        }

        if settings.providerKind.providesBuiltInWebResearch {
            await agentResearch(
                prompt: question,
                mode: .research,
                speakerKey: speakerKey,
                appState: appState
            )
            return
        }

        guard let key = KeychainStore.tavilyAPIKey, !key.isEmpty else {
            append(
                LiveAssistCard(
                    kind: .research,
                    title: "Question",
                    body: question,
                    speakerKey: speakerKey
                )
            )
            return
        }

        do {
            let client = TavilyClient(apiKey: key)
            let useResearchAPI = settings.tavilyAPIMode == .research || settings.tavilyAPIMode == .auto
            if useResearchAPI {
                let response = try await client.research(query: question, options: settings.tavilyResearchOptions)
                searchCount += 1
                lastSearchAt = .now
                let sources = response.sources.prefix(4).map {
                    LiveAssistSource(title: $0.title, url: $0.url)
                }
                let report = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
                append(
                    LiveAssistCard(
                        kind: .research,
                        title: "Research",
                        body: report.isEmpty ? question : "\(question)\n\n\(report)",
                        sources: Array(sources),
                        speakerKey: speakerKey
                    )
                )
            } else {
                let response = try await client.search(query: question, options: settings.tavilySearchOptions)
                searchCount += 1
                lastSearchAt = .now
                let sources = response.results.prefix(min(3, settings.tavilyMaxResults)).map {
                    LiveAssistSource(title: $0.title, url: $0.url)
                }
                let answer = response.answer?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                append(
                    LiveAssistCard(
                        kind: .research,
                        title: "Research",
                        body: answer.isEmpty ? question : "\(question)\n\n\(answer)",
                        sources: Array(sources),
                        speakerKey: speakerKey
                    )
                )
            }
        } catch {
            append(
                LiveAssistCard(
                    kind: .research,
                    title: "Question",
                    body: question,
                    speakerKey: speakerKey
                )
            )
        }
    }

    private enum AgentResearchMode {
        case factCheck
        case research
    }

    /// Hermes / OpenClaw already have web tools — ask the agent instead of Tavily.
    private func agentResearch(
        prompt: String,
        mode: AgentResearchMode,
        speakerKey: String?,
        appState: AppState
    ) async {
        let system: String
        switch mode {
        case .factCheck:
            system = """
            You are assisting during a live meeting. Fact-check the claim using your tools if needed.
            Reply with a short assessment (2-6 sentences). Mention if it is supported, contested, or unclear.
            Include source titles/URLs when you have them. Do not invent sources.
            \(MemoryMCPHints.systemPromptAddon)
            """
        case .research:
            system = """
            You are assisting during a live meeting. Briefly research the question using your tools if needed.
            Reply with a concise answer (3-8 sentences) useful mid-meeting. Include source titles/URLs when available.
            Do not invent sources.
            \(MemoryMCPHints.systemPromptAddon)
            """
        }

        do {
            let (client, modelID) = try appState.makeClient()
            let models = (try? await client.listModels()) ?? []
            let fallback = appState.settings.providerKind.suggestedModel
            let model = modelID.isEmpty
                ? (models.first?.id ?? (fallback.isEmpty ? OpenRouterProvider.suggestedModel : fallback))
                : modelID
            let raw = try await client.complete(
                model: model,
                messages: [
                    ChatMessage(role: "system", content: system),
                    ChatMessage(role: "user", content: prompt)
                ]
            )
            searchCount += 1
            lastSearchAt = .now
            let answer = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let sources = Self.extractURLs(from: answer)
            switch mode {
            case .factCheck:
                append(
                    LiveAssistCard(
                        kind: .factCheck,
                        title: "Fact-check",
                        body: answer.isEmpty ? prompt : "\(prompt)\n\n\(answer)",
                        sources: sources,
                        verdict: Self.verdict(fromText: answer, hasSources: !sources.isEmpty),
                        speakerKey: speakerKey
                    )
                )
            case .research:
                append(
                    LiveAssistCard(
                        kind: .research,
                        title: "Research",
                        body: answer.isEmpty ? prompt : "\(prompt)\n\n\(answer)",
                        sources: sources,
                        speakerKey: speakerKey
                    )
                )
            }
        } catch {
            append(
                LiveAssistCard(
                    kind: mode == .factCheck ? .factCheck : .research,
                    title: mode == .factCheck ? "Claim" : "Question",
                    body: prompt,
                    verdict: mode == .factCheck ? .unclear : nil,
                    speakerKey: speakerKey
                )
            )
        }
    }

    private static func extractURLs(from text: String) -> [LiveAssistSource] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return []
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var sources: [LiveAssistSource] = []
        var seen = Set<String>()
        detector.enumerateMatches(in: text, options: [], range: range) { match, _, _ in
            guard let match, let url = match.url else { return }
            let absolute = url.absoluteString
            guard seen.insert(absolute).inserted else { return }
            sources.append(LiveAssistSource(title: url.host ?? absolute, url: absolute))
        }
        return Array(sources.prefix(4))
    }

    private func append(_ card: LiveAssistCard) {
        cards.insert(card, at: 0)
        if cards.count > 40 {
            cards = Array(cards.prefix(40))
        }
        onCardsChanged?(cards)
    }

    private static func verdict(fromText answer: String, hasSources: Bool) -> FactCheckVerdict {
        let lowered = answer.lowercased()
        if lowered.contains("false") || lowered.contains("incorrect") || lowered.contains("not true")
            || lowered.contains("debunk") || lowered.contains("contradict") {
            return .contested
        }
        if lowered.contains("true") || lowered.contains("correct") || lowered.contains("confirmed")
            || lowered.contains("supported") || hasSources {
            return (!hasSources && lowered.isEmpty) ? .unclear : .supported
        }
        return .unclear
    }

    private struct ExtractedItem {
        var type: String
        var text: String
        var speakerKey: String?
    }

    private static func parseItems(_ raw: String) -> [ExtractedItem] {
        guard let data = Summarizer.extractJSON(from: raw),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["items"] as? [[String: Any]]
        else { return [] }
        return items.compactMap { item in
            guard let type = item["type"] as? String,
                  let text = item["text"] as? String
            else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return ExtractedItem(type: type, text: trimmed, speakerKey: nil)
        }
    }
}
