import Foundation
import FSRS

struct DeckStats: Equatable {
    let newAvailable: Int
    let learningDue: Int
    let reviewDue: Int
    let dueLaterToday: Int

    var studyTotal: Int { learningDue + reviewDue + newAvailable }

    init(newAvailable: Int, learningDue: Int, reviewDue: Int, dueLaterToday: Int = 0) {
        self.newAvailable = newAvailable
        self.learningDue = learningDue
        self.reviewDue = reviewDue
        self.dueLaterToday = dueLaterToday
    }

    static let zero = DeckStats(newAvailable: 0, learningDue: 0, reviewDue: 0, dueLaterToday: 0)
}

enum DeckStatsCalculator {
    static func compute(
        deck: DeckContent,
        progressByCardID: [UUID: CardProgress],
        dailyUsage: DeckDailyUsage?,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> DeckStats {
        guard deck.isActive else { return .zero }

        var newCount = 0
        var learningDue = 0
        var learningLaterToday = 0
        var reviewDue = 0
        var reviewLaterToday = 0
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
                if fsrs.due <= now {
                    learningDue += 1
                } else if StudyDay.isDate(fsrs.due, inSameStudyDayAs: now, calendar: calendar) {
                    learningLaterToday += 1
                }
            case .review:
                if fsrs.due <= now {
                    reviewDue += 1
                } else if StudyDay.isDate(fsrs.due, inSameStudyDayAs: now, calendar: calendar) {
                    reviewLaterToday += 1
                }
            }
        }

        let cappedReviewDue = min(reviewDue, deck.reviewCardsPerDay)
        let cappedReviewTotalToday = min(reviewDue + reviewLaterToday, deck.reviewCardsPerDay)
        let cappedReviewLaterToday = max(0, cappedReviewTotalToday - cappedReviewDue)

        return DeckStats(
            newAvailable: min(newCount, newSlotsLeft),
            learningDue: learningDue,
            reviewDue: cappedReviewDue,
            dueLaterToday: learningLaterToday + cappedReviewLaterToday
        )
    }
}
