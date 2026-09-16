import Foundation

// Shared meeting-structure taxonomy used by the post-meeting summary (Summarizer.swift) and,
// conceptually, the live extractor's item types (LiveAssistantEngine.swift keeps its own flat
// `LiveItem` wire type for ticks, but uses the same vocabulary). `id` on each row is a
// SwiftUI-convenience identity generated at decode/construction time — it is never part of the
// JSON wire schema, so it's intentionally absent from every CodingKeys enum below. Every type
// also gets a plain memberwise init (not just `init(from:)`) so code that isn't decoding JSON —
// tests, previews, future direct construction — can build one too.

enum MeetingType: String, Codable, Equatable, Sendable {
    case standup, oneOnOne, planning, review, design, customer, interview, training, social, other
}

enum AskStatus: String, Codable, Equatable, Sendable {
    case open, accepted, declined, deferred
}

enum ResolvedKind: String, Codable, Equatable, Sendable {
    case ask, question, blocker, actionItem
}

enum BlockerSeverity: String, Codable, Equatable, Sendable {
    case low, medium, high
}

enum EntityKind: String, Codable, Equatable, Sendable {
    case person, org, system, project, document
}

enum PriorItemStatus: String, Codable, Equatable, Sendable {
    case completed, inProgress, blocked, dropped, reassigned, superseded
}

enum TrackedItemVerification: String, Codable, Equatable, Sendable {
    case transcriptExplicit, corroborated, inferred
}

enum SentimentValue: String, Codable, Equatable, Sendable {
    case positive, neutral, tense, mixed
}

enum TranscriptCoverage: String, Codable, Equatable, Sendable {
    case full, partial, thin, empty
}

/// Decodes either the new keyed object shape, or a bare JSON string (legacy `summaryJSON` from
/// before this taxonomy existed) — falls back to a text-only value so old meetings keep displaying.
private func decodeLegacyString(_ decoder: Decoder) -> String? {
    guard let single = try? decoder.singleValueContainer() else { return nil }
    return try? single.decode(String.self)
}

struct Decision: Codable, Equatable, Sendable, Identifiable {
    var id = UUID()
    var text: String
    var rationale: String?
    var madeBy: [String]
    var evidence: String
    var confidence: Double
    /// Resolved after the model responds, by matching `evidence` back against the recorded
    /// transcript (see TranscriptTimestampResolver) — never part of the JSON wire schema, since
    /// LLM-reported timestamps aren't reliable enough to seek playback with.
    var timestamp: TimeInterval?

    init(text: String, rationale: String? = nil, madeBy: [String] = [], evidence: String = "", confidence: Double = 0, timestamp: TimeInterval? = nil) {
        self.text = text
        self.rationale = rationale
        self.madeBy = madeBy
        self.evidence = evidence
        self.confidence = confidence
        self.timestamp = timestamp
    }

    enum CodingKeys: String, CodingKey { case text, rationale, madeBy, evidence, confidence, timestamp }

    init(from decoder: Decoder) throws {
        if let legacy = decodeLegacyString(decoder) {
            text = legacy
            rationale = nil
            madeBy = []
            evidence = ""
            confidence = 0
            timestamp = nil
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decode(String.self, forKey: .text)
        rationale = try container.decodeIfPresent(String.self, forKey: .rationale)
        madeBy = try container.decodeIfPresent([String].self, forKey: .madeBy) ?? []
        evidence = try container.decodeIfPresent(String.self, forKey: .evidence) ?? ""
        confidence = try container.decodeIfPresent(Double.self, forKey: .confidence) ?? 0
        timestamp = try container.decodeIfPresent(TimeInterval.self, forKey: .timestamp)
    }
}

struct ActionItem: Codable, Equatable, Sendable, Identifiable {
    var id: UUID
    var text: String
    var owner: String?
    var requester: String?
    var due: String?
    var dueISO: String?
    var evidence: String
    var confidence: Double
    var timestamp: TimeInterval?

    init(
        id: UUID = UUID(),
        text: String,
        owner: String? = nil,
        requester: String? = nil,
        due: String? = nil,
        dueISO: String? = nil,
        evidence: String = "",
        confidence: Double = 0,
        timestamp: TimeInterval? = nil
    ) {
        self.id = id
        self.text = text
        self.owner = owner
        self.requester = requester
        self.due = due
        self.dueISO = dueISO
        self.evidence = evidence
        self.confidence = confidence
        self.timestamp = timestamp
    }

    enum CodingKeys: String, CodingKey { case id, text, owner, requester, due, dueISO, evidence, confidence, timestamp }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        text = try container.decode(String.self, forKey: .text)
        owner = try container.decodeIfPresent(String.self, forKey: .owner)
        requester = try container.decodeIfPresent(String.self, forKey: .requester)
        due = try container.decodeIfPresent(String.self, forKey: .due)
        dueISO = try container.decodeIfPresent(String.self, forKey: .dueISO)
        evidence = try container.decodeIfPresent(String.self, forKey: .evidence) ?? ""
        confidence = try container.decodeIfPresent(Double.self, forKey: .confidence) ?? 0
        timestamp = try container.decodeIfPresent(TimeInterval.self, forKey: .timestamp)
    }
}

struct Ask: Codable, Equatable, Sendable, Identifiable {
    var id = UUID()
    var text: String
    var requester: String?
    var target: String?
    var status: AskStatus
    var evidence: String
    var confidence: Double
    var timestamp: TimeInterval?

    init(text: String, requester: String? = nil, target: String? = nil, status: AskStatus = .open, evidence: String = "", confidence: Double = 0, timestamp: TimeInterval? = nil) {
        self.text = text
        self.requester = requester
        self.target = target
        self.status = status
        self.evidence = evidence
        self.confidence = confidence
        self.timestamp = timestamp
    }

    enum CodingKeys: String, CodingKey { case text, requester, target, status, evidence, confidence, timestamp }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decode(String.self, forKey: .text)
        requester = try container.decodeIfPresent(String.self, forKey: .requester)
        target = try container.decodeIfPresent(String.self, forKey: .target)
        status = try container.decodeIfPresent(AskStatus.self, forKey: .status) ?? .open
        evidence = try container.decodeIfPresent(String.self, forKey: .evidence) ?? ""
        confidence = try container.decodeIfPresent(Double.self, forKey: .confidence) ?? 0
        timestamp = try container.decodeIfPresent(TimeInterval.self, forKey: .timestamp)
    }
}

struct ResolvedInMeetingItem: Codable, Equatable, Sendable, Identifiable {
    var id = UUID()
    var text: String
    var kind: ResolvedKind
    var resolution: String
    var resolvedBy: String?
    var evidence: String
    var confidence: Double
    var timestamp: TimeInterval?

    init(
        text: String,
        kind: ResolvedKind,
        resolution: String = "",
        resolvedBy: String? = nil,
        evidence: String = "",
        confidence: Double = 0,
        timestamp: TimeInterval? = nil
    ) {
        self.text = text
        self.kind = kind
        self.resolution = resolution
        self.resolvedBy = resolvedBy
        self.evidence = evidence
        self.confidence = confidence
        self.timestamp = timestamp
    }

    enum CodingKeys: String, CodingKey { case text, kind, resolution, resolvedBy, evidence, confidence, timestamp }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decode(String.self, forKey: .text)
        kind = try container.decodeIfPresent(ResolvedKind.self, forKey: .kind) ?? .actionItem
        resolution = try container.decodeIfPresent(String.self, forKey: .resolution) ?? ""
        resolvedBy = try container.decodeIfPresent(String.self, forKey: .resolvedBy)
        evidence = try container.decodeIfPresent(String.self, forKey: .evidence) ?? ""
        confidence = try container.decodeIfPresent(Double.self, forKey: .confidence) ?? 0
        timestamp = try container.decodeIfPresent(TimeInterval.self, forKey: .timestamp)
    }
}

struct OpenQuestion: Codable, Equatable, Sendable, Identifiable {
    var id = UUID()
    var text: String
    var askedBy: String?
    var directedTo: String?
    var evidence: String
    var confidence: Double
    var timestamp: TimeInterval?

    init(text: String, askedBy: String? = nil, directedTo: String? = nil, evidence: String = "", confidence: Double = 0, timestamp: TimeInterval? = nil) {
        self.text = text
        self.askedBy = askedBy
        self.directedTo = directedTo
        self.evidence = evidence
        self.confidence = confidence
        self.timestamp = timestamp
    }

    enum CodingKeys: String, CodingKey { case text, askedBy, directedTo, evidence, confidence, timestamp }

    init(from decoder: Decoder) throws {
        if let legacy = decodeLegacyString(decoder) {
            text = legacy
            askedBy = nil
            directedTo = nil
            evidence = ""
            confidence = 0
            timestamp = nil
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decode(String.self, forKey: .text)
        askedBy = try container.decodeIfPresent(String.self, forKey: .askedBy)
        directedTo = try container.decodeIfPresent(String.self, forKey: .directedTo)
        evidence = try container.decodeIfPresent(String.self, forKey: .evidence) ?? ""
        confidence = try container.decodeIfPresent(Double.self, forKey: .confidence) ?? 0
        timestamp = try container.decodeIfPresent(TimeInterval.self, forKey: .timestamp)
    }
}

struct Blocker: Codable, Equatable, Sendable, Identifiable {
    var id = UUID()
    var text: String
    var blockedParty: String?
    var unblockedBy: String?
    var severity: BlockerSeverity
    var evidence: String
    var confidence: Double
    var timestamp: TimeInterval?

    init(
        text: String,
        blockedParty: String? = nil,
        unblockedBy: String? = nil,
        severity: BlockerSeverity = .medium,
        evidence: String = "",
        confidence: Double = 0,
        timestamp: TimeInterval? = nil
    ) {
        self.text = text
        self.blockedParty = blockedParty
        self.unblockedBy = unblockedBy
        self.severity = severity
        self.evidence = evidence
        self.confidence = confidence
        self.timestamp = timestamp
    }

    enum CodingKeys: String, CodingKey { case text, blockedParty, unblockedBy, severity, evidence, confidence, timestamp }

    init(from decoder: Decoder) throws {
        if let legacy = decodeLegacyString(decoder) {
            text = legacy
            blockedParty = nil
            unblockedBy = nil
            severity = .medium
            evidence = ""
            confidence = 0
            timestamp = nil
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decode(String.self, forKey: .text)
        blockedParty = try container.decodeIfPresent(String.self, forKey: .blockedParty)
        unblockedBy = try container.decodeIfPresent(String.self, forKey: .unblockedBy)
        severity = try container.decodeIfPresent(BlockerSeverity.self, forKey: .severity) ?? .medium
        evidence = try container.decodeIfPresent(String.self, forKey: .evidence) ?? ""
        confidence = try container.decodeIfPresent(Double.self, forKey: .confidence) ?? 0
        timestamp = try container.decodeIfPresent(TimeInterval.self, forKey: .timestamp)
    }
}

struct Topic: Codable, Equatable, Sendable, Identifiable {
    var id = UUID()
    var order: Int
    var title: String
    var summary: String
    var evidence: String

    init(order: Int = 0, title: String, summary: String = "", evidence: String = "") {
        self.order = order
        self.title = title
        self.summary = summary
        self.evidence = evidence
    }

    enum CodingKeys: String, CodingKey { case order, title, summary, evidence }

    init(from decoder: Decoder) throws {
        if let legacy = decodeLegacyString(decoder) {
            order = 0
            title = legacy
            summary = ""
            evidence = ""
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        order = try container.decodeIfPresent(Int.self, forKey: .order) ?? 0
        title = try container.decode(String.self, forKey: .title)
        summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        evidence = try container.decodeIfPresent(String.self, forKey: .evidence) ?? ""
    }
}

struct KeyDate: Codable, Equatable, Sendable, Identifiable {
    var id = UUID()
    var text: String
    var isoDate: String?
    var relatesTo: String?
    var evidence: String
    var timestamp: TimeInterval?

    init(text: String, isoDate: String? = nil, relatesTo: String? = nil, evidence: String = "", timestamp: TimeInterval? = nil) {
        self.text = text
        self.isoDate = isoDate
        self.relatesTo = relatesTo
        self.evidence = evidence
        self.timestamp = timestamp
    }

    enum CodingKeys: String, CodingKey { case text, isoDate, relatesTo, evidence, timestamp }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decode(String.self, forKey: .text)
        isoDate = try container.decodeIfPresent(String.self, forKey: .isoDate)
        relatesTo = try container.decodeIfPresent(String.self, forKey: .relatesTo)
        evidence = try container.decodeIfPresent(String.self, forKey: .evidence) ?? ""
        timestamp = try container.decodeIfPresent(TimeInterval.self, forKey: .timestamp)
    }
}

struct Metric: Codable, Equatable, Sendable, Identifiable {
    var id = UUID()
    var text: String
    var value: String?
    var unit: String?
    var speaker: String?
    var evidence: String
    var timestamp: TimeInterval?

    init(text: String, value: String? = nil, unit: String? = nil, speaker: String? = nil, evidence: String = "", timestamp: TimeInterval? = nil) {
        self.text = text
        self.value = value
        self.unit = unit
        self.speaker = speaker
        self.evidence = evidence
        self.timestamp = timestamp
    }

    enum CodingKeys: String, CodingKey { case text, value, unit, speaker, evidence, timestamp }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decode(String.self, forKey: .text)
        value = try container.decodeIfPresent(String.self, forKey: .value)
        unit = try container.decodeIfPresent(String.self, forKey: .unit)
        speaker = try container.decodeIfPresent(String.self, forKey: .speaker)
        evidence = try container.decodeIfPresent(String.self, forKey: .evidence) ?? ""
        timestamp = try container.decodeIfPresent(TimeInterval.self, forKey: .timestamp)
    }
}

struct Entity: Codable, Equatable, Sendable, Identifiable {
    var id = UUID()
    var name: String
    var kind: EntityKind
    var evidence: String

    init(name: String, kind: EntityKind, evidence: String = "") {
        self.name = name
        self.kind = kind
        self.evidence = evidence
    }

    enum CodingKeys: String, CodingKey { case name, kind, evidence }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        kind = try container.decodeIfPresent(EntityKind.self, forKey: .kind) ?? .system
        evidence = try container.decodeIfPresent(String.self, forKey: .evidence) ?? ""
    }
}

struct Attendee: Codable, Equatable, Sendable, Identifiable {
    var id = UUID()
    var name: String
    var isOwner: Bool
    var role: String?
    var org: String?

    init(name: String, isOwner: Bool = false, role: String? = nil, org: String? = nil) {
        self.name = name
        self.isOwner = isOwner
        self.role = role
        self.org = org
    }

    enum CodingKeys: String, CodingKey { case name, isOwner, role, org }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        isOwner = try container.decodeIfPresent(Bool.self, forKey: .isOwner) ?? false
        role = try container.decodeIfPresent(String.self, forKey: .role)
        org = try container.decodeIfPresent(String.self, forKey: .org)
    }
}

struct PriorItemUpdate: Codable, Equatable, Sendable, Identifiable {
    var id = UUID()
    var trackedItemId: UUID?
    var status: PriorItemStatus
    var newOwner: String?
    var note: String
    var evidence: String
    var confidence: Double

    init(
        trackedItemId: UUID? = nil,
        status: PriorItemStatus,
        newOwner: String? = nil,
        note: String = "",
        evidence: String = "",
        confidence: Double = 0
    ) {
        self.trackedItemId = trackedItemId
        self.status = status
        self.newOwner = newOwner
        self.note = note
        self.evidence = evidence
        self.confidence = confidence
    }

    enum CodingKeys: String, CodingKey { case trackedItemId, status, newOwner, note, evidence, confidence }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        trackedItemId = try container.decodeIfPresent(UUID.self, forKey: .trackedItemId)
        status = try container.decodeIfPresent(PriorItemStatus.self, forKey: .status) ?? .inProgress
        newOwner = try container.decodeIfPresent(String.self, forKey: .newOwner)
        note = try container.decodeIfPresent(String.self, forKey: .note) ?? ""
        evidence = try container.decodeIfPresent(String.self, forKey: .evidence) ?? ""
        confidence = try container.decodeIfPresent(Double.self, forKey: .confidence) ?? 0
    }
}

struct Quote: Codable, Equatable, Sendable, Identifiable {
    var id = UUID()
    var text: String
    var speaker: String?
    var timestamp: TimeInterval?

    init(text: String, speaker: String? = nil, timestamp: TimeInterval? = nil) {
        self.text = text
        self.speaker = speaker
        self.timestamp = timestamp
    }

    enum CodingKeys: String, CodingKey { case text, speaker, timestamp }

    init(from decoder: Decoder) throws {
        if let legacy = decodeLegacyString(decoder) {
            text = legacy
            speaker = nil
            timestamp = nil
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decode(String.self, forKey: .text)
        speaker = try container.decodeIfPresent(String.self, forKey: .speaker)
        timestamp = try container.decodeIfPresent(TimeInterval.self, forKey: .timestamp)
    }
}

struct MeetingSentiment: Codable, Equatable, Sendable {
    var overall: SentimentValue
    var note: String?

    init(overall: SentimentValue, note: String? = nil) {
        self.overall = overall
        self.note = note
    }

    enum CodingKeys: String, CodingKey { case overall, note }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        overall = try container.decodeIfPresent(SentimentValue.self, forKey: .overall) ?? .neutral
        note = try container.decodeIfPresent(String.self, forKey: .note)
    }
}

struct MeetingQuality: Codable, Equatable, Sendable {
    var transcriptCoverage: TranscriptCoverage
    var notes: String?

    init(transcriptCoverage: TranscriptCoverage, notes: String? = nil) {
        self.transcriptCoverage = transcriptCoverage
        self.notes = notes
    }

    enum CodingKeys: String, CodingKey { case transcriptCoverage, notes }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        transcriptCoverage = try container.decodeIfPresent(TranscriptCoverage.self, forKey: .transcriptCoverage) ?? .partial
        notes = try container.decodeIfPresent(String.self, forKey: .notes)
    }
}
