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

    func setDeckStatus(_ status: ContentStatus, for deckID: UUID) throws {
        try database.updateDeckStatus(deckID: deckID, status: status)
    }

    func studyActivity(days: Int) throws -> [StudyActivityDay] {
        let start = Calendar.current.date(
            byAdding: .day,
            value: -max(0, days - 1),
            to: Calendar.current.startOfDay(for: .now)
        ) ?? .now
        return try database.studyActivity(since: start)
    }

    func studyReviewCount(since startDate: Date) throws -> StudyReviewCount {
        try database.studyReviewCount(since: startDate)
    }

    func weakCards(limit: Int = 10) throws -> [WeakCardStat] {
        try database.weakCards(limit: limit)
    }

    func scheduledReviewDays(days: Int) throws -> [ScheduledReviewDay] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let activeDecks = try allDecks().filter(\.isActive)
        var countsByDay: [String: Int] = [:]

        for offset in 0..<days {
            let date = calendar.date(byAdding: .day, value: offset, to: today) ?? today
            countsByDay[DeckDailyUsage.dayKey(for: date, calendar: calendar)] = 0
        }

        for deck in activeDecks {
            let activeCardIDs = Set(deck.activeCards.map(\.id))
            let progress = try database.progressMap(deckID: deck.id)
            for (cardID, cardProgress) in progress where activeCardIDs.contains(cardID) {
                let state = cardProgress.fsrsCard.state
                guard state != .new else { continue }
                let dueDay = calendar.startOfDay(for: cardProgress.fsrsCard.due)
                let normalizedDay = dueDay < today ? today : dueDay
                guard let dayOffset = calendar.dateComponents([.day], from: today, to: normalizedDay).day,
                      dayOffset >= 0,
                      dayOffset < days else { continue }
                let key = DeckDailyUsage.dayKey(for: normalizedDay, calendar: calendar)
                countsByDay[key, default: 0] += 1
            }
        }

        return (0..<days).map { offset in
            let date = calendar.date(byAdding: .day, value: offset, to: today) ?? today
            let key = DeckDailyUsage.dayKey(for: date, calendar: calendar)
            return ScheduledReviewDay(dayKey: key, dueCount: countsByDay[key, default: 0])
        }
    }

    func firstDeckWithStudyToday(mode: StudyMode = .flashcards) throws -> (DeckContent, StudySession)? {
        for deck in try allDecks() where deck.isActive {
            let stats = try stats(for: deck)
            guard stats.studyTotal > 0 else { continue }
            return (deck, try startTodaySession(deck: deck, mode: mode))
        }
        return nil
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
        let studyCards = deck.isActive ? deck.activeCards : []
        let progress = try database.progressMap(deckID: deck.id)
        let usage = try database.dailyUsage(deckID: deck.id, dayKey: DeckDailyUsage.todayKey())
        let queue: [StudyQueueItem]
        if mode == .matching || mode == .recall {
            let items = studyCards.map { card in
                StudyQueueItem(
                    card: card,
                    progress: progress[card.id] ?? CardProgress.newCard(cardID: card.id)
                )
            }
            queue = mode == .recall ? items.shuffled() : items
        } else {
            var built = StudyQueueBuilder.build(
                deck: deck,
                progressByCardID: progress,
                dailyUsage: usage
            )
            if built.isEmpty {
                built = studyCards.map { card in
                    StudyQueueItem(
                        card: card,
                        progress: progress[card.id] ?? CardProgress.newCard(cardID: card.id)
                    )
                }.shuffled()
            }
            queue = built
        }
        return StudySession(
            deckID: deck.id,
            mode: mode,
            queue: queue,
            deckCards: studyCards,
            dailyUsage: usage,
            engine: engine
        )
    }

    /// Сессия только из карт, попавших в очередь на сегодня (вкладка «Сегодня»).
    func startTodaySession(deck: DeckContent, mode: StudyMode) throws -> StudySession {
        let studyCards = deck.isActive ? deck.activeCards : []
        let progress = try database.progressMap(deckID: deck.id)
        let usage = try database.dailyUsage(deckID: deck.id, dayKey: DeckDailyUsage.todayKey())
        let queue = StudyQueueBuilder.build(
            deck: deck,
            progressByCardID: progress,
            dailyUsage: usage
        )

        return StudySession(
            deckID: deck.id,
            mode: mode,
            queue: queue,
            deckCards: studyCards,
            dailyUsage: usage,
            engine: engine
        )
    }

    /// Сессия из всех активных карт колоды независимо от расписания (вкладка «Колоды»).
    func startAllCardsSession(deck: DeckContent, mode: StudyMode) throws -> StudySession {
        let studyCards = deck.isActive ? deck.activeCards : []
        let progress = try database.progressMap(deckID: deck.id)
        let usage = try database.dailyUsage(deckID: deck.id, dayKey: DeckDailyUsage.todayKey())
        let items = studyCards.map { card in
            StudyQueueItem(
                card: card,
                progress: progress[card.id] ?? CardProgress.newCard(cardID: card.id)
            )
        }
        let queue = (mode == .recall || mode == .clozeMultipleChoice) ? items.shuffled() : items

        return StudySession(
            deckID: deck.id,
            mode: mode,
            queue: queue,
            deckCards: studyCards,
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

    func saveStudyReview(_ event: StudyReviewEvent) throws {
        try database.saveStudyReview(event)
    }

    func matchingRecord(deckID: UUID) throws -> DeckMatchingRecord? {
        try database.matchingRecord(deckID: deckID)
    }

    /// Saves when there is no record, the pair count changed, or the time improved.
    @discardableResult
    func saveMatchingRecordIfBest(
        deckID: UUID,
        duration: TimeInterval,
        pairCount: Int
    ) throws -> Bool {
        let existing = try database.matchingRecord(deckID: deckID)
        if let existing {
            guard existing.pairCount == pairCount else {
                try database.saveMatchingRecord(
                    DeckMatchingRecord(
                        deckID: deckID,
                        bestDuration: duration,
                        pairCount: pairCount,
                        achievedAt: .now
                    )
                )
                return true
            }
            guard duration < existing.bestDuration else { return false }
        }
        try database.saveMatchingRecord(
            DeckMatchingRecord(
                deckID: deckID,
                bestDuration: duration,
                pairCount: pairCount,
                achievedAt: .now
            )
        )
        return true
    }
}

extension StudySession {
    func advanceAfterReview(
        outcome: ReviewOutcome,
        store: DeckStore
    ) throws {
        try advanceAfterReview(outcome: outcome) { progress, wasNew in
            try store.saveProgress(deckID: deckID, progress: progress, wasNew: wasNew)
        } onReview: { event in
            try store.saveStudyReview(event)
        }
    }
}
