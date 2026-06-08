import Foundation
import FSRS

nonisolated struct DeckStats: Equatable, Sendable {
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

nonisolated enum DeckStatsCalculator {
    static func compute(
        deck: DeckContent,
        progressBySenseID: [UUID: CardProgress],
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
            for sense in card.activeSenses {
                guard let progress = progressBySenseID[sense.id] else {
                    newCount += 1
                    continue
                }
                let fsrs = progress.fsrsCard
                let due = ReviewSchedule.availableDate(for: fsrs.due, calendar: calendar)
                switch fsrs.state {
                case .new:
                    newCount += 1
                case .learning, .relearning:
                    if due <= now {
                        learningDue += 1
                    } else if StudyDay.isDate(due, inSameStudyDayAs: now, calendar: calendar) {
                        learningLaterToday += 1
                    }
                case .review:
                    if due <= now {
                        reviewDue += 1
                    } else if StudyDay.isDate(due, inSameStudyDayAs: now, calendar: calendar) {
                        reviewLaterToday += 1
                    }
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

nonisolated enum StudyPlanForecastCalculator {
    static func compute(
        days: Int,
        decks: [DeckContent],
        progressByDeckID: [UUID: [UUID: CardProgress]],
        dailyUsageByDeckID: [UUID: DeckDailyUsage],
        now: Date = .now,
        calendar: Calendar = .current
    ) -> [ScheduledReviewDay] {
        guard days > 0 else { return [] }

        let today = StudyDay.start(for: now, calendar: calendar)
        var countsByOffset = Array(repeating: 0, count: days)

        for deck in decks where deck.isActive {
            let progressBySenseID = progressByDeckID[deck.id] ?? [:]
            let dailyUsage = dailyUsageByDeckID[deck.id]
            let todayStats = DeckStatsCalculator.compute(
                deck: deck,
                progressBySenseID: progressBySenseID,
                dailyUsage: dailyUsage,
                now: now,
                calendar: calendar
            )
            countsByOffset[0] += todayStats.studyTotal

            var newCardsRemaining = 0
            var reviewDueByOffset = Array(repeating: 0, count: days)
            var learningDueByOffset = Array(repeating: 0, count: days)

            for card in deck.activeCards {
                for sense in card.activeSenses {
                    guard let progress = progressBySenseID[sense.id] else {
                        newCardsRemaining += 1
                        continue
                    }

                    let fsrs = progress.fsrsCard
                    let due = ReviewSchedule.availableDate(for: fsrs.due, calendar: calendar)
                    switch fsrs.state {
                    case .new:
                        newCardsRemaining += 1
                    case .learning, .relearning:
                        guard let offset = studyDayOffset(
                            for: due,
                            today: today,
                            days: days,
                            calendar: calendar
                        ) else { continue }
                        learningDueByOffset[offset] += 1
                    case .review:
                        guard let offset = studyDayOffset(
                            for: due,
                            today: today,
                            days: days,
                            calendar: calendar
                        ) else { continue }
                        reviewDueByOffset[offset] += 1
                    }
                }
            }

            newCardsRemaining = max(0, newCardsRemaining - todayStats.newAvailable)

            var reviewBacklog = max(0, reviewDueByOffset[0] - todayStats.reviewDue)
            for offset in 1..<days {
                reviewBacklog += reviewDueByOffset[offset]
                let plannedReviews = min(reviewBacklog, deck.reviewCardsPerDay)
                reviewBacklog -= plannedReviews

                let plannedNewCards = min(newCardsRemaining, deck.newCardsPerDay)
                newCardsRemaining -= plannedNewCards

                countsByOffset[offset] += learningDueByOffset[offset] + plannedReviews + plannedNewCards
            }
        }

        return (0..<days).map { offset in
            let date = calendar.date(byAdding: .day, value: offset, to: today) ?? today
            return ScheduledReviewDay(
                dayKey: DeckDailyUsage.dayKey(for: date, calendar: calendar),
                dueCount: countsByOffset[offset]
            )
        }
    }

    private static func studyDayOffset(
        for dueDate: Date,
        today: Date,
        days: Int,
        calendar: Calendar
    ) -> Int? {
        let dueDay = StudyDay.start(for: dueDate, calendar: calendar)
        let normalizedDay = dueDay < today ? today : dueDay
        guard let offset = calendar.dateComponents([.day], from: today, to: normalizedDay).day,
              offset >= 0,
              offset < days else { return nil }
        return offset
    }
}
