import Foundation
import SwiftData

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
            description: "Semantically search Sauron meeting memory for relevant past-meeting excerpts.",
            inputSchema: [
                "type": AnyCodable("object"),
                "properties": AnyCodable([
                    "query": [
                        "type": "string",
                        "description": "Natural-language search query"
                    ],
                    "top_k": [
                        "type": "integer",
                        "description": "Max results (1-24). Defaults to Sauron Memory top-k."
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
            description: "Fetch one Sauron meeting by id, including summary fields and a transcript excerpt.",
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
            description: "List recent Sauron meetings with basic metadata.",
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
            description: "Report Sauron meeting-memory index health and settings.",
            inputSchema: [
                "type": AnyCodable("object"),
                "properties": AnyCodable([:] as [String: Any]),
                "required": AnyCodable([] as [String])
            ]
        ),
        ToolDefinition(
            name: "list_tracked_items",
            description: "List Sauron tracked items (action items, asks, blockers, next steps) synced from meetings.",
            inputSchema: [
                "type": AnyCodable("object"),
                "properties": AnyCodable([
                    "status": [
                        "type": "string",
                        "enum": ["open", "done", "dismissed"],
                        "description": "Filter by status. Defaults to open."
                    ],
                    "kind": [
                        "type": "string",
                        "enum": ["action", "ask", "blocker", "nextStep"],
                        "description": "Filter by kind. Omit for all kinds."
                    ],
                    "owner": [
                        "type": "string",
                        "description": "Filter by owner name (case-insensitive substring)."
                    ],
                    "meeting_id": [
                        "type": "string",
                        "description": "Filter to items sourced from this meeting UUID."
                    ],
                    "limit": [
                        "type": "integer",
                        "description": "Max items to return (1-100). Default 50."
                    ]
                ] as [String: Any]),
                "required": AnyCodable([] as [String])
            ]
        ),
        ToolDefinition(
            name: "create_tracked_item",
            description: "Create a new tracked item (action item, ask, blocker, or next step). Idempotent: reuses an existing open item with the same kind/text/owner.",
            inputSchema: [
                "type": AnyCodable("object"),
                "properties": AnyCodable([
                    "kind": [
                        "type": "string",
                        "enum": ["action", "ask", "blocker", "nextStep"],
                        "description": "Type of item to create."
                    ],
                    "text": [
                        "type": "string",
                        "description": "The item text."
                    ],
                    "owner": [
                        "type": "string",
                        "description": "Person responsible, if any."
                    ],
                    "due": [
                        "type": "string",
                        "description": "Due date/time, free text, if mentioned."
                    ],
                    "meeting_id": [
                        "type": "string",
                        "description": "Meeting UUID this item comes from. Defaults to the meeting currently in progress, if any."
                    ]
                ] as [String: Any]),
                "required": AnyCodable(["kind", "text"])
            ]
        ),
        ToolDefinition(
            name: "update_tracked_item",
            description: "Edit a tracked item's kind, text, owner, or due date.",
            inputSchema: [
                "type": AnyCodable("object"),
                "properties": AnyCodable([
                    "id": [
                        "type": "string",
                        "description": "Tracked item UUID."
                    ],
                    "kind": [
                        "type": "string",
                        "enum": ["action", "ask", "blocker", "nextStep"]
                    ],
                    "text": [
                        "type": "string",
                        "description": "New item text."
                    ],
                    "owner": [
                        "type": ["string", "null"],
                        "description": "New owner, or null to clear."
                    ],
                    "due": [
                        "type": ["string", "null"],
                        "description": "New due date/time, or null to clear."
                    ]
                ] as [String: Any]),
                "required": AnyCodable(["id"])
            ]
        ),
        ToolDefinition(
            name: "complete_tracked_item",
            description: "Mark a tracked item done.",
            inputSchema: [
                "type": AnyCodable("object"),
                "properties": AnyCodable([
                    "id": [
                        "type": "string",
                        "description": "Tracked item UUID."
                    ],
                    "note": [
                        "type": "string",
                        "description": "Short evidence or resolution note."
                    ]
                ] as [String: Any]),
                "required": AnyCodable(["id"])
            ]
        ),
        ToolDefinition(
            name: "reopen_tracked_item",
            description: "Reopen a done or dismissed tracked item.",
            inputSchema: [
                "type": AnyCodable("object"),
                "properties": AnyCodable([
                    "id": [
                        "type": "string",
                        "description": "Tracked item UUID."
                    ]
                ] as [String: Any]),
                "required": AnyCodable(["id"])
            ]
        ),
        ToolDefinition(
            name: "dismiss_tracked_item",
            description: "Dismiss a tracked item as no longer relevant.",
            inputSchema: [
                "type": AnyCodable("object"),
                "properties": AnyCodable([
                    "id": [
                        "type": "string",
                        "description": "Tracked item UUID."
                    ]
                ] as [String: Any]),
                "required": AnyCodable(["id"])
            ]
        ),
        ToolDefinition(
            name: "add_meeting_note",
            description: "Add or replace the user notes on a meeting.",
            inputSchema: [
                "type": AnyCodable("object"),
                "properties": AnyCodable([
                    "meeting_id": [
                        "type": "string",
                        "description": "Meeting UUID."
                    ],
                    "note": [
                        "type": "string",
                        "description": "Note text."
                    ],
                    "mode": [
                        "type": "string",
                        "enum": ["append", "replace"],
                        "description": "Append to existing notes (default) or replace them."
                    ]
                ] as [String: Any]),
                "required": AnyCodable(["meeting_id", "note"])
            ]
        ),
        ToolDefinition(
            name: "list_tracked_item_proposals",
            description: "List reconciler proposals — status changes for tracked items that weren't confident/verified enough to auto-apply and need confirmation.",
            inputSchema: [
                "type": AnyCodable("object"),
                "properties": AnyCodable([
                    "includeResolved": [
                        "type": "boolean",
                        "description": "Include already-applied/dismissed proposals. Default false (unresolved only)."
                    ],
                    "limit": [
                        "type": "integer",
                        "description": "Max proposals to return (1-100). Default 50."
                    ]
                ] as [String: Any]),
                "required": AnyCodable([] as [String])
            ]
        ),
        ToolDefinition(
            name: "resolve_tracked_item_proposal",
            description: "Apply or dismiss a tracked-item reconciliation proposal. Applying sets the linked tracked item's status when the proposed status is completed or dropped (other statuses have no safe automatic mutation yet and are just marked resolved).",
            inputSchema: [
                "type": AnyCodable("object"),
                "properties": AnyCodable([
                    "id": [
                        "type": "string",
                        "description": "Proposal UUID."
                    ],
                    "action": [
                        "type": "string",
                        "enum": ["apply", "dismiss"],
                        "description": "apply performs the proposed mutation where possible; dismiss discards the proposal."
                    ]
                ] as [String: Any]),
                "required": AnyCodable(["id", "action"])
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
            case "list_tracked_items":
                return try listTrackedItems(arguments: arguments, appState: appState)
            case "create_tracked_item":
                return try createTrackedItem(arguments: arguments, appState: appState)
            case "update_tracked_item":
                return try updateTrackedItem(arguments: arguments, appState: appState)
            case "complete_tracked_item":
                return try completeTrackedItem(arguments: arguments, appState: appState)
            case "reopen_tracked_item":
                return try setTrackedItemStatus(arguments: arguments, appState: appState) { item, context in
                    TrackedItemStore.reopen(item, context: context)
                }
            case "dismiss_tracked_item":
                return try setTrackedItemStatus(arguments: arguments, appState: appState) { item, context in
                    TrackedItemStore.dismiss(item, by: .agent, context: context)
                }
            case "add_meeting_note":
                return try addMeetingNote(arguments: arguments, appState: appState)
            case "list_tracked_item_proposals":
                return try listTrackedItemProposals(arguments: arguments, appState: appState)
            case "resolve_tracked_item_proposal":
                return try resolveTrackedItemProposal(arguments: arguments, appState: appState)
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

    @MainActor
    private static func listTrackedItems(arguments: [String: Any], appState: AppState) throws -> ToolCallResult {
        let status = stringArg(arguments["status"]).flatMap(TrackedItemStatus.init(rawValue:)) ?? .open
        let kind = stringArg(arguments["kind"]).flatMap(TrackedItemKind.init(rawValue:))
        let owner = stringArg(arguments["owner"])?.lowercased()
        let meetingID = stringArg(arguments["meeting_id"]).flatMap(UUID.init(uuidString:))
        let limit = max(1, min(intArg(arguments["limit"]) ?? 50, 100))

        var items = TrackedItemStore.all(context: appState.modelContext).filter { $0.status == status }
        if let kind { items = items.filter { $0.kind == kind } }
        if let owner { items = items.filter { ($0.owner ?? "").lowercased().contains(owner) } }
        if let meetingID { items = items.filter { $0.sourceMeetingID == meetingID } }
        let payload = items.prefix(limit).map(TrackedItemDTO.init)
        return try ToolCallResult.json(TrackedItemListResponse(items: Array(payload), count: payload.count))
    }

    @MainActor
    private static func createTrackedItem(arguments: [String: Any], appState: AppState) throws -> ToolCallResult {
        guard let kindRaw = stringArg(arguments["kind"]), let kind = TrackedItemKind(rawValue: kindRaw) else {
            return .text("kind must be one of: action, ask, blocker, nextStep.", isError: true)
        }
        guard let text = stringArg(arguments["text"]), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .text("text must not be empty.", isError: true)
        }
        let meetingID: UUID
        let meetingTitle: String
        if let raw = stringArg(arguments["meeting_id"]) {
            guard let id = UUID(uuidString: raw), let meeting = MeetingStore.meeting(id: id, context: appState.modelContext) else {
                return .text("meeting_id must be a valid, existing meeting UUID.", isError: true)
            }
            meetingID = id
            meetingTitle = meeting.title
        } else if let current = appState.currentMeeting {
            meetingID = current.id
            meetingTitle = current.title
        } else {
            return .text("meeting_id is required when no meeting is currently in progress.", isError: true)
        }
        let item = TrackedItemStore.create(
            kind: kind,
            text: text,
            owner: stringArg(arguments["owner"]),
            dueRaw: stringArg(arguments["due"]),
            sourceMeetingID: meetingID,
            sourceMeetingTitle: meetingTitle,
            context: appState.modelContext
        )
        return try ToolCallResult.json(TrackedItemDTO(item))
    }

    @MainActor
    private static func updateTrackedItem(arguments: [String: Any], appState: AppState) throws -> ToolCallResult {
        guard let item = try trackedItem(arguments: arguments, appState: appState) else {
            return .text("No tracked item found for that id.", isError: true)
        }
        let kind = stringArg(arguments["kind"]).flatMap(TrackedItemKind.init(rawValue:))
        TrackedItemStore.update(
            item,
            kind: kind,
            text: stringArg(arguments["text"]),
            owner: optionalStringArg(arguments, key: "owner"),
            dueRaw: optionalStringArg(arguments, key: "due"),
            context: appState.modelContext
        )
        return try ToolCallResult.json(TrackedItemDTO(item))
    }

    @MainActor
    private static func completeTrackedItem(arguments: [String: Any], appState: AppState) throws -> ToolCallResult {
        guard let item = try trackedItem(arguments: arguments, appState: appState) else {
            return .text("No tracked item found for that id.", isError: true)
        }
        TrackedItemStore.complete(item, by: .agent, note: stringArg(arguments["note"]), context: appState.modelContext)
        return try ToolCallResult.json(TrackedItemDTO(item))
    }

    @MainActor
    private static func setTrackedItemStatus(
        arguments: [String: Any],
        appState: AppState,
        apply: (TrackedItem, ModelContext) -> Void
    ) throws -> ToolCallResult {
        guard let item = try trackedItem(arguments: arguments, appState: appState) else {
            return .text("No tracked item found for that id.", isError: true)
        }
        apply(item, appState.modelContext)
        return try ToolCallResult.json(TrackedItemDTO(item))
    }

    @MainActor
    private static func trackedItem(arguments: [String: Any], appState: AppState) throws -> TrackedItem? {
        guard let raw = stringArg(arguments["id"]), let id = UUID(uuidString: raw) else {
            return nil
        }
        return TrackedItemStore.all(context: appState.modelContext).first { $0.id == id }
    }

    /// Distinguishes "field omitted" (nil) from "field explicitly set to null" (Optional(nil)).
    private static func optionalStringArg(_ arguments: [String: Any], key: String) -> String?? {
        guard let raw = arguments[key] else { return nil }
        let unwrapped = (raw as? AnyCodable)?.value ?? raw
        if unwrapped is NSNull { return .some(nil) }
        return .some(stringArg(raw))
    }

    @MainActor
    private static func addMeetingNote(arguments: [String: Any], appState: AppState) throws -> ToolCallResult {
        guard let raw = stringArg(arguments["meeting_id"]), let id = UUID(uuidString: raw),
              let meeting = MeetingStore.meeting(id: id, context: appState.modelContext)
        else {
            return .text("meeting_id must be a valid, existing meeting UUID.", isError: true)
        }
        guard let note = stringArg(arguments["note"]), !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .text("note must not be empty.", isError: true)
        }
        let mode = stringArg(arguments["mode"]) ?? "append"
        let combined: String
        if mode == "replace" {
            combined = note
        } else if let existing = meeting.userNotes, !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            combined = "\(existing)\n\n\(note)"
        } else {
            combined = note
        }
        appState.saveUserNotes(combined, for: meeting)
        return .text("Note saved.")
    }

    @MainActor
    private static func listTrackedItemProposals(arguments: [String: Any], appState: AppState) throws -> ToolCallResult {
        let includeResolved = (arguments["includeResolved"] as? Bool) ?? false
        let limit = max(1, min(intArg(arguments["limit"]) ?? 50, 100))
        let all = TrackedItemProposalStore.all(context: appState.modelContext)
        let filtered = includeResolved ? all : all.filter { !$0.isResolved }
        let payload = filtered.prefix(limit).map(TrackedItemProposalDTO.init)
        return try ToolCallResult.json(TrackedItemProposalListResponse(proposals: Array(payload), count: payload.count))
    }

    @MainActor
    private static func resolveTrackedItemProposal(arguments: [String: Any], appState: AppState) throws -> ToolCallResult {
        guard let raw = stringArg(arguments["id"]), let id = UUID(uuidString: raw),
              let proposal = TrackedItemProposalStore.all(context: appState.modelContext).first(where: { $0.id == id })
        else {
            return .text("No proposal found for that id.", isError: true)
        }
        guard let action = stringArg(arguments["action"]), action == "apply" || action == "dismiss" else {
            return .text("action must be \"apply\" or \"dismiss\".", isError: true)
        }
        guard !proposal.isResolved else {
            return .text("Proposal is already resolved.", isError: true)
        }
        if action == "apply" {
            TrackedItemProposalStore.apply(proposal, context: appState.modelContext)
        } else {
            TrackedItemProposalStore.dismiss(proposal, context: appState.modelContext)
        }
        return try ToolCallResult.json(TrackedItemProposalDTO(proposal))
    }

    private struct TrackedItemProposalDTO: Encodable {
        var id: UUID
        var trackedItemID: UUID?
        var sourceMeetingID: UUID
        var sourceMeetingTitle: String
        var proposedStatus: String
        var verification: String
        var confidence: Double
        var note: String
        var evidence: String
        var newOwner: String?
        var supersededByText: String?
        var createdAt: Date
        var resolvedAt: Date?
        var resolvedAction: String?

        init(_ proposal: TrackedItemProposal) {
            id = proposal.id
            trackedItemID = proposal.trackedItemID
            sourceMeetingID = proposal.sourceMeetingID
            sourceMeetingTitle = proposal.sourceMeetingTitle
            proposedStatus = proposal.proposedStatus.rawValue
            verification = proposal.verification.rawValue
            confidence = proposal.confidence
            note = proposal.note
            evidence = proposal.evidence
            newOwner = proposal.newOwner
            supersededByText = proposal.supersededByText
            createdAt = proposal.createdAt
            resolvedAt = proposal.resolvedAt
            resolvedAction = proposal.resolvedAction?.rawValue
        }
    }

    private struct TrackedItemProposalListResponse: Encodable {
        var proposals: [TrackedItemProposalDTO]
        var count: Int
    }

    private struct TrackedItemDTO: Encodable {
        var id: UUID
        var kind: String
        var text: String
        var owner: String?
        var due: String?
        var status: String
        var sourceMeetingID: UUID
        var sourceMeetingTitle: String
        var createdAt: Date
        var completedAt: Date?
        var completedBy: String?
        var resolvedInMeetingID: UUID?
        var resolutionNote: String?
        var timestamp: TimeInterval?

        init(_ item: TrackedItem) {
            id = item.id
            kind = item.kind.rawValue
            text = item.text
            owner = item.owner
            due = item.dueRaw
            status = item.status.rawValue
            sourceMeetingID = item.sourceMeetingID
            sourceMeetingTitle = item.sourceMeetingTitle
            createdAt = item.createdAt
            completedAt = item.completedAt
            completedBy = item.completedBy?.rawValue
            resolvedInMeetingID = item.resolvedInMeetingID
            resolutionNote = item.resolutionNote
            timestamp = item.timestamp
        }
    }

    private struct TrackedItemListResponse: Encodable {
        var items: [TrackedItemDTO]
        var count: Int
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
