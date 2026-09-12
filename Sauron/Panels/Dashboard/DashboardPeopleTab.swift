import SwiftData
import SwiftUI

struct DashboardPeopleTab: View {
    @Environment(AppState.self) private var appState
    private let store = SpeakerProfileStore.shared
    @State private var query = ""
    @State private var selectedID: UUID?

    var body: some View {
        let meetings = MeetingStore.all(context: appState.modelContext)
        let people = [store.selfProfile] + store.otherProfiles
        let filtered = people.filter {
            query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)
        }
        let selected = filtered.first { $0.id == selectedID } ?? filtered.first

        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    DashboardScreenHeader(title: "People", subtitle: "Speakers across your meetings.")
                    DashboardSearchField(placeholder: "Search people", text: $query)
                }
                .padding(24)

                if filtered.isEmpty {
                    DashboardEmptyState(
                        systemImage: "person.2",
                        title: "No people yet",
                        message: "Assign remote speakers from a meeting report to build this list.",
                        actionTitle: "Open Library",
                        action: { appState.dashboardSelectedTab = .library }
                    )
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 12)], spacing: 12) {
                            ForEach(filtered, id: \.id) { profile in
                                personCard(profile, meetings: meetings, selected: selected?.id == profile.id)
                                    .onTapGesture { selectedID = profile.id }
                            }
                        }
                        .padding(.horizontal, 24)
                        .padding(.bottom, 24)
                    }
                }
            }
            .frame(maxWidth: .infinity)

            Divider().overlay(SauronTheme.hairlineStrong)
            detail(selected, meetings: meetings)
                .frame(width: 320)
        }
        .onAppear {
            store.attach(context: appState.modelContext)
            selectedID = filtered.first?.id
        }
    }

    private func personCard(_ profile: SpeakerProfile, meetings: [Meeting], selected: Bool) -> some View {
        let related = meetingsFor(profile, in: meetings)
        let hours = related.reduce(0.0) { $0 + $1.duration } / 3600
        let relatedIDs = Set(related.map(\.id))
        let openAsks = TrackedItemStore.all(context: appState.modelContext)
            .filter { $0.status == .open && relatedIDs.contains($0.sourceMeetingID) }

        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .strokeBorder(SauronTheme.irisGradient, lineWidth: 2)
                        .frame(width: 44, height: 44)
                    Text(String(profile.name.prefix(1)).uppercased())
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(SauronTheme.textPrimary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(SauronTheme.textPrimary)
                    Text(profile.isSelf ? "You" : "Participant")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(SauronTheme.textSecondary)
                }
            }
            HStack {
                stat("meetings", "\(related.count)")
                stat("hours", String(format: "%.1f", hours))
                stat("open asks", "\(openAsks.count)")
            }
            if selected {
                HStack(spacing: 8) {
                    Button("Ask about them") { appState.dashboardSelectedTab = .ask }
                        .observerGlassProminentButton()
                    Button("Timeline") {
                        if let first = related.first { appState.openReport(first) }
                    }
                    .observerGlassButton()
                }
            }
        }
        .padding(14)
        .background(selected ? SauronTheme.surfaceElevated : SauronTheme.surface, in: RoundedRectangle(cornerRadius: SauronTheme.radiusCard, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: SauronTheme.radiusCard, style: .continuous)
                .strokeBorder(selected ? SauronTheme.irisSolid.opacity(0.45) : SauronTheme.hairline, lineWidth: 1)
        )
    }

    private func detail(_ profile: SpeakerProfile?, meetings: [Meeting]) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            DashboardOverline(text: "Person")
            if let profile {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .strokeBorder(SauronTheme.irisGradient, lineWidth: 2)
                            .frame(width: 56, height: 56)
                        Text(String(profile.name.prefix(1)).uppercased())
                            .font(.system(size: 20, weight: .semibold))
                    }
                    Text(profile.name)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(SauronTheme.textPrimary)
                }
                let related = meetingsFor(profile, in: meetings)
                VStack(alignment: .leading, spacing: 8) {
                    DashboardOverline(text: "Relationship")
                    meta("Meetings", "\(related.count)")
                    if let last = related.first {
                        meta("Last met", last.startedAt.formatted(date: .abbreviated, time: .shortened))
                    }
                    if let first = related.last {
                        meta("First met", first.startedAt.formatted(date: .abbreviated, time: .omitted))
                    }
                }
                .padding(12)
                .observerSurfaceCard()

                VStack(alignment: .leading, spacing: 8) {
                    DashboardOverline(text: "Recent meetings")
                    ForEach(related.prefix(5)) { meeting in
                        Button {
                            appState.openReport(meeting)
                        } label: {
                            HStack {
                                Text(meeting.title)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(SauronTheme.textPrimary)
                                    .lineLimit(1)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(SauronTheme.textTertiary)
                            }
                            .padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)
                    }
                }
                Spacer()
                Button("Ask about this person") { appState.dashboardSelectedTab = .ask }
                    .observerGlassProminentButton()
            } else {
                Text("Select a person")
                    .foregroundStyle(SauronTheme.textSecondary)
                Spacer()
            }
        }
        .padding(20)
        .background(SauronTheme.surfaceSunken)
    }

    private func meetingsFor(_ profile: SpeakerProfile, in meetings: [Meeting]) -> [Meeting] {
        let key = profile.speakerKey
        return meetings.filter { meeting in
            meeting.segments.contains { $0.speakerKey == key }
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(SauronTheme.textPrimary)
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(SauronTheme.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func meta(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(SauronTheme.textTertiary)
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(SauronTheme.textPrimary)
        }
    }
}
