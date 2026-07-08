import EventKit
import Foundation

// Reminder creation input, decoupled from the HTTP layer.
struct ReminderInput: Sendable {
    var title: String
    var list: String?
    var notes: String?
    var due: String?
    var priority: Int?
    var url: String?
}

enum ReminderError: Error {
    case accessDenied
    case listNotFound(available: [String])
    case badDue(String)
    case saveFailed(String)
}

// EventKit wrapper. An actor so the non-Sendable EKEventStore is only ever
// touched under serialized access — required under Swift 6 strict concurrency
// since Hummingbird handlers are @Sendable closures.
//
// NOTE: the EventKit reminder-creation logic here is intentionally a small
// duplicate of the `remind` CLI (cookbooks/remind/files/remind.swift). The CLI
// is the reference; it is kept a separate single-file swiftc build so that Macs
// which only use the CLI do not pay Hummingbird's dependency/build cost. Keep
// the two in sync when changing field handling.
actor Reminders {
    private let store = EKEventStore()
    private(set) var hasAccess = false

    func requestAccess() async -> Bool {
        let ok: Bool = await withCheckedContinuation { cont in
            store.requestFullAccessToReminders { granted, _ in cont.resume(returning: granted) }
        }
        hasAccess = ok
        return ok
    }

    func lists() -> [String] {
        store.calendars(for: .reminder).map { $0.title }
    }

    func create(_ input: ReminderInput) throws -> (id: String, list: String) {
        guard hasAccess else { throw ReminderError.accessDenied }

        let calendar: EKCalendar
        if let name = input.list {
            guard let c = store.calendars(for: .reminder).first(where: { $0.title == name }) else {
                throw ReminderError.listNotFound(available: store.calendars(for: .reminder).map { $0.title })
            }
            calendar = c
        } else {
            guard let c = store.defaultCalendarForNewReminders() else {
                throw ReminderError.saveFailed("no default reminders list")
            }
            calendar = c
        }

        let reminder = EKReminder(eventStore: store)
        reminder.title = input.title
        reminder.calendar = calendar
        if let notes = input.notes { reminder.notes = notes }
        if let priority = input.priority { reminder.priority = priority }
        if let urlStr = input.url, let url = URL(string: urlStr) { reminder.url = url }
        if let dueStr = input.due {
            let (components, alarmDate) = try Reminders.parseDue(dueStr)
            reminder.dueDateComponents = components
            if let alarmDate = alarmDate { reminder.addAlarm(EKAlarm(absoluteDate: alarmDate)) }
        }

        do {
            try store.save(reminder, commit: true)
        } catch {
            throw ReminderError.saveFailed(error.localizedDescription)
        }
        return (reminder.calendarItemIdentifier, calendar.title)
    }

    static func parseDue(_ s: String) throws -> (DateComponents, Date?) {
        let fmts = ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"]
        for f in fmts {
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.timeZone = .current
            df.dateFormat = f
            if let d = df.date(from: s) {
                // Bound to a sane window; far-future dates can choke some stores.
                if abs(d.timeIntervalSinceNow) > 100.0 * 365.25 * 86400 {
                    throw ReminderError.badDue(s)
                }
                let cal = Calendar.current
                if f.contains("HH") {
                    return (cal.dateComponents([.year, .month, .day, .hour, .minute], from: d), d)
                } else {
                    return (cal.dateComponents([.year, .month, .day], from: d), nil)
                }
            }
        }
        throw ReminderError.badDue(s)
    }
}
