import Foundation

nonisolated struct DeckStatisticsSnapshot: Sendable {
    let todayUniqueCardCount: Int
    let todayMatchingAttemptCount: Int
    let weekUniqueCardCount: Int
    let weekMatchingAttemptCount: Int
    let monthUniqueCardCount: Int
    let monthMatchingAttemptCount: Int
    let todayStudyTimeBreakdown: StudyTimeBreakdown
    let activityDays: [StudyActivityDay]
    let scheduledDays: [ScheduledReviewDay]
    let weakCards: [WeakCardStat]
}

nonisolated enum DeckStatisticsSnapshotBuilder {
    static func snapshot(userID: UUID) throws -> DeckStatisticsSnapshot {
        let database = try ContentDatabase(userID: userID, mode: .readOnly)
        return try database.readTransaction {
            try snapshot(database: database)
        }
    }

    static func snapshot(database: ContentDatabase) throws -> DeckStatisticsSnapshot {
        let calendar = Calendar.current
        let todayStart = StudyDay.start(for: .now, calendar: calendar)
        let weekStart = calendar.date(byAdding: .day, value: -6, to: todayStart) ?? todayStart
        let monthStart = calendar.date(byAdding: .day, value: -29, to: todayStart) ?? todayStart
        return DeckStatisticsSnapshot(
            todayUniqueCardCount: try database.uniqueStudyCardCount(since: todayStart),
            todayMatchingAttemptCount: try database.matchingAttemptCount(since: todayStart),
            weekUniqueCardCount: try database.uniqueStudyCardCount(since: weekStart),
            weekMatchingAttemptCount: try database.matchingAttemptCount(since: weekStart),
            monthUniqueCardCount: try database.uniqueStudyCardCount(since: monthStart),
            monthMatchingAttemptCount: try database.matchingAttemptCount(since: monthStart),
            todayStudyTimeBreakdown: try database.studyTimeBreakdown(since: todayStart),
            activityDays: try studyActivity(database: database, days: 120),
            scheduledDays: try scheduledReviewDays(database: database, days: 7),
            weakCards: try database.weakCards(limit: WeakCardsPractice.fetchLimit)
        )
    }

    static func studyActivity(
        database: ContentDatabase,
        days: Int
    ) throws -> [StudyActivityDay] {
        let start = Calendar.current.date(
            byAdding: .day,
            value: -max(0, days - 1),
            to: StudyDay.start(for: .now)
        ) ?? .now
        return try database.studyActivity(since: start)
    }

    private static func scheduledReviewDays(
        database: ContentDatabase,
        days: Int
    ) throws -> [ScheduledReviewDay] {
        let activeDecks = try database.loadDecks().filter(\.isActive)
        var progressByDeckID: [UUID: [UUID: CardProgress]] = [:]
        var dailyUsageByDeckID: [UUID: DeckDailyUsage] = [:]

        for deck in activeDecks {
            progressByDeckID[deck.id] = try database.progressMap(deckID: deck.id)
            if let usage = try database.dailyUsage(deckID: deck.id, dayKey: DeckDailyUsage.todayKey()) {
                dailyUsageByDeckID[deck.id] = usage
            }
        }

        return StudyPlanForecastCalculator.compute(
            days: days,
            decks: activeDecks,
            progressByDeckID: progressByDeckID,
            dailyUsageByDeckID: dailyUsageByDeckID
        )
    }
}
