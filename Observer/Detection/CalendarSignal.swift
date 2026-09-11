import EventKit
import Foundation

struct CalendarMeetingSignal: Equatable, Sendable {
    var title: String
    var location: String?
}

enum CalendarSignal {
    static func currentMeeting() -> CalendarMeetingSignal? {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            return nil
        }

        let store = EKEventStore()
        let now = Date()
        let window = DateInterval(start: now.addingTimeInterval(-15 * 60), end: now.addingTimeInterval(15 * 60))
        let predicate = store.predicateForEvents(withStart: window.start, end: window.end, calendars: nil)
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
}
