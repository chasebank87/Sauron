import Foundation

enum TavilyAPIMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case search
    case research
    case auto

    var id: String { rawValue }

    var title: String {
        switch self {
        case .search: "Search"
        case .research: "Research"
        case .auto: "Auto"
        }
    }

    var detail: String {
        switch self {
        case .search: "Fast web search for every claim and question"
        case .research: "Deeper multi-step research reports (slower, more credits)"
        case .auto: "Search for fact-checks; Research API for open questions"
        }
    }
}

enum TavilySearchDepth: String, CaseIterable, Identifiable, Codable, Sendable {
    case ultraFast = "ultra-fast"
    case fast = "fast"
    case basic = "basic"
    case advanced = "advanced"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ultraFast: "Ultra-fast"
        case .fast: "Fast"
        case .basic: "Basic"
        case .advanced: "Advanced"
        }
    }
}

enum TavilyResearchModel: String, CaseIterable, Identifiable, Codable, Sendable {
    case mini
    case pro
    case auto

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mini: "Mini"
        case .pro: "Pro"
        case .auto: "Auto"
        }
    }

    var detail: String {
        switch self {
        case .mini: "Targeted and efficient"
        case .pro: "Broad multi-angle research"
        case .auto: "Let Tavily choose"
        }
    }
}

enum TavilyResearchOutputLength: String, CaseIterable, Identifiable, Codable, Sendable {
    case short
    case standard
    case long

    var id: String { rawValue }

    var title: String {
        switch self {
        case .short: "Short"
        case .standard: "Standard"
        case .long: "Long"
        }
    }
}

struct TavilyResult: Equatable, Sendable {
    var title: String
    var url: String
    var content: String
}

struct TavilySearchResponse: Equatable, Sendable {
    var answer: String?
    var results: [TavilyResult]
}

struct TavilyResearchResponse: Equatable, Sendable {
    var content: String
    var sources: [TavilyResult]
}

enum TavilyClientError: Error {
    case missingAPIKey
    case badURL
    case http(Int, String)
    case decoding
    case researchFailed
    case researchTimedOut
}

struct TavilyClient: Sendable {
    var apiKey: String
    var session: URLSession = .shared

    static let searchURL = URL(string: "https://api.tavily.com/search")!
    static let researchURL = URL(string: "https://api.tavily.com/research")!

    struct SearchOptions: Sendable {
        var depth: TavilySearchDepth = .basic
        var maxResults: Int = 5
        var chunksPerSource: Int = 3
        var includeDomains: [String] = []
        var excludeDomains: [String] = []
    }

    struct ResearchOptions: Sendable {
        var model: TavilyResearchModel = .mini
        var outputLength: TavilyResearchOutputLength = .short
        var includeDomains: [String] = []
        var excludeDomains: [String] = []
        var pollInterval: Duration = .seconds(3)
        var timeout: Duration = .seconds(90)
    }

    func search(query: String, options: SearchOptions = SearchOptions()) async throws -> TavilySearchResponse {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return TavilySearchResponse(answer: nil, results: [])
        }
        guard !apiKey.isEmpty else { throw TavilyClientError.missingAPIKey }

        var request = URLRequest(url: Self.searchURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        var body: [String: Any] = [
            "query": String(trimmed.prefix(380)),
            "search_depth": options.depth.rawValue,
            "max_results": max(1, min(20, options.maxResults)),
            "include_answer": true
        ]
        // chunks_per_source is supported for advanced / basic / fast (not ultra-fast).
        if options.depth != .ultraFast {
            body["chunks_per_source"] = max(1, min(3, options.chunksPerSource))
        }
        if !options.includeDomains.isEmpty {
            body["include_domains"] = Array(options.includeDomains.prefix(50))
        }
        if !options.excludeDomains.isEmpty {
            body["exclude_domains"] = Array(options.excludeDomains.prefix(50))
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        try Self.throwIfHTTPError(response, data: data)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TavilyClientError.decoding
        }
        let answer = json["answer"] as? String
        let rawResults = json["results"] as? [[String: Any]] ?? []
        let results: [TavilyResult] = rawResults.compactMap(Self.parseResult)
        return TavilySearchResponse(answer: answer, results: results)
    }

    /// Starts a Research task and polls until completed or timeout.
    func research(query: String, options: ResearchOptions = ResearchOptions()) async throws -> TavilyResearchResponse {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return TavilyResearchResponse(content: "", sources: [])
        }
        guard !apiKey.isEmpty else { throw TavilyClientError.missingAPIKey }

        var request = URLRequest(url: Self.researchURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        var body: [String: Any] = [
            "input": String(trimmed.prefix(800)),
            "model": options.model.rawValue,
            "stream": false,
            "citation_format": "numbered",
            "output_length": options.outputLength.rawValue
        ]
        if !options.includeDomains.isEmpty {
            body["include_domains"] = Array(options.includeDomains.prefix(20))
        }
        if !options.excludeDomains.isEmpty {
            body["exclude_domains"] = Array(options.excludeDomains.prefix(20))
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        try Self.throwIfHTTPError(response, data: data)
        let payload = (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        if let requestID = payload["request_id"] as? String {
            let deadline = ContinuousClock.now + options.timeout
            while ContinuousClock.now < deadline {
                if Task.isCancelled { throw CancellationError() }
                try await Task.sleep(for: options.pollInterval)
                let status = try await getResearch(requestID: requestID)
                switch status.status {
                case "completed":
                    return TavilyResearchResponse(content: status.content ?? "", sources: status.sources)
                case "failed":
                    throw TavilyClientError.researchFailed
                default:
                    continue
                }
            }
            throw TavilyClientError.researchTimedOut
        }

        // Some deployments may return a completed payload immediately.
        if let content = Self.contentString(from: payload) {
            let sources = (payload["sources"] as? [[String: Any]] ?? []).compactMap(Self.parseResult)
            return TavilyResearchResponse(content: content, sources: sources)
        }
        throw TavilyClientError.decoding
    }

    private struct ResearchStatus {
        var status: String
        var content: String?
        var sources: [TavilyResult]
    }

    private func getResearch(requestID: String) async throws -> ResearchStatus {
        guard let url = URL(string: "https://api.tavily.com/research/\(requestID)") else {
            throw TavilyClientError.badURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode == 202 {
            let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            let status = (json["status"] as? String) ?? "pending"
            return ResearchStatus(status: status, content: nil, sources: [])
        }
        try Self.throwIfHTTPError(response, data: data)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = json["status"] as? String
        else {
            throw TavilyClientError.decoding
        }
        let sources = (json["sources"] as? [[String: Any]] ?? []).compactMap(Self.parseResult)
        return ResearchStatus(
            status: status,
            content: Self.contentString(from: json),
            sources: sources
        )
    }

    private static func contentString(from json: [String: Any]) -> String? {
        if let text = json["content"] as? String { return text }
        if let object = json["content"] as? [String: Any],
           let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted]),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        return nil
    }

    private static func parseResult(_ item: [String: Any]) -> TavilyResult? {
        guard let url = item["url"] as? String else { return nil }
        let title = (item["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let content = (item["content"] as? String) ?? ""
        return TavilyResult(
            title: (title?.isEmpty == false) ? title! : url,
            url: url,
            content: content
        )
    }

    private static func throwIfHTTPError(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse, http.statusCode >= 400 else { return }
        throw TavilyClientError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
    }
}

enum TavilyDomainList {
    static func parse(_ raw: String) -> [String] {
        raw
            .split { $0 == "," || $0.isNewline || $0 == ";" }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .map { token -> String in
                var value = token.lowercased()
                if let url = URL(string: value), let host = url.host {
                    value = host
                }
                if value.hasPrefix("www.") {
                    value = String(value.dropFirst(4))
                }
                return value
            }
            .filter { !$0.isEmpty }
    }

    static func display(_ domains: [String]) -> String {
        domains.joined(separator: ", ")
    }
}
