import Foundation
import FSRS

@Observable
@MainActor
final class StudySession {
    private static let matchingStartDelay: TimeInterval = 1

    let deckID: UUID
    let mode: StudyMode
    let matchingRecordScope: MatchingRecordScope
    let reviewSource: StudyReviewSource
    /// Когда false — обычные review events не сохраняются.
    /// Matching-рекорд управляется отдельно через `matchingRecordScope`.
    let savesProgress: Bool
    let matchingTotalPairCount: Int
    private(set) var matchingStartedAt: Date?
    private let flashcardWholeCardTotalCount: Int
    private(set) var queue: [StudyQueueItem]
    /// Cards queued at session start — stable MCQ distractor pool for the whole session.
    let sessionChoicePool: [WordCardContent]
    /// Full deck — fills remaining distractor slots when the session pool is too small.
    let deckChoicePool: [WordCardContent]
    private var matchingScheduler: MatchingPairScheduler?
    private var dailyUsage: DeckDailyUsage?
    private var currentStartedAt: Date?
    private var pausedAt: Date?
    private let engine: StudySessionEngine

    var current: StudyQueueItem? { queue.first }
    var remainingCount: Int {
        if mode.isMatching {
            return matchingScheduler?.remainingCount ?? 0
        }
        return queue.count
    }
    var isFinished: Bool {
        if mode.isMatching {
            return matchingScheduler?.isFinished ?? true
        }
        return queue.isEmpty
    }
    var matchingVisibleItems: [MatchingPair] {
        matchingScheduler?.visible ?? []
    }

    func displayTotalCount(flashcardDisplayMode: FlashcardDisplayMode) -> Int {
        guard mode.usesWholeCardCounters(flashcardDisplayMode: flashcardDisplayMode) else {
            return sessionChoicePool.count
        }
        return flashcardWholeCardTotalCount
    }

    func displayRemainingCount(flashcardDisplayMode: FlashcardDisplayMode) -> Int {
        guard mode.usesWholeCardCounters(flashcardDisplayMode: flashcardDisplayMode) else {
            return remainingCount
        }
        return Self.uniqueCardGroupCount(in: queue)
    }

    var matchingElapsed: TimeInterval {
        guard let matchingStartedAt else { return 0 }
        return max(0, Date().timeIntervalSince(matchingStartedAt))
    }

    init(
        deckID: UUID,
        mode: StudyMode,
        queue: [StudyQueueItem],
        deckCards: [WordCardContent] = [],
        dailyUsage: DeckDailyUsage?,
        engine: StudySessionEngine,
        matchingRecordScope: MatchingRecordScope? = nil,
        reviewSource: StudyReviewSource = .deckSession,
        savesProgress: Bool = true
    ) {
        self.deckID = deckID
        self.mode = mode
        self.savesProgress = savesProgress
        self.matchingRecordScope = matchingRecordScope ?? (savesProgress && !mode.isAudioMatching ? .deck(deckID) : .none)
        self.reviewSource = reviewSource
        self.dailyUsage = dailyUsage
        self.engine = engine
        sessionChoicePool = queue.map(\.card)
        flashcardWholeCardTotalCount = Self.uniqueCardGroupCount(in: queue)
        deckChoicePool = Self.focusedActiveCards(deckCards)
        if mode.isMatching {
            let pairs = queue.flatMap { MatchingPair.pairs(from: $0) }
            matchingTotalPairCount = pairs.count
            matchingStartedAt = Date().addingTimeInterval(Self.matchingStartDelay)
            self.queue = []
            var rng = SystemRandomNumberGenerator()
            matchingScheduler = MatchingPairScheduler(pairs: pairs, rng: &rng)
        } else {
            matchingTotalPairCount = 0
            matchingStartedAt = nil
            self.queue = queue
            currentStartedAt = queue.isEmpty ? nil : Date()
        }
    }

    func outcome(for result: ReviewOutcome) -> ReviewOutcome {
        result
    }

    func removeMatchedPair(id: String) {
        guard mode.isMatching else { return }
        var rng = SystemRandomNumberGenerator()
        matchingScheduler?.removeMatched(id: id, rng: &rng)
    }

    func advanceAfterReview(
        outcome: ReviewOutcome,
        additionalFailureProgress: CardProgress? = nil,
        reviewsActiveCardSenses: Bool = false,
        onSave: (_ item: StudyQueueItem, _ progress: CardProgress, _ wasNew: Bool) throws -> Void,
        onAdditionalFailureSave: ((_ progress: CardProgress) throws -> Void)? = nil,
        onReview: ((_ event: StudyReviewEvent) throws -> Void)? = nil,
        onPracticeReview: ((_ event: PracticeReviewEvent) throws -> Void)? = nil
    ) throws {
        guard let item = current else { return }
        let reviewedItems = reviewsActiveCardSenses
            ? queue.filter { $0.cardID == item.cardID && $0.deckID == item.deckID }
            : [item]
        let reviewedAt = Date()
        let durationMS = reviewDurationMS(endedAt: reviewedAt)
        if mode.skipsProgressSave(outcome: outcome) {
            queue.removeFirst()
            startNextCurrentIfNeeded()
            return
        }

        var didRecordNewCardStudied = false
        for reviewedItem in reviewedItems {
            let wasNew = reviewedItem.progress.fsrsCard.state == .new
            let updated: CardProgress
            if mode.resetsProgress(outcome: outcome) {
                updated = CardProgress.newSense(senseID: reviewedItem.senseID, now: reviewedAt)
            } else {
                updated = try engine.applyReview(progress: reviewedItem.progress, outcome: outcome, now: reviewedAt)
            }
            if savesProgress {
                let eventDeckID = reviewedItem.deckID ?? deckID
                let recordsNewCardStudied = wasNew
                    && outcome.passed
                    && (!reviewsActiveCardSenses || !didRecordNewCardStudied)
                try onSave(reviewedItem, updated, recordsNewCardStudied)
                if recordsNewCardStudied {
                    didRecordNewCardStudied = true
                }
                if mode.recordsStudyReview {
                    try onReview?(
                        StudyReviewEvent(
                            cardID: reviewedItem.cardID,
                            senseID: reviewedItem.senseID,
                            deckID: eventDeckID,
                            mode: mode,
                            outcome: outcome,
                            source: reviewSource,
                            reviewedAt: reviewedAt,
                            durationMS: durationMS,
                            wasNew: wasNew,
                            previousState: String(describing: reviewedItem.progress.fsrsCard.state),
                            newState: String(describing: updated.fsrsCard.state)
                        )
                    )
                }
            } else if mode.recordsStudyReview {
                let eventDeckID = reviewedItem.deckID ?? deckID
                try onPracticeReview?(
                    PracticeReviewEvent(
                        cardID: reviewedItem.cardID,
                        senseID: reviewedItem.senseID,
                        deckID: eventDeckID,
                        mode: mode,
                        outcome: outcome,
                        source: reviewSource,
                        practicedAt: reviewedAt,
                        durationMS: durationMS
                    )
                )
            }
        }

        if savesProgress,
           let additionalFailureProgress,
           additionalFailureProgress.senseID != item.progress.senseID {
            let updatedAdditional = try engine.applyReview(
                progress: additionalFailureProgress,
                outcome: .incorrect,
                now: reviewedAt
            )
            try onAdditionalFailureSave?(updatedAdditional)
        }

        if reviewsActiveCardSenses {
            let reviewedSenseIDs = Set(reviewedItems.map(\.senseID))
            queue.removeAll { reviewedSenseIDs.contains($0.senseID) }
        } else {
            queue.removeFirst()
        }
        startNextCurrentIfNeeded()
    }

    private func reviewDurationMS(endedAt: Date) -> Int? {
        guard let currentStartedAt else { return nil }
        return max(0, Int((endedAt.timeIntervalSince(currentStartedAt) * 1000).rounded()))
    }

    /// Freezes the active timers when the app leaves the foreground, so time
    /// spent backgrounded or with the screen locked is not counted as study time.
    func pauseTiming() {
        guard pausedAt == nil else { return }
        pausedAt = Date()
    }

    /// Resumes timing, shifting the start timestamps forward by the paused
    /// interval so that gap is excluded from the next recorded duration.
    func resumeTiming() {
        guard let pausedAt else { return }
        self.pausedAt = nil
        let pausedInterval = Date().timeIntervalSince(pausedAt)
        guard pausedInterval > 0 else { return }
        currentStartedAt = currentStartedAt?.addingTimeInterval(pausedInterval)
        matchingStartedAt = matchingStartedAt?.addingTimeInterval(pausedInterval)
    }

    private func startNextCurrentIfNeeded() {
        currentStartedAt = queue.isEmpty ? nil : Date()
    }

    private static func uniqueCardGroupCount(in items: [StudyQueueItem]) -> Int {
        Set(items.map { StudyCardGroupKey(cardID: $0.cardID, deckID: $0.deckID) }).count
    }

    private static func focusedActiveCards(_ cards: [WordCardContent]) -> [WordCardContent] {
        cards.flatMap { card in
            card.activeSenses.map { card.focused(on: $0) }
        }
    }
}

private struct StudyCardGroupKey: Hashable {
    let cardID: UUID
    let deckID: UUID?
}
