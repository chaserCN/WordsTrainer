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
        var newCount = 0
        var learningDue = 0
        var reviewDue = 0

        for card in deck.cards {
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
            newAvailable: newCount,
            learningDue: learningDue,
            reviewDue: reviewDue
        )
    }
}
