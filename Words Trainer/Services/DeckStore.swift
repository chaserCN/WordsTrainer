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

@MainActor
@Observable
final class DeckStore {
    static let localDataDidChangeNotification = Notification.Name("DeckStore.localDataDidChange")
    static let changedDeckIDUserInfoKey = "deckID"

    private let userID: UUID
    private let database: ContentDatabase
    private let todayDataLoader: TodaySessionDataLoader
    private let engine = StudySessionEngine()
    var currentUserID: UUID { userID }

    init(database: ContentDatabase) {
        self.userID = database.currentUserID
        self.database = database
        self.todayDataLoader = TodaySessionDataLoader(userID: database.currentUserID, database: database)
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
        let started = Date()
        let snapshot = try await Task.detached(priority: .userInitiated) {
            try TodayReadOnlySnapshotBuilder.dashboardSnapshot(userID: userID)
        }.value
        Log.log("Stats", "dashboard counters recomputed for \(snapshot.statsByDeckID.count) decks (lightweight: progress + counts only, no card content) in \(Int(Date().timeIntervalSince(started) * 1000))ms")
        return snapshot
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

    nonisolated static func statisticsSnapshot(userID: UUID) async throws -> DeckStatisticsSnapshot {
        try await Task.detached(priority: .userInitiated) {
            try DeckStatisticsSnapshotBuilder.snapshot(userID: userID)
        }.value
    }

    nonisolated static func deckDetailSnapshot(userID: UUID, deck: DeckContent) async throws -> DeckDetailSnapshot {
        try await Task.detached(priority: .userInitiated) {
            try DeckDetailSnapshotBuilder.snapshot(userID: userID, deck: deck)
        }.value
    }

    /// Today's word-list (all decks) built OFF the main thread.
    ///
    /// `cachedCards` is a snapshot of StudyCardCache taken on the MainActor by the
    /// caller; card content is taken from it (no DB), while deck shells and fresh
    /// progress are read from a read-only DB connection here. A deck missing from
    /// the snapshot (cold cache) is loaded fully from the DB. Keeps the ~80ms of
    /// queue-building + content assembly off the main thread to avoid frame hitches
    /// when the Today screen appears.
    nonisolated static func todayWordListSnapshot(
        userID: UUID,
        cachedCards: [UUID: [WordCardContent]]
    ) async throws -> [WordCardContent] {
        try await Task.detached(priority: .userInitiated) {
            try TodayReadOnlySnapshotBuilder.wordListSnapshot(userID: userID, cachedCards: cachedCards)
        }.value
    }

    /// Per-deck variant of todayWordListSnapshot, off the main thread.
    nonisolated static func todayWordListSnapshot(
        userID: UUID,
        deckID: UUID,
        cachedCards: [UUID: [WordCardContent]]
    ) async throws -> [WordCardContent] {
        try await Task.detached(priority: .userInitiated) {
            try TodayReadOnlySnapshotBuilder.wordListSnapshot(
                userID: userID,
                deckID: deckID,
                cachedCards: cachedCards
            )
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
        return StudySessionFactory.weakMatchingSession(queue: queue, engine: engine)
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
        // The queue is rebuilt from fresh progress here, so it reflects cards just
        // studied; only the card *content* for display is sourced from the cache.
        if let session = try startTodaySession(mode: .flashcards) {
            return uniqueCards(unfocusedCards(for: session.queue, in: try todayDataLoader.activeDecksWithFullCardsFavoringCache()))
        }
        if let session = try startTodayPracticeSession(mode: .flashcards) {
            return uniqueCards(unfocusedCards(for: session.queue, in: try todayDataLoader.activeDecksWithFullCardsFavoringCache()))
        }
        return []
    }

    func todayStudyCards(deck deckArg: DeckContent) throws -> [WordCardContent] {
        // Ensure the deck used for word-list mapping has full cards (cache/DB),
        // so the displayed cards carry audio; the queue is rebuilt from fresh
        // progress, reflecting cards just studied.
        let deck = try todayDataLoader.deckWithFullCards(deckArg)
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
        try TodayStudySessionBuilder.todayPracticeCardCount(
            snapshot: todayDataLoader.todaySnapshot(deck: deck)
        )
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

    /// Сессия только из карт, попавших в очередь на сегодня (вкладка «Сегодня»).
    func startTodaySession(deck deckArg: DeckContent, mode: StudyMode) throws -> StudySession {
        // "Сегодня" passes a lightweight dashboard deck; ensure full cards so
        // flashcards play their recording instead of TTS.
        let started = Date()
        let deck = try todayDataLoader.deckWithFullCards(deckArg)
        let progress = try database.progressMap(deckID: deck.id)
        let usage = try database.dailyUsage(deckID: deck.id, dayKey: DeckDailyUsage.todayKey())
        let studyCardCount = deck.isActive ? deck.activeCards.count : 0
        let session = StudySessionFactory.todayDeckSession(
            deck: deck,
            mode: mode,
            progressBySenseID: progress,
            dailyUsage: usage,
            engine: engine
        )
        Log.log("Perf", "Сегодня start \(mode): deck \(studyCardCount) cards → today queue \(session.queue.count) items, built in \(Int(Date().timeIntervalSince(started) * 1000))ms")
        return session
    }

    func startTodayPracticeSession(mode: StudyMode) throws -> StudySession? {
        try TodayStudySessionBuilder.todayPracticeSession(
            snapshots: todaySnapshots(),
            mode: mode,
            dayKey: DeckDailyUsage.todayKey(),
            engine: engine
        )
    }

    func startTodayPracticeSession(deck deckArg: DeckContent, mode: StudyMode) throws -> StudySession? {
        let deck = try todayDataLoader.deckWithFullCards(deckArg)
        return try TodayStudySessionBuilder.todayPracticeSession(
            snapshot: todayDataLoader.todaySnapshot(deck: deck),
            mode: mode,
            engine: engine
        )
    }

    /// Сессия из всех активных карт колоды независимо от расписания (вкладка «Колоды»).
    func startAllCardsSession(deck deckArg: DeckContent, mode: StudyMode) throws -> StudySession {
        let started = Date()
        let deck = try todayDataLoader.deckWithFullCards(deckArg)
        let progress = try database.progressMap(deckID: deck.id)
        let usage = try database.dailyUsage(deckID: deck.id, dayKey: DeckDailyUsage.todayKey())
        let studyCardCount = deck.isActive ? deck.activeCards.count : 0
        let session = StudySessionFactory.allCardsSession(
            deck: deck,
            mode: mode,
            progressBySenseID: progress,
            dailyUsage: usage,
            engine: engine
        )
        Log.log("Perf", "Колоди start \(mode): ALL \(studyCardCount) cards → queue \(session.queue.count) items, built in \(Int(Date().timeIntervalSince(started) * 1000))ms")
        return session
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

    func startWeakCardsSession(deck deckArg: DeckContent, mode: StudyMode) throws -> StudySession? {
        let deck = try todayDataLoader.deckWithFullCards(deckArg)
        let weakStats = try weakCards(deckID: deck.id, limit: deck.activeCards.count)
        let weakCardIDs = Set(weakStats.map(\.cardID))
        let studyCards = deck.isActive ? deck.activeCards.filter { weakCardIDs.contains($0.id) } : []
        guard !studyCards.isEmpty else { return nil }

        let progress = try database.progressMap(deckID: deck.id)
        let usage = try database.dailyUsage(deckID: deck.id, dayKey: DeckDailyUsage.todayKey())
        return StudySessionFactory.weakCardsSession(
            deck: deck,
            studyCards: studyCards,
            mode: mode,
            progressBySenseID: progress,
            dailyUsage: usage,
            engine: engine
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
        try todayDataLoader.todaySnapshots()
    }

    private func todaySnapshots(deckIDs: Set<UUID>) throws -> [TodayStudyDeckSnapshot] {
        try todayDataLoader.todaySnapshots(deckIDs: deckIDs)
    }

    private func uniqueCards(_ cards: [WordCardContent]) -> [WordCardContent] {
        TodaySnapshotBuilder.uniqueCards(cards)
    }

    private func unfocusedCards(for queue: [StudyQueueItem], in decks: [DeckContent]) -> [WordCardContent] {
        var cardByID: [UUID: WordCardContent] = [:]
        for card in decks.flatMap(\.activeCards) {
            cardByID[card.id] = card
        }
        return queue.compactMap { item in cardByID[item.cardID] }
    }

}

extension StudySession {
    func advanceAfterReview(
        outcome: ReviewOutcome,
        additionalFailureSenseID: UUID? = nil,
        reviewsActiveCardSenses: Bool = false,
        store: DeckStore
    ) throws {
        let shouldNotify = savesProgress && !mode.skipsProgressSave(outcome: outcome)
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
