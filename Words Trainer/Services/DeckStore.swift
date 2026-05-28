import Foundation
import FSRS
import SwiftData

@MainActor
@Observable
final class DeckStore {
    private let modelContext: ModelContext
    private let engine = StudySessionEngine()

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    func seedIfNeeded() throws {
        let descriptor = FetchDescriptor<DeckRecord>()
        let existing = try modelContext.fetch(descriptor)
        if !existing.isEmpty {
            if let animalsDeck = existing.first(where: { $0.id == SampleDeck.animalsID }) {
                try updateDeck(animalsDeck, with: SampleDeck.animals)
            }
            try modelContext.save()
            return
        }
        try importDeck(SampleDeck.animals)
    }

    func importDeck(_ content: DeckContent) throws {
        let deck = DeckRecord(
            id: content.id,
            title: content.title,
            avatarSystemName: content.avatarSystemName,
            languageCode: content.languageCode,
            newCardsPerDay: content.newCardsPerDay,
            reviewCardsPerDay: content.reviewCardsPerDay
        )
        modelContext.insert(deck)
        for card in content.cards {
            let record = CardRecord(from: card, deck: deck)
            modelContext.insert(record)
            deck.cards.append(record)
        }
        try modelContext.save()
    }

    private func updateDeck(_ deck: DeckRecord, with content: DeckContent) throws {
        deck.title = content.title
        deck.avatarSystemName = content.avatarSystemName
        deck.languageCode = content.languageCode
        deck.newCardsPerDay = content.newCardsPerDay
        deck.reviewCardsPerDay = content.reviewCardsPerDay

        let existingCardIDs = Set(deck.cards.map(\.id))
        for card in content.cards where !existingCardIDs.contains(card.id) {
            let record = CardRecord(from: card, deck: deck)
            modelContext.insert(record)
            deck.cards.append(record)
        }
    }

    func allDecks() throws -> [DeckRecord] {
        var descriptor = FetchDescriptor<DeckRecord>()
        descriptor.sortBy = [SortDescriptor(\.title)]
        return try modelContext.fetch(descriptor)
    }

    func stats(for deck: DeckRecord) throws -> DeckStats {
        let content = deck.toContent()
        let progress = try progressMap(deckID: deck.id)
        let usage = try dailyUsage(deckID: deck.id)
        return DeckStatsCalculator.compute(
            deck: content,
            progressByCardID: progress,
            dailyUsage: usage
        )
    }

    func startSession(deck: DeckRecord, mode: StudyMode) throws -> StudySession {
        let content = deck.toContent()
        let progress = try progressMap(deckID: deck.id)
        let usage = try dailyUsage(deckID: deck.id)
        let queue: [StudyQueueItem]
        if mode == .matching {
            queue = content.cards.map { card in
                StudyQueueItem(
                    card: card,
                    progress: progress[card.id] ?? CardProgress.newCard(cardID: card.id)
                )
            }
        } else {
            queue = StudyQueueBuilder.build(
                deck: content,
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
        let encoded = try CardProgressRecord.encode(progress, deckID: deckID)
        if let existing = try fetchProgressRecord(cardID: progress.cardID) {
            existing.fsrsData = encoded.fsrsData
            existing.updatedAt = encoded.updatedAt
        } else {
            modelContext.insert(encoded)
        }

        if wasNew {
            let usage = try dailyUsage(deckID: deckID) ?? DeckDailyUsage(dayKey: DeckDailyUsage.todayKey())
            let updated = engine.recordNewCardStudied(previous: usage)
            try saveDailyUsage(deckID: deckID, usage: updated)
        }
        try modelContext.save()
    }

    private func progressMap(deckID: UUID) throws -> [UUID: CardProgress] {
        let descriptor = FetchDescriptor<CardProgressRecord>(
            predicate: #Predicate { $0.deckID == deckID }
        )
        let records = try modelContext.fetch(descriptor)
        var map: [UUID: CardProgress] = [:]
        for record in records {
            if let p = try? record.toProgress() {
                map[p.cardID] = p
            }
        }
        return map
    }

    private func fetchProgressRecord(cardID: UUID) throws -> CardProgressRecord? {
        var descriptor = FetchDescriptor<CardProgressRecord>(
            predicate: #Predicate { $0.cardID == cardID }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func dailyUsage(deckID: UUID) throws -> DeckDailyUsage? {
        let key = DeckDailyUsage.todayKey()
        var descriptor = FetchDescriptor<DeckDailyUsageRecord>(
            predicate: #Predicate { $0.deckID == deckID && $0.dayKey == key }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first?.toUsage()
    }

    private func saveDailyUsage(deckID: UUID, usage: DeckDailyUsage) throws {
        let key = usage.dayKey
        if let existing = try modelContext.fetch(FetchDescriptor<DeckDailyUsageRecord>(
            predicate: #Predicate { $0.deckID == deckID && $0.dayKey == key }
        )).first {
            existing.newCardsStudied = usage.newCardsStudied
        } else {
            modelContext.insert(DeckDailyUsageRecord(
                deckID: deckID,
                dayKey: key,
                newCardsStudied: usage.newCardsStudied
            ))
        }
    }
}

@Observable
@MainActor
final class StudySession {
    let deckID: UUID
    let mode: StudyMode
    private(set) var queue: [StudyQueueItem]
    private var dailyUsage: DeckDailyUsage?
    private let engine: StudySessionEngine

    var current: StudyQueueItem? { queue.first }
    var remainingCount: Int { queue.count }
    var isFinished: Bool { queue.isEmpty }
    var matchingVisibleItems: [StudyQueueItem] { Array(queue.prefix(4)) }

    init(
        deckID: UUID,
        mode: StudyMode,
        queue: [StudyQueueItem],
        dailyUsage: DeckDailyUsage?,
        engine: StudySessionEngine
    ) {
        self.deckID = deckID
        self.mode = mode
        self.queue = queue
        self.dailyUsage = dailyUsage
        self.engine = engine
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

    func removeMatchedCard(id: UUID) {
        queue.removeAll { $0.id == id }
    }
}
