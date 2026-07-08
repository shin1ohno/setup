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
var dumpMode = false
var includeCompleted = false
var completeId: String? = nil
var annotateId: String? = nil
var mklistName: String? = nil

var i = 0
while i < rawArgs.count {
    let a = rawArgs[i]
    switch a {
    case "--list": i += 1; listName = i < rawArgs.count ? rawArgs[i] : nil
    case "--notes": i += 1; notes = i < rawArgs.count ? rawArgs[i] : nil
    case "--due": i += 1; dueStr = i < rawArgs.count ? rawArgs[i] : nil
    case "--lists": listOnly = true
    case "--dump": dumpMode = true
    case "--include-completed": includeCompleted = true
    case "--complete": i += 1; completeId = i < rawArgs.count ? rawArgs[i] : nil
    case "--annotate": i += 1; annotateId = i < rawArgs.count ? rawArgs[i] : nil
    case "--mklist": i += 1; mklistName = i < rawArgs.count ? rawArgs[i] : nil
    case "-h", "--help":
        print("usage: remind <title> [--list NAME] [--due 'YYYY-MM-DD HH:MM'] [--notes TEXT]")
        print("       remind --lists")
        print("       remind --dump [--list NAME] [--include-completed]")
        print("       remind --complete <id>")
        print("       remind --annotate <id> --notes TEXT")
        print("       remind --mklist <name>")
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

// --- shared helpers (dump / complete / annotate) ---
func fetchAllReminders(in calendars: [EKCalendar]?) -> [EKReminder] {
    let sem = DispatchSemaphore(value: 0)
    var result: [EKReminder] = []
    let predicate = store.predicateForReminders(in: calendars)
    store.fetchReminders(matching: predicate) { rs in
        result = rs ?? []
        sem.signal()
    }
    sem.wait()
    return result
}

func jsonEscape(_ s: String) -> String {
    var out = ""
    for scalar in s.unicodeScalars {
        switch scalar {
        case "\\": out += "\\\\"
        case "\"": out += "\\\""
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        default:
            if scalar.value < 0x20 {
                out += String(format: "\\u%04x", scalar.value)
            } else {
                out.append(Character(scalar))
            }
        }
    }
    return out
}

func jsonString(_ s: String?) -> String {
    guard let s = s else { return "null" }
    return "\"\(jsonEscape(s))\""
}

let isoFormatter = ISO8601DateFormatter()

func jsonDate(_ d: Date?) -> String {
    guard let d = d else { return "null" }
    return "\"\(isoFormatter.string(from: d))\""
}

// calendarItemIdentifier を先に試し、無ければ externalId で全 reminder を検索
func resolveReminder(_ id: String) -> EKReminder? {
    if let item = store.calendarItem(withIdentifier: id) as? EKReminder {
        return item
    }
    return fetchAllReminders(in: nil).first(where: { $0.calendarItemExternalIdentifier == id })
}

// --- --lists mode ---
if listOnly {
    for c in store.calendars(for: .reminder) { print(c.title) }
    exit(0)
}

// --- --dump mode ---
if dumpMode {
    var cals: [EKCalendar]? = nil
    if let listName = listName {
        guard let c = store.calendars(for: .reminder).first(where: { $0.title == listName }) else {
            let avail = store.calendars(for: .reminder).map { $0.title }.joined(separator: ", ")
            die("list not found: \(listName). available: \(avail)")
        }
        cals = [c]
    }
    var items: [String] = []
    for r in fetchAllReminders(in: cals) {
        if !includeCompleted && r.isCompleted { continue }
        var due: Date? = nil
        if let dc = r.dueDateComponents, dc.year != nil, let d = Calendar.current.date(from: dc) {
            due = d
        }
        let fields = [
            "\"id\":\(jsonString(r.calendarItemIdentifier))",
            "\"externalId\":\(jsonString(r.calendarItemExternalIdentifier))",
            "\"title\":\(jsonString(r.title ?? ""))",
            "\"notes\":\(jsonString(r.notes))",
            "\"list\":\(jsonString(r.calendar?.title ?? ""))",
            "\"completed\":\(r.isCompleted)",
            "\"completionDate\":\(jsonDate(r.completionDate))",
            "\"due\":\(jsonDate(due))",
            "\"priority\":\(r.priority)",
            "\"created\":\(jsonDate(r.creationDate))",
        ]
        items.append("{" + fields.joined(separator: ",") + "}")
    }
    print("[" + items.joined(separator: ",") + "]")
    exit(0)
}

// --- --complete mode ---
if let completeId = completeId {
    guard let r = resolveReminder(completeId) else {
        die("reminder not found: \(completeId)")
    }
    r.isCompleted = true
    do {
        try store.save(r, commit: true)
        print("completed: \"\(r.title ?? "")\"")
    } catch {
        die("save failed: \(error.localizedDescription)")
    }
    exit(0)
}

// --- --annotate mode ---
if let annotateId = annotateId {
    guard let text = notes else {
        die("--annotate requires --notes TEXT")
    }
    guard let r = resolveReminder(annotateId) else {
        die("reminder not found: \(annotateId)")
    }
    if let existing = r.notes, !existing.isEmpty {
        r.notes = existing + "\n" + text
    } else {
        r.notes = text
    }
    do {
        try store.save(r, commit: true)
        print("annotated: \"\(r.title ?? "")\"")
    } catch {
        die("save failed: \(error.localizedDescription)")
    }
    exit(0)
}

// --- --mklist mode ---
if let mklistName = mklistName {
    if store.calendars(for: .reminder).contains(where: { $0.title == mklistName }) {
        print("exists: \(mklistName)")
        exit(0)
    }
    let cal = EKCalendar(for: .reminder, eventStore: store)
    cal.title = mklistName
    if let src = store.defaultCalendarForNewReminders()?.source {
        cal.source = src
    } else if let src = store.sources.first(where: { $0.sourceType == .calDAV })
        ?? store.sources.first(where: { $0.sourceType == .local }) {
        cal.source = src
    } else {
        die("no suitable source for new list")
    }
    do {
        try store.saveCalendar(cal, commit: true)
        print("created list: \(mklistName)")
    } catch {
        die("saveCalendar failed: \(error.localizedDescription)")
    }
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
