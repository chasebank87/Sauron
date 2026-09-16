import Foundation
import SwiftData

@MainActor
enum TrackedItemProposalStore {
    static func all(context: ModelContext) -> [TrackedItemProposal] {
        let descriptor = FetchDescriptor<TrackedItemProposal>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    static func unresolved(context: ModelContext) -> [TrackedItemProposal] {
        all(context: context).filter { !$0.isResolved }
    }

    @discardableResult
    static func create(
        trackedItemID: UUID?,
        sourceMeetingID: UUID,
        sourceMeetingTitle: String,
        proposedStatus: PriorItemStatus,
        verification: TrackedItemVerification,
        confidence: Double,
        note: String,
        evidence: String,
        newOwner: String? = nil,
        supersededByText: String? = nil,
        context: ModelContext
    ) -> TrackedItemProposal {
        let proposal = TrackedItemProposal(
            trackedItemID: trackedItemID,
            sourceMeetingID: sourceMeetingID,
            sourceMeetingTitle: sourceMeetingTitle,
            proposedStatus: proposedStatus,
            verification: verification,
            confidence: confidence,
            note: note,
            evidence: evidence,
            newOwner: newOwner,
            supersededByText: supersededByText
        )
        context.insert(proposal)
        try? context.save()
        return proposal
    }

    /// Applies the proposal's intended mutation where the target `TrackedItem`'s status machine
    /// supports it (completed/dropped only — see TrackedItemReconciler's auto-apply note), then
    /// marks the proposal resolved either way.
    static func apply(_ proposal: TrackedItemProposal, context: ModelContext) {
        if let trackedItemID = proposal.trackedItemID,
           let item = TrackedItemStore.all(context: context).first(where: { $0.id == trackedItemID }) {
            switch proposal.proposedStatus {
            case .completed:
                TrackedItemStore.complete(item, by: .agent, note: proposal.note, context: context)
            case .dropped:
                TrackedItemStore.dismiss(item, by: .agent, context: context)
            case .inProgress, .blocked, .reassigned, .superseded:
                break
            }
        }
        proposal.resolvedAt = .now
        proposal.resolvedAction = .applied
        try? context.save()
    }

    static func dismiss(_ proposal: TrackedItemProposal, context: ModelContext) {
        proposal.resolvedAt = .now
        proposal.resolvedAction = .dismissed
        try? context.save()
    }

    static func deleteLinked(to meetingIDs: Set<UUID>, context: ModelContext) {
        guard !meetingIDs.isEmpty else { return }
        for proposal in all(context: context) where meetingIDs.contains(proposal.sourceMeetingID) {
            context.delete(proposal)
        }
        try? context.save()
    }
}
