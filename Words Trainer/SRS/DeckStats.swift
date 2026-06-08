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
            var cardHasNew = false
            var cardHasLearningDue = false
            var cardHasLearningLaterToday = false
            var cardHasReviewDue = false
            var cardHasReviewLaterToday = false

            for sense in card.activeSenses {
                guard let progress = progressBySenseID[sense.id] else {
                    cardHasNew = true
                    continue
                }
                let fsrs = progress.fsrsCard
                let due = ReviewSchedule.availableDate(for: fsrs.due, calendar: calendar)
                switch fsrs.state {
                case .new:
                    cardHasNew = true
                case .learning, .relearning:
                    if due <= now {
                        cardHasLearningDue = true
                    } else if StudyDay.isDate(due, inSameStudyDayAs: now, calendar: calendar) {
                        cardHasLearningLaterToday = true
                    }
                case .review:
                    if due <= now {
                        cardHasReviewDue = true
                    } else if StudyDay.isDate(due, inSameStudyDayAs: now, calendar: calendar) {
                        cardHasReviewLaterToday = true
                    }
                }
            }

            if cardHasLearningDue {
                learningDue += 1
            } else if cardHasReviewDue {
                reviewDue += 1
            } else if cardHasNew {
                newCount += 1
            } else if cardHasLearningLaterToday {
                learningLaterToday += 1
            } else if cardHasReviewLaterToday {
                reviewLaterToday += 1
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

            var newCardIDs = Set<UUID>()
            var reviewDueByOffset = Array(repeating: Set<UUID>(), count: days)
            var learningDueByOffset = Array(repeating: Set<UUID>(), count: days)

            for card in deck.activeCards {
                var cardHasNew = false
                var learningOffsets = Set<Int>()
                var reviewOffsets = Set<Int>()

                for sense in card.activeSenses {
                    guard let progress = progressBySenseID[sense.id] else {
                        cardHasNew = true
                        continue
                    }

                    let fsrs = progress.fsrsCard
                    let due = ReviewSchedule.availableDate(for: fsrs.due, calendar: calendar)
                    switch fsrs.state {
                    case .new:
                        cardHasNew = true
                    case .learning, .relearning:
                        guard let offset = studyDayOffset(
                            for: due,
                            today: today,
                            days: days,
                            calendar: calendar
                        ) else { continue }
                        learningOffsets.insert(offset)
                    case .review:
                        guard let offset = studyDayOffset(
                            for: due,
                            today: today,
                            days: days,
                            calendar: calendar
                        ) else { continue }
                        reviewOffsets.insert(offset)
                    }
                }

                if cardHasNew {
                    newCardIDs.insert(card.id)
                }
                for offset in learningOffsets {
                    learningDueByOffset[offset].insert(card.id)
                }
                for offset in reviewOffsets {
                    reviewDueByOffset[offset].insert(card.id)
                }
            }

            var newCardsRemaining = newCardIDs
            newCardsRemaining.subtract(sortedPrefix(newCardsRemaining, count: todayStats.newAvailable))

            var reviewBacklog = reviewDueByOffset[0]
            reviewBacklog.subtract(sortedPrefix(reviewBacklog, count: todayStats.reviewDue))
            for offset in 1..<days {
                var scheduledToday = learningDueByOffset[offset]

                reviewBacklog.formUnion(reviewDueByOffset[offset])
                let reviewCandidates = reviewBacklog.subtracting(scheduledToday)
                let plannedReviews = sortedPrefix(reviewCandidates, count: deck.reviewCardsPerDay)
                scheduledToday.formUnion(plannedReviews)
                reviewBacklog.subtract(plannedReviews)

                let newCandidates = newCardsRemaining.subtracting(scheduledToday)
                let plannedNewCards = sortedPrefix(newCandidates, count: deck.newCardsPerDay)
                scheduledToday.formUnion(plannedNewCards)
                newCardsRemaining.subtract(plannedNewCards)

                countsByOffset[offset] += scheduledToday.count
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

    private static func sortedPrefix(_ ids: Set<UUID>, count: Int) -> Set<UUID> {
        guard count > 0 else { return [] }
        return Set(ids.sorted { $0.uuidString < $1.uuidString }.prefix(count))
    }
}
