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

@Observable
@MainActor
final class StudySession {
    private static let matchingSlotCount = 4

    let deckID: UUID
    let mode: StudyMode
    private(set) var queue: [StudyQueueItem]
    private(set) var matchingWordSlots: [StudyQueueItem] = []
    private var matchingPool: [StudyQueueItem] = []
    private var dailyUsage: DeckDailyUsage?
    private let engine: StudySessionEngine

    var current: StudyQueueItem? { queue.first }
    var remainingCount: Int {
        if mode == .matching {
            return matchingWordSlots.count + matchingPool.count
        }
        return queue.count
    }
    var isFinished: Bool {
        if mode == .matching {
            return matchingWordSlots.isEmpty && matchingPool.isEmpty
        }
        return queue.isEmpty
    }
    var matchingVisibleItems: [StudyQueueItem] { matchingWordSlots }

    init(
        deckID: UUID,
        mode: StudyMode,
        queue: [StudyQueueItem],
        dailyUsage: DeckDailyUsage?,
        engine: StudySessionEngine
    ) {
        self.deckID = deckID
        self.mode = mode
        self.dailyUsage = dailyUsage
        self.engine = engine
        if mode == .matching {
            matchingWordSlots = Array(queue.prefix(Self.matchingSlotCount))
            matchingPool = Array(queue.dropFirst(Self.matchingSlotCount))
            self.queue = []
        } else {
            self.queue = queue
        }
    }

    func outcome(for result: ReviewOutcome) -> ReviewOutcome {
        result
    }

    func advanceAfterReview(
        outcome: ReviewOutcome,
        store: DeckStore
    ) throws {
        guard let item = current else { return }
        let wasNew = item.progress.fsrsCard.state == .new
        let updated = try engine.applyReview(progress: item.progress, outcome: outcome)
        try store.saveProgress(deckID: deckID, progress: updated, wasNew: wasNew && outcome.passed)
        queue.removeFirst()
    }

    /// Removes a matched card; refills that word slot from the pool when possible.
    /// Returns slot index and the new card in that slot (if refilled).
    func removeMatchedCard(id: UUID) -> (slotIndex: Int, newCard: StudyQueueItem?)? {
        guard mode == .matching else {
            queue.removeAll { $0.id == id }
            return nil
        }
        guard let slotIndex = matchingWordSlots.firstIndex(where: { $0.id == id }) else {
            return nil
        }
        matchingWordSlots.remove(at: slotIndex)
        guard let next = matchingPool.first else {
            return (slotIndex, nil)
        }
        matchingPool.removeFirst()
        matchingWordSlots.insert(next, at: slotIndex)
        return (slotIndex, next)
    }
}
