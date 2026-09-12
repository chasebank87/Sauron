import Foundation

enum HermesProvider {
    static let defaultBaseURL = URL(string: "http://127.0.0.1:8642")!
    static let suggestedModel = "hermes-agent"
}

enum OpenClawProvider {
    static let defaultBaseURL = URL(string: "http://127.0.0.1:18789")!
    static let suggestedModel = "openclaw/default"
}
