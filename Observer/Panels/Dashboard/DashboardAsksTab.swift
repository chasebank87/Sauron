import SwiftData
import SwiftUI

struct DashboardAsksTab: View {
    @Environment(AppState.self) private var appState
    @State private var filter: AskFilter = .open
    @State private var selectedID: UUID?
    @State private var query = ""

    private enum AskFilter: String, CaseIterable {
        case open = "Open"
        case done = "Done"
        case all = "All"
    }

    var body: some View {
        let items = filtered(TrackedItemStore.all(context: appState.modelContext))
        let selected = items.first { $0.id == selectedID } ?? items.first

        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                header
                if items.isEmpty {
                    DashboardEmptyState(
                        systemImage: "checklist",
                        title: "No open asks",
                        message: "Action items and questions from meeting summaries land here.",
                        actionTitle: "Open Library",
                        action: { appState.dashboardSelectedTab = .library }
                    )
                } else {
                    List(selection: $selectedID) {
                        ForEach(grouped(items), id: \.title) { group in
                            Section(group.title) {
                                ForEach(group.items, id: \.id) { item in
                                    AskRowCard(
                                        item: item,
                                        onToggle: { toggle(item) },
                                        onOpenSource: { selectedID = item.id },
                                        selected: selectedID == item.id
                                    )
                                    .tag(item.id)
                                    .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
                                    .listRowBackground(Color.clear)
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .frame(maxWidth: .infinity)

            Divider().overlay(ObserverTheme.hairlineStrong)

            inspector(selected)
                .frame(width: 320)
        }
        .onAppear {
            if selectedID == nil {
                selectedID = items.first?.id
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            DashboardScreenHeader(title: "Asks", subtitle: "Commitments, questions, and blockers across meetings.")
            HStack {
                Picker("Status", selection: $filter) {
                    ForEach(AskFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 280)
                Spacer()
                DashboardSearchField(placeholder: "Search asks", text: $query)
                    .frame(maxWidth: 260)
            }
        }
        .padding(24)
        .padding(.bottom, 4)
    }

    private func inspector(_ item: TrackedItem?) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            DashboardOverline(text: "Detail")
            if let item {
                Text(item.text)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(ObserverTheme.textPrimary)
                VStack(alignment: .leading, spacing: 8) {
                    meta("Kind", item.kind.title)
                    meta("Source", item.sourceMeetingTitle)
                    if let owner = item.owner, !owner.isEmpty {
                        meta("Owner", owner)
                    }
                    if let note = item.resolutionNote, !note.isEmpty {
                        meta("Resolution", note)
                    }
                }
                .padding(14)
                .observerSurfaceCard()

                VStack(alignment: .leading, spacing: 8) {
                    DashboardOverline(text: "From the meeting")
                    Text("Open the source meeting report to review transcript context and mark related asks.")
                        .font(.system(size: 12))
                        .foregroundStyle(ObserverTheme.textSecondary)
                    Button("Open source meeting") {
                        if let meeting = MeetingStore.meeting(id: item.sourceMeetingID, context: appState.modelContext) {
                            appState.openReport(meeting)
                        }
                    }
                    .observerGlassButton()
                }

                Spacer()
                HStack {
                    if item.status == .open {
                        Button("Mark done") {
                            TrackedItemStore.complete(item, by: .manual, context: appState.modelContext)
                        }
                        .observerGlassProminentButton()
                        Button("Dismiss") {
                            TrackedItemStore.dismiss(item, context: appState.modelContext)
                        }
                        .observerGlassButton()
                    } else {
                        Button("Reopen") {
                            TrackedItemStore.reopen(item, context: appState.modelContext)
                        }
                        .observerGlassProminentButton()
                    }
                }
            } else {
                Text("Select an ask")
                    .foregroundStyle(ObserverTheme.textSecondary)
                Spacer()
            }
        }
        .padding(20)
        .background(ObserverTheme.surfaceSunken)
    }

    private func meta(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(ObserverTheme.textTertiary)
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(ObserverTheme.textPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
        }
    }

    private func filtered(_ items: [TrackedItem]) -> [TrackedItem] {
        items.filter { item in
            switch filter {
            case .open: if item.status != .open { return false }
            case .done: if item.status != .done { return false }
            case .all: break
            }
            let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !q.isEmpty else { return true }
            return item.text.lowercased().contains(q) || item.sourceMeetingTitle.lowercased().contains(q)
        }
    }

    private struct Group {
        var title: String
        var items: [TrackedItem]
    }

    private func grouped(_ items: [TrackedItem]) -> [Group] {
        let overdue = items.filter { $0.status == .open && Date().timeIntervalSince($0.createdAt) > 7 * 86_400 }
        let overdueIDs = Set(overdue.map(\.id))
        let week = Calendar.current.date(byAdding: .day, value: -7, to: .now) ?? .now
        let thisWeek = items.filter { $0.status == .open && !overdueIDs.contains($0.id) && $0.createdAt >= week }
        let later = items.filter { $0.status == .open && !overdueIDs.contains($0.id) && $0.createdAt < week }
        let done = items.filter { $0.status != .open }

        var groups: [Group] = []
        if filter != .done {
            if !overdue.isEmpty { groups.append(Group(title: "Overdue (\(overdue.count))", items: overdue)) }
            if !thisWeek.isEmpty { groups.append(Group(title: "This week (\(thisWeek.count))", items: thisWeek)) }
            if !later.isEmpty { groups.append(Group(title: "Earlier (\(later.count))", items: later)) }
        }
        if filter != .open, !done.isEmpty {
            groups.append(Group(title: "Done (\(done.count))", items: done))
        }
        return groups
    }

    private func toggle(_ item: TrackedItem) {
        if item.status == .open {
            TrackedItemStore.complete(item, by: .manual, context: appState.modelContext)
        } else {
            TrackedItemStore.reopen(item, context: appState.modelContext)
        }
    }
}
