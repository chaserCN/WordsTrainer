import Foundation

nonisolated struct DeckTodaySnapshot: Sendable {
    let decks: [DeckContent]
    let statsByDeckID: [UUID: DeckStats]
    let todayPracticeCount: Int
    let todayPracticeCountByDeckID: [UUID: Int]
    let todayStudyCards: [WordCardContent]
    let todayStudyCardsByDeckID: [UUID: [WordCardContent]]
    let activityDays: [StudyActivityDay]
}

nonisolated enum TodayReadOnlySnapshotBuilder {
    static func dashboardSnapshot(userID: UUID) throws -> DeckTodaySnapshot {
        let database = try ContentDatabase(userID: userID, mode: .readOnly)
        return try database.readTransaction {
            try dashboardSnapshot(database: database)
        }
    }

    /// Dashboard snapshot: counts and stats only, using the lightweight deck
    /// load (no examples/questions/forms/distractors/media). The full study-card
    /// lists are intentionally empty here; study modes load them on demand.
    static func dashboardSnapshot(database: ContentDatabase) throws -> DeckTodaySnapshot {
        let decks = try database.loadDecksLite()
        let activeDecks = decks.filter(\.isActive)
        var statsByDeckID: [UUID: DeckStats] = [:]
        var todayPracticeCountByDeckID: [UUID: Int] = [:]
        var todayPracticeCount = 0

        for deck in activeDecks {
            let snapshot = try TodaySnapshotBuilder.deckSnapshot(database: database, deck: deck)
            let deckPracticeCount = TodaySnapshotBuilder.practiceCards(snapshot: snapshot).count
            todayPracticeCountByDeckID[deck.id] = deckPracticeCount
            statsByDeckID[deck.id] = DeckStatsCalculator.compute(
                deck: deck,
                progressBySenseID: snapshot.progressBySenseID,
                dailyUsage: snapshot.dailyUsage
            )
            todayPracticeCount += deckPracticeCount
        }
        let activity = try DeckStatisticsSnapshotBuilder.studyActivity(database: database, days: 90)

        return DeckTodaySnapshot(
            decks: decks,
            statsByDeckID: statsByDeckID,
            todayPracticeCount: todayPracticeCount,
            todayPracticeCountByDeckID: todayPracticeCountByDeckID,
            todayStudyCards: [],
            todayStudyCardsByDeckID: [:],
            activityDays: activity
        )
    }

    static func wordListSnapshot(
        userID: UUID,
        cachedCards: [UUID: [WordCardContent]]
    ) throws -> [WordCardContent] {
        let database = try ContentDatabase(userID: userID, mode: .readOnly)
        return try database.readTransaction {
            let decks = try activeDecksWithCards(database: database, cachedCards: cachedCards)
            var queue: [WordCardContent] = []
            var practice: [WordCardContent] = []
            for deck in decks {
                let snapshot = try TodaySnapshotBuilder.deckSnapshot(database: database, deck: deck)
                queue.append(contentsOf: TodaySnapshotBuilder.queueCards(snapshot: snapshot))
                practice.append(contentsOf: TodaySnapshotBuilder.practiceCards(snapshot: snapshot))
            }
            return TodaySnapshotBuilder.uniqueCards(queue.isEmpty ? practice : queue)
        }
    }

    static func wordListSnapshot(
        userID: UUID,
        deckID: UUID,
        cachedCards: [UUID: [WordCardContent]]
    ) throws -> [WordCardContent] {
        let database = try ContentDatabase(userID: userID, mode: .readOnly)
        return try database.readTransaction {
            guard var deck = try database.loadDecksLite().first(where: { $0.id == deckID && $0.isActive }) else {
                return []
            }
            deck = try deckWithCards(deck, database: database, cachedCards: cachedCards)
            let snapshot = try TodaySnapshotBuilder.deckSnapshot(database: database, deck: deck)
            let queue = TodaySnapshotBuilder.queueCards(snapshot: snapshot)
            return TodaySnapshotBuilder.uniqueCards(
                queue.isEmpty ? TodaySnapshotBuilder.practiceCards(snapshot: snapshot) : queue
            )
        }
    }

    private static func activeDecksWithCards(
        database: ContentDatabase,
        cachedCards: [UUID: [WordCardContent]]
    ) throws -> [DeckContent] {
        try database.loadDecksLite().filter(\.isActive).map { deck in
            try deckWithCards(deck, database: database, cachedCards: cachedCards)
        }
    }

    private static func deckWithCards(
        _ deck: DeckContent,
        database: ContentDatabase,
        cachedCards: [UUID: [WordCardContent]]
    ) throws -> DeckContent {
        var full = deck
        if let cached = cachedCards[deck.id] {
            full.cards = cached
        } else {
            let dbCards = try database.deckCards(deckID: deck.id)
            if !dbCards.isEmpty {
                full.cards = dbCards
            }
        }
        return full
    }
}
