import Foundation
import FSRS

enum DeckStoreError: LocalizedError {
    case missingSelectedUser

    var errorDescription: String? {
        switch self {
        case .missingSelectedUser:
            "Пользователь ещё не загружен с сервера."
        }
    }
}

enum WeakCardsPractice {
    /// Синтетический id для игры «Забытые слова» — у неё нет реальной колоды.
    static let deckID = UUID(uuidString: "00000000-0000-0000-0000-0000DEADBEEF")!
    static let fetchLimit = 30
    static let displayLimit = 10
    static let gamePairLimit = 12
}

@MainActor
@Observable
final class DeckStore {
    static let localDataDidChangeNotification = Notification.Name("DeckStore.localDataDidChange")
    static let changedDeckIDUserInfoKey = "deckID"

    private let userID: UUID
    private let database: ContentDatabase
    private let todayMatchingRecordStore: TodayMatchingRecordStore
    private let engine = StudySessionEngine()

    init(database: ContentDatabase) {
        self.userID = database.currentUserID
        self.database = database
        self.todayMatchingRecordStore = TodayMatchingRecordStore()
    }

    init(database: ContentDatabase, todayMatchingRecordStore: TodayMatchingRecordStore) {
        self.userID = database.currentUserID
        self.database = database
        self.todayMatchingRecordStore = todayMatchingRecordStore
    }

    convenience init() throws {
        guard let selectedUserID = AppUserStore.shared.selectedUserID else {
            throw DeckStoreError.missingSelectedUser
        }
        try self.init(database: ContentDatabase(userID: selectedUserID))
    }

    convenience init(userID: UUID) throws {
        try self.init(database: ContentDatabase(userID: userID))
    }

    static var databaseExists: Bool { ContentDatabase.databaseExists() }

    func allDecks() throws -> [DeckContent] {
        try database.loadDecks()
    }

    func setDeckStatus(_ status: ContentStatus, for deckID: UUID) throws {
        try database.updateDeckStatus(deckID: deckID, status: status)
        notifyLocalDataDidChange(deckID: deckID)
    }

    func studyActivity(days: Int) throws -> [StudyActivityDay] {
        let start = Calendar.current.date(
            byAdding: .day,
            value: -max(0, days - 1),
            to: StudyDay.start(for: .now)
        ) ?? .now
        return try database.studyActivity(since: start)
    }

    func studyReviewCount(since startDate: Date) throws -> StudyReviewCount {
        try database.studyReviewCount(since: startDate)
    }

    func weakCards(limit: Int = 30) throws -> [WeakCardStat] {
        try database.weakCards(limit: limit)
    }

    func weakCards(deckID: UUID, limit: Int = 30) throws -> [WeakCardStat] {
        try database.weakCards(limit: limit, deckID: deckID)
    }

    /// Игра «Колонки» из самых забываемых слов всех активных колод.
    /// Чистая практика: ничего не сохраняем (`savesProgress: false`).
    func weakCardsMatchingSession(
        from weakStats: [WeakCardStat],
        limit: Int = 12
    ) throws -> StudySession? {
        let weak = Array(weakStats.shuffled().prefix(limit))
        guard !weak.isEmpty else { return nil }
        var cardByID: [UUID: WordCardContent] = [:]
        for deck in try allDecks() where deck.isActive {
            for card in deck.activeCards {
                cardByID[card.id] = card
            }
        }
        let cards = weak.compactMap { cardByID[$0.cardID] }
        guard cards.count >= 2 else { return nil }
        let queue = cards.map { card in
            StudyQueueItem(card: card, progress: CardProgress.newCard(cardID: card.id))
        }
        return StudySession(
            deckID: WeakCardsPractice.deckID,
            mode: .matching,
            queue: queue,
            deckCards: cards,
            dailyUsage: nil,
            engine: engine,
            savesProgress: false
        )
    }

    func scheduledReviewDays(days: Int) throws -> [ScheduledReviewDay] {
        let calendar = Calendar.current
        let today = StudyDay.start(for: .now, calendar: calendar)
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
                let dueDay = StudyDay.start(for: cardProgress.fsrsCard.due, calendar: calendar)
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

    func startTodaySession(mode: StudyMode) throws -> StudySession? {
        try TodayStudySessionBuilder.todaySession(
            snapshots: todaySnapshots(),
            mode: mode,
            dayKey: DeckDailyUsage.todayKey(),
            engine: engine
        )
    }

    func todayStudyCards() throws -> [WordCardContent] {
        if let session = try startTodaySession(mode: .flashcards) {
            return uniqueCards(session.queue.map(\.card))
        }
        if let session = try startTodayPracticeSession(mode: .flashcards) {
            return uniqueCards(session.queue.map(\.card))
        }
        return []
    }

    func todayStudyCards(deck: DeckContent) throws -> [WordCardContent] {
        let todaySession = try startTodaySession(deck: deck, mode: .flashcards)
        if !todaySession.queue.isEmpty {
            return uniqueCards(todaySession.queue.map(\.card))
        }
        if let practiceSession = try startTodayPracticeSession(deck: deck, mode: .flashcards) {
            return uniqueCards(practiceSession.queue.map(\.card))
        }
        return []
    }

    func todayPracticeCardCount() throws -> Int {
        try TodayStudySessionBuilder.todayPracticeCardCount(snapshots: todaySnapshots())
    }

    func todayPracticeCardCount(deck: DeckContent) throws -> Int {
        try TodayStudySessionBuilder.todayPracticeCardCount(snapshot: todaySnapshot(deck: deck))
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
        if mode.isMatching || mode == .recall {
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
            engine: engine,
            reviewSource: .todayQueue
        )
    }

    func startTodayPracticeSession(mode: StudyMode) throws -> StudySession? {
        try TodayStudySessionBuilder.todayPracticeSession(
            snapshots: todaySnapshots(),
            mode: mode,
            dayKey: DeckDailyUsage.todayKey(),
            engine: engine
        )
    }

    func startTodayPracticeSession(deck: DeckContent, mode: StudyMode) throws -> StudySession? {
        try TodayStudySessionBuilder.todayPracticeSession(
            snapshot: todaySnapshot(deck: deck),
            mode: mode,
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
            engine: engine,
            reviewSource: .deckSession
        )
    }

    func startWeakCardsSession(deck: DeckContent, mode: StudyMode) throws -> StudySession? {
        let weakStats = try weakCards(deckID: deck.id, limit: deck.activeCards.count)
        let weakCardIDs = Set(weakStats.map(\.cardID))
        let studyCards = deck.isActive ? deck.activeCards.filter { weakCardIDs.contains($0.id) } : []
        guard !studyCards.isEmpty else { return nil }

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
            engine: engine,
            matchingRecordScope: mode.isMatching ? .none : .deck(deck.id),
            reviewSource: .weakCards
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

    func matchingRecord(scope: MatchingRecordScope) throws -> MatchingRecordSummary? {
        switch scope {
        case .none:
            return nil
        case .deck(let deckID):
            return try database.matchingRecord(deckID: deckID)?.summary
        case .today(let dayKey):
            return todayMatchingRecordStore.record(userID: userID, dayKey: dayKey)
        }
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
                notifyLocalDataDidChange(deckID: deckID)
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
        notifyLocalDataDidChange(deckID: deckID)
        return true
    }

    @discardableResult
    func saveMatchingRecordIfBest(
        scope: MatchingRecordScope,
        duration: TimeInterval,
        pairCount: Int
    ) throws -> Bool {
        switch scope {
        case .none:
            return false
        case .deck(let deckID):
            return try saveMatchingRecordIfBest(
                deckID: deckID,
                duration: duration,
                pairCount: pairCount
            )
        case .today(let dayKey):
            return todayMatchingRecordStore.saveIfBest(
                userID: userID,
                dayKey: dayKey,
                duration: duration,
                pairCount: pairCount
            )
        }
    }

    func notifyLocalDataDidChange(deckID: UUID) {
        NotificationCenter.default.post(
            name: Self.localDataDidChangeNotification,
            object: self,
            userInfo: [Self.changedDeckIDUserInfoKey: deckID]
        )
    }

    private func todaySnapshots() throws -> [TodayStudyDeckSnapshot] {
        try allDecks().filter(\.isActive).map { deck in
            try todaySnapshot(deck: deck)
        }
    }

    private func todaySnapshot(deck: DeckContent) throws -> TodayStudyDeckSnapshot {
        try TodayStudyDeckSnapshot(
            deck: deck,
            progressByCardID: database.progressMap(deckID: deck.id),
            dailyUsage: database.dailyUsage(deckID: deck.id, dayKey: DeckDailyUsage.todayKey()),
            reviewedCardIDs: database.reviewedCardIDs(deckID: deck.id, source: .todayQueue)
        )
    }

    private func uniqueCards(_ cards: [WordCardContent]) -> [WordCardContent] {
        var seen: Set<UUID> = []
        return cards.filter { card in
            seen.insert(card.id).inserted
        }
    }
}

extension StudySession {
    func advanceAfterReview(
        outcome: ReviewOutcome,
        store: DeckStore
    ) throws {
        let shouldNotify = savesProgress
        let progressDeckID = current?.deckID ?? deckID
        try advanceAfterReview(outcome: outcome) { progress, wasNew in
            try store.saveProgress(deckID: progressDeckID, progress: progress, wasNew: wasNew)
        } onReview: { event in
            try store.saveStudyReview(event)
        }
        guard shouldNotify else { return }
        store.notifyLocalDataDidChange(deckID: progressDeckID)
    }
}
