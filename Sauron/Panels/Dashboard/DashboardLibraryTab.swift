import SwiftData
import SwiftUI

struct DashboardLibraryTab: View {
    @Environment(AppState.self) private var appState
    @State private var mode: LibraryMode = .timeline
    @State private var query = ""
    @State private var month = Date()
    @State private var selectedDay = Date()
    @State private var selectedMeetingID: UUID?
    @State private var isSelecting = false
    @State private var checkedIDs: Set<UUID> = []
    @State private var pendingDeleteIDs: Set<UUID> = []
    @State private var showDeleteConfirm = false

    private enum LibraryMode: String, CaseIterable {
        case timeline = "Timeline"
        case calendar = "Calendar"
        case grid = "Grid"
    }

    var body: some View {
        let meetings = filter(deletable(MeetingStore.all(context: appState.modelContext)))
        let selected = meetings.first { $0.id == selectedMeetingID } ?? meetings.first

        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                toolbar(meetings: meetings)
                Group {
                    switch mode {
                    case .timeline: timeline(meetings)
                    case .calendar: calendarBody(meetings)
                    case .grid: grid(meetings)
                    }
                }
            }
            .frame(maxWidth: .infinity)

            Divider().overlay(SauronTheme.hairlineStrong)
            inspector(selected, all: meetings)
                .frame(width: 320)
        }
        .onAppear {
            if selectedMeetingID == nil {
                selectedMeetingID = meetings.first?.id
            }
        }
        .onChange(of: isSelecting) { _, selecting in
            if !selecting { checkedIDs = [] }
        }
        .confirmationDialog(
            deleteDialogTitle,
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete \(pendingDeleteIDs.count) meeting\(pendingDeleteIDs.count == 1 ? "" : "s")", role: .destructive) {
                confirmDelete()
            }
            Button("Cancel", role: .cancel) {
                pendingDeleteIDs = []
            }
        } message: {
            Text("Recordings, transcripts, linked asks, and memory for these meetings will be removed from this Mac. This can’t be undone.")
        }
    }

    private var deleteDialogTitle: String {
        let n = pendingDeleteIDs.count
        return n == 1 ? "Delete this meeting?" : "Delete \(n) meetings?"
    }

    private func toolbar(meetings: [Meeting]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            DashboardScreenHeader(title: "Library", subtitle: "Meetings, transcripts, and recordings.")
            HStack(spacing: 12) {
                DashboardSearchField(
                    placeholder: "Search transcripts, people, topics",
                    text: $query
                )
                Picker("Mode", selection: $mode) {
                    ForEach(LibraryMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 280)

                if isSelecting {
                    Button("Select all") {
                        checkedIDs = Set(meetings.map(\.id))
                    }
                    .observerGlassButton()
                    .disabled(meetings.isEmpty || checkedIDs.count == meetings.count)

                    Button("Delete", role: .destructive) {
                        requestDelete(checkedIDs)
                    }
                    .observerGlassProminentButton()
                    .disabled(checkedIDs.isEmpty)
                    .tint(SauronTheme.red)

                    Button("Done") {
                        isSelecting = false
                    }
                    .observerGlassButton()
                } else {
                    Button("Select") {
                        isSelecting = true
                    }
                    .observerGlassButton()
                    .disabled(meetings.isEmpty)
                }
            }

            if isSelecting {
                Text(checkedIDs.isEmpty
                       ? "Select meetings to delete."
                       : "\(checkedIDs.count) selected")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(SauronTheme.textSecondary)
            }
        }
        .padding(24)
        .padding(.bottom, 8)
    }

    private func filter(_ meetings: [Meeting]) -> [Meeting] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return meetings }
        return meetings.filter {
            $0.title.lowercased().contains(needle)
                || $0.plainTranscript.lowercased().contains(needle)
                || $0.appName.lowercased().contains(needle)
                || ($0.summary?.topics.joined(separator: " ").lowercased().contains(needle) ?? false)
        }
    }

    /// Hide the in-progress recording from bulk delete.
    private func deletable(_ meetings: [Meeting]) -> [Meeting] {
        guard let liveID = appState.currentMeeting?.id else { return meetings }
        return meetings.filter { $0.id != liveID }
    }

    private func meetingCard(_ meeting: Meeting) -> some View {
        MeetingRowCard(
            meeting: meeting,
            isSelected: checkedIDs.contains(meeting.id) || (!isSelecting && selectedMeetingID == meeting.id),
            isSelecting: isSelecting,
            onOpen: {
                selectedMeetingID = meeting.id
                if !isSelecting {
                    appState.openReport(meeting)
                }
            },
            onAsk: {
                selectedMeetingID = meeting.id
                appState.dashboardSelectedTab = .ask
            },
            onDelete: {
                requestDelete([meeting.id])
            },
            onToggleSelect: {
                toggleCheck(meeting.id)
                selectedMeetingID = meeting.id
            }
        )
    }

    private func timeline(_ meetings: [Meeting]) -> some View {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: meetings) { calendar.startOfDay(for: $0.startedAt) }
        let days = grouped.keys.sorted(by: >)
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                if meetings.isEmpty {
                    DashboardEmptyState(
                        systemImage: "books.vertical",
                        title: "No meetings yet",
                        message: "Recordings you capture show up here as a timeline.",
                        actionTitle: "Ask Sauron instead",
                        action: { appState.dashboardSelectedTab = .ask }
                    )
                    .frame(height: 280)
                } else {
                    ForEach(days, id: \.self) { day in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(dayHeader(day))
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(SauronTheme.textSecondary)
                            ForEach(grouped[day] ?? []) { meeting in
                                meetingCard(meeting)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
    }

    private func calendarBody(_ meetings: [Meeting]) -> some View {
        let calendar = Calendar.current
        let daysInMonth = days(for: month)
        let selectedMeetings = meetings.filter { calendar.isDate($0.startedAt, inSameDayAs: selectedDay) }
        return HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Button { month = calendar.date(byAdding: .month, value: -1, to: month) ?? month } label: {
                        Image(systemName: "chevron.left")
                    }
                    .buttonStyle(.plain)
                    Text(month.formatted(.dateTime.month(.wide).year()))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(SauronTheme.textPrimary)
                        .frame(maxWidth: .infinity)
                    Button { month = calendar.date(byAdding: .month, value: 1, to: month) ?? month } label: {
                        Image(systemName: "chevron.right")
                    }
                    .buttonStyle(.plain)
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 7), spacing: 6) {
                    ForEach(["S", "M", "T", "W", "T", "F", "S"], id: \.self) { label in
                        Text(label)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(SauronTheme.textTertiary)
                    }
                    ForEach(daysInMonth, id: \.self) { day in
                        let count = meetings.filter { calendar.isDate($0.startedAt, inSameDayAs: day) }.count
                        Button { selectedDay = day } label: {
                            VStack(spacing: 3) {
                                Text("\(calendar.component(.day, from: day))")
                                    .font(.system(size: 12, weight: calendar.isDate(day, inSameDayAs: selectedDay) ? .bold : .regular))
                                    .foregroundStyle(SauronTheme.textPrimary)
                                Circle()
                                    .fill(count > 0 ? SauronTheme.irisSolid : Color.clear)
                                    .frame(width: 5, height: 5)
                            }
                            .frame(maxWidth: .infinity, minHeight: 36)
                            .background(
                                calendar.isDate(day, inSameDayAs: selectedDay)
                                    ? SauronTheme.surfaceElevated
                                    : Color.clear,
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                            )
                        }
                        .buttonStyle(.plain)
                        .opacity(calendar.isDate(day, equalTo: month, toGranularity: .month) ? 1 : 0.35)
                    }
                }
            }
            .padding(16)
            .observerSurfaceCard()
            .frame(width: 320)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    Text(selectedDay.formatted(date: .complete, time: .omitted))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(SauronTheme.textPrimary)
                    if selectedMeetings.isEmpty {
                        Text("No meetings this day.")
                            .foregroundStyle(SauronTheme.textSecondary)
                    } else {
                        ForEach(selectedMeetings) { meeting in
                            meetingCard(meeting)
                        }
                    }
                }
                .padding(.trailing, 24)
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 24)
    }

    private func grid(_ meetings: [Meeting]) -> some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 12)], spacing: 12) {
                ForEach(meetings) { meeting in
                    let checked = checkedIDs.contains(meeting.id)
                    VStack(alignment: .leading, spacing: 10) {
                        ZStack(alignment: .topTrailing) {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(SauronTheme.irisGradient.opacity(0.2))
                                .frame(height: 88)
                            Image(systemName: "waveform")
                                .foregroundStyle(SauronTheme.irisSolid)
                            if isSelecting {
                                Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                                    .font(.title3)
                                    .foregroundStyle(checked ? SauronTheme.irisSolid : SauronTheme.textTertiary)
                                    .padding(10)
                            }
                        }
                        Text(meeting.title)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(SauronTheme.textPrimary)
                            .lineLimit(2)
                        Text(meeting.duration.observerShortDuration)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(SauronTheme.textSecondary)
                        if let bullets = meeting.summary?.notes.prefix(2), !bullets.isEmpty {
                            ForEach(Array(bullets), id: \.self) { note in
                                Text("• \(note)")
                                    .font(.system(size: 11))
                                    .foregroundStyle(SauronTheme.textSecondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .padding(12)
                    .background(
                        (checked || selectedMeetingID == meeting.id) ? SauronTheme.surfaceElevated : SauronTheme.surface,
                        in: RoundedRectangle(cornerRadius: SauronTheme.radiusCard, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: SauronTheme.radiusCard, style: .continuous)
                            .strokeBorder(
                                checked ? SauronTheme.irisSolid.opacity(0.55) : SauronTheme.hairline,
                                lineWidth: 1
                            )
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if isSelecting {
                            toggleCheck(meeting.id)
                            selectedMeetingID = meeting.id
                        } else {
                            selectedMeetingID = meeting.id
                            appState.openReport(meeting)
                        }
                    }
                    .contextMenu {
                        if !isSelecting {
                            Button("Open report") {
                                selectedMeetingID = meeting.id
                                appState.openReport(meeting)
                            }
                            Button("Ask about this") {
                                selectedMeetingID = meeting.id
                                appState.dashboardSelectedTab = .ask
                            }
                            Divider()
                            Button("Delete…", role: .destructive) {
                                requestDelete([meeting.id])
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
    }

    private func inspector(_ meeting: Meeting?, all meetings: [Meeting]) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if isSelecting, !checkedIDs.isEmpty {
                DashboardOverline(text: "Selection")
                Text("\(checkedIDs.count) meeting\(checkedIDs.count == 1 ? "" : "s")")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(SauronTheme.textPrimary)
                Text("Delete removes recordings, transcripts, linked asks, and memory chunks.")
                    .font(.system(size: 12))
                    .foregroundStyle(SauronTheme.textSecondary)
                Spacer()
                Button("Delete selected", role: .destructive) {
                    requestDelete(checkedIDs)
                }
                .observerGlassProminentButton()
                .tint(SauronTheme.red)
                .frame(maxWidth: .infinity)
            } else if let meeting {
                DashboardOverline(text: "Meeting")
                Text(meeting.title)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(SauronTheme.textPrimary)
                Text("\(meeting.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(meeting.duration.observerShortDuration)")
                    .font(.system(size: 12))
                    .foregroundStyle(SauronTheme.textSecondary)

                if let summary = meeting.summary {
                    VStack(alignment: .leading, spacing: 8) {
                        DashboardOverline(text: "AI TLDR")
                        ForEach(Array(summary.notes.prefix(3).enumerated()), id: \.offset) { _, note in
                            Text("• \(note)")
                                .font(.system(size: 12))
                                .foregroundStyle(SauronTheme.textPrimary)
                        }
                        if summary.notes.isEmpty {
                            Text(summary.summary)
                                .font(.system(size: 12))
                                .foregroundStyle(SauronTheme.textSecondary)
                                .lineLimit(5)
                        }
                    }
                    .padding(12)
                    .observerSurfaceCard()
                }

                MeetingDocumentsSection(meeting: meeting, compact: true)
                MeetingUserNotesEditor(meeting: meeting, compact: true)

                Spacer()
                VStack(spacing: 8) {
                    Button("Open report") { appState.openReport(meeting) }
                        .observerGlassProminentButton()
                        .frame(maxWidth: .infinity)
                    Button("Ask about this") { appState.dashboardSelectedTab = .ask }
                        .observerGlassButton()
                        .frame(maxWidth: .infinity)
                    Button("Delete…", role: .destructive) {
                        requestDelete([meeting.id])
                    }
                    .observerGlassButton()
                    .frame(maxWidth: .infinity)
                }
            } else {
                Text("Select a meeting")
                    .foregroundStyle(SauronTheme.textSecondary)
                Spacer()
            }
        }
        .padding(20)
        .background(SauronTheme.surfaceSunken)
    }

    private func toggleCheck(_ id: UUID) {
        if checkedIDs.contains(id) {
            checkedIDs.remove(id)
        } else {
            checkedIDs.insert(id)
        }
    }

    private func requestDelete(_ ids: Set<UUID>) {
        let liveID = appState.currentMeeting?.id
        let filtered = ids.filter { $0 != liveID }
        guard !filtered.isEmpty else { return }
        pendingDeleteIDs = filtered
        showDeleteConfirm = true
    }

    private func requestDelete(_ ids: [UUID]) {
        requestDelete(Set(ids))
    }

    private func confirmDelete() {
        let ids = pendingDeleteIDs
        pendingDeleteIDs = []
        let meetings = ids.compactMap { MeetingStore.meeting(id: $0, context: appState.modelContext) }
        _ = appState.deleteMeetings(meetings)
        checkedIDs.subtract(ids)
        if let selectedMeetingID, ids.contains(selectedMeetingID) {
            self.selectedMeetingID = MeetingStore.all(context: appState.modelContext).first?.id
        }
        if checkedIDs.isEmpty {
            isSelecting = false
        }
    }

    private func dayHeader(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(date: .complete, time: .omitted)
    }

    private func days(for month: Date) -> [Date] {
        let calendar = Calendar.current
        guard let monthInterval = calendar.dateInterval(of: .month, for: month),
              let firstWeek = calendar.dateInterval(of: .weekOfMonth, for: monthInterval.start)
        else { return [] }
        var days: [Date] = []
        var cursor = firstWeek.start
        while days.count < 42 {
            days.append(cursor)
            cursor = calendar.date(byAdding: .day, value: 1, to: cursor) ?? cursor
        }
        return days
    }
}
