import Foundation

enum MemoryMCPHandlers {
    struct ToolDefinition: Encodable {
        var name: String
        var description: String
        var inputSchema: [String: AnyCodable]
    }

    struct ToolCallResult: Encodable {
        var content: [ContentItem]
        var isError: Bool

        struct ContentItem: Encodable {
            var type: String
            var text: String
        }

        static func text(_ text: String, isError: Bool = false) -> ToolCallResult {
            ToolCallResult(content: [ContentItem(type: "text", text: text)], isError: isError)
        }

        static func json(_ value: some Encodable, isError: Bool = false) throws -> ToolCallResult {
            let data = try JSONEncoder.mcp.encode(value)
            let text = String(data: data, encoding: .utf8) ?? "{}"
            return .text(text, isError: isError)
        }
    }

    static let tools: [ToolDefinition] = [
        ToolDefinition(
            name: "search_meetings",
            description: "Semantically search Observer meeting memory for relevant past-meeting excerpts.",
            inputSchema: [
                "type": AnyCodable("object"),
                "properties": AnyCodable([
                    "query": [
                        "type": "string",
                        "description": "Natural-language search query"
                    ],
                    "top_k": [
                        "type": "integer",
                        "description": "Max results (1-24). Defaults to Observer Memory top-k."
                    ],
                    "min_score": [
                        "type": "number",
                        "description": "Minimum cosine similarity floor (0-1). Default 0.35."
                    ],
                    "exclude_meeting_id": [
                        "type": "string",
                        "description": "Optional meeting UUID to exclude (e.g. the meeting being summarized)."
                    ]
                ] as [String: Any]),
                "required": AnyCodable(["query"])
            ]
        ),
        ToolDefinition(
            name: "get_meeting",
            description: "Fetch one Observer meeting by id, including summary fields and a transcript excerpt.",
            inputSchema: [
                "type": AnyCodable("object"),
                "properties": AnyCodable([
                    "meeting_id": [
                        "type": "string",
                        "description": "Meeting UUID"
                    ]
                ] as [String: Any]),
                "required": AnyCodable(["meeting_id"])
            ]
        ),
        ToolDefinition(
            name: "list_recent_meetings",
            description: "List recent Observer meetings with basic metadata.",
            inputSchema: [
                "type": AnyCodable("object"),
                "properties": AnyCodable([
                    "limit": [
                        "type": "integer",
                        "description": "Max meetings to return (1-50). Default 10."
                    ]
                ] as [String: Any]),
                "required": AnyCodable([] as [String])
            ]
        ),
        ToolDefinition(
            name: "memory_status",
            description: "Report Observer meeting-memory index health and settings.",
            inputSchema: [
                "type": AnyCodable("object"),
                "properties": AnyCodable([:] as [String: Any]),
                "required": AnyCodable([] as [String])
            ]
        )
    ]

    static var toolNames: [String] {
        tools.map(\.name)
    }

    @MainActor
    static func callTool(name: String, arguments: [String: Any], appState: AppState) async -> ToolCallResult {
        do {
            switch name {
            case "search_meetings":
                return try await searchMeetings(arguments: arguments, appState: appState)
            case "get_meeting":
                return try getMeeting(arguments: arguments, appState: appState)
            case "list_recent_meetings":
                return try listRecent(arguments: arguments, appState: appState)
            case "memory_status":
                return try ToolCallResult.json(MeetingMemoryQuery.status(appState: appState))
            default:
                return .text("Unknown tool: \(name)", isError: true)
            }
        } catch let error as MemoryQueryError {
            return .text(error.localizedDescription, isError: true)
        } catch {
            return .text(error.localizedDescription, isError: true)
        }
    }

    @MainActor
    private static func searchMeetings(arguments: [String: Any], appState: AppState) async throws -> ToolCallResult {
        guard appState.settings.memoryEnabled else {
            throw MemoryQueryError.memoryDisabled
        }
        guard let query = stringArg(arguments["query"]), !query.isEmpty else {
            throw MemoryQueryError.emptyQuery
        }
        let topK = intArg(arguments["top_k"])
        let minScore = floatArg(arguments["min_score"])
        let exclude = stringArg(arguments["exclude_meeting_id"]).flatMap(UUID.init(uuidString:))
        let hits = try await MeetingMemoryIndexer.retrieveHits(
            query: query,
            appState: appState,
            excludingMeetingID: exclude,
            topK: topK,
            minScore: minScore
        )
        let payload = hits.map { hit in
            SearchHitDTO(
                chunkID: hit.chunk.id,
                meetingID: hit.chunk.meetingID,
                meetingTitle: hit.chunk.meetingTitle,
                meetingDate: hit.chunk.meetingDate,
                kind: hit.chunk.kind.rawValue,
                score: hit.score,
                text: hit.chunk.text
            )
        }
        return try ToolCallResult.json(SearchResponse(hits: payload, count: payload.count))
    }

    @MainActor
    private static func getMeeting(arguments: [String: Any], appState: AppState) throws -> ToolCallResult {
        guard appState.settings.memoryEnabled else {
            throw MemoryQueryError.memoryDisabled
        }
        guard let raw = stringArg(arguments["meeting_id"]), let id = UUID(uuidString: raw) else {
            return .text("meeting_id must be a valid UUID.", isError: true)
        }
        let detail = try MeetingMemoryQuery.meetingDetail(id: id, context: appState.modelContext)
        return try ToolCallResult.json(detail)
    }

    @MainActor
    private static func listRecent(arguments: [String: Any], appState: AppState) throws -> ToolCallResult {
        guard appState.settings.memoryEnabled else {
            throw MemoryQueryError.memoryDisabled
        }
        let limit = intArg(arguments["limit"]) ?? 10
        let items = MeetingMemoryQuery.listRecent(limit: limit, context: appState.modelContext)
        return try ToolCallResult.json(ListResponse(meetings: items, count: items.count))
    }

    private struct SearchHitDTO: Encodable {
        var chunkID: UUID
        var meetingID: UUID
        var meetingTitle: String
        var meetingDate: Date
        var kind: String
        var score: Float
        var text: String
    }

    private struct SearchResponse: Encodable {
        var hits: [SearchHitDTO]
        var count: Int
    }

    private struct ListResponse: Encodable {
        var meetings: [MemoryMeetingListItem]
        var count: Int
    }

    static func stringArg(_ value: Any?) -> String? {
        switch value {
        case let string as String: string
        case let codable as AnyCodable: stringArg(codable.value)
        default: nil
        }
    }

    static func intArg(_ value: Any?) -> Int? {
        switch value {
        case let int as Int: int
        case let double as Double: Int(double)
        case let number as NSNumber: number.intValue
        case let string as String: Int(string)
        case let codable as AnyCodable: intArg(codable.value)
        default: nil
        }
    }

    static func floatArg(_ value: Any?) -> Float? {
        switch value {
        case let float as Float: float
        case let double as Double: Float(double)
        case let int as Int: Float(int)
        case let number as NSNumber: number.floatValue
        case let string as String: Float(string)
        case let codable as AnyCodable: floatArg(codable.value)
        default: nil
        }
    }
}
