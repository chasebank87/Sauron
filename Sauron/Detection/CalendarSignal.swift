import EventKit
import Foundation

struct CalendarMeetingSignal: Equatable, Sendable {
    var title: String
    var location: String?
}

struct SauronCalendarInfo: Identifiable, Equatable, Sendable {
    var id: String { calendarIdentifier }
    var calendarIdentifier: String
    var title: String
    var sourceTitle: String
    var isSubscribedDefault: Bool
}

struct UpcomingCalendarEvent: Identifiable, Equatable, Sendable {
    var id: String
    var title: String
    var start: Date
    var end: Date
    var calendarTitle: String
    var calendarIdentifier: String
    var location: String?

    func isInProgress(at now: Date = .now) -> Bool {
        start <= now && end > now
    }

    func timingLabel(at now: Date = .now) -> String {
        if isInProgress(at: now) {
            return "In progress · ends \(end.formatted(date: .omitted, time: .shortened))"
        }
        let calendar = Calendar.current
        if calendar.isDateInToday(start) {
            return "Today, \(start.formatted(date: .omitted, time: .shortened))"
        }
        if calendar.isDateInTomorrow(start) {
            return "Tomorrow, \(start.formatted(date: .omitted, time: .shortened))"
        }
        return start.formatted(date: .complete, time: .shortened)
    }
}

enum CalendarSignal {
    /// In-progress conference-looking event on subscribed calendars (detection assist).
    static func currentMeeting(subscribedCalendarIDs: [String]? = nil) -> CalendarMeetingSignal? {
        guard hasFullAccess else { return nil }
        let store = EKEventStore()
        let now = Date()
        let window = DateInterval(start: now.addingTimeInterval(-15 * 60), end: now.addingTimeInterval(15 * 60))
        let calendars = resolveCalendars(store: store, subscribedIDs: subscribedCalendarIDs)
        guard !calendars.isEmpty else { return nil }

        let predicate = store.predicateForEvents(withStart: window.start, end: window.end, calendars: calendars)
        let events = store.events(matching: predicate)
            .filter { event in
                !event.isAllDay &&
                event.startDate <= now &&
                event.endDate >= now &&
                looksLikeConference(event)
            }
            .sorted { $0.startDate > $1.startDate }

        guard let event = events.first else { return nil }
        return CalendarMeetingSignal(title: event.title ?? "Calendar meeting", location: event.location)
    }

    /// Future (and in-progress) events from subscribed calendars, relative to `now`.
    static func upcoming(
        now: Date = .now,
        lookAhead: TimeInterval = 7 * 24 * 60 * 60,
        limit: Int = 8,
        subscribedCalendarIDs: [String]?
    ) -> [UpcomingCalendarEvent] {
        guard hasFullAccess else { return [] }
        let store = EKEventStore()
        let calendars = resolveCalendars(store: store, subscribedIDs: subscribedCalendarIDs)
        guard !calendars.isEmpty else { return [] }

        let end = now.addingTimeInterval(lookAhead)
        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-30 * 60), end: end, calendars: calendars)
        return store.events(matching: predicate)
            .filter { event in
                !event.isAllDay && event.endDate > now
            }
            .sorted { $0.startDate < $1.startDate }
            .prefix(limit)
            .map { event in
                UpcomingCalendarEvent(
                    id: event.eventIdentifier ?? UUID().uuidString,
                    title: (event.title?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled event",
                    start: event.startDate,
                    end: event.endDate,
                    calendarTitle: event.calendar.title,
                    calendarIdentifier: event.calendar.calendarIdentifier,
                    location: event.location
                )
            }
    }

    static func availableCalendars() -> [SauronCalendarInfo] {
        guard hasFullAccess else { return [] }
        let store = EKEventStore()
        return store.calendars(for: .event)
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            .map { calendar in
                SauronCalendarInfo(
                    calendarIdentifier: calendar.calendarIdentifier,
                    title: calendar.title,
                    sourceTitle: calendar.source.title,
                    isSubscribedDefault: calendar.allowsContentModifications || calendar.type == .calDAV || calendar.type == .exchange
                )
            }
    }

    static var hasFullAccess: Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    static func looksLikeConference(_ event: EKEvent) -> Bool {
        let blob = [
            event.title,
            event.location,
            event.notes,
            event.url?.absoluteString
        ]
        .compactMap { $0 }
        .joined(separator: " ")
        .lowercased()

        let tokens = ["zoom.us", "meet.google", "teams.microsoft", "webex", "facetime", "slack.com/call", "meeting"]
        return tokens.contains { blob.contains($0) }
    }

    private static func resolveCalendars(store: EKEventStore, subscribedIDs: [String]?) -> [EKCalendar] {
        let all = store.calendars(for: .event)
        guard let subscribedIDs else { return all }
        // Empty configured list means none selected.
        if subscribedIDs.isEmpty { return [] }
        let allowed = Set(subscribedIDs)
        return all.filter { allowed.contains($0.calendarIdentifier) }
    }
}
