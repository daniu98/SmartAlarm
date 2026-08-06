import Foundation

enum Format {
    static func time(_ date: Date?) -> String {
        guard let date else { return "—" }
        return date.formatted(date: .omitted, time: .shortened)
    }

    static func dayAndTime(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }

    static func relativeDay(_ dayStart: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        if calendar.isDateInToday(dayStart) { return "Today" }
        if calendar.isDateInTomorrow(dayStart) { return "Tomorrow" }
        return dayStart.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }

    static func minutes(_ seconds: Double?) -> String {
        guard let seconds else { return "—" }
        return "\(Int((seconds / 60).rounded())) min"
    }

    static func signedMinutes(_ seconds: Double) -> String {
        let value = Int((seconds / 60).rounded())
        return value >= 0 ? "+\(value) min" : "\(value) min"
    }

    static func duration(from start: Date, to end: Date) -> String {
        minutes(end.timeIntervalSince(start))
    }
}
