import Foundation

/// One item surfaced by a live-extraction tick. This is the engine's internal wire/ledger type —
/// deliberately flat (a `type` discriminator instead of per-type structs) since that's what the
/// extraction prompt emits every ~45s under time pressure. `LiveAssistantEngine` renders each item
/// into a `LiveAssistCard` for the UI; evidence/confidence/`updates`-supersede stay engine-internal.
enum LiveItemType: String, Codable, Sendable {
    case decision, actionItem, ask, resolvedInMeeting, openQuestion, blocker
    case claim, question, context, date, metric, suggestion, insight
}

struct LiveItem: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var type: LiveItemType
    var text: String
    var speaker: String?
    var owner: String?
    var requester: String?
    var due: String?
    var evidence: String
    var confidence: Double
    var priority: String
    var needsWeb: Bool
    var needsMemory: Bool
    var updates: String?
    var source: String?

    enum CodingKeys: String, CodingKey {
        case id, type, text, speaker, owner, requester, due, evidence, confidence, priority, needsWeb, needsMemory, updates, source
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        type = try container.decodeIfPresent(LiveItemType.self, forKey: .type) ?? .insight
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        speaker = try container.decodeIfPresent(String.self, forKey: .speaker)
        owner = try container.decodeIfPresent(String.self, forKey: .owner)
        requester = try container.decodeIfPresent(String.self, forKey: .requester)
        due = try container.decodeIfPresent(String.self, forKey: .due)
        evidence = try container.decodeIfPresent(String.self, forKey: .evidence) ?? ""
        confidence = try container.decodeIfPresent(Double.self, forKey: .confidence) ?? 0
        priority = try container.decodeIfPresent(String.self, forKey: .priority) ?? "normal"
        needsWeb = try container.decodeIfPresent(Bool.self, forKey: .needsWeb) ?? false
        needsMemory = try container.decodeIfPresent(Bool.self, forKey: .needsMemory) ?? false
        updates = try container.decodeIfPresent(String.self, forKey: .updates)
        source = try container.decodeIfPresent(String.self, forKey: .source)
    }
}

struct LiveLedgerState: Codable, Equatable, Sendable {
    var currentTopic: String?
    var topicChanged: Bool
    var ownerHasUnansweredAsk: Bool

    static let empty = LiveLedgerState(currentTopic: nil, topicChanged: false, ownerHasUnansweredAsk: false)

    enum CodingKeys: String, CodingKey { case currentTopic, topicChanged, ownerHasUnansweredAsk }

    init(currentTopic: String?, topicChanged: Bool, ownerHasUnansweredAsk: Bool) {
        self.currentTopic = currentTopic
        self.topicChanged = topicChanged
        self.ownerHasUnansweredAsk = ownerHasUnansweredAsk
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        currentTopic = try container.decodeIfPresent(String.self, forKey: .currentTopic)
        topicChanged = try container.decodeIfPresent(Bool.self, forKey: .topicChanged) ?? false
        ownerHasUnansweredAsk = try container.decodeIfPresent(Bool.self, forKey: .ownerHasUnansweredAsk) ?? false
    }
}

/// Rolling per-meeting state: what's already been surfaced (so the extractor stops repeating
/// itself every tick) plus the lightweight topic/unanswered-ask state the prompt maintains.
private struct LiveMeetingLedger {
    private(set) var surfacedItems: [String: LiveItem] = [:]
    private(set) var order: [String] = []
    var state: LiveLedgerState = .empty

    mutating func apply(_ items: [LiveItem]) {
        for item in items {
            if let supersededID = item.updates, supersededID != item.id {
                surfacedItems.removeValue(forKey: supersededID)
                order.removeAll { $0 == supersededID }
            }
            if surfacedItems[item.id] == nil {
                order.append(item.id)
            }
            surfacedItems[item.id] = item
        }
    }

    var recentSurfaced: [LiveItem] {
        order.suffix(25).compactMap { surfacedItems[$0] }
    }

    var allSurfaced: [LiveItem] {
        order.compactMap { surfacedItems[$0] }
    }
}

/// Extracts insights / decisions / asks / claims / questions from the live transcript, keeps a
/// rolling ledger so nothing repeats every tick, and optionally fact-checks or researches items
/// the model flagged as needing web/memory tools.
@MainActor
final class LiveAssistantEngine {
    private(set) var cards: [LiveAssistCard] = []
    /// The ledger's surfaced items at the end of the meeting — handed to the summarizer as hints.
    private(set) var lastSurfacedItems: [LiveItem] = []

    var onCardsChanged: (@MainActor ([LiveAssistCard]) -> Void)?

    private var pendingFinals: [LiveSegment] = []
    private var allFinalSegments: [LiveSegment] = []
    private var ledger = LiveMeetingLedger()
    private var knownSpeakers: [String] = []
    private var lastExtractionAt: Date = .distantPast
    private var lastSearchAt: Date = .distantPast
    private var searchCount = 0
    private var runningTask: Task<Void, Never>?
    private var isRunning = false

    private let extractionInterval: TimeInterval = 45
    private let minFinalsBeforeExtract = 3
    private let maxItemsPerTick = 2

    func start() {
        stop()
        cards = []
        lastSurfacedItems = []
        pendingFinals = []
        allFinalSegments = []
        ledger = LiveMeetingLedger()
        knownSpeakers = []
        lastExtractionAt = .distantPast
        lastSearchAt = .distantPast
        searchCount = 0
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
        allFinalSegments = Array((allFinalSegments + [segment]).suffix(80))
        let name = SpeakerProfileStore.shared.displayName(for: segment.speakerKey)
        if !knownSpeakers.contains(name) { knownSpeakers.append(name) }
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
            await self?.extract(newSegments: window, appState: appState)
        }
    }

    private func extract(newSegments: [LiveSegment], appState: AppState) async {
        guard isRunning, !newSegments.isEmpty else { return }
        let olderSegments = Array(allFinalSegments.dropLast(newSegments.count).suffix(30))

        func rendered(_ segments: [LiveSegment]) -> String {
            segments.map { segment in
                let name = SpeakerProfileStore.shared.displayName(for: segment.speakerKey)
                return "\(name): \(segment.text)"
            }.joined(separator: "\n")
        }

        let fullTranscript = rendered(olderSegments + newSegments)
        let memory = await MeetingMemoryIndexer.retrieveContext(query: fullTranscript, appState: appState)
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

        let settings = appState.settings
        let memoryEnabled = settings.memoryEnabled
        let injectMemory = settings.shouldInjectMemoryIntoPrompts

        let elapsed = appState.currentMeeting.map { Date().timeIntervalSince($0.startedAt) } ?? 0
        let openItems = TrackedItemStore.openItems(context: appState.modelContext, limit: 10)

        let systemContent = SauronPrompts.system([
            SauronPrompts.Fragment.identity,
            """
            Task: you are watching a live meeting through a rolling transcript window. Each tick, surface the few things that are \
            most useful to the owner RIGHT NOW and keep a lightweight running state of the meeting.
            """,
            SauronPrompts.Fragment.speakerConventions,
            SauronPrompts.Fragment.asksVsActions,
            SauronPrompts.Fragment.grounding,
            SauronPrompts.Fragment.confidenceScale,
            """
            Item types you may emit (pick the most specific):
            - decision: an agreement was just reached
            - actionItem: someone was assigned or committed to a task (include owner/due if said)
            - ask: someone requested something and it has not yet been accepted or declined
            - resolvedInMeeting: an earlier ask/question/blocker from THIS meeting was just closed (reference it in "text")
            - openQuestion: a question was raised that nobody answered
            - blocker: a risk, dependency, or blocker was called out
            - claim: a checkable factual assertion the owner may want verified (set needsWeb=true if external, needsMemory=true if about a prior meeting)
            - question: a research-worthy question that tools could answer (same flags)
            - context: a speaker referenced a prior meeting — if memory tools are available, look it up and summarize the relevant excerpt with a citation
            - date: a deadline, milestone, or follow-up meeting was mentioned
            - metric: a number/figure worth capturing
            - suggestion: something the owner could usefully say, ask, or clarify now (e.g. an unassigned task, an ambiguous decision, an unanswered question directed at them)
            - insight: a short helpful note that does not fit above

            Selection rules:
            - Emit at most \(maxItemsPerTick) items. Prefer: (1) things directed at or owed by the owner, (2) decisions/actions/asks, (3) checkable claims, (4) everything else.
            - Do NOT re-emit anything semantically already present in "Already surfaced". If new information changes a surfaced item (e.g. an owner or due date was added, or it was resolved), emit it once as an update with "updates" set to that item's id.
            - Only emit from the NEW portion of the window (segments after the last tick) unless an older line is needed as evidence.
            - Speaker "self" lines are the owner. When the owner is asked something and has not answered, prefer a suggestion.
            - If nothing meets the bar, return empty items. Silence is a valid and common answer.

            Agentic behavior:
            - If memory tools are available and a speaker clearly references a prior meeting or a tracked item, you may make ONE memory call this tick and return the result as a context item. Do not make web calls during extraction; flag them with needsWeb instead.
            """,
            SauronPrompts.Fragment.jsonContract,
            """
            Schema:
            {
              "items": [
                {
                  "id": "short stable slug, e.g. action-send-budget",
                  "type": "decision|actionItem|ask|resolvedInMeeting|openQuestion|blocker|claim|question|context|date|metric|suggestion|insight",
                  "text": "one sentence, ≤140 chars, plain text",
                  "speaker": "name or null",
                  "owner": "name or null",
                  "requester": "name or null",
                  "due": "verbatim due phrase or null",
                  "evidence": "verbatim transcript snippet ≤160 chars",
                  "confidence": 0.0,
                  "priority": "high|normal",
                  "needsWeb": false,
                  "needsMemory": false,
                  "updates": "id of previously surfaced item this supersedes, or null",
                  "source": null
                }
              ],
              "state": {
                "currentTopic": "≤8 words or null",
                "topicChanged": false,
                "ownerHasUnansweredAsk": false
              }
            }
            """,
            memoryEnabled ? SauronPrompts.ToolAddon.memory : SauronPrompts.ToolAddon.noTools
        ])

        let surfacedLines = ledger.recentSurfaced.map { "- [\($0.id)] \($0.type.rawValue): \($0.text)" }.joined(separator: "\n")
        let openItemLines = openItems.map { "- [\($0.id.uuidString)] \($0.kind.rawValue) owner=\($0.owner ?? "null"): \($0.text)" }.joined(separator: "\n")

        var userBody = """
            Meeting: \(appState.currentMeeting?.title ?? "")   App: \(appState.currentMeeting?.appName ?? "")   Elapsed: \(Self.formatElapsed(elapsed))
            Known participants: \(knownSpeakers.isEmpty ? "(unknown)" : knownSpeakers.joined(separator: ", "))
            Current topic (from last tick): \(ledger.state.currentTopic ?? "(none)")

            Already surfaced (do not repeat; may update by id):
            \(surfacedLines.isEmpty ? "(none)" : surfacedLines)

            Open tracked items from prior meetings (for context/resolution only):
            \(openItemLines.isEmpty ? "(none)" : openItemLines)
            """
        if injectMemory, !memory.context.isEmpty {
            userBody += """


            Relevant past-meeting excerpts (continuity only):
            \(memory.context)
            """
        }
        userBody += """


            Transcript window (newest last; lines after "--- new since last tick ---" are new):
            \(rendered(olderSegments))
            --- new since last tick ---
            \(rendered(newSegments))
            """

        let messages = [
            ChatMessage(role: "system", content: systemContent),
            ChatMessage(role: "user", content: userBody)
        ]

        do {
            let (client, modelID) = try appState.makeClient()
            let models = (try? await client.listModels()) ?? []
            let model = modelID.isEmpty ? (models.first?.id ?? OpenRouterProvider.suggestedModel) : modelID
            let raw = try await client.complete(model: model, messages: messages)
            guard let data = Summarizer.extractJSON(from: raw),
                  let response = try? JSONDecoder().decode(LiveExtractionResponse.self, from: data)
            else { return }

            ledger.apply(response.items)
            ledger.state = response.state
            lastSurfacedItems = ledger.allSurfaced

            for item in response.items {
                await route(item, appState: appState)
            }
        } catch {
            // Soft-fail: live assist is optional.
        }
    }

    private func route(_ item: LiveItem, appState: AppState) async {
        switch item.type {
        case .claim:
            if item.needsWeb || item.needsMemory {
                await factCheck(item, appState: appState)
            } else {
                append(LiveAssistCard(kind: .insight, title: "Claim (opinion)", body: item.text, speakerKey: nil))
            }
        case .question:
            if item.needsWeb || item.needsMemory {
                await research(item, appState: appState)
            } else {
                append(LiveAssistCard(kind: .insight, title: "Question", body: item.text, speakerKey: nil))
            }
        case .context:
            append(
                LiveAssistCard(
                    kind: .memory,
                    title: "From past meetings",
                    body: item.text,
                    sources: item.source.map { [LiveAssistSource(title: "Meeting reference", url: $0)] } ?? []
                )
            )
        case .decision, .actionItem, .ask, .resolvedInMeeting, .openQuestion, .blocker, .date, .metric, .suggestion, .insight:
            append(LiveAssistCard(kind: .insight, title: Self.title(for: item.type), body: item.text, speakerKey: nil))
        }
    }

    private static func title(for type: LiveItemType) -> String {
        switch type {
        case .decision: "Decision"
        case .actionItem: "Action item"
        case .ask: "Ask"
        case .resolvedInMeeting: "Resolved"
        case .openQuestion: "Open question"
        case .blocker: "Blocker"
        case .date: "Date"
        case .metric: "Metric"
        case .suggestion: "Suggestion"
        case .insight, .claim, .question, .context: "Insight"
        }
    }

    // MARK: - Fact-check / research (agent-capable providers) + Tavily fallback

    private func factCheck(_ item: LiveItem, appState: AppState) async {
        let settings = appState.settings
        guard settings.liveResearchEnabled,
              searchCount < settings.maxResearchQueriesPerMeeting,
              Date().timeIntervalSince(lastSearchAt) >= settings.researchCooldownSeconds
        else {
            append(LiveAssistCard(kind: .factCheck, title: "Claim", body: item.text, verdict: .unclear, speakerKey: item.speaker))
            return
        }

        if settings.providerKind.providesBuiltInWebResearch {
            await agentFactCheck(item, appState: appState)
            return
        }

        guard let key = KeychainStore.tavilyAPIKey, !key.isEmpty else {
            append(LiveAssistCard(kind: .factCheck, title: "Claim", body: item.text, verdict: .unclear, speakerKey: item.speaker))
            return
        }

        do {
            let client = TavilyClient(apiKey: key)
            if settings.tavilyAPIMode == .research {
                let response = try await client.research(query: item.text, options: settings.tavilyResearchOptions)
                searchCount += 1
                lastSearchAt = .now
                let sources = response.sources.prefix(3).map { LiveAssistSource(title: $0.title, url: $0.url) }
                let report = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
                append(
                    LiveAssistCard(
                        kind: .factCheck,
                        title: "Fact-check",
                        body: report.isEmpty ? item.text : "\(item.text)\n\n\(report)",
                        sources: Array(sources),
                        verdict: Self.verdict(fromText: report, hasSources: !sources.isEmpty),
                        speakerKey: item.speaker
                    )
                )
            } else {
                let response = try await client.search(query: item.text, options: settings.tavilySearchOptions)
                searchCount += 1
                lastSearchAt = .now
                let sources = response.results.prefix(min(3, settings.tavilyMaxResults)).map { LiveAssistSource(title: $0.title, url: $0.url) }
                let answer = response.answer?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                append(
                    LiveAssistCard(
                        kind: .factCheck,
                        title: "Fact-check",
                        body: answer.isEmpty ? item.text : "\(item.text)\n\n\(answer)",
                        sources: Array(sources),
                        verdict: Self.verdict(fromText: answer, hasSources: !sources.isEmpty),
                        speakerKey: item.speaker
                    )
                )
            }
        } catch {
            append(LiveAssistCard(kind: .factCheck, title: "Claim", body: item.text, verdict: .unclear, speakerKey: item.speaker))
        }
    }

    private func research(_ item: LiveItem, appState: AppState) async {
        let settings = appState.settings
        guard settings.liveResearchEnabled,
              searchCount < settings.maxResearchQueriesPerMeeting,
              Date().timeIntervalSince(lastSearchAt) >= settings.researchCooldownSeconds
        else {
            append(LiveAssistCard(kind: .research, title: "Question", body: item.text, speakerKey: item.speaker))
            return
        }

        if settings.providerKind.providesBuiltInWebResearch {
            await agentResearch(item, appState: appState)
            return
        }

        guard let key = KeychainStore.tavilyAPIKey, !key.isEmpty else {
            append(LiveAssistCard(kind: .research, title: "Question", body: item.text, speakerKey: item.speaker))
            return
        }

        do {
            let client = TavilyClient(apiKey: key)
            let useResearchAPI = settings.tavilyAPIMode == .research || settings.tavilyAPIMode == .auto
            if useResearchAPI {
                let response = try await client.research(query: item.text, options: settings.tavilyResearchOptions)
                searchCount += 1
                lastSearchAt = .now
                let sources = response.sources.prefix(4).map { LiveAssistSource(title: $0.title, url: $0.url) }
                let report = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
                append(
                    LiveAssistCard(
                        kind: .research,
                        title: "Research",
                        body: report.isEmpty ? item.text : "\(item.text)\n\n\(report)",
                        sources: Array(sources),
                        speakerKey: item.speaker
                    )
                )
            } else {
                let response = try await client.search(query: item.text, options: settings.tavilySearchOptions)
                searchCount += 1
                lastSearchAt = .now
                let sources = response.results.prefix(min(3, settings.tavilyMaxResults)).map { LiveAssistSource(title: $0.title, url: $0.url) }
                let answer = response.answer?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                append(
                    LiveAssistCard(
                        kind: .research,
                        title: "Research",
                        body: answer.isEmpty ? item.text : "\(item.text)\n\n\(answer)",
                        sources: Array(sources),
                        speakerKey: item.speaker
                    )
                )
            }
        } catch {
            append(LiveAssistCard(kind: .research, title: "Question", body: item.text, speakerKey: item.speaker))
        }
    }

    /// Hermes / OpenClaw already have web tools — ask the agent instead of Tavily.
    private func agentFactCheck(_ item: LiveItem, appState: AppState) async {
        let webEnabled = appState.settings.providerKind.providesBuiltInWebResearch
        let memoryEnabled = appState.settings.memoryEnabled
        let system = SauronPrompts.system([
            SauronPrompts.Fragment.identity,
            """
            Task: fact-check a single claim made during a live meeting. The owner will read your output mid-meeting, so be fast, decisive, and honest about uncertainty.
            """,
            """
            Procedure:
            1. Classify the claim: external fact (use web), internal/prior-meeting fact (use memory), or opinion/unfalsifiable (no tools; say so).
            2. Make at most 3 tool calls total. Stop as soon as you have a primary source or two agreeing secondary sources.
            3. If sources disagree, say "contested" and name both sides. If nothing reliable is found, say "unclear" — never guess.
            4. If the claim is partly right, mark it "partially_supported" and state the correction precisely (numbers, dates, versions).
            """,
            SauronPrompts.Fragment.grounding,
            SauronPrompts.Fragment.jsonContract,
            """
            Schema:
            {
              "verdict": "supported|partially_supported|contested|unsupported|unclear|not_checkable",
              "summary": "1–3 sentences the owner can say out loud",
              "correction": "the accurate version if the claim is off, else null",
              "details": "optional 1–4 sentences of nuance, else null",
              "sources": [{"kind":"web|meeting","title":"...","url":"...","id":"...","date":"..."}],
              "confidence": 0.0,
              "toolCallsUsed": 0
            }
            """,
            webEnabled ? SauronPrompts.ToolAddon.web : "",
            memoryEnabled ? SauronPrompts.ToolAddon.memory : ""
        ])
        let user = """
            Meeting: \(appState.currentMeeting?.title ?? "")
            Claim: \(item.text)
            Said by: \(item.speaker ?? "unknown")
            Transcript context: \(item.evidence.isEmpty ? item.text : item.evidence)
            """

        do {
            let (client, modelID) = try appState.makeClient()
            let models = (try? await client.listModels()) ?? []
            let fallback = appState.settings.providerKind.suggestedModel
            let model = modelID.isEmpty ? (models.first?.id ?? (fallback.isEmpty ? OpenRouterProvider.suggestedModel : fallback)) : modelID
            let raw = try await client.complete(
                model: model,
                messages: [ChatMessage(role: "system", content: system), ChatMessage(role: "user", content: user)]
            )
            searchCount += 1
            lastSearchAt = .now
            if let data = Summarizer.extractJSON(from: raw),
               let result = try? JSONDecoder().decode(AgentFactCheckResult.self, from: data) {
                var body = result.summary
                if let correction = result.correction, !correction.isEmpty {
                    body += "\n\nCorrection: \(correction)"
                }
                if let details = result.details, !details.isEmpty {
                    body += "\n\n\(details)"
                }
                append(
                    LiveAssistCard(
                        kind: .factCheck,
                        title: "Fact-check",
                        body: body.isEmpty ? item.text : body,
                        sources: result.sources.map(Self.liveSource),
                        verdict: Self.mapVerdict(result.verdict),
                        speakerKey: item.speaker
                    )
                )
            } else {
                let answer = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                append(
                    LiveAssistCard(
                        kind: .factCheck,
                        title: "Fact-check",
                        body: answer.isEmpty ? item.text : answer,
                        sources: Self.extractURLs(from: answer),
                        verdict: Self.verdict(fromText: answer, hasSources: false),
                        speakerKey: item.speaker
                    )
                )
            }
        } catch {
            append(LiveAssistCard(kind: .factCheck, title: "Claim", body: item.text, verdict: .unclear, speakerKey: item.speaker))
        }
    }

    private func agentResearch(_ item: LiveItem, appState: AppState) async {
        let webEnabled = appState.settings.providerKind.providesBuiltInWebResearch
        let memoryEnabled = appState.settings.memoryEnabled
        let system = SauronPrompts.system([
            SauronPrompts.Fragment.identity,
            """
            Task: answer a research-worthy question that came up in a live meeting. Optimize for something the owner can use in the next two minutes: \
            a direct answer first, then the two or three facts that matter, then where it came from.
            """,
            """
            Procedure:
            1. Decide the source: prior meetings (memory) vs. external (web) vs. neither (answer from general knowledge and say so with lower confidence).
            2. At most 3 tool calls. Prefer primary sources. Stop when the answer is stable.
            3. If the question is ambiguous, answer the most likely reading and state the assumption in "assumption".
            4. If the question is really a task for a person on the call ("can someone look into X?"), say so in "note" instead of researching.
            """,
            SauronPrompts.Fragment.grounding,
            SauronPrompts.Fragment.jsonContract,
            """
            Schema:
            {
              "answer": "1–2 sentence direct answer",
              "keyPoints": ["≤3 short supporting facts"],
              "assumption": "how you interpreted the question, or null",
              "suggestedFollowUp": "a sharper question the owner could ask the room, or null",
              "note": "caveat or redirection, or null",
              "sources": [{"kind":"web|meeting","title":"...","url":"...","id":"...","date":"..."}],
              "confidence": 0.0,
              "toolCallsUsed": 0
            }
            """,
            webEnabled ? SauronPrompts.ToolAddon.web : "",
            memoryEnabled ? SauronPrompts.ToolAddon.memory : ""
        ])
        let user = """
            Meeting: \(appState.currentMeeting?.title ?? "")
            Question: \(item.text)
            Asked by: \(item.speaker ?? "unknown")
            Transcript context: \(item.evidence.isEmpty ? item.text : item.evidence)
            """

        do {
            let (client, modelID) = try appState.makeClient()
            let models = (try? await client.listModels()) ?? []
            let fallback = appState.settings.providerKind.suggestedModel
            let model = modelID.isEmpty ? (models.first?.id ?? (fallback.isEmpty ? OpenRouterProvider.suggestedModel : fallback)) : modelID
            let raw = try await client.complete(
                model: model,
                messages: [ChatMessage(role: "system", content: system), ChatMessage(role: "user", content: user)]
            )
            searchCount += 1
            lastSearchAt = .now
            if let data = Summarizer.extractJSON(from: raw),
               let result = try? JSONDecoder().decode(AgentResearchResult.self, from: data) {
                var body = result.answer
                if !result.keyPoints.isEmpty {
                    body += "\n\n" + result.keyPoints.map { "• \($0)" }.joined(separator: "\n")
                }
                if let note = result.note, !note.isEmpty {
                    body += "\n\n\(note)"
                }
                append(
                    LiveAssistCard(
                        kind: .research,
                        title: "Research",
                        body: body.isEmpty ? item.text : body,
                        sources: result.sources.map(Self.liveSource),
                        speakerKey: item.speaker
                    )
                )
            } else {
                let answer = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                append(
                    LiveAssistCard(
                        kind: .research,
                        title: "Research",
                        body: answer.isEmpty ? item.text : answer,
                        sources: Self.extractURLs(from: answer),
                        speakerKey: item.speaker
                    )
                )
            }
        } catch {
            append(LiveAssistCard(kind: .research, title: "Question", body: item.text, speakerKey: item.speaker))
        }
    }

    private static func liveSource(_ source: AgentSourceDTO) -> LiveAssistSource {
        if let url = source.url, !url.isEmpty {
            return LiveAssistSource(title: source.title ?? url, url: url)
        }
        if source.kind == "meeting", let id = source.id {
            return LiveAssistSource(title: source.title ?? "Meeting reference", url: "observer://meeting/\(id)")
        }
        return LiveAssistSource(title: source.title ?? "Source", url: "")
    }

    private static func mapVerdict(_ raw: String) -> FactCheckVerdict {
        switch raw {
        case "supported": .supported
        case "unclear", "not_checkable": .unclear
        default: .contested // partially_supported, contested, unsupported
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

    private static func formatElapsed(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

private struct LiveExtractionResponse: Decodable {
    var items: [LiveItem]
    var state: LiveLedgerState

    enum CodingKeys: String, CodingKey { case items, state }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = try container.decodeIfPresent([LiveItem].self, forKey: .items) ?? []
        state = try container.decodeIfPresent(LiveLedgerState.self, forKey: .state) ?? .empty
    }
}

private struct AgentSourceDTO: Decodable {
    var kind: String?
    var title: String?
    var url: String?
    var id: String?
    var date: String?
}

private struct AgentFactCheckResult: Decodable {
    var verdict: String
    var summary: String
    var correction: String?
    var details: String?
    var sources: [AgentSourceDTO]
    var confidence: Double

    enum CodingKeys: String, CodingKey { case verdict, summary, correction, details, sources, confidence }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        verdict = try container.decodeIfPresent(String.self, forKey: .verdict) ?? "unclear"
        summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        correction = try container.decodeIfPresent(String.self, forKey: .correction)
        details = try container.decodeIfPresent(String.self, forKey: .details)
        sources = try container.decodeIfPresent([AgentSourceDTO].self, forKey: .sources) ?? []
        confidence = try container.decodeIfPresent(Double.self, forKey: .confidence) ?? 0
    }
}

private struct AgentResearchResult: Decodable {
    var answer: String
    var keyPoints: [String]
    var assumption: String?
    var suggestedFollowUp: String?
    var note: String?
    var sources: [AgentSourceDTO]
    var confidence: Double

    enum CodingKeys: String, CodingKey { case answer, keyPoints, assumption, suggestedFollowUp, note, sources, confidence }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        answer = try container.decodeIfPresent(String.self, forKey: .answer) ?? ""
        keyPoints = try container.decodeIfPresent([String].self, forKey: .keyPoints) ?? []
        assumption = try container.decodeIfPresent(String.self, forKey: .assumption)
        suggestedFollowUp = try container.decodeIfPresent(String.self, forKey: .suggestedFollowUp)
        note = try container.decodeIfPresent(String.self, forKey: .note)
        sources = try container.decodeIfPresent([AgentSourceDTO].self, forKey: .sources) ?? []
        confidence = try container.decodeIfPresent(Double.self, forKey: .confidence) ?? 0
    }
}
