import EventKit
import Foundation

func die(_ msg: String) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(1)
}

// --- arg parse ---
let rawArgs = Array(CommandLine.arguments.dropFirst())
var title: String? = nil
var listName: String? = nil
var notes: String? = nil
var dueStr: String? = nil
var listOnly = false

var i = 0
while i < rawArgs.count {
    let a = rawArgs[i]
    switch a {
    case "--list": i += 1; listName = i < rawArgs.count ? rawArgs[i] : nil
    case "--notes": i += 1; notes = i < rawArgs.count ? rawArgs[i] : nil
    case "--due": i += 1; dueStr = i < rawArgs.count ? rawArgs[i] : nil
    case "--lists": listOnly = true
    case "-h", "--help":
        print("usage: remind <title> [--list NAME] [--due 'YYYY-MM-DD HH:MM'] [--notes TEXT]")
        print("       remind --lists")
        exit(0)
    default:
        title = (title == nil) ? a : title! + " " + a
    }
    i += 1
}

let store = EKEventStore()

// --- auth (macOS 14+ full-access model) ---
func requestAccess() -> Bool {
    let sem = DispatchSemaphore(value: 0)
    var granted = false
    if #available(macOS 14.0, *) {
        store.requestFullAccessToReminders { ok, err in
            granted = ok
            if let err = err {
                FileHandle.standardError.write("auth error: \(err.localizedDescription)\n".data(using: .utf8)!)
            }
            sem.signal()
        }
    } else {
        store.requestAccess(to: .reminder) { ok, _ in granted = ok; sem.signal() }
    }
    sem.wait()
    return granted
}

guard requestAccess() else {
    die("Reminders access not granted (System Settings > Privacy & Security > Reminders)")
}

// --- --lists mode ---
if listOnly {
    for c in store.calendars(for: .reminder) { print(c.title) }
    exit(0)
}

guard let title = title, !title.isEmpty else {
    die("usage: remind <title> [--list NAME] [--due 'YYYY-MM-DD HH:MM'] [--notes TEXT]")
}

// --- resolve list ---
let calendar: EKCalendar
if let listName = listName {
    guard let c = store.calendars(for: .reminder).first(where: { $0.title == listName }) else {
        let avail = store.calendars(for: .reminder).map { $0.title }.joined(separator: ", ")
        die("list not found: \(listName). available: \(avail)")
    }
    calendar = c
} else {
    guard let c = store.defaultCalendarForNewReminders() else { die("no default reminders list") }
    calendar = c
}

// --- parse due ---
var dueComponents: DateComponents? = nil
var alarmDate: Date? = nil
if let dueStr = dueStr {
    let fmts = ["yyyy-MM-dd HH:mm", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd"]
    var parsed: Date? = nil
    var hasTime = false
    for f in fmts {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone.current
        df.dateFormat = f
        if let d = df.date(from: dueStr) { parsed = d; hasTime = f.contains("HH"); break }
    }
    guard let d = parsed else {
        die("could not parse --due: \(dueStr) (use 'YYYY-MM-DD HH:MM' or 'YYYY-MM-DD')")
    }
    let cal = Calendar.current
    if hasTime {
        dueComponents = cal.dateComponents([.year, .month, .day, .hour, .minute], from: d)
        alarmDate = d
    } else {
        dueComponents = cal.dateComponents([.year, .month, .day], from: d)
    }
}

// --- create ---
let reminder = EKReminder(eventStore: store)
reminder.title = title
reminder.calendar = calendar
if let notes = notes { reminder.notes = notes }
if let dueComponents = dueComponents { reminder.dueDateComponents = dueComponents }
if let alarmDate = alarmDate { reminder.addAlarm(EKAlarm(absoluteDate: alarmDate)) }

do {
    try store.save(reminder, commit: true)
    var msg = "created: \"\(title)\" in \"\(calendar.title)\""
    if let dueStr = dueStr { msg += " due \(dueStr)" }
    print(msg)
} catch {
    die("save failed: \(error.localizedDescription)")
}
