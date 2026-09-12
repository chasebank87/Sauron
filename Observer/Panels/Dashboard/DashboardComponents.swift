import Charts
import SwiftUI

// MARK: - Navigation

enum DashboardTab: String, CaseIterable, Identifiable, Sendable {
    case home
    case insights
    case library
    case people
    case asks
    case ask
    case memory

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Home"
        case .insights: "Insights"
        case .library: "Library"
        case .people: "People"
        case .asks: "Asks"
        case .ask: "Ask"
        case .memory: "Memory"
        }
    }

    var systemImage: String {
        switch self {
        case .home: "house"
        case .insights: "chart.xyaxis.line"
        case .library: "books.vertical"
        case .people: "person.2"
        case .asks: "checklist"
        case .ask: "sparkles"
        case .memory: "brain.head.profile"
        }
    }

    var section: DashboardNavSection {
        switch self {
        case .home, .insights: .today
        case .library, .people, .asks: .workspace
        case .ask, .memory: .intelligence
        }
    }
}

enum DashboardNavSection: String, CaseIterable, Identifiable {
    case today
    case workspace
    case intelligence

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: "TODAY"
        case .workspace: "WORKSPACE"
        case .intelligence: "INTELLIGENCE"
        }
    }

    var tabs: [DashboardTab] {
        DashboardTab.allCases.filter { $0.section == self }
    }
}

// MARK: - Shared components

struct DashboardOverline: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(ObserverTheme.textTertiary)
    }
}

/// Dark-surface search field matching the dashboard design system (not system roundedBorder).
struct DashboardSearchField: View {
    var placeholder: String
    @Binding var text: String
    var systemImage: String = "magnifyingglass"

    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(focused ? ObserverTheme.irisSolid : ObserverTheme.textTertiary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(ObserverTheme.textPrimary)
                .focused($focused)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(ObserverTheme.textTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(ObserverTheme.surfaceElevated, in: RoundedRectangle(cornerRadius: ObserverTheme.radiusControl, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: ObserverTheme.radiusControl, style: .continuous)
                .strokeBorder(
                    focused ? ObserverTheme.irisSolid.opacity(0.55) : ObserverTheme.hairline,
                    lineWidth: 1
                )
        )
    }
}

/// Plain dark text field for settings-like inputs inside dashboard cards.
struct DashboardTextField: View {
    var placeholder: String
    @Binding var text: String

    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .foregroundStyle(ObserverTheme.textPrimary)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .focused($focused)
            .background(ObserverTheme.surfaceSunken, in: RoundedRectangle(cornerRadius: ObserverTheme.radiusControl, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: ObserverTheme.radiusControl, style: .continuous)
                    .strokeBorder(
                        focused ? ObserverTheme.irisSolid.opacity(0.45) : ObserverTheme.hairline,
                        lineWidth: 1
                    )
            )
    }
}

struct DashboardEmptyState: View {
    var systemImage: String
    var title: String
    var message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(ObserverTheme.irisGradient)
                .frame(width: 56, height: 56)
                .background(ObserverTheme.surfaceElevated, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(ObserverTheme.textPrimary)
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(ObserverTheme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .observerGlassProminentButton()
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}

struct StatTile: View {
    var label: String
    var value: String
    var delta: String?
    var deltaPositive: Bool = true
    var spark: [Double]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            DashboardOverline(text: label)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(value)
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(ObserverTheme.textPrimary)
                    .contentTransition(.numericText())
                if let delta {
                    Text(delta)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(deltaPositive ? ObserverTheme.mint : ObserverTheme.red)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            (deltaPositive ? ObserverTheme.mint : ObserverTheme.red).opacity(0.14),
                            in: Capsule()
                        )
                }
            }
            Chart {
                ForEach(Array(spark.enumerated()), id: \.offset) { index, point in
                    LineMark(
                        x: .value("i", index),
                        y: .value("v", point)
                    )
                    .foregroundStyle(ObserverTheme.irisGradient)
                    .interpolationMethod(.catmullRom)
                }
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .frame(height: 28)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .leading)
        .observerSurfaceCard()
    }
}

struct TopicChip: View {
    var text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(ObserverTheme.textSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(ObserverTheme.surfaceElevated, in: Capsule())
            .overlay(Capsule().strokeBorder(ObserverTheme.hairline, lineWidth: 1))
    }
}

struct MeetingRowCard: View {
    let meeting: Meeting
    var isSelected: Bool = false
    var isSelecting: Bool = false
    var onOpen: () -> Void
    var onAsk: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil
    var onToggleSelect: (() -> Void)? = nil

    @State private var hovered = false

    var body: some View {
        Button(action: {
            if isSelecting {
                onToggleSelect?()
            } else {
                onOpen()
            }
        }) {
            HStack(spacing: 12) {
                if isSelecting {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(isSelected ? ObserverTheme.irisSolid : ObserverTheme.textTertiary)
                        .frame(width: 28)
                }

                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(ObserverTheme.irisGradient.opacity(0.22))
                    Image(systemName: "waveform")
                        .foregroundStyle(ObserverTheme.irisSolid)
                    if hovered && !isSelecting {
                        Image(systemName: "play.fill")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(8)
                            .background(.black.opacity(0.45), in: Circle())
                    }
                }
                .frame(width: 48, height: 48)

                VStack(alignment: .leading, spacing: 4) {
                    Text(meeting.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(ObserverTheme.textPrimary)
                        .lineLimit(1)
                    Text("\(meeting.startedAt.formatted(date: .omitted, time: .shortened)) · \(meeting.duration.observerShortDuration) · \(meeting.kind.displayName)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(ObserverTheme.textSecondary)
                }
                Spacer(minLength: 8)
                if !isSelecting {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(ObserverTheme.textTertiary)
                }
            }
            .padding(12)
            .background(
                (isSelected || hovered) ? ObserverTheme.surfaceElevated : ObserverTheme.surface,
                in: RoundedRectangle(cornerRadius: ObserverTheme.radiusCard, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: ObserverTheme.radiusCard, style: .continuous)
                    .strokeBorder(
                        isSelected ? ObserverTheme.irisSolid.opacity(0.55) : ObserverTheme.hairline,
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .contextMenu {
            if !isSelecting {
                Button("Open report", action: onOpen)
                if let onAsk {
                    Button("Ask about this", action: onAsk)
                }
                if let onDelete {
                    Divider()
                    Button("Delete…", role: .destructive, action: onDelete)
                }
            }
        }
    }
}

struct AskRowCard: View {
    let item: TrackedItem
    var onToggle: () -> Void
    var onOpenSource: (() -> Void)? = nil
    var selected: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: onToggle) {
                Image(systemName: item.status == .done ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(item.status == .done ? ObserverTheme.mint : ObserverTheme.textTertiary)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 6) {
                Text(item.text)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(ObserverTheme.textPrimary)
                    .strikethrough(item.status == .done)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 8) {
                    Label(item.sourceMeetingTitle, systemImage: "waveform")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(ObserverTheme.textSecondary)
                        .lineLimit(1)
                    TopicChip(text: item.kind.title)
                    if isOverdue {
                        Text(agingLabel)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(ObserverTheme.red)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(ObserverTheme.red.opacity(0.14), in: Capsule())
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            selected ? ObserverTheme.surfaceElevated : ObserverTheme.surface,
            in: RoundedRectangle(cornerRadius: ObserverTheme.radiusCard, style: .continuous)
        )
        .overlay(alignment: .leading) {
            if isOverdue && item.status == .open {
                RoundedRectangle(cornerRadius: 2)
                    .fill(ObserverTheme.red)
                    .frame(width: 2)
                    .padding(.vertical, 8)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: ObserverTheme.radiusCard, style: .continuous)
                .strokeBorder(selected ? ObserverTheme.irisSolid.opacity(0.45) : ObserverTheme.hairline, lineWidth: 1)
        )
        .onTapGesture {
            onOpenSource?()
        }
    }

    private var isOverdue: Bool {
        guard item.status == .open else { return false }
        return Date().timeIntervalSince(item.createdAt) > 7 * 86_400
    }

    private var agingLabel: String {
        let days = Int(Date().timeIntervalSince(item.createdAt) / 86_400)
        return "\(max(1, days))d overdue"
    }
}

struct SourceCardView: View {
    let citation: MemoryCitation
    var onOpen: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(citation.meetingTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(ObserverTheme.textPrimary)
                    .lineLimit(2)
                Spacer()
                Text("\(Int(citation.score * 100))%")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(ObserverTheme.mint)
            }
            ProgressView(value: Double(min(max(citation.score, 0), 1)))
                .tint(ObserverTheme.irisSolid)
            Text(citation.text)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(ObserverTheme.textSecondary)
                .lineLimit(3)
            if let onOpen {
                Button("Open meeting", action: onOpen)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(ObserverTheme.irisSolid)
                    .buttonStyle(.plain)
            }
        }
        .padding(12)
        .observerSurfaceCard()
    }
}

struct DashboardScreenHeader: View {
    var title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 28, weight: .semibold))
                .tracking(-0.4)
                .foregroundStyle(ObserverTheme.textPrimary)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(ObserverTheme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
