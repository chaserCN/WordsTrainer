import Foundation
import FSRS

nonisolated struct CardProgress: Codable, Hashable, Sendable {
    let senseID: UUID
    var fsrsCard: Card
    var updatedAt: Date

    init(senseID: UUID, fsrsCard: Card, updatedAt: Date = .now) {
        self.senseID = senseID
        self.fsrsCard = fsrsCard
        self.updatedAt = updatedAt
    }

    static func newSense(senseID: UUID, now: Date = .now) -> CardProgress {
        CardProgress(senseID: senseID, fsrsCard: Card(due: now), updatedAt: now)
    }
}

nonisolated struct DeckDailyUsage: Codable, Sendable, Hashable {
    var dayKey: String
    var newCardsStudied: Int

    init(dayKey: String, newCardsStudied: Int = 0) {
        self.dayKey = dayKey
        self.newCardsStudied = newCardsStudied
    }

    static func todayKey(calendar: Calendar = .current) -> String {
        StudyDay.key(calendar: calendar)
    }

    static func dayKey(for date: Date, calendar: Calendar = .current) -> String {
        StudyDay.key(for: date, calendar: calendar)
    }

    static func calendarDayKey(for date: Date, calendar: Calendar = .current) -> String {
        let y = calendar.component(.year, from: date)
        let m = calendar.component(.month, from: date)
        let day = calendar.component(.day, from: date)
        return String(format: "%04d-%02d-%02d", y, m, day)
    }
}
