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
        let talkHours = window.reduce(0.0) { $0 + $1.selfTalkDuration } / 3600
        let priorTalkHours = prior.reduce(0.0) { $0 + $1.selfTalkDuration } / 3600
        let avgShare = averageTalkShare(window)
        let priorShare = averageTalkShare(prior)

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

                highlights(
                    window: window,
                    prior: prior,
                    openAsks: openAsks,
                    avgShare: avgShare,
                    priorShare: priorShare
                )

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
                        label: "Your talk",
                        value: String(format: "%.1fh", talkHours),
                        delta: String(format: "%+.1fh", talkHours - priorTalkHours),
                        deltaPositive: talkHours >= priorTalkHours,
                        spark: dailyTalkHours(window, days: min(rangeDays, 14))
                    )
                    StatTile(
                        label: "Talk share",
                        value: window.isEmpty ? "—" : String(format: "%.0f%%", avgShare * 100),
                        delta: prior.isEmpty ? nil : String(format: "%+.0f pts", (avgShare - priorShare) * 100),
                        deltaPositive: avgShare >= priorShare,
                        spark: dailyTalkShare(window, days: min(rangeDays, 14))
                    )
                }

                presenceSection(window: window, prior: prior)

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
                            .foregroundStyle(SauronTheme.textPrimary)
                        Text("Volume across the selected range.")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(SauronTheme.textSecondary)
                        Chart {
                            ForEach(dailyHoursPoints(window, days: rangeDays), id: \.day) { row in
                                AreaMark(
                                    x: .value("Day", row.day),
                                    y: .value("Hours", row.hours)
                                )
                                .foregroundStyle(SauronTheme.irisGradient.opacity(0.35))
                                LineMark(
                                    x: .value("Day", row.day),
                                    y: .value("Hours", row.hours)
                                )
                                .foregroundStyle(SauronTheme.irisSolid)
                                .lineStyle(StrokeStyle(lineWidth: 1.5))
                            }
                        }
                        .chartXAxis {
                            AxisMarks(values: .stride(by: .day, count: max(1, rangeDays / 7))) { _ in
                                AxisGridLine().foregroundStyle(SauronTheme.hairline)
                                AxisValueLabel().foregroundStyle(SauronTheme.textTertiary)
                            }
                        }
                        .chartYAxis {
                            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                                AxisGridLine().foregroundStyle(Color.white.opacity(0.06))
                                AxisValueLabel().foregroundStyle(SauronTheme.textTertiary)
                            }
                        }
                        .frame(height: 200)
                        .padding(16)
                        .observerSurfaceCard()
                    }

                    talkShareChart(window)

                    HStack(alignment: .top, spacing: 16) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("By app")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(SauronTheme.textPrimary)
                            Chart {
                                ForEach(Array(byKind.keys.sorted { $0.displayName < $1.displayName }), id: \.self) { kind in
                                    BarMark(
                                        x: .value("Count", byKind[kind]?.count ?? 0),
                                        y: .value("App", kind.displayName)
                                    )
                                    .foregroundStyle(SauronTheme.irisGradient)
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

    @ViewBuilder
    private func presenceSection(window: [Meeting], prior: [Meeting]) -> some View {
        let scored = window.compactMap(\.presence)
        let priorScored = prior.compactMap(\.presence)
        VStack(alignment: .leading, spacing: 12) {
            Text("Your presence")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(SauronTheme.textPrimary)
            Text("How you showed up — scored after each summary. Talk time comes from your transcript turns.")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(SauronTheme.textSecondary)

            if scored.isEmpty {
                Text("Presence scores appear after meetings are summarized.")
                    .font(.system(size: 12))
                    .foregroundStyle(SauronTheme.textSecondary)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .observerSurfaceCard()
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 5), spacing: 10) {
                    ForEach(PresenceDimension.allCases) { dimension in
                        let avg = average(for: dimension, in: scored)
                        let priorAvg = priorScored.isEmpty ? nil : average(for: dimension, in: priorScored)
                        presenceTile(
                            title: dimension.title,
                            value: avg,
                            delta: priorAvg.map { avg - $0 }
                        )
                    }
                }

                presenceOverTimeChart(window.filter { $0.presence != nil })
            }
        }
    }

    private func presenceTile(title: String, value: Double, delta: Double?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(SauronTheme.textSecondary)
                .lineLimit(1)
            Text(String(format: "%.1f", value))
                .font(.system(size: 22, weight: .semibold).monospacedDigit())
                .foregroundStyle(SauronTheme.textPrimary)
            if let delta {
                Text(String(format: "%+.1f", delta))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(delta >= 0 ? SauronTheme.mint : SauronTheme.red)
            } else {
                Text(" ")
                    .font(.system(size: 11, weight: .semibold))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .observerSurfaceCard()
    }

    private func presenceOverTimeChart(_ meetings: [Meeting]) -> some View {
        let points: [(date: Date, dimension: PresenceDimension, value: Double)] = meetings.flatMap { meeting -> [(Date, PresenceDimension, Double)] in
            guard let presence = meeting.presence else { return [] }
            return PresenceDimension.allCases.map { dim in
                (meeting.startedAt, dim, dim.value(in: presence))
            }
        }.map { (date: $0.0, dimension: $0.1, value: $0.2) }

        return VStack(alignment: .leading, spacing: 8) {
            Text("Presence over time")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(SauronTheme.textPrimary)
            Chart {
                ForEach(Array(points.enumerated()), id: \.offset) { _, point in
                    LineMark(
                        x: .value("Meeting", point.date),
                        y: .value("Score", point.value),
                        series: .value("Dimension", point.dimension.title)
                    )
                    .foregroundStyle(by: .value("Dimension", point.dimension.title))
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                    .interpolationMethod(.catmullRom)

                    PointMark(
                        x: .value("Meeting", point.date),
                        y: .value("Score", point.value)
                    )
                    .foregroundStyle(by: .value("Dimension", point.dimension.title))
                    .symbolSize(28)
                }
            }
            .chartForegroundStyleScale([
                PresenceDimension.likeability.title: SauronTheme.irisSolid,
                PresenceDimension.professionalism.title: SauronTheme.mint,
                PresenceDimension.receptiveness.title: SauronTheme.amber,
                PresenceDimension.clarity.title: Color(nsColor: .systemTeal),
                PresenceDimension.collaboration.title: SauronTheme.red.opacity(0.85)
            ])
            .chartYScale(domain: 1...10)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                    AxisGridLine().foregroundStyle(SauronTheme.hairline)
                    AxisValueLabel().foregroundStyle(SauronTheme.textTertiary)
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: [1, 4, 7, 10]) { _ in
                    AxisGridLine().foregroundStyle(Color.white.opacity(0.06))
                    AxisValueLabel().foregroundStyle(SauronTheme.textTertiary)
                }
            }
            .chartLegend(position: .bottom, alignment: .leading)
            .frame(height: 220)
            .padding(16)
            .observerSurfaceCard()
        }
    }

    private func talkShareChart(_ meetings: [Meeting]) -> some View {
        let points = meetings
            .sorted { $0.startedAt < $1.startedAt }
            .map { (date: $0.startedAt, share: $0.talkShare * 100) }

        return VStack(alignment: .leading, spacing: 8) {
            Text("Your talk share over time")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(SauronTheme.textPrimary)
            Text("Percent of each meeting where you were speaking (from transcript timings).")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(SauronTheme.textSecondary)
            if points.allSatisfy({ $0.share == 0 }) {
                Text("Talk share appears once self speaker turns are on the transcript.")
                    .font(.system(size: 12))
                    .foregroundStyle(SauronTheme.textSecondary)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .observerSurfaceCard()
            } else {
                Chart {
                    ForEach(Array(points.enumerated()), id: \.offset) { _, point in
                        AreaMark(
                            x: .value("Meeting", point.date),
                            y: .value("Share", point.share)
                        )
                        .foregroundStyle(SauronTheme.mint.opacity(0.22))
                        LineMark(
                            x: .value("Meeting", point.date),
                            y: .value("Share", point.share)
                        )
                        .foregroundStyle(SauronTheme.mint)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                        PointMark(
                            x: .value("Meeting", point.date),
                            y: .value("Share", point.share)
                        )
                        .foregroundStyle(SauronTheme.mint)
                        .symbolSize(28)
                    }
                }
                .chartYScale(domain: 0...100)
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                        AxisGridLine().foregroundStyle(SauronTheme.hairline)
                        AxisValueLabel().foregroundStyle(SauronTheme.textTertiary)
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: [0, 25, 50, 75, 100]) { _ in
                        AxisGridLine().foregroundStyle(Color.white.opacity(0.06))
                        AxisValueLabel().foregroundStyle(SauronTheme.textTertiary)
                    }
                }
                .frame(height: 200)
                .padding(16)
                .observerSurfaceCard()
            }
        }
    }

    private func highlights(
        window: [Meeting],
        prior: [Meeting],
        openAsks: [TrackedItem],
        avgShare: Double,
        priorShare: Double
    ) -> some View {
        let delta = window.count - prior.count
        var lines: [String] = []
        lines.append(
            delta == 0
                ? "Meeting volume is flat versus the prior period."
                : "Meetings are \(delta > 0 ? "up" : "down") \(abs(delta)) versus the prior period."
        )
        lines.append(
            openAsks.isEmpty
                ? "No open asks right now."
                : "\(openAsks.count) open asks still need attention."
        )

        let scored = window.compactMap(\.presence)
        let priorScored = prior.compactMap(\.presence)
        if !scored.isEmpty, !priorScored.isEmpty {
            for dimension in PresenceDimension.allCases {
                let now = average(for: dimension, in: scored)
                let before = average(for: dimension, in: priorScored)
                if abs(now - before) >= 0.5 {
                    lines.append(
                        "\(dimension.title) is \(now >= before ? "up" : "down") \(String(format: "%.1f", abs(now - before))) vs prior."
                    )
                    break
                }
            }
        }
        if !window.isEmpty, !prior.isEmpty, abs(avgShare - priorShare) >= 0.05 {
            let pts = Int((abs(avgShare - priorShare) * 100).rounded())
            lines.append(
                "Your talk share is \(avgShare >= priorShare ? "up" : "down") \(pts) pts versus the prior period."
            )
        }

        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: "sparkles")
                .foregroundStyle(SauronTheme.irisGradient)
            VStack(alignment: .leading, spacing: 4) {
                Text("AI highlights")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(SauronTheme.irisSolid)
                Text(lines.joined(separator: " "))
                    .font(.system(size: 13))
                    .foregroundStyle(SauronTheme.textPrimary)
            }
            Spacer()
        }
        .padding(16)
        .background(
            LinearGradient(
                colors: [SauronTheme.irisStart.opacity(0.16), SauronTheme.surface],
                startPoint: .leading,
                endPoint: .trailing
            ),
            in: RoundedRectangle(cornerRadius: SauronTheme.radiusCard, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: SauronTheme.radiusCard, style: .continuous)
                .strokeBorder(SauronTheme.irisSolid.opacity(0.28), lineWidth: 1)
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
                .foregroundStyle(SauronTheme.textPrimary)
            VStack(alignment: .leading, spacing: 10) {
                agingRow("New", count: fresh, total: total, color: SauronTheme.mint)
                agingRow("In progress", count: mid, total: total, color: SauronTheme.amber)
                agingRow("Overdue", count: old, total: total, color: SauronTheme.red)
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
                    .foregroundStyle(SauronTheme.textSecondary)
                Spacer()
                Text("\(count)")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(SauronTheme.textPrimary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(SauronTheme.surfaceElevated)
                    Capsule()
                        .fill(color)
                        .frame(width: geo.size.width * CGFloat(count) / CGFloat(total))
                }
            }
            .frame(height: 8)
        }
    }

    private func topTopics(_ meetings: [Meeting]) -> some View {
        let topics = meetings.compactMap(\.summary).flatMap(\.topics).map(\.title)
        let counts = Dictionary(grouping: topics, by: { $0 }).mapValues(\.count)
        let top = counts.sorted { $0.value > $1.value }.prefix(12)
        return VStack(alignment: .leading, spacing: 8) {
            Text("Top topics")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(SauronTheme.textPrimary)
            if top.isEmpty {
                Text("Topics appear after meetings are summarized.")
                    .font(.system(size: 12))
                    .foregroundStyle(SauronTheme.textSecondary)
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

    private func average(for dimension: PresenceDimension, in scores: [MeetingPresenceScores]) -> Double {
        guard !scores.isEmpty else { return 0 }
        return scores.reduce(0) { $0 + dimension.value(in: $1) } / Double(scores.count)
    }

    private func averageTalkShare(_ meetings: [Meeting]) -> Double {
        guard !meetings.isEmpty else { return 0 }
        return meetings.reduce(0.0) { $0 + $1.talkShare } / Double(meetings.count)
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

    private func dailyTalkHours(_ meetings: [Meeting], days: Int) -> [Double] {
        let calendar = Calendar.current
        return (0..<days).reversed().map { offset in
            let day = calendar.startOfDay(for: calendar.date(byAdding: .day, value: -offset, to: .now) ?? .now)
            return meetings.filter { calendar.isDate($0.startedAt, inSameDayAs: day) }
                .reduce(0.0) { $0 + $1.selfTalkDuration } / 3600
        }
    }

    private func dailyTalkShare(_ meetings: [Meeting], days: Int) -> [Double] {
        let calendar = Calendar.current
        return (0..<days).reversed().map { offset in
            let day = calendar.startOfDay(for: calendar.date(byAdding: .day, value: -offset, to: .now) ?? .now)
            let dayMeetings = meetings.filter { calendar.isDate($0.startedAt, inSameDayAs: day) }
            guard !dayMeetings.isEmpty else { return 0 }
            return averageTalkShare(dayMeetings) * 100
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
