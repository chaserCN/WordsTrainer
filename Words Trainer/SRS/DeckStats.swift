import Foundation
import FSRS

struct DeckStats: Equatable {
    let newAvailable: Int
    let learningDue: Int
    let reviewDue: Int

    var studyTotal: Int { learningDue + reviewDue + newAvailable }

    static let zero = DeckStats(newAvailable: 0, learningDue: 0, reviewDue: 0)
}

enum DeckStatsCalculator {
    static func compute(
        deck: DeckContent,
        progressByCardID: [UUID: CardProgress],
        dailyUsage: DeckDailyUsage?,
        now: Date = .now
    ) -> DeckStats {
        guard deck.isActive else { return .zero }

        var newCount = 0
        var learningDue = 0
        var reviewDue = 0
        let studiedToday = dailyUsage?.newCardsStudied ?? 0
        let newSlotsLeft = max(0, deck.newCardsPerDay - studiedToday)

        for card in deck.activeCards {
            guard let progress = progressByCardID[card.id] else {
                newCount += 1
                continue
            }
            let fsrs = progress.fsrsCard
            switch fsrs.state {
            case .new:
                newCount += 1
            case .learning, .relearning:
                if fsrs.due <= now { learningDue += 1 }
            case .review:
                if fsrs.due <= now { reviewDue += 1 }
            }
        }

        return DeckStats(
            newAvailable: min(newCount, newSlotsLeft),
            learningDue: learningDue,
            reviewDue: min(reviewDue, deck.reviewCardsPerDay)
        )
    }
}
