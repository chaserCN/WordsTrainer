import Foundation
import FSRS

struct CardProgress: Codable, Sendable {
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
        let d = Date()
        let y = calendar.component(.year, from: d)
        let m = calendar.component(.month, from: d)
        let day = calendar.component(.day, from: d)
        return String(format: "%04d-%02d-%02d", y, m, day)
    }
}
