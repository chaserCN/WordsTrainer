import Foundation
import FSRS

@MainActor
@Observable
final class DeckStore {
    private let database: ContentDatabase
    private let engine = StudySessionEngine()

    init(database: ContentDatabase) {
        self.database = database
    }

    convenience init() throws {
        try self.init(database: ContentDatabase())
    }

    static var databaseExists: Bool { ContentDatabase.databaseExists() }

    func allDecks() throws -> [DeckContent] {
        try database.loadDecks()
    }

    func stats(for deck: DeckContent) throws -> DeckStats {
        let progress = try database.progressMap(deckID: deck.id)
        let usage = try database.dailyUsage(deckID: deck.id, dayKey: DeckDailyUsage.todayKey())
        return DeckStatsCalculator.compute(
            deck: deck,
            progressByCardID: progress,
            dailyUsage: usage
        )
    }

    func startSession(deck: DeckContent, mode: StudyMode) throws -> StudySession {
        let progress = try database.progressMap(deckID: deck.id)
        let usage = try database.dailyUsage(deckID: deck.id, dayKey: DeckDailyUsage.todayKey())
        let queue: [StudyQueueItem]
        if mode == .matching {
            queue = deck.cards.map { card in
                StudyQueueItem(
                    card: card,
                    progress: progress[card.id] ?? CardProgress.newCard(cardID: card.id)
                )
            }
        } else {
            queue = StudyQueueBuilder.build(
                deck: deck,
                progressByCardID: progress,
                dailyUsage: usage
            )
        }
        return StudySession(
            deckID: deck.id,
            mode: mode,
            queue: queue,
            dailyUsage: usage,
            engine: engine
        )
    }

    func saveProgress(
        deckID: UUID,
        progress: CardProgress,
        wasNew: Bool
    ) throws {
        try database.saveProgress(deckID: deckID, progress: progress)

        if wasNew {
            let key = DeckDailyUsage.todayKey()
            let usage = try database.dailyUsage(deckID: deckID, dayKey: key)
                ?? DeckDailyUsage(dayKey: key)
            let updated = engine.recordNewCardStudied(previous: usage)
            try database.saveDailyUsage(deckID: deckID, usage: updated)
        }
    }
}

extension StudySession {
    func advanceAfterReview(
        outcome: ReviewOutcome,
        store: DeckStore
    ) throws {
        try advanceAfterReview(outcome: outcome) { progress, wasNew in
            try store.saveProgress(deckID: deckID, progress: progress, wasNew: wasNew)
        }
    }
}
