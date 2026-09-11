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

    var modelID: String {
        didSet { defaults.set(modelID, forKey: Keys.model) }
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
        defaultVisual = defaults.object(forKey: Keys.visual) as? Bool ?? true
        defaultAudio = defaults.object(forKey: Keys.audio) as? Bool ?? true
        defaultTranscript = defaults.object(forKey: Keys.transcript) as? Bool ?? true
        meetingAppAudioOnly = defaults.bool(forKey: Keys.meetingAppAudio)
        micPriorityIDs = defaults.stringArray(forKey: Keys.micPriority) ?? []
        let providerRaw = defaults.string(forKey: Keys.provider) ?? LLMProviderKind.ollama.rawValue
        providerKind = LLMProviderKind(rawValue: providerRaw) ?? .ollama
        ollamaURL = defaults.string(forKey: Keys.ollamaURL) ?? OllamaProvider.defaultBaseURL.absoluteString
        lmStudioURL = defaults.string(forKey: Keys.lmStudioURL) ?? LMStudioProvider.defaultBaseURL.absoluteString
        openRouterURL = defaults.string(forKey: Keys.openRouterURL) ?? OpenRouterProvider.defaultBaseURL.absoluteString
        modelID = defaults.string(forKey: Keys.model) ?? ""
    }

    private enum Keys {
        static let onboarding = "hasCompletedOnboarding"
        static let watch = "watchForMeetings"
        static let visual = "recordVisual"
        static let audio = "recordAudio"
        static let transcript = "recordTranscript"
        static let meetingAppAudio = "meetingAppAudioOnly"
        static let micPriority = "micPriorityIDs"
        static let provider = "llmProvider"
        static let ollamaURL = "ollamaURL"
        static let lmStudioURL = "lmStudioURL"
        static let openRouterURL = "openRouterURL"
        static let model = "llmModel"
    }
}
