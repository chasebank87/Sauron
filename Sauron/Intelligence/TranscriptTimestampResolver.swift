import Foundation

/// Resolves each evidence-bearing item in a `MeetingSummary` to a transcript timestamp, by
/// matching its verbatim `evidence` quote back against the recorded segments — not by trusting
/// an LLM-reported number, which models aren't reliably precise about. Lets the report UI show a
/// play button next to a decision/ask/blocker/etc. that seeks playback to the moment it happened.
enum TranscriptTimestampResolver {
    static func resolve(_ summary: MeetingSummary, segments: [TranscriptSegment]) -> MeetingSummary {
        guard !segments.isEmpty else { return summary }
        var summary = summary
        summary.decisions = summary.decisions.map { stamped($0, evidence: $0.evidence, segments: segments) }
        summary.actionItems = summary.actionItems.map { stamped($0, evidence: $0.evidence, segments: segments) }
        summary.asks = summary.asks.map { stamped($0, evidence: $0.evidence, segments: segments) }
        summary.resolvedInMeeting = summary.resolvedInMeeting.map { stamped($0, evidence: $0.evidence, segments: segments) }
        summary.openQuestions = summary.openQuestions.map { stamped($0, evidence: $0.evidence, segments: segments) }
        summary.blockers = summary.blockers.map { stamped($0, evidence: $0.evidence, segments: segments) }
        summary.dates = summary.dates.map { stamped($0, evidence: $0.evidence, segments: segments) }
        summary.metrics = summary.metrics.map { stamped($0, evidence: $0.evidence, segments: segments) }
        summary.quotes = summary.quotes.map { stamped($0, evidence: $0.text, segments: segments) }
        return summary
    }

    private static func stamped<T>(_ item: T, evidence: String, segments: [TranscriptSegment]) -> T where T: TimestampedEvidence {
        var item = item
        item.timestamp = timestamp(forEvidence: evidence, in: segments)
        return item
    }

    /// Finds the segment whose text best matches `evidence` and returns its start time.
    /// Tries exact/substring containment first (the common case for a verbatim quote), then a
    /// 2-segment window (evidence spanning a segment boundary), then falls back to word-overlap
    /// scoring for near-paraphrases. Returns nil rather than guessing when nothing matches well.
    static func timestamp(forEvidence evidence: String, in segments: [TranscriptSegment]) -> TimeInterval? {
        let needle = normalize(evidence)
        guard needle.count >= 8 else { return nil }
        let sorted = segments.sorted { $0.start < $1.start }

        if let hit = sorted.first(where: { normalize($0.text).contains(needle) }) {
            return hit.start
        }

        if sorted.count > 1 {
            for index in 0..<(sorted.count - 1) {
                let joined = normalize(sorted[index].text + " " + sorted[index + 1].text)
                if joined.contains(needle) {
                    return sorted[index].start
                }
            }
        }

        let needleWords = wordSet(needle)
        guard !needleWords.isEmpty else { return nil }
        var best: (start: TimeInterval, score: Int)?
        for segment in sorted {
            let score = needleWords.intersection(wordSet(normalize(segment.text))).count
            guard score > 0 else { continue }
            if best == nil || score > best!.score {
                best = (segment.start, score)
            }
        }
        guard let best, best.score >= 3 else { return nil }
        return best.start
    }

    private static func normalize(_ text: String) -> String {
        text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func wordSet(_ text: String) -> Set<Substring> {
        Set(text.split(separator: " ").filter { $0.count > 2 })
    }
}

/// Conformed by every taxonomy type with an `evidence`/quote-derived timestamp field, so the
/// resolver can update them generically.
protocol TimestampedEvidence {
    var timestamp: TimeInterval? { get set }
}

extension Decision: TimestampedEvidence {}
extension ActionItem: TimestampedEvidence {}
extension Ask: TimestampedEvidence {}
extension ResolvedInMeetingItem: TimestampedEvidence {}
extension OpenQuestion: TimestampedEvidence {}
extension Blocker: TimestampedEvidence {}
extension KeyDate: TimestampedEvidence {}
extension Metric: TimestampedEvidence {}
extension Quote: TimestampedEvidence {}
