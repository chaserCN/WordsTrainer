import Foundation

nonisolated enum TodaySnapshotBuilder {
    static func deckSnapshot(
        database: ContentDatabase,
        deck: DeckContent
    ) throws -> TodayStudyDeckSnapshot {
        try TodayStudyDeckSnapshot(
            deck: deck,
            progressBySenseID: database.progressMap(deckID: deck.id),
            dailyUsage: database.dailyUsage(deckID: deck.id, dayKey: DeckDailyUsage.todayKey()),
            reviewedSenseIDs: database.reviewedSenseIDs(deckID: deck.id, source: .todayQueue)
        )
    }

    static func practiceCardCount(snapshot: TodayStudyDeckSnapshot) -> Int {
        guard snapshot.deck.isActive, !snapshot.reviewedSenseIDs.isEmpty else { return 0 }
        let activeSenseIDs = Set(snapshot.deck.activeCards.flatMap { $0.activeSenses.map(\.id) })
        return snapshot.reviewedSenseIDs.reduce(0) { count, senseID in
            activeSenseIDs.contains(senseID) ? count + 1 : count
        }
    }

    static func queueCards(snapshot: TodayStudyDeckSnapshot) -> [WordCardContent] {
        let cardByID = Dictionary(uniqueKeysWithValues: snapshot.deck.activeCards.map { ($0.id, $0) })
        return StudyQueueBuilder.build(
            deck: snapshot.deck,
            progressBySenseID: snapshot.progressBySenseID,
            dailyUsage: snapshot.dailyUsage
        ).compactMap { item in cardByID[item.cardID] }
    }

    static func practiceCards(snapshot: TodayStudyDeckSnapshot) -> [WordCardContent] {
        guard snapshot.deck.isActive, !snapshot.reviewedSenseIDs.isEmpty else { return [] }
        let reviewedSenseIDs = Set(snapshot.reviewedSenseIDs)
        var cards: [WordCardContent] = []
        var seenCardIDs: Set<UUID> = []
        for card in snapshot.deck.activeCards where card.activeSenses.contains(where: { reviewedSenseIDs.contains($0.id) }) {
            if seenCardIDs.insert(card.id).inserted {
                cards.append(card)
            }
        }
        return cards
    }

    static func uniqueCards(_ cards: [WordCardContent]) -> [WordCardContent] {
        var seen: Set<UUID> = []
        return cards.filter { seen.insert($0.id).inserted }
    }
}
