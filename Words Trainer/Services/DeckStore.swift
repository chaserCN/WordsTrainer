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
    let todayPracticeCountByDeckID: [UUID: Int]
    let todayStudyCards: [WordCardContent]
    let todayStudyCardsByDeckID: [UUID: [WordCardContent]]
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

nonisolated struct DeckDetailSnapshot: Sendable {
    let stats: DeckStats
    let matchingRecord: DeckMatchingRecord?
    let weakCardIDs: Set<UUID>
}

@MainActor
@Observable
final class DeckStore {
    static let localDataDidChangeNotification = Notification.Name("DeckStore.localDataDidChange")
    static let changedDeckIDUserInfoKey = "deckID"

    private let userID: UUID
    private let database: ContentDatabase
    private let engine = StudySessionEngine()
    var currentUserID: UUID { userID }

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

    /// Lightweight decks (card/sense rows only, no examples/questions/media)
    /// loaded off the main actor. Enough to render the deck list and its card
    /// counts immediately; full content is loaded separately on demand.
    nonisolated static func allDecksLiteSnapshot(userID: UUID) async throws -> [DeckContent] {
        try await Task.detached(priority: .userInitiated) {
            let database = try ContentDatabase(userID: userID, mode: .readOnly)
            return try database.readTransaction {
                try database.loadDecksLite()
            }
        }.value
    }

    /// Full decks (with card content) loaded off the main actor — for the deck
    /// list's word search index and for opening a deck's details/study.
    nonisolated static func allDecksSnapshot(userID: UUID) async throws -> [DeckContent] {
        try await Task.detached(priority: .userInitiated) {
            let database = try ContentDatabase(userID: userID, mode: .readOnly)
            return try database.readTransaction {
                try database.loadDecks()
            }
        }.value
    }

    /// Full card content for a single deck, loaded off the main actor.
    nonisolated static func deckCardsSnapshot(userID: UUID, deckID: UUID) async throws -> [WordCardContent] {
        try await Task.detached(priority: .userInitiated) {
            let database = try ContentDatabase(userID: userID, mode: .readOnly)
            return try database.readTransaction {
                try database.loadDecks().first(where: { $0.id == deckID })?.cards ?? []
            }
        }.value
    }

    /// Full study-card list for today (all decks), loaded off the main actor.
    /// Used by the study-modes word-list, which needs complete cards (examples,
    /// questions) — the dashboard snapshot intentionally omits these.
    nonisolated static func todayStudyCardsSnapshot(userID: UUID) async throws -> [WordCardContent] {
        try await Task.detached(priority: .userInitiated) {
            let database = try ContentDatabase(userID: userID, mode: .readOnly)
            return try database.readTransaction {
                let decks = try database.loadDecks().filter(\.isActive)
                var queue: [WordCardContent] = []
                var practice: [WordCardContent] = []
                for deck in decks {
                    let snapshot = try todayStudyDeckSnapshot(database: database, deck: deck)
                    queue.append(contentsOf: todayQueueCards(snapshot: snapshot))
                    practice.append(contentsOf: todayPracticeCards(snapshot: snapshot))
                }
                return uniqueCards(queue.isEmpty ? practice : queue)
            }
        }.value
    }

    /// Full study-card list for today for a single deck, loaded off the main actor.
    nonisolated static func todayStudyCardsSnapshot(userID: UUID, deckID: UUID) async throws -> [WordCardContent] {
        try await Task.detached(priority: .userInitiated) {
            let database = try ContentDatabase(userID: userID, mode: .readOnly)
            return try database.readTransaction {
                guard let deck = try database.loadDecks().first(where: { $0.id == deckID && $0.isActive }) else { return [] }
                let snapshot = try todayStudyDeckSnapshot(database: database, deck: deck)
                let queue = todayQueueCards(snapshot: snapshot)
                return uniqueCards(queue.isEmpty ? todayPracticeCards(snapshot: snapshot) : queue)
            }
        }.value
    }

    nonisolated static func statisticsSnapshot(userID: UUID) async throws -> DeckStatisticsSnapshot {
        try await Task.detached(priority: .userInitiated) {
            try loadStatisticsSnapshot(userID: userID)
        }.value
    }

    nonisolated static func deckDetailSnapshot(userID: UUID, deck: DeckContent) async throws -> DeckDetailSnapshot {
        try await Task.detached(priority: .userInitiated) {
            try loadDeckDetailSnapshot(userID: userID, deck: deck)
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
            guard let sense = card.activeSenses.first(where: { $0.id == weakCard.senseID }) else { return nil }
            return StudyQueueItem(
                card: card,
                sense: sense,
                progress: progressByDeckID[weakCard.deckID]?[weakCard.senseID]
                    ?? CardProgress.newSense(senseID: weakCard.senseID),
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
            return uniqueCards(unfocusedCards(for: session.queue, in: try allDecks()))
        }
        if let session = try startTodayPracticeSession(mode: .flashcards) {
            return uniqueCards(unfocusedCards(for: session.queue, in: try allDecks()))
        }
        return []
    }

    func todayStudyCards(deck: DeckContent) throws -> [WordCardContent] {
        let todaySession = try startTodaySession(deck: deck, mode: .flashcards)
        if !todaySession.queue.isEmpty {
            return uniqueCards(unfocusedCards(for: todaySession.queue, in: [deck]))
        }
        if let practiceSession = try startTodayPracticeSession(deck: deck, mode: .flashcards) {
            return uniqueCards(unfocusedCards(for: practiceSession.queue, in: [deck]))
        }
        return []
    }

    func todayPracticeCardCount() throws -> Int {
        try TodayStudySessionBuilder.todayPracticeCardCount(snapshots: todaySnapshots())
    }

    func todayPracticeCardCount(deck: DeckContent) throws -> Int {
        try TodayStudySessionBuilder.todayPracticeCardCount(snapshot: todaySnapshot(deck: deck))
    }

    func randomStudyCards() throws -> [WordCardContent] {
        try RandomStudySessionBuilder.randomCards(
            snapshots: todaySnapshots(),
            limit: database.randomCardCount()
        )
    }

    func randomStudyCards(deckIDs: Set<UUID>) throws -> [WordCardContent] {
        try RandomStudySessionBuilder.randomCards(
            snapshots: todaySnapshots(deckIDs: deckIDs),
            limit: database.randomCardCount()
        )
    }

    func stats(for deck: DeckContent) throws -> DeckStats {
        let progress = try database.progressMap(deckID: deck.id)
        let usage = try database.dailyUsage(deckID: deck.id, dayKey: DeckDailyUsage.todayKey())
        return DeckStatsCalculator.compute(
            deck: deck,
            progressBySenseID: progress,
            dailyUsage: usage
        )
    }

    func startSession(deck: DeckContent, mode: StudyMode) throws -> StudySession {
        let studyCards = deck.isActive ? deck.activeCards : []
        let progress = try database.progressMap(deckID: deck.id)
        let usage = try database.dailyUsage(deckID: deck.id, dayKey: DeckDailyUsage.todayKey())
        let queue: [StudyQueueItem]
        if mode.isMatching || mode == .recall {
            let items = StudyQueueBuilder.allItems(cards: studyCards, progressBySenseID: progress)
            queue = mode == .recall ? items.shuffled() : items
        } else {
            var built = StudyQueueBuilder.build(
                deck: deck,
                progressBySenseID: progress,
                dailyUsage: usage
            )
            if built.isEmpty {
                built = StudyQueueBuilder.allItems(cards: studyCards, progressBySenseID: progress).shuffled()
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
            progressBySenseID: progress,
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
        let items = StudyQueueBuilder.allItems(cards: studyCards, progressBySenseID: progress)
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

    func startRandomCardsSession(mode: StudyMode) throws -> StudySession? {
        try RandomStudySessionBuilder.randomSession(
            snapshots: todaySnapshots(),
            mode: mode,
            engine: engine,
            limit: database.randomCardCount()
        )
    }

    func startRandomCardsSession(cards: [WordCardContent], mode: StudyMode) throws -> StudySession? {
        try RandomStudySessionBuilder.session(
            snapshots: todaySnapshots(),
            cards: cards,
            mode: mode,
            engine: engine
        )
    }

    func startRandomCardsSession(cards: [WordCardContent], deckIDs: Set<UUID>, mode: StudyMode) throws -> StudySession? {
        try RandomStudySessionBuilder.session(
            snapshots: todaySnapshots(deckIDs: deckIDs),
            cards: cards,
            mode: mode,
            engine: engine
        )
    }

    func startWeakCardsSession(deck: DeckContent, mode: StudyMode) throws -> StudySession? {
        let weakStats = try weakCards(deckID: deck.id, limit: deck.activeCards.count)
        let weakCardIDs = Set(weakStats.map(\.cardID))
        let studyCards = deck.isActive ? deck.activeCards.filter { weakCardIDs.contains($0.id) } : []
        guard !studyCards.isEmpty else { return nil }

        let progress = try database.progressMap(deckID: deck.id)
        let usage = try database.dailyUsage(deckID: deck.id, dayKey: DeckDailyUsage.todayKey())
        let items = StudyQueueBuilder.allItems(cards: studyCards, progressBySenseID: progress)
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
        cardID: UUID?,
        progress: CardProgress,
        wasNew: Bool
    ) throws {
        try database.saveProgress(deckID: deckID, progress: progress)

        if wasNew {
            guard let cardID else { return }
            let key = DeckDailyUsage.todayKey()
            guard try !database.hasPassedNewStudyReview(deckID: deckID, cardID: cardID, dayKey: key) else {
                return
            }
            let usage = try database.dailyUsage(deckID: deckID, dayKey: key)
                ?? DeckDailyUsage(dayKey: key)
            let updated = engine.recordNewCardStudied(previous: usage)
            try database.saveDailyUsage(deckID: deckID, usage: updated)
        }
    }

    func progress(deckID: UUID, senseID: UUID) throws -> CardProgress? {
        try database.progressMap(deckID: deckID)[senseID]
    }

    func deckID(forCardID cardID: UUID) throws -> UUID? {
        try database.deckID(forCardID: cardID)
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

    private func todaySnapshots(deckIDs: Set<UUID>) throws -> [TodayStudyDeckSnapshot] {
        guard !deckIDs.isEmpty else { return [] }
        return try allDecks()
            .filter { $0.isActive && deckIDs.contains($0.id) }
            .map { deck in
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

    private func unfocusedCards(for queue: [StudyQueueItem], in decks: [DeckContent]) -> [WordCardContent] {
        var cardByID: [UUID: WordCardContent] = [:]
        for card in decks.flatMap(\.activeCards) {
            cardByID[card.id] = card
        }
        return queue.compactMap { item in cardByID[item.cardID] }
    }

    nonisolated private static func loadTodayDashboardSnapshot(userID: UUID) throws -> DeckTodaySnapshot {
        let database = try ContentDatabase(userID: userID, mode: .readOnly)
        return try database.readTransaction {
            try loadTodayDashboardSnapshot(database: database)
        }
    }

    /// Dashboard snapshot: counts and stats only, using the lightweight deck
    /// load (no examples/questions/forms/distractors/media). The full study-card
    /// lists (todayStudyCards*) are intentionally empty here — they are loaded
    /// on demand by the study-modes views via `todayStudyCards()`/
    /// `todayStudyCards(deck:)`, which use the full content path.
    nonisolated private static func loadTodayDashboardSnapshot(database: ContentDatabase) throws -> DeckTodaySnapshot {
        let decks = try database.loadDecksLite()
        let activeDecks = decks.filter(\.isActive)
        var statsByDeckID: [UUID: DeckStats] = [:]
        var todayPracticeCountByDeckID: [UUID: Int] = [:]
        var todayPracticeCount = 0

        for deck in activeDecks {
            let snapshot = try todayStudyDeckSnapshot(database: database, deck: deck)
            let deckPracticeCount = todayPracticeCards(snapshot: snapshot).count
            todayPracticeCountByDeckID[deck.id] = deckPracticeCount
            statsByDeckID[deck.id] = DeckStatsCalculator.compute(
                deck: deck,
                progressBySenseID: snapshot.progressBySenseID,
                dailyUsage: snapshot.dailyUsage
            )
            todayPracticeCount += deckPracticeCount
        }
        let activity = try studyActivity(database: database, days: 90)

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

    nonisolated private static func loadStatisticsSnapshot(userID: UUID) throws -> DeckStatisticsSnapshot {
        let database = try ContentDatabase(userID: userID, mode: .readOnly)
        return try database.readTransaction {
            try loadStatisticsSnapshot(database: database)
        }
    }

    nonisolated private static func loadStatisticsSnapshot(database: ContentDatabase) throws -> DeckStatisticsSnapshot {
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

    nonisolated private static func loadDeckDetailSnapshot(
        userID: UUID,
        deck: DeckContent
    ) throws -> DeckDetailSnapshot {
        let database = try ContentDatabase(userID: userID, mode: .readOnly)
        return try database.readTransaction {
            try loadDeckDetailSnapshot(database: database, deck: deck)
        }
    }

    nonisolated private static func loadDeckDetailSnapshot(
        database: ContentDatabase,
        deck: DeckContent
    ) throws -> DeckDetailSnapshot {
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
            progressBySenseID: database.progressMap(deckID: deck.id),
            dailyUsage: database.dailyUsage(deckID: deck.id, dayKey: DeckDailyUsage.todayKey()),
            reviewedSenseIDs: database.reviewedSenseIDs(deckID: deck.id, source: .todayQueue)
        )
    }

    nonisolated private static func todayPracticeCardCount(snapshot: TodayStudyDeckSnapshot) -> Int {
        guard snapshot.deck.isActive, !snapshot.reviewedSenseIDs.isEmpty else { return 0 }
        let activeSenseIDs = Set(snapshot.deck.activeCards.flatMap { $0.activeSenses.map(\.id) })
        return snapshot.reviewedSenseIDs.reduce(0) { count, senseID in
            activeSenseIDs.contains(senseID) ? count + 1 : count
        }
    }

    nonisolated private static func todayQueueCards(snapshot: TodayStudyDeckSnapshot) -> [WordCardContent] {
        let cardByID = Dictionary(uniqueKeysWithValues: snapshot.deck.activeCards.map { ($0.id, $0) })
        return StudyQueueBuilder.build(
            deck: snapshot.deck,
            progressBySenseID: snapshot.progressBySenseID,
            dailyUsage: snapshot.dailyUsage
        ).compactMap { item in cardByID[item.cardID] }
    }

    nonisolated private static func todayPracticeCards(snapshot: TodayStudyDeckSnapshot) -> [WordCardContent] {
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

    nonisolated private static func uniqueCards(_ cards: [WordCardContent]) -> [WordCardContent] {
        var seen: Set<UUID> = []
        return cards.filter { card in
            seen.insert(card.id).inserted
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
        additionalFailureSenseID: UUID? = nil,
        reviewsActiveCardSenses: Bool = false,
        store: DeckStore
    ) throws {
        let shouldNotify = savesProgress && !(mode == .recall && outcome == .remembered)
        let progressDeckID = current?.deckID ?? deckID
        let additionalFailureProgress: CardProgress?
        if let additionalFailureSenseID {
            additionalFailureProgress = try store.progress(deckID: progressDeckID, senseID: additionalFailureSenseID)
                ?? CardProgress.newSense(senseID: additionalFailureSenseID)
        } else {
            additionalFailureProgress = nil
        }
        try advanceAfterReview(
            outcome: outcome,
            additionalFailureProgress: additionalFailureProgress,
            reviewsActiveCardSenses: reviewsActiveCardSenses
        ) { item, progress, wasNew in
            try store.saveProgress(deckID: progressDeckID, cardID: item.cardID, progress: progress, wasNew: wasNew)
        } onAdditionalFailureSave: { progress in
            try store.saveProgress(deckID: progressDeckID, cardID: nil, progress: progress, wasNew: false)
        } onReview: { event in
            try store.saveStudyReview(event)
        } onPracticeReview: { event in
            try store.savePracticeReview(event)
        }
        guard shouldNotify else { return }
        store.notifyLocalDataDidChange(deckID: progressDeckID)
    }
}
