import Foundation

@MainActor
enum StudySessionFactory {
    static func todayDeckSession(
        deck: DeckContent,
        mode: StudyMode,
        progressBySenseID: [UUID: CardProgress],
        dailyUsage: DeckDailyUsage?,
        engine: StudySessionEngine
    ) -> StudySession {
        let studyCards = deck.isActive ? deck.activeCards : []
        let scheduledItems = StudyQueueBuilder.build(
            deck: deck,
            progressBySenseID: progressBySenseID,
            dailyUsage: dailyUsage
        )
        let queue = mode.preparedScheduledQueue(scheduledItems)
        return StudySession(
            deckID: deck.id,
            mode: mode,
            queue: queue,
            deckCards: studyCards,
            dailyUsage: dailyUsage,
            engine: engine,
            matchingRecordScope: mode.disablesMatchingRecordScope ? MatchingRecordScope.none : nil,
            reviewSource: .todayQueue,
            savesProgress: mode.savesProgressByDefault
        )
    }

    static func allCardsSession(
        deck: DeckContent,
        mode: StudyMode,
        progressBySenseID: [UUID: CardProgress],
        dailyUsage: DeckDailyUsage?,
        engine: StudySessionEngine
    ) -> StudySession {
        let studyCards = deck.isActive ? deck.activeCards : []
        let items = StudyQueueBuilder.allItems(cards: studyCards, progressBySenseID: progressBySenseID)
        let queue = mode.preparedDeckQueue(items)
        return StudySession(
            deckID: deck.id,
            mode: mode,
            queue: queue,
            deckCards: studyCards,
            dailyUsage: dailyUsage,
            engine: engine,
            reviewSource: .deckSession,
            savesProgress: mode.savesProgressByDefault
        )
    }

    static func weakCardsSession(
        deck: DeckContent,
        studyCards: [WordCardContent],
        mode: StudyMode,
        progressBySenseID: [UUID: CardProgress],
        dailyUsage: DeckDailyUsage?,
        engine: StudySessionEngine
    ) -> StudySession? {
        guard !studyCards.isEmpty else { return nil }
        let items = StudyQueueBuilder.allItems(cards: studyCards, progressBySenseID: progressBySenseID)
        let queue = mode.preparedDeckQueue(items)
        return StudySession(
            deckID: deck.id,
            mode: mode,
            queue: queue,
            deckCards: studyCards,
            dailyUsage: dailyUsage,
            engine: engine,
            matchingRecordScope: mode.disablesMatchingRecordScope ? MatchingRecordScope.none : .deck(deck.id),
            reviewSource: .weakCards,
            savesProgress: mode.savesProgressByDefault
        )
    }

    static func weakMatchingSession(
        queue: [StudyQueueItem],
        engine: StudySessionEngine
    ) -> StudySession? {
        guard queue.count >= 2 else { return nil }
        return StudySession(
            deckID: WeakCardsPractice.deckID,
            mode: .matching,
            queue: queue,
            deckCards: queue.map(\.card),
            dailyUsage: nil,
            engine: engine,
            matchingRecordScope: MatchingRecordScope.none,
            reviewSource: .weakCards,
            savesProgress: false
        )
    }
}
