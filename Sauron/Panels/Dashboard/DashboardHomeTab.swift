import SwiftData
import SwiftUI

struct DashboardHomeTab: View {
    @Environment(AppState.self) private var appState
    var onAsk: (String) -> Void
    var onOpenLibrary: () -> Void
    var onOpenAsks: () -> Void
    var onOpenInsights: () -> Void

    @State private var askDraft = ""

    var body: some View {
        let meetings = MeetingStore.all(context: appState.modelContext)
        let asks = TrackedItemStore.all(context: appState.modelContext).filter { $0.status == .open }
        let week = Calendar.current.date(byAdding: .day, value: -7, to: .now) ?? .now
        let prior = Calendar.current.date(byAdding: .day, value: -14, to: .now) ?? .now
        let thisWeek = meetings.filter { $0.startedAt >= week }
        let lastWeek = meetings.filter { $0.startedAt >= prior && $0.startedAt < week }
        let hours = thisWeek.reduce(0.0) { $0 + $1.duration } / 3600
        let priorHours = lastWeek.reduce(0.0) { $0 + $1.duration } / 3600
        let avg = thisWeek.isEmpty ? 0 : thisWeek.reduce(0.0) { $0 + $1.duration } / Double(thisWeek.count) / 60
        let overdue = asks.filter { Date().timeIntervalSince($0.createdAt) > 7 * 86_400 }

        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                DashboardScreenHeader(title: "Home", subtitle: "What happened, what’s next, what needs you.")

                askBar

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
                    Button { onOpenInsights() } label: {
                        StatTile(
                            label: "Meetings this week",
                            value: "\(thisWeek.count)",
                            delta: delta(thisWeek.count - lastWeek.count),
                            deltaPositive: thisWeek.count >= lastWeek.count,
                            spark: spark(from: meetings, days: 7)
                        )
                    }
                    .buttonStyle(.plain)
                    Button { onOpenAsks() } label: {
                        StatTile(
                            label: "Open asks",
                            value: "\(asks.count)",
                            delta: overdue.isEmpty ? nil : "\(overdue.count) overdue",
                            deltaPositive: overdue.isEmpty,
                            spark: askSpark(asks)
                        )
                    }
                    .buttonStyle(.plain)
                    StatTile(
                        label: "Hours (7d)",
                        value: String(format: "%.1fh", hours),
                        delta: String(format: "%+.1fh", hours - priorHours),
                        deltaPositive: hours >= priorHours,
                        spark: hourSpark(from: meetings)
                    )
                    StatTile(
                        label: "Avg duration",
                        value: avg == 0 ? "—" : "\(Int(avg))m",
                        delta: nil,
                        spark: spark(from: meetings, days: 7)
                    )
                }

                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 16) {
                        upNextCard()
                        recentSection(meetings: Array(meetings.prefix(5)))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(alignment: .leading, spacing: 16) {
                        needsYou(asks: Array((overdue + asks).uniqued(by: \.id).prefix(6)))
                        threadsCard
                    }
                    .frame(width: 320)
                }
            }
            .padding(24)
        }
    }

    private var askBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .foregroundStyle(SauronTheme.irisGradient)
                TextField("Ask anything about your meetings…", text: $askDraft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .foregroundStyle(SauronTheme.textPrimary)
                    .onSubmit { submitAsk() }
                Button(action: submitAsk) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(SauronTheme.irisGradient, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(askDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(SauronTheme.irisSolid.opacity(0.35), lineWidth: 1)
            )

            HStack(spacing: 8) {
                ForEach(suggestions, id: \.self) { chip in
                    Button(chip) {
                        askDraft = chip
                        submitAsk()
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(SauronTheme.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(SauronTheme.surface, in: Capsule())
                    .overlay(Capsule().strokeBorder(SauronTheme.hairline, lineWidth: 1))
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var suggestions: [String] {
        [
            "What did I commit to this week?",
            "Summarize my last meeting",
            "Which asks are overdue?"
        ]
    }

    private func submitAsk() {
        let q = askDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        onAsk(q)
        askDraft = ""
    }

    private func upNextCard() -> some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let now = context.date
            let upcoming = CalendarSignal.upcoming(
                now: now,
                lookAhead: 7 * 24 * 60 * 60,
                limit: 1,
                subscribedCalendarIDs: appState.settings.effectiveSubscribedCalendarIDs
            )
            let next = upcoming.first

            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    DashboardOverline(text: "Up next")
                    Spacer()
                    Text(now.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(SauronTheme.textTertiary)
                }

                if !CalendarSignal.hasFullAccess {
                    Text("Calendar access needed")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(SauronTheme.textPrimary)
                    Text("Grant calendar access in Permissions, then pick calendars in Settings → General.")
                        .font(.system(size: 13))
                        .foregroundStyle(SauronTheme.textSecondary)
                } else if appState.settings.calendarSubscriptionsConfigured,
                          appState.settings.subscribedCalendarIDs.isEmpty {
                    Text("No calendars selected")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(SauronTheme.textPrimary)
                    Text("Choose which calendars to follow in Settings → General.")
                        .font(.system(size: 13))
                        .foregroundStyle(SauronTheme.textSecondary)
                } else if let next {
                    Text(next.timingLabel(at: now))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(SauronTheme.textSecondary)
                    Text(next.title)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(SauronTheme.textPrimary)
                    HStack(spacing: 8) {
                        Label(next.calendarTitle, systemImage: "calendar")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(SauronTheme.textSecondary)
                        if let location = next.location, !location.isEmpty {
                            Text("·")
                                .foregroundStyle(SauronTheme.textTertiary)
                            Text(location)
                                .font(.system(size: 12))
                                .foregroundStyle(SauronTheme.textSecondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        if next.isInProgress(at: now) {
                            Text("Now")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(SauronTheme.irisSolid)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(SauronTheme.irisSolid.opacity(0.15), in: Capsule())
                        }
                    }
                } else {
                    Text("Nothing upcoming")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(SauronTheme.textPrimary)
                    Text("No events in the next 7 days on your subscribed calendars.")
                        .font(.system(size: 13))
                        .foregroundStyle(SauronTheme.textSecondary)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                LinearGradient(
                    colors: [SauronTheme.irisStart.opacity(0.28), SauronTheme.irisEnd.opacity(0.12), SauronTheme.surface],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: SauronTheme.radiusPanel, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: SauronTheme.radiusPanel, style: .continuous)
                    .strokeBorder(SauronTheme.irisSolid.opacity(0.25), lineWidth: 1)
            )
        }
    }

    private func recentSection(meetings: [Meeting]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                DashboardOverline(text: "Recent")
                Spacer()
                Button("View all in Library", action: onOpenLibrary)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(SauronTheme.irisSolid)
                    .buttonStyle(.plain)
            }
            if meetings.isEmpty {
                DashboardEmptyState(
                    systemImage: "waveform",
                    title: "No meetings yet",
                    message: "Record a meeting to fill Home, Library, and Memory.",
                    actionTitle: "Simulate meeting",
                    action: { appState.simulateMeeting() }
                )
                .frame(height: 180)
                .observerSurfaceCard()
            } else {
                ForEach(meetings) { meeting in
                    MeetingRowCard(meeting: meeting) {
                        appState.openReport(meeting)
                    } onAsk: {
                        onAsk("Tell me about \(meeting.title)")
                    }
                }
            }
        }
    }

    private func needsYou(asks: [TrackedItem]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                DashboardOverline(text: "Needs you")
                Spacer()
                Button("All asks", action: onOpenAsks)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(SauronTheme.irisSolid)
                    .buttonStyle(.plain)
            }
            if asks.isEmpty {
                Text("You’re clear — no open asks.")
                    .font(.system(size: 13))
                    .foregroundStyle(SauronTheme.textSecondary)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .observerSurfaceCard()
            } else {
                ForEach(asks, id: \.id) { item in
                    AskRowCard(item: item) {
                        TrackedItemStore.complete(item, by: .manual, context: appState.modelContext)
                    } onOpenSource: {
                        if let meeting = MeetingStore.meeting(id: item.sourceMeetingID, context: appState.modelContext) {
                            appState.openReport(meeting)
                        }
                    }
                }
            }
        }
    }

    private var threadsCard: some View {
        let threads = DashboardChatStore.shared.allThreads().prefix(3)
        return VStack(alignment: .leading, spacing: 10) {
            DashboardOverline(text: "Threads")
            if threads.isEmpty {
                Text("Ask conversations will appear here.")
                    .font(.system(size: 13))
                    .foregroundStyle(SauronTheme.textSecondary)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .observerSurfaceCard()
            } else {
                ForEach(Array(threads)) { thread in
                    Button {
                        onAsk(thread.title)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(thread.title)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(SauronTheme.textPrimary)
                                .lineLimit(1)
                            if let last = thread.messages.last(where: { $0.role == "assistant" }) {
                                Text(last.content)
                                    .font(.system(size: 12))
                                    .foregroundStyle(SauronTheme.textSecondary)
                                    .lineLimit(2)
                            }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .observerSurfaceCard()
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func delta(_ value: Int) -> String? {
        guard value != 0 else { return nil }
        return String(format: "%+d", value)
    }

    private func spark(from meetings: [Meeting], days: Int) -> [Double] {
        let calendar = Calendar.current
        return (0..<days).reversed().map { offset in
            let day = calendar.date(byAdding: .day, value: -offset, to: .now) ?? .now
            return Double(meetings.filter { calendar.isDate($0.startedAt, inSameDayAs: day) }.count)
        }
    }

    private func hourSpark(from meetings: [Meeting]) -> [Double] {
        let calendar = Calendar.current
        return (0..<7).reversed().map { offset in
            let day = calendar.date(byAdding: .day, value: -offset, to: .now) ?? .now
            let hours = meetings.filter { calendar.isDate($0.startedAt, inSameDayAs: day) }
                .reduce(0.0) { $0 + $1.duration } / 3600
            return hours
        }
    }

    private func askSpark(_ asks: [TrackedItem]) -> [Double] {
        let calendar = Calendar.current
        return (0..<7).reversed().map { offset in
            let day = calendar.date(byAdding: .day, value: -offset, to: .now) ?? .now
            return Double(asks.filter { calendar.isDate($0.createdAt, inSameDayAs: day) }.count)
        }
    }
}

private extension Array {
    func uniqued<ID: Hashable>(by key: KeyPath<Element, ID>) -> [Element] {
        var seen = Set<ID>()
        return filter { seen.insert($0[keyPath: key]).inserted }
    }
}
