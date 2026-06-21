import Foundation

nonisolated struct DeckDetailSnapshot: Sendable {
    let stats: DeckStats
    let matchingRecord: DeckMatchingRecord?
    let weakCardIDs: Set<UUID>
}

nonisolated enum DeckDetailSnapshotBuilder {
    static func snapshot(userID: UUID, deck: DeckContent) throws -> DeckDetailSnapshot {
        let database = try ContentDatabase(userID: userID, mode: .readOnly)
        return try database.readTransaction {
            try snapshot(database: database, deck: deck)
        }
    }

    static func snapshot(database: ContentDatabase, deck: DeckContent) throws -> DeckDetailSnapshot {
        let progress = try database.progressMap(deckID: deck.id)
        let usage = try database.dailyUsage(deckID: deck.id, dayKey: DeckDailyUsage.todayKey())
        let weakCards = try database.weakCards(limit: deck.activeCards.count, deckID: deck.id)
        return DeckDetailSnapshot(
            stats: DeckStatsCalculator.compute(
                deck: deck,
                progressBySenseID: progress,
                dailyUsage: usage
            ),
            matchingRecord: try database.matchingRecord(deckID: deck.id),
            weakCardIDs: Set(weakCards.map(\.cardID))
        )
    }
}
