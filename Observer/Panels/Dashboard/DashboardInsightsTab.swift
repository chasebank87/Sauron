import Charts
import SwiftData
import SwiftUI

struct DashboardInsightsTab: View {
    @Environment(AppState.self) private var appState
    @State private var rangeDays = 30

    var body: some View {
        let meetings = MeetingStore.all(context: appState.modelContext)
        let items = TrackedItemStore.all(context: appState.modelContext)
        let start = Calendar.current.date(byAdding: .day, value: -rangeDays, to: .now) ?? .now
        let priorStart = Calendar.current.date(byAdding: .day, value: -(rangeDays * 2), to: .now) ?? .now
        let window = meetings.filter { $0.startedAt >= start }
        let prior = meetings.filter { $0.startedAt >= priorStart && $0.startedAt < start }
        let hours = window.reduce(0.0) { $0 + $1.duration } / 3600
        let priorHours = prior.reduce(0.0) { $0 + $1.duration } / 3600
        let openAsks = items.filter { $0.status == .open }
        let doneAsks = items.filter { $0.status == .done }
        let byKind = Dictionary(grouping: window, by: \.kind)

        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .top) {
                    DashboardScreenHeader(title: "Insights", subtitle: "Trends from your meetings — color only on the data.")
                    Spacer()
                    Picker("Range", selection: $rangeDays) {
                        Text("7d").tag(7)
                        Text("30d").tag(30)
                        Text("90d").tag(90)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 180)
                }

                highlights(window: window, prior: prior, openAsks: openAsks)

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
                    StatTile(
                        label: "Meetings",
                        value: "\(window.count)",
                        delta: String(format: "%+d", window.count - prior.count),
                        deltaPositive: window.count >= prior.count,
                        spark: dailyCounts(window, days: min(rangeDays, 14)).map(\.count)
                    )
                    StatTile(
                        label: "Hours",
                        value: String(format: "%.1f", hours),
                        delta: String(format: "%+.1f", hours - priorHours),
                        deltaPositive: hours >= priorHours,
                        spark: dailyHours(window, days: min(rangeDays, 14))
                    )
                    StatTile(
                        label: "Open asks",
                        value: "\(openAsks.count)",
                        delta: doneAsks.isEmpty ? nil : "\(doneAsks.count) done",
                        deltaPositive: true,
                        spark: [Double(openAsks.count)]
                    )
                    StatTile(
                        label: "Avg duration",
                        value: window.isEmpty ? "—" : "\(Int(window.reduce(0.0) { $0 + $1.duration } / Double(window.count) / 60))m",
                        spark: dailyCounts(window, days: min(rangeDays, 14)).map(\.count)
                    )
                }

                if window.isEmpty {
                    DashboardEmptyState(
                        systemImage: "chart.xyaxis.line",
                        title: "Not enough data yet",
                        message: "Record a few meetings to see trends, distributions, and ask aging.",
                        actionTitle: "Simulate meeting",
                        action: { appState.simulateMeeting() }
                    )
                    .frame(height: 240)
                    .observerSurfaceCard()
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Meeting hours per day")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(ObserverTheme.textPrimary)
                        Text("Volume across the selected range.")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(ObserverTheme.textSecondary)
                        Chart {
                            ForEach(dailyHoursPoints(window, days: rangeDays), id: \.day) { row in
                                AreaMark(
                                    x: .value("Day", row.day),
                                    y: .value("Hours", row.hours)
                                )
                                .foregroundStyle(ObserverTheme.irisGradient.opacity(0.35))
                                LineMark(
                                    x: .value("Day", row.day),
                                    y: .value("Hours", row.hours)
                                )
                                .foregroundStyle(ObserverTheme.irisSolid)
                                .lineStyle(StrokeStyle(lineWidth: 1.5))
                            }
                        }
                        .chartXAxis {
                            AxisMarks(values: .stride(by: .day, count: max(1, rangeDays / 7))) { _ in
                                AxisGridLine().foregroundStyle(ObserverTheme.hairline)
                                AxisValueLabel().foregroundStyle(ObserverTheme.textTertiary)
                            }
                        }
                        .chartYAxis {
                            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                                AxisGridLine().foregroundStyle(Color.white.opacity(0.06))
                                AxisValueLabel().foregroundStyle(ObserverTheme.textTertiary)
                            }
                        }
                        .frame(height: 200)
                        .padding(16)
                        .observerSurfaceCard()
                    }

                    HStack(alignment: .top, spacing: 16) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("By app")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(ObserverTheme.textPrimary)
                            Chart {
                                ForEach(Array(byKind.keys.sorted { $0.displayName < $1.displayName }), id: \.self) { kind in
                                    BarMark(
                                        x: .value("Count", byKind[kind]?.count ?? 0),
                                        y: .value("App", kind.displayName)
                                    )
                                    .foregroundStyle(ObserverTheme.irisGradient)
                                }
                            }
                            .frame(height: 180)
                            .padding(16)
                            .observerSurfaceCard()
                        }
                        .frame(maxWidth: .infinity)

                        askAging(items: openAsks)
                            .frame(maxWidth: .infinity)
                    }

                    topTopics(window)
                }
            }
            .padding(24)
        }
    }

    private func highlights(window: [Meeting], prior: [Meeting], openAsks: [TrackedItem]) -> some View {
        let delta = window.count - prior.count
        let line1 = delta == 0
            ? "Meeting volume is flat versus the prior period."
            : "Meetings are \(delta > 0 ? "up" : "down") \(abs(delta)) versus the prior period."
        let line2 = openAsks.isEmpty
            ? "No open asks right now."
            : "\(openAsks.count) open asks still need attention."
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: "sparkles")
                .foregroundStyle(ObserverTheme.irisGradient)
            VStack(alignment: .leading, spacing: 4) {
                Text("AI highlights")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(ObserverTheme.irisSolid)
                Text("\(line1) \(line2)")
                    .font(.system(size: 13))
                    .foregroundStyle(ObserverTheme.textPrimary)
            }
            Spacer()
        }
        .padding(16)
        .background(
            LinearGradient(
                colors: [ObserverTheme.irisStart.opacity(0.16), ObserverTheme.surface],
                startPoint: .leading,
                endPoint: .trailing
            ),
            in: RoundedRectangle(cornerRadius: ObserverTheme.radiusCard, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: ObserverTheme.radiusCard, style: .continuous)
                .strokeBorder(ObserverTheme.irisSolid.opacity(0.28), lineWidth: 1)
        )
    }

    private func askAging(items: [TrackedItem]) -> some View {
        let fresh = items.filter { Date().timeIntervalSince($0.createdAt) <= 3 * 86_400 }.count
        let mid = items.filter {
            let age = Date().timeIntervalSince($0.createdAt)
            return age > 3 * 86_400 && age <= 7 * 86_400
        }.count
        let old = items.filter { Date().timeIntervalSince($0.createdAt) > 7 * 86_400 }.count
        let total = max(items.count, 1)

        return VStack(alignment: .leading, spacing: 8) {
            Text("Ask aging")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(ObserverTheme.textPrimary)
            VStack(alignment: .leading, spacing: 10) {
                agingRow("New", count: fresh, total: total, color: ObserverTheme.mint)
                agingRow("In progress", count: mid, total: total, color: ObserverTheme.amber)
                agingRow("Overdue", count: old, total: total, color: ObserverTheme.red)
            }
            .padding(16)
            .observerSurfaceCard()
        }
    }

    private func agingRow(_ title: String, count: Int, total: Int, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(ObserverTheme.textSecondary)
                Spacer()
                Text("\(count)")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(ObserverTheme.textPrimary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(ObserverTheme.surfaceElevated)
                    Capsule()
                        .fill(color)
                        .frame(width: geo.size.width * CGFloat(count) / CGFloat(total))
                }
            }
            .frame(height: 8)
        }
    }

    private func topTopics(_ meetings: [Meeting]) -> some View {
        let topics = meetings.compactMap(\.summary).flatMap(\.topics)
        let counts = Dictionary(grouping: topics, by: { $0 }).mapValues(\.count)
        let top = counts.sorted { $0.value > $1.value }.prefix(12)
        return VStack(alignment: .leading, spacing: 8) {
            Text("Top topics")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(ObserverTheme.textPrimary)
            if top.isEmpty {
                Text("Topics appear after meetings are summarized.")
                    .font(.system(size: 12))
                    .foregroundStyle(ObserverTheme.textSecondary)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .observerSurfaceCard()
            } else {
                FlowLayout(spacing: 8) {
                    ForEach(Array(top), id: \.key) { item in
                        TopicChip(text: "\(item.key) · \(item.value)")
                    }
                }
                .padding(16)
                .observerSurfaceCard()
            }
        }
    }

    private struct DayCount {
        var day: Date
        var count: Double
    }

    private struct DayHours {
        var day: Date
        var hours: Double
    }

    private func dailyCounts(_ meetings: [Meeting], days: Int) -> [DayCount] {
        let calendar = Calendar.current
        return (0..<days).reversed().map { offset in
            let day = calendar.startOfDay(for: calendar.date(byAdding: .day, value: -offset, to: .now) ?? .now)
            let count = Double(meetings.filter { calendar.isDate($0.startedAt, inSameDayAs: day) }.count)
            return DayCount(day: day, count: count)
        }
    }

    private func dailyHours(_ meetings: [Meeting], days: Int) -> [Double] {
        dailyHoursPoints(meetings, days: days).map(\.hours)
    }

    private func dailyHoursPoints(_ meetings: [Meeting], days: Int) -> [DayHours] {
        let calendar = Calendar.current
        return (0..<min(days, 30)).reversed().map { offset in
            let day = calendar.startOfDay(for: calendar.date(byAdding: .day, value: -offset, to: .now) ?? .now)
            let hours = meetings.filter { calendar.isDate($0.startedAt, inSameDayAs: day) }
                .reduce(0.0) { $0 + $1.duration } / 3600
            return DayHours(day: day, hours: hours)
        }
    }
}

/// Simple wrapping layout for topic chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = compute(proposal.replacingUnspecifiedDimensions().width, subviews: subviews)
        let height = rows.reduce(0) { $0 + $1.height + spacing } - spacing
        return CGSize(width: proposal.width ?? 0, height: max(0, height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = compute(bounds.width, subviews: subviews)
        var y = bounds.minY
        var index = 0
        for row in rows {
            var x = bounds.minX
            for _ in 0..<row.count {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
                index += 1
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var count: Int
        var height: CGFloat
    }

    private func compute(_ width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var count = 0
        var x: CGFloat = 0
        var height: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if count > 0, x + size.width > width {
                rows.append(Row(count: count, height: height))
                count = 0
                x = 0
                height = 0
            }
            count += 1
            height = max(height, size.height)
            x += size.width + spacing
        }
        if count > 0 { rows.append(Row(count: count, height: height)) }
        return rows
    }
}
