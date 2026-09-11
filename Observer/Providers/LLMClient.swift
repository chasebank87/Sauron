import Foundation

enum LLMProviderKind: String, CaseIterable, Identifiable, Sendable {
    case ollama
    case lmStudio
    case openRouter

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ollama: "Ollama"
        case .lmStudio: "LM Studio"
        case .openRouter: "OpenRouter"
        }
    }

    var defaultBaseURL: URL {
        switch self {
        case .ollama: OllamaProvider.defaultBaseURL
        case .lmStudio: LMStudioProvider.defaultBaseURL
        case .openRouter: OpenRouterProvider.defaultBaseURL
        }
    }

    var requiresAPIKey: Bool {
        self == .openRouter
    }
}

struct LLMModel: Identifiable, Equatable, Sendable {
    var id: String
    var name: String
}

struct ChatMessage: Equatable, Sendable {
    var role: String
    var content: String
}

enum LLMClientError: Error {
    case badURL
    case http(Int, String)
    case decoding
    case empty
}

struct LLMClient: Sendable {
    var kind: LLMProviderKind
    var baseURL: URL
    var apiKey: String?
    var session: URLSession = .shared

    static func openAIRoot(_ url: URL) -> URL {
        if url.lastPathComponent == "v1" { return url }
        return url.appending(path: "v1")
    }

    func listModels() async throws -> [LLMModel] {
        switch kind {
        case .ollama:
            return try await listOllama()
        case .lmStudio, .openRouter:
            return try await listOpenAIModels()
        }
    }

    func streamChat(model: String, messages: [ChatMessage]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let url = Self.openAIRoot(baseURL).appending(path: "chat/completions")
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    applyAuth(to: &request)
                    let body: [String: Any] = [
                        "model": model,
                        "stream": true,
                        "temperature": 0.2,
                        "messages": messages.map { ["role": $0.role, "content": $0.content] }
                    ]
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)
                    let (bytes, response) = try await session.bytes(for: request)
                    if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
                        var errorBody = ""
                        for try await line in bytes.lines { errorBody += line }
                        throw LLMClientError.http(http.statusCode, errorBody)
                    }
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let data = payload.data(using: .utf8),
                              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let choices = json["choices"] as? [[String: Any]],
                              let delta = choices.first?["delta"] as? [String: Any]
                        else { continue }
                        if let content = delta["content"] as? String, !content.isEmpty {
                            continuation.yield(content)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func complete(model: String, messages: [ChatMessage]) async throws -> String {
        var output = ""
        for try await chunk in streamChat(model: model, messages: messages) {
            output += chunk
        }
        if output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw LLMClientError.empty
        }
        return output
    }

    func testConnection() async throws -> [LLMModel] {
        try await listModels()
    }

    private func applyAuth(to request: inout URLRequest) {
        if kind == .openRouter {
            if let apiKey {
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            }
            request.setValue("https://observer.app", forHTTPHeaderField: "HTTP-Referer")
            request.setValue("Observer", forHTTPHeaderField: "X-Title")
        } else if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
    }

    private func listOpenAIModels() async throws -> [LLMModel] {
        let url = Self.openAIRoot(baseURL).appending(path: "models")
        var request = URLRequest(url: url)
        applyAuth(to: &request)
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            throw LLMClientError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataArray = json["data"] as? [[String: Any]]
        else { throw LLMClientError.decoding }
        return dataArray.compactMap { item in
            guard let id = item["id"] as? String else { return nil }
            return LLMModel(id: id, name: id)
        }
    }

    private func listOllama() async throws -> [LLMModel] {
        if let models = try? await listOpenAIModels(), !models.isEmpty {
            return models
        }
        return try await OllamaProvider.listTags(baseURL: baseURL, session: session)
    }
}
