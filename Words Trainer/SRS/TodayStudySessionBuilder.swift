import Foundation

nonisolated struct TodayStudyDeckSnapshot: Sendable {
    let deck: DeckContent
    let progressBySenseID: [UUID: CardProgress]
    let dailyUsage: DeckDailyUsage?
    let reviewedSenseIDs: [UUID]

    init(
        deck: DeckContent,
        progressBySenseID: [UUID: CardProgress],
        dailyUsage: DeckDailyUsage?,
        reviewedSenseIDs: [UUID] = []
    ) {
        self.deck = deck
        self.progressBySenseID = progressBySenseID
        self.dailyUsage = dailyUsage
        self.reviewedSenseIDs = reviewedSenseIDs
    }
}

enum TodayStudySessionBuilder {
    static let deckID = UUID(uuidString: "00000000-0000-0000-0000-0000DA17DA7A")!
    static var title: String { L10n.text("Сегодня") }
    static var practiceTitle: String { L10n.text("Практика сегодня") }

    @MainActor
    static func todaySession(
        snapshots: [TodayStudyDeckSnapshot],
        mode: StudyMode,
        dayKey: String,
        engine: StudySessionEngine
    ) -> StudySession? {
        var rng = SystemRandomNumberGenerator()
        return todaySession(
            snapshots: snapshots,
            mode: mode,
            dayKey: dayKey,
            engine: engine,
            using: &rng
        )
    }

    @MainActor
    static func todaySession<RNG: RandomNumberGenerator>(
        snapshots: [TodayStudyDeckSnapshot],
        mode: StudyMode,
        dayKey: String,
        engine: StudySessionEngine,
        using rng: inout RNG
    ) -> StudySession? {
        var queue: [StudyQueueItem] = []
        var choicePool: [WordCardContent] = []

        for snapshot in snapshots where snapshot.deck.isActive {
            let deckQueue = StudyQueueBuilder.build(
                deck: snapshot.deck,
                progressBySenseID: snapshot.progressBySenseID,
                dailyUsage: snapshot.dailyUsage,
                using: &rng
            ).map { $0.withDeckID(snapshot.deck.id) }
            queue.append(contentsOf: deckQueue)
            choicePool.append(contentsOf: snapshot.deck.activeCards)
        }

        guard !queue.isEmpty else { return nil }
        queue.shuffle(using: &rng)
        // Picture-choice is a recognition warm-up: only senses with an image, and
        // it must not write FSRS / consume the day's new-card budget.
        if mode == .pictureChoice {
            queue = queue.filter { $0.sense.imageURL != nil }
            guard !queue.isEmpty else { return nil }
        }
        return StudySession(
            deckID: deckID,
            mode: mode,
            queue: queue,
            deckCards: choicePool,
            dailyUsage: nil,
            engine: engine,
            matchingRecordScope: matchingRecordScope(for: mode, dayKey: dayKey),
            reviewSource: .todayQueue,
            savesProgress: mode != .pictureChoice
        )
    }

    static func todayPracticeCardCount(snapshots: [TodayStudyDeckSnapshot]) -> Int {
        snapshots.reduce(0) { count, snapshot in
            count + todayPracticeItems(snapshot: snapshot).count
        }
    }

    static func todayPracticeCardCount(snapshot: TodayStudyDeckSnapshot) -> Int {
        todayPracticeItems(snapshot: snapshot).count
    }

    @MainActor
    static func todayPracticeSession(
        snapshots: [TodayStudyDeckSnapshot],
        mode: StudyMode,
        dayKey: String,
        engine: StudySessionEngine
    ) -> StudySession? {
        var queue: [StudyQueueItem] = []
        var choicePool: [WordCardContent] = []

        for snapshot in snapshots where snapshot.deck.isActive {
            choicePool.append(contentsOf: snapshot.deck.activeCards)
            queue.append(contentsOf: todayPracticeItems(snapshot: snapshot))
        }

        guard !queue.isEmpty else { return nil }
        return StudySession(
            deckID: deckID,
            mode: mode,
            queue: practiceQueue(queue, for: mode),
            deckCards: choicePool,
            dailyUsage: nil,
            engine: engine,
            matchingRecordScope: matchingRecordScope(for: mode, dayKey: dayKey),
            reviewSource: .todayPractice,
            savesProgress: false
        )
    }

    @MainActor
    static func todayPracticeSession(
        snapshot: TodayStudyDeckSnapshot,
        mode: StudyMode,
        engine: StudySessionEngine
    ) -> StudySession? {
        let queue = todayPracticeItems(snapshot: snapshot)
        guard !queue.isEmpty else { return nil }
        let studyCards = snapshot.deck.isActive ? snapshot.deck.activeCards : []
        return StudySession(
            deckID: snapshot.deck.id,
            mode: mode,
            queue: practiceQueue(queue, for: mode),
            deckCards: studyCards,
            dailyUsage: nil,
            engine: engine,
            matchingRecordScope: matchingRecordScope(for: mode, deckID: snapshot.deck.id),
            reviewSource: .todayPractice,
            savesProgress: false
        )
    }

    private static func todayPracticeItems(snapshot: TodayStudyDeckSnapshot) -> [StudyQueueItem] {
        guard snapshot.deck.isActive, !snapshot.reviewedSenseIDs.isEmpty else { return [] }
        let reviewedIDSet = Set(snapshot.reviewedSenseIDs)
        var itemBySenseID: [UUID: StudyQueueItem] = [:]
        for card in snapshot.deck.activeCards {
            for sense in card.activeSenses where reviewedIDSet.contains(sense.id) {
                itemBySenseID[sense.id] = StudyQueueItem(
                    card: card,
                    sense: sense,
                    progress: snapshot.progressBySenseID[sense.id] ?? CardProgress.newSense(senseID: sense.id),
                    deckID: snapshot.deck.id
                )
            }
        }
        return snapshot.reviewedSenseIDs.compactMap { itemBySenseID[$0] }
    }

    private static func practiceQueue(_ items: [StudyQueueItem], for mode: StudyMode) -> [StudyQueueItem] {
        // Picture-choice only ever asks senses that have an image, even in the
        // practice fallback (queue already drained for the day). Without this the
        // fallback showed imageless / wrong-deck senses with blank pictures.
        if mode == .pictureChoice {
            return items.filter { $0.sense.imageURL != nil }.shuffled()
        }
        if mode.isMatching || mode == .recall || mode == .clozeMultipleChoice {
            return items.shuffled()
        }
        return items
    }

    private static func matchingRecordScope(for _: StudyMode, dayKey _: String) -> MatchingRecordScope {
        .none
    }

    private static func matchingRecordScope(for _: StudyMode, deckID _: UUID) -> MatchingRecordScope {
        .none
    }
}

enum RandomStudySessionBuilder {
    static let deckID = UUID(uuidString: "00000000-0000-0000-0000-0000A11CA7E5")!
    nonisolated static let defaultLimit = UserStudySettingsDefaults.randomCardCount
    static var title: String { L10n.text("Случайные") }

    @MainActor
    static func randomSession(
        snapshots: [TodayStudyDeckSnapshot],
        mode: StudyMode,
        engine: StudySessionEngine,
        limit: Int = defaultLimit
    ) -> StudySession? {
        var rng = SystemRandomNumberGenerator()
        return randomSession(
            snapshots: snapshots,
            mode: mode,
            engine: engine,
            limit: limit,
            using: &rng
        )
    }

    @MainActor
    static func randomSession<RNG: RandomNumberGenerator>(
        snapshots: [TodayStudyDeckSnapshot],
        mode: StudyMode,
        engine: StudySessionEngine,
        limit: Int = defaultLimit,
        using rng: inout RNG
    ) -> StudySession? {
        let cards = randomCards(snapshots: snapshots, limit: limit, using: &rng)
        return session(
            snapshots: snapshots,
            cards: cards,
            mode: mode,
            engine: engine
        )
    }

    @MainActor
    static func session(
        snapshots: [TodayStudyDeckSnapshot],
        cards: [WordCardContent],
        mode: StudyMode,
        engine: StudySessionEngine
    ) -> StudySession? {
        let activeSnapshots = snapshots.filter { $0.deck.isActive }
        let requestedCardIDs = Set(cards.map(\.id))
        var itemBySenseID: [UUID: StudyQueueItem] = [:]
        var queue: [StudyQueueItem] = []
        var choicePool: [WordCardContent] = []

        for snapshot in activeSnapshots {
            choicePool.append(contentsOf: snapshot.deck.activeCards)
            for card in snapshot.deck.activeCards where requestedCardIDs.contains(card.id) {
                for sense in card.activeSenses {
                    itemBySenseID[sense.id] = StudyQueueItem(
                        card: card,
                        sense: sense,
                        progress: snapshot.progressBySenseID[sense.id] ?? CardProgress.newSense(senseID: sense.id),
                        deckID: snapshot.deck.id
                    )
                }
            }
        }

        queue = cards.flatMap { card in card.activeSenses.compactMap { itemBySenseID[$0.id] } }
        // Picture-choice keeps only senses with an image and never writes FSRS /
        // daily-usage progress (it's a recognition warm-up). Without this the
        // picture session from «Сегодня» reviewed imageless senses and consumed
        // the day's new-card budget, emptying the queue for the other modes.
        if mode == .pictureChoice {
            queue = queue.filter { $0.sense.imageURL != nil }.shuffled()
        }
        guard !queue.isEmpty else { return nil }

        return StudySession(
            deckID: deckID,
            mode: mode,
            queue: queue,
            deckCards: choicePool,
            dailyUsage: nil,
            engine: engine,
            matchingRecordScope: MatchingRecordScope.none,
            reviewSource: .deckSession,
            savesProgress: mode != .pictureChoice
        )
    }

    static func randomCards(
        snapshots: [TodayStudyDeckSnapshot],
        limit: Int = defaultLimit
    ) -> [WordCardContent] {
        var rng = SystemRandomNumberGenerator()
        return randomCards(snapshots: snapshots, limit: limit, using: &rng)
    }

    static func randomCards<RNG: RandomNumberGenerator>(
        snapshots: [TodayStudyDeckSnapshot],
        limit: Int = defaultLimit,
        using rng: inout RNG
    ) -> [WordCardContent] {
        guard limit > 0 else { return [] }
        var cards = snapshots
            .filter { $0.deck.isActive }
            .flatMap { $0.deck.activeCards }
        cards.shuffle(using: &rng)
        return Array(cards.prefix(limit))
    }
}
