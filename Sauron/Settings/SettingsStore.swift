import AppKit
import Foundation
import Observation

@Observable
@MainActor
final class SettingsStore {
    var hasCompletedOnboarding: Bool {
        didSet { defaults.set(hasCompletedOnboarding, forKey: Keys.onboarding) }
    }

    var watchForMeetings: Bool {
        didSet { defaults.set(watchForMeetings, forKey: Keys.watch) }
    }

    /// Sound + entrance animation when the record prompt appears.
    var promptAlertEnabled: Bool {
        didSet { defaults.set(promptAlertEnabled, forKey: Keys.promptAlert) }
    }

    /// Hide the transcript and Live Assist panes while this Mac is presenting.
    var hideLivePanesWhileSharing: Bool {
        didSet { defaults.set(hideLivePanesWhileSharing, forKey: Keys.hideLivePanesWhileSharing) }
    }

    /// Calendar identifiers used for Up Next + meeting-context. Empty + configured = none.
    var subscribedCalendarIDs: [String] {
        didSet { defaults.set(subscribedCalendarIDs, forKey: Keys.subscribedCalendars) }
    }

    /// Once true, empty `subscribedCalendarIDs` means “no calendars”, not “all”.
    var calendarSubscriptionsConfigured: Bool {
        didSet { defaults.set(calendarSubscriptionsConfigured, forKey: Keys.calendarsConfigured) }
    }

    var defaultVisual: Bool {
        didSet { defaults.set(defaultVisual, forKey: Keys.visual) }
    }

    var defaultAudio: Bool {
        didSet { defaults.set(defaultAudio, forKey: Keys.audio) }
    }

    var defaultTranscript: Bool {
        didSet { defaults.set(defaultTranscript, forKey: Keys.transcript) }
    }

    /// When true, capture only the meeting app's audio. Default false = full system audio.
    var meetingAppAudioOnly: Bool {
        didSet { defaults.set(meetingAppAudioOnly, forKey: Keys.meetingAppAudio) }
    }

    /// When true, speaker playback captured as system audio is subtracted from the mic
    /// (acoustic echo / speaker-to-mic bleed). Default on.
    var echoCancellationEnabled: Bool {
        didSet { defaults.set(echoCancellationEnabled, forKey: Keys.echoCancellation) }
    }

    /// Ordered mic device IDs after System Default. System Default is always applied as #1 at resolve time.
    var micPriorityIDs: [String] {
        didSet { defaults.set(micPriorityIDs, forKey: Keys.micPriority) }
    }

    var defaultAudioSource: CaptureAudioSource {
        get { meetingAppAudioOnly ? .meetingApp : .system }
        set { meetingAppAudioOnly = newValue == .meetingApp }
    }

    var providerKind: LLMProviderKind {
        didSet { defaults.set(providerKind.rawValue, forKey: Keys.provider) }
    }

    var ollamaURL: String {
        didSet { defaults.set(ollamaURL, forKey: Keys.ollamaURL) }
    }

    var lmStudioURL: String {
        didSet { defaults.set(lmStudioURL, forKey: Keys.lmStudioURL) }
    }

    var openRouterURL: String {
        didSet { defaults.set(openRouterURL, forKey: Keys.openRouterURL) }
    }

    var hermesURL: String {
        didSet { defaults.set(hermesURL, forKey: Keys.hermesURL) }
    }

    var openClawURL: String {
        didSet { defaults.set(openClawURL, forKey: Keys.openClawURL) }
    }

    var modelID: String {
        didSet { defaults.set(modelID, forKey: Keys.model) }
    }

    /// Embedding model for meeting memory (RAG). Empty = provider default.
    var embeddingModelID: String {
        didSet { defaults.set(embeddingModelID, forKey: Keys.embeddingModel) }
    }

    /// Used when the chat backend is Hermes/OpenClaw (which do not host embeddings).
    var embeddingProviderKind: LLMProviderKind {
        didSet {
            let resolved = embeddingProviderKind.supportsEmbeddings ? embeddingProviderKind : .ollama
            if resolved != embeddingProviderKind {
                embeddingProviderKind = resolved
                return
            }
            defaults.set(resolved.rawValue, forKey: Keys.embeddingProvider)
        }
    }

    var memoryEnabled: Bool {
        didSet { defaults.set(memoryEnabled, forKey: Keys.memoryEnabled) }
    }

    var memoryTopK: Int {
        didSet { defaults.set(memoryTopK, forKey: Keys.memoryTopK) }
    }

    /// Localhost Streamable HTTP MCP for Hermes/OpenClaw (and other MCP clients).
    var mcpServerEnabled: Bool {
        didSet { defaults.set(mcpServerEnabled, forKey: Keys.mcpServerEnabled) }
    }

    var mcpServerPort: Int {
        didSet { defaults.set(mcpServerPort, forKey: Keys.mcpServerPort) }
    }

    /// Carbon/NSEvent key code for opening the Dashboard (default D = 2).
    var dashboardShortcutKeyCode: UInt16 {
        didSet { defaults.set(Int(dashboardShortcutKeyCode), forKey: Keys.dashboardKeyCode) }
    }

    /// NSEvent.ModifierFlags raw value (default option+command).
    var dashboardShortcutModifiers: UInt {
        didSet { defaults.set(Int(dashboardShortcutModifiers), forKey: Keys.dashboardModifiers) }
    }

    /// Absolute path for meeting video/audio folders. Empty = Application Support default.
    var recordingsFolderPath: String {
        didSet {
            defaults.set(recordingsFolderPath, forKey: Keys.recordingsFolder)
            MediaStore.applyCustomRoot(path: recordingsFolderPath)
        }
    }

    /// Live Assist: claim extraction + optional Tavily fact-check/research.
    var liveResearchEnabled: Bool {
        didSet { defaults.set(liveResearchEnabled, forKey: Keys.liveResearch) }
    }

    /// Which Tavily product Live Assist uses.
    var tavilyAPIMode: TavilyAPIMode {
        didSet { defaults.set(tavilyAPIMode.rawValue, forKey: Keys.tavilyMode) }
    }

    /// Tavily Search `search_depth`.
    var tavilySearchDepth: TavilySearchDepth {
        didSet { defaults.set(tavilySearchDepth.rawValue, forKey: Keys.tavilyDepth) }
    }

    /// Results returned per Search query (1…20).
    var tavilyMaxResults: Int {
        didSet { defaults.set(tavilyMaxResults, forKey: Keys.tavilyMaxResults) }
    }

    /// Chunks per source for Search (1…3). Ignored for ultra-fast.
    var tavilyChunksPerSource: Int {
        didSet { defaults.set(tavilyChunksPerSource, forKey: Keys.tavilyChunks) }
    }

    /// Soft include list (comma / newline separated hosts).
    var tavilyIncludeDomains: String {
        didSet { defaults.set(tavilyIncludeDomains, forKey: Keys.tavilyIncludeDomains) }
    }

    /// Hard exclude list (comma / newline separated hosts).
    var tavilyExcludeDomains: String {
        didSet { defaults.set(tavilyExcludeDomains, forKey: Keys.tavilyExcludeDomains) }
    }

    var tavilyResearchModel: TavilyResearchModel {
        didSet { defaults.set(tavilyResearchModel.rawValue, forKey: Keys.tavilyResearchModel) }
    }

    var tavilyResearchOutputLength: TavilyResearchOutputLength {
        didSet { defaults.set(tavilyResearchOutputLength.rawValue, forKey: Keys.tavilyResearchLength) }
    }

    var maxResearchQueriesPerMeeting: Int {
        didSet { defaults.set(maxResearchQueriesPerMeeting, forKey: Keys.maxResearchQueries) }
    }

    /// Seconds between automatic Tavily queries.
    var researchCooldownSeconds: Double {
        didSet { defaults.set(researchCooldownSeconds, forKey: Keys.researchCooldown) }
    }

    /// Sortformer neural diarization for remote speakers (ANE). Falls back to classical F0 when off/unavailable.
    var neuralDiarizationEnabled: Bool {
        didSet { defaults.set(neuralDiarizationEnabled, forKey: Keys.neuralDiarization) }
    }

    /// Parakeet post-meeting retranscription for better accuracy (does not affect live Apple Speech).
    var enhanceTranscriptEnabled: Bool {
        didSet { defaults.set(enhanceTranscriptEnabled, forKey: Keys.enhanceTranscript) }
    }

    var tavilyIncludeDomainList: [String] { TavilyDomainList.parse(tavilyIncludeDomains) }
    var tavilyExcludeDomainList: [String] { TavilyDomainList.parse(tavilyExcludeDomains) }

    var resolvedEmbeddingProviderKind: LLMProviderKind {
        if providerKind.supportsEmbeddings {
            return providerKind
        }
        return embeddingProviderKind.supportsEmbeddings ? embeddingProviderKind : .ollama
    }

    var usesSeparateEmbeddingProvider: Bool {
        !providerKind.supportsEmbeddings
    }

    var resolvedEmbeddingModelID: String {
        let trimmed = embeddingModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return Self.defaultEmbeddingModel(for: resolvedEmbeddingProviderKind)
    }

    static func defaultEmbeddingModel(for kind: LLMProviderKind) -> String {
        switch kind {
        case .openRouter: "openai/text-embedding-3-small"
        case .hermes, .openClaw: "nomic-embed-text"
        case .ollama, .lmStudio: "nomic-embed-text"
        }
    }

    /// Whether Live Assist should call Tavily (false for Hermes/OpenClaw).
    var usesTavilyForResearch: Bool {
        !providerKind.providesBuiltInWebResearch
    }

    /// Non-agent providers get RAG excerpts stuffed into prompts; Hermes/OpenClaw use MCP tools instead.
    var shouldInjectMemoryIntoPrompts: Bool {
        memoryEnabled && !providerKind.providesBuiltInWebResearch
    }

    /// MCP listens when both memory and the MCP toggle are on.
    var shouldRunMemoryMCPServer: Bool {
        memoryEnabled && mcpServerEnabled
    }

    var mcpEndpointURL: URL {
        URL(string: "http://127.0.0.1:\(mcpServerPort)/mcp")!
    }

    func hermesMCPSnippet(token: String) -> String {
        """
        mcp_servers:
          sauron:
            url: "\(mcpEndpointURL.absoluteString)"
            headers:
              Authorization: "Bearer \(token)"
            enabled: true
        """
    }

    func openClawMCPSnippet(token: String) -> String {
        """
        {
          "mcp": {
            "servers": {
              "sauron": {
                "url": "\(mcpEndpointURL.absoluteString)",
                "transport": "streamable-http",
                "headers": {
                  "Authorization": "Bearer \(token)"
                },
                "enabled": true
              }
            }
          }
        }
        """
    }

    /// Calendar IDs to query. `nil` means all calendars (pre-configuration default).
    var effectiveSubscribedCalendarIDs: [String]? {
        calendarSubscriptionsConfigured ? subscribedCalendarIDs : nil
    }

    /// Seed subscriptions to every available calendar the first time Settings opens calendars.
    func ensureCalendarSubscriptionsSeeded() {
        guard !calendarSubscriptionsConfigured else { return }
        let available = CalendarSignal.availableCalendars()
        guard !available.isEmpty else { return }
        subscribedCalendarIDs = available.map(\.calendarIdentifier)
        calendarSubscriptionsConfigured = true
    }

    func isCalendarSubscribed(_ id: String) -> Bool {
        if !calendarSubscriptionsConfigured { return true }
        return subscribedCalendarIDs.contains(id)
    }

    func setCalendarSubscribed(_ id: String, enabled: Bool) {
        if !calendarSubscriptionsConfigured {
            ensureCalendarSubscriptionsSeeded()
        }
        var ids = Set(subscribedCalendarIDs)
        if enabled {
            ids.insert(id)
        } else {
            ids.remove(id)
        }
        subscribedCalendarIDs = Array(ids).sorted()
        calendarSubscriptionsConfigured = true
    }

    var tavilySearchOptions: TavilyClient.SearchOptions {
        TavilyClient.SearchOptions(
            depth: tavilySearchDepth,
            maxResults: tavilyMaxResults,
            chunksPerSource: tavilyChunksPerSource,
            includeDomains: tavilyIncludeDomainList,
            excludeDomains: tavilyExcludeDomainList
        )
    }

    var tavilyResearchOptions: TavilyClient.ResearchOptions {
        TavilyClient.ResearchOptions(
            model: tavilyResearchModel,
            outputLength: tavilyResearchOutputLength,
            includeDomains: tavilyIncludeDomainList,
            excludeDomains: tavilyExcludeDomainList
        )
    }

    var defaultCapture: CaptureMedia {
        get { defaultVisual ? .videoAndAudio : .audioOnly }
        set {
            defaultVisual = newValue == .videoAndAudio
            defaultAudio = true
        }
    }

    var defaultModes: Set<RecordMode> {
        defaultCapture.modes(transcript: defaultTranscript)
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hasCompletedOnboarding = defaults.bool(forKey: Keys.onboarding)
        watchForMeetings = defaults.object(forKey: Keys.watch) as? Bool ?? true
        promptAlertEnabled = defaults.object(forKey: Keys.promptAlert) as? Bool ?? true
        hideLivePanesWhileSharing = defaults.object(forKey: Keys.hideLivePanesWhileSharing) as? Bool ?? true
        subscribedCalendarIDs = defaults.stringArray(forKey: Keys.subscribedCalendars) ?? []
        calendarSubscriptionsConfigured = defaults.bool(forKey: Keys.calendarsConfigured)
        defaultVisual = defaults.object(forKey: Keys.visual) as? Bool ?? true
        defaultAudio = defaults.object(forKey: Keys.audio) as? Bool ?? true
        defaultTranscript = defaults.object(forKey: Keys.transcript) as? Bool ?? true
        meetingAppAudioOnly = defaults.bool(forKey: Keys.meetingAppAudio)
        echoCancellationEnabled = defaults.object(forKey: Keys.echoCancellation) as? Bool ?? true
        micPriorityIDs = defaults.stringArray(forKey: Keys.micPriority) ?? []
        let providerRaw = defaults.string(forKey: Keys.provider) ?? LLMProviderKind.ollama.rawValue
        providerKind = LLMProviderKind(rawValue: providerRaw) ?? .ollama
        ollamaURL = defaults.string(forKey: Keys.ollamaURL) ?? OllamaProvider.defaultBaseURL.absoluteString
        lmStudioURL = defaults.string(forKey: Keys.lmStudioURL) ?? LMStudioProvider.defaultBaseURL.absoluteString
        openRouterURL = defaults.string(forKey: Keys.openRouterURL) ?? OpenRouterProvider.defaultBaseURL.absoluteString
        hermesURL = defaults.string(forKey: Keys.hermesURL) ?? HermesProvider.defaultBaseURL.absoluteString
        openClawURL = defaults.string(forKey: Keys.openClawURL) ?? OpenClawProvider.defaultBaseURL.absoluteString
        modelID = defaults.string(forKey: Keys.model) ?? ""
        embeddingModelID = defaults.string(forKey: Keys.embeddingModel) ?? ""
        let embeddingProviderRaw = defaults.string(forKey: Keys.embeddingProvider) ?? LLMProviderKind.ollama.rawValue
        let loadedEmbeddingProvider = LLMProviderKind(rawValue: embeddingProviderRaw) ?? .ollama
        embeddingProviderKind = loadedEmbeddingProvider.supportsEmbeddings ? loadedEmbeddingProvider : .ollama
        memoryEnabled = defaults.object(forKey: Keys.memoryEnabled) as? Bool ?? true
        memoryTopK = defaults.object(forKey: Keys.memoryTopK) as? Int ?? 6
        mcpServerEnabled = defaults.object(forKey: Keys.mcpServerEnabled) as? Bool ?? true
        let port = defaults.object(forKey: Keys.mcpServerPort) as? Int ?? 8787
        mcpServerPort = min(65535, max(1024, port))
        let keyCode = defaults.object(forKey: Keys.dashboardKeyCode) as? Int ?? 2
        dashboardShortcutKeyCode = UInt16(keyCode)
        let mods = defaults.object(forKey: Keys.dashboardModifiers) as? Int
            ?? Int(NSEvent.ModifierFlags.option.rawValue | NSEvent.ModifierFlags.command.rawValue)
        dashboardShortcutModifiers = UInt(mods)
        liveResearchEnabled = defaults.bool(forKey: Keys.liveResearch)
        let modeRaw = defaults.string(forKey: Keys.tavilyMode) ?? TavilyAPIMode.auto.rawValue
        tavilyAPIMode = TavilyAPIMode(rawValue: modeRaw) ?? .auto
        let depthRaw = defaults.string(forKey: Keys.tavilyDepth) ?? TavilySearchDepth.basic.rawValue
        tavilySearchDepth = TavilySearchDepth(rawValue: depthRaw) ?? .basic
        tavilyMaxResults = defaults.object(forKey: Keys.tavilyMaxResults) as? Int ?? 5
        tavilyChunksPerSource = defaults.object(forKey: Keys.tavilyChunks) as? Int ?? 3
        tavilyIncludeDomains = defaults.string(forKey: Keys.tavilyIncludeDomains) ?? ""
        tavilyExcludeDomains = defaults.string(forKey: Keys.tavilyExcludeDomains) ?? ""
        let researchModelRaw = defaults.string(forKey: Keys.tavilyResearchModel) ?? TavilyResearchModel.mini.rawValue
        tavilyResearchModel = TavilyResearchModel(rawValue: researchModelRaw) ?? .mini
        let lengthRaw = defaults.string(forKey: Keys.tavilyResearchLength) ?? TavilyResearchOutputLength.short.rawValue
        tavilyResearchOutputLength = TavilyResearchOutputLength(rawValue: lengthRaw) ?? .short
        let maxQueries = defaults.object(forKey: Keys.maxResearchQueries) as? Int
        maxResearchQueriesPerMeeting = maxQueries ?? 8
        let cooldown = defaults.object(forKey: Keys.researchCooldown) as? Double
        researchCooldownSeconds = cooldown ?? 25
        neuralDiarizationEnabled = defaults.object(forKey: Keys.neuralDiarization) as? Bool ?? true
        enhanceTranscriptEnabled = defaults.object(forKey: Keys.enhanceTranscript) as? Bool ?? true
        let folder = defaults.string(forKey: Keys.recordingsFolder) ?? ""
        recordingsFolderPath = folder
        MediaStore.applyCustomRoot(path: folder)
    }

    private enum Keys {
        static let onboarding = "hasCompletedOnboarding"
        static let watch = "watchForMeetings"
        static let promptAlert = "promptAlertEnabled"
        static let hideLivePanesWhileSharing = "hideLivePanesWhileSharing"
        static let subscribedCalendars = "subscribedCalendarIDs"
        static let calendarsConfigured = "calendarSubscriptionsConfigured"
        static let visual = "recordVisual"
        static let audio = "recordAudio"
        static let transcript = "recordTranscript"
        static let meetingAppAudio = "meetingAppAudioOnly"
        static let echoCancellation = "echoCancellationEnabled"
        static let micPriority = "micPriorityIDs"
        static let provider = "llmProvider"
        static let ollamaURL = "ollamaURL"
        static let lmStudioURL = "lmStudioURL"
        static let openRouterURL = "openRouterURL"
        static let hermesURL = "hermesURL"
        static let openClawURL = "openClawURL"
        static let model = "llmModel"
        static let embeddingModel = "embeddingModelID"
        static let embeddingProvider = "embeddingProviderKind"
        static let memoryEnabled = "memoryEnabled"
        static let memoryTopK = "memoryTopK"
        static let mcpServerEnabled = "mcpServerEnabled"
        static let mcpServerPort = "mcpServerPort"
        static let dashboardKeyCode = "dashboardShortcutKeyCode"
        static let dashboardModifiers = "dashboardShortcutModifiers"
        static let recordingsFolder = "recordingsFolderPath"
        static let liveResearch = "liveResearchEnabled"
        static let tavilyMode = "tavilyAPIMode"
        static let tavilyDepth = "tavilySearchDepth"
        static let tavilyMaxResults = "tavilyMaxResults"
        static let tavilyChunks = "tavilyChunksPerSource"
        static let tavilyIncludeDomains = "tavilyIncludeDomains"
        static let tavilyExcludeDomains = "tavilyExcludeDomains"
        static let tavilyResearchModel = "tavilyResearchModel"
        static let tavilyResearchLength = "tavilyResearchOutputLength"
        static let maxResearchQueries = "maxResearchQueriesPerMeeting"
        static let researchCooldown = "researchCooldownSeconds"
        static let neuralDiarization = "neuralDiarizationEnabled"
        static let enhanceTranscript = "enhanceTranscriptEnabled"
    }
}
