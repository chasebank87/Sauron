import Foundation
import Security

enum KeychainStore {
    private static let service = "app.observer.Observer"

    static func string(for account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ value: String?, for account: String) {
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(deleteQuery as CFDictionary)
        guard let value, !value.isEmpty, let data = value.data(using: .utf8) else { return }
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        SecItemAdd(add as CFDictionary, nil)
    }

    static var openRouterAPIKey: String? {
        get { string(for: "openrouter") }
        set { set(newValue, for: "openrouter") }
    }

    static var hermesAPIKey: String? {
        get { string(for: "hermes") }
        set { set(newValue, for: "hermes") }
    }

    static var openClawAPIKey: String? {
        get { string(for: "openclaw") }
        set { set(newValue, for: "openclaw") }
    }

    static var tavilyAPIKey: String? {
        get { string(for: "tavily") }
        set { set(newValue, for: "tavily") }
    }

    /// Bearer token for the localhost Memory MCP server.
    static var mcpServerToken: String {
        get {
            if let existing = string(for: "mcpServerToken"), !existing.isEmpty {
                return existing
            }
            return rotateMCPServerToken()
        }
        set { set(newValue, for: "mcpServerToken") }
    }

    @discardableResult
    static func rotateMCPServerToken() -> String {
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        set(token, for: "mcpServerToken")
        return token
    }

    static func apiKey(for kind: LLMProviderKind) -> String? {
        switch kind {
        case .openRouter: openRouterAPIKey
        case .hermes: hermesAPIKey
        case .openClaw: openClawAPIKey
        case .ollama, .lmStudio: nil
        }
    }
}
