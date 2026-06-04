import Foundation
import FSRS

struct CardProgress: Codable, Hashable, Sendable {
    let cardID: UUID
    var fsrsCard: Card
    var updatedAt: Date

    init(cardID: UUID, fsrsCard: Card, updatedAt: Date = .now) {
        self.cardID = cardID
        self.fsrsCard = fsrsCard
        self.updatedAt = updatedAt
    }

    static func newCard(cardID: UUID, now: Date = .now) -> CardProgress {
        CardProgress(cardID: cardID, fsrsCard: Card(due: now), updatedAt: now)
    }
}

struct DeckDailyUsage: Codable, Sendable, Hashable {
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
