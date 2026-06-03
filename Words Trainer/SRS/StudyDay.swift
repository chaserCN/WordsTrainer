import Foundation

enum StudyDay {
    static let rolloverHour = 4

    static func start(for date: Date, calendar: Calendar = .current) -> Date {
        let shifted = calendar.date(byAdding: .hour, value: -rolloverHour, to: date) ?? date
        let shiftedStart = calendar.startOfDay(for: shifted)
        return calendar.date(byAdding: .hour, value: rolloverHour, to: shiftedStart) ?? shiftedStart
    }

    static func end(for date: Date, calendar: Calendar = .current) -> Date {
        let start = start(for: date, calendar: calendar)
        return calendar.date(byAdding: .day, value: 1, to: start)
            ?? start.addingTimeInterval(24 * 60 * 60)
    }

    static func key(for date: Date = .now, calendar: Calendar = .current) -> String {
        let shifted = calendar.date(byAdding: .hour, value: -rolloverHour, to: date) ?? date
        return DeckDailyUsage.calendarDayKey(for: shifted, calendar: calendar)
    }

    static func isDate(_ date: Date, inSameStudyDayAs other: Date, calendar: Calendar = .current) -> Bool {
        key(for: date, calendar: calendar) == key(for: other, calendar: calendar)
    }
}

