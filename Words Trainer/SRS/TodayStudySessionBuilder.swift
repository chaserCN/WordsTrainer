import Foundation

nonisolated struct TodayStudyDeckSnapshot: Sendable {
    let deck: DeckContent
    let progressByCardID: [UUID: CardProgress]
    let dailyUsage: DeckDailyUsage?
    let reviewedCardIDs: [UUID]

    init(
        deck: DeckContent,
        progressByCardID: [UUID: CardProgress],
        dailyUsage: DeckDailyUsage?,
        reviewedCardIDs: [UUID] = []
    ) {
        self.deck = deck
        self.progressByCardID = progressByCardID
        self.dailyUsage = dailyUsage
        self.reviewedCardIDs = reviewedCardIDs
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
                progressByCardID: snapshot.progressByCardID,
                dailyUsage: snapshot.dailyUsage,
                using: &rng
            ).map { $0.withDeckID(snapshot.deck.id) }
            queue.append(contentsOf: deckQueue)
            choicePool.append(contentsOf: snapshot.deck.activeCards)
        }

        guard !queue.isEmpty else { return nil }
        queue.shuffle(using: &rng)
        return StudySession(
            deckID: deckID,
            mode: mode,
            queue: queue,
            deckCards: choicePool,
            dailyUsage: nil,
            engine: engine,
            matchingRecordScope: matchingRecordScope(for: mode, dayKey: dayKey),
            reviewSource: .todayQueue
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
        guard snapshot.deck.isActive, !snapshot.reviewedCardIDs.isEmpty else { return [] }
        let reviewedIDSet = Set(snapshot.reviewedCardIDs)
        var itemByCardID: [UUID: StudyQueueItem] = [:]
        for card in snapshot.deck.activeCards where reviewedIDSet.contains(card.id) {
            itemByCardID[card.id] = StudyQueueItem(
                card: card,
                progress: snapshot.progressByCardID[card.id] ?? CardProgress.newCard(cardID: card.id),
                deckID: snapshot.deck.id
            )
        }
        return snapshot.reviewedCardIDs.compactMap { itemByCardID[$0] }
    }

    private static func practiceQueue(_ items: [StudyQueueItem], for mode: StudyMode) -> [StudyQueueItem] {
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
