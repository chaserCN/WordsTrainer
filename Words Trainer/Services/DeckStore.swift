import Foundation
import FSRS

enum DeckStoreError: LocalizedError {
    case missingSelectedUser

    var errorDescription: String? {
        switch self {
        case .missingSelectedUser:
            L10n.text("Пользователь ещё не загружен с сервера.")
        }
    }
}

nonisolated enum WeakCardsPractice {
    /// Синтетический id для игры «Забытые слова» — у неё нет реальной колоды.
    static let deckID = UUID(uuidString: "00000000-0000-0000-0000-0000DEADBEEF")!
    static let fetchLimit = 30
    static let displayLimit = 10
    static let gamePairLimit = 12
}

nonisolated struct DeckTodaySnapshot: Sendable {
    let decks: [DeckContent]
    let statsByDeckID: [UUID: DeckStats]
    let todayPracticeCount: Int
    let activityDays: [StudyActivityDay]
}

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

@MainActor
@Observable
final class DeckStore {
    static let localDataDidChangeNotification = Notification.Name("DeckStore.localDataDidChange")
    static let changedDeckIDUserInfoKey = "deckID"

    private let userID: UUID
    private let database: ContentDatabase
    private let engine = StudySessionEngine()

    init(database: ContentDatabase) {
        self.userID = database.currentUserID
        self.database = database
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

    nonisolated static func todayDashboardSnapshot(userID: UUID) async throws -> DeckTodaySnapshot {
        try await Task.detached(priority: .userInitiated) {
            try loadTodayDashboardSnapshot(userID: userID)
        }.value
    }

    nonisolated static func statisticsSnapshot(userID: UUID) async throws -> DeckStatisticsSnapshot {
        try await Task.detached(priority: .userInitiated) {
            try loadStatisticsSnapshot(userID: userID)
        }.value
    }

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

    func uniqueStudyCardCount(since startDate: Date) throws -> Int {
        try database.uniqueStudyCardCount(since: startDate)
    }

    func matchingAttemptCount(since startDate: Date) throws -> Int {
        try database.matchingAttemptCount(since: startDate)
    }

    func studyTimeBreakdown(since startDate: Date) throws -> StudyTimeBreakdown {
        try database.studyTimeBreakdown(since: startDate)
    }

    func weakCards(limit: Int = 30) throws -> [WeakCardStat] {
        try database.weakCards(limit: limit)
    }

    func weakCards(deckID: UUID, limit: Int = 30) throws -> [WeakCardStat] {
        try database.weakCards(limit: limit, deckID: deckID)
    }

    /// Игра «Колонки» из самых забываемых слов всех активных колод.
    /// Review events не пишем (`savesProgress: false`), но ошибки в matching всё равно обновляют FSRS.
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
        var progressByDeckID: [UUID: [UUID: CardProgress]] = [:]
        let queue = try weak.compactMap { weakCard -> StudyQueueItem? in
            guard let card = cardByID[weakCard.cardID] else { return nil }
            if progressByDeckID[weakCard.deckID] == nil {
                progressByDeckID[weakCard.deckID] = try database.progressMap(deckID: weakCard.deckID)
            }
            return StudyQueueItem(
                card: card,
                progress: progressByDeckID[weakCard.deckID]?[weakCard.cardID]
                    ?? CardProgress.newCard(cardID: weakCard.cardID),
                deckID: weakCard.deckID
            )
        }
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

    func scheduledReviewDays(days: Int) throws -> [ScheduledReviewDay] {
        let activeDecks = try allDecks().filter(\.isActive)
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
            matchingRecordScope: mode.isMatching ? MatchingRecordScope.none : nil,
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
            matchingRecordScope: mode.isMatching ? MatchingRecordScope.none : .deck(deck.id),
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

    func savePracticeReview(_ event: PracticeReviewEvent) throws {
        try database.savePracticeReview(event)
    }

    func saveMatchingAttempt(_ event: MatchingAttemptEvent) throws {
        try database.saveMatchingAttempt(event)
        notifyLocalDataDidChange(deckID: event.deckID ?? WeakCardsPractice.deckID)
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
        try Self.todayStudyDeckSnapshot(database: database, deck: deck)
    }

    private func uniqueCards(_ cards: [WordCardContent]) -> [WordCardContent] {
        var seen: Set<UUID> = []
        return cards.filter { card in
            seen.insert(card.id).inserted
        }
    }

    nonisolated private static func loadTodayDashboardSnapshot(userID: UUID) throws -> DeckTodaySnapshot {
        let database = try ContentDatabase(userID: userID)
        let decks = try database.loadDecks()
        let activeDecks = decks.filter(\.isActive)
        var statsByDeckID: [UUID: DeckStats] = [:]
        var todayPracticeCount = 0

        for deck in activeDecks {
            let snapshot = try todayStudyDeckSnapshot(database: database, deck: deck)
            statsByDeckID[deck.id] = DeckStatsCalculator.compute(
                deck: deck,
                progressByCardID: snapshot.progressByCardID,
                dailyUsage: snapshot.dailyUsage
            )
            todayPracticeCount += todayPracticeCardCount(snapshot: snapshot)
        }

        return DeckTodaySnapshot(
            decks: decks,
            statsByDeckID: statsByDeckID,
            todayPracticeCount: todayPracticeCount,
            activityDays: try studyActivity(database: database, days: 90)
        )
    }

    nonisolated private static func loadStatisticsSnapshot(userID: UUID) throws -> DeckStatisticsSnapshot {
        let database = try ContentDatabase(userID: userID)
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

    nonisolated private static func studyActivity(
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

    nonisolated private static func todayStudyDeckSnapshot(
        database: ContentDatabase,
        deck: DeckContent
    ) throws -> TodayStudyDeckSnapshot {
        try TodayStudyDeckSnapshot(
            deck: deck,
            progressByCardID: database.progressMap(deckID: deck.id),
            dailyUsage: database.dailyUsage(deckID: deck.id, dayKey: DeckDailyUsage.todayKey()),
            reviewedCardIDs: database.reviewedCardIDs(deckID: deck.id, source: .todayQueue)
        )
    }

    nonisolated private static func todayPracticeCardCount(snapshot: TodayStudyDeckSnapshot) -> Int {
        guard snapshot.deck.isActive, !snapshot.reviewedCardIDs.isEmpty else { return 0 }
        let activeCardIDs = Set(snapshot.deck.activeCards.map(\.id))
        return snapshot.reviewedCardIDs.reduce(0) { count, cardID in
            activeCardIDs.contains(cardID) ? count + 1 : count
        }
    }

    nonisolated private static func scheduledReviewDays(
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

extension StudySession {
    func advanceAfterReview(
        outcome: ReviewOutcome,
        store: DeckStore
    ) throws {
        let shouldNotify = savesProgress && !(mode == .recall && outcome == .remembered)
        let progressDeckID = current?.deckID ?? deckID
        try advanceAfterReview(outcome: outcome) { progress, wasNew in
            try store.saveProgress(deckID: progressDeckID, progress: progress, wasNew: wasNew)
        } onReview: { event in
            try store.saveStudyReview(event)
        } onPracticeReview: { event in
            try store.savePracticeReview(event)
        }
        guard shouldNotify else { return }
        store.notifyLocalDataDidChange(deckID: progressDeckID)
    }
}
