import Foundation

enum OllamaProvider {
    static let defaultBaseURL = URL(string: "http://127.0.0.1:11434")!

    static func listTags(baseURL: URL, session: URLSession) async throws -> [LLMModel] {
        let url = stripped(baseURL).appending(path: "api/tags")
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            throw LLMClientError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]]
        else { throw LLMClientError.decoding }
        return models.compactMap { item in
            let name = (item["name"] as? String) ?? (item["model"] as? String)
            guard let name else { return nil }
            return LLMModel(id: name, name: name)
        }
    }

    private static func stripped(_ url: URL) -> URL {
        if url.lastPathComponent == "v1" {
            return url.deletingLastPathComponent()
        }
        return url
    }
}
