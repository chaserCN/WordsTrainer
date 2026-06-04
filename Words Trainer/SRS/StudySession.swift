import Foundation
import FSRS

@Observable
@MainActor
final class StudySession {
    let deckID: UUID
    let mode: StudyMode
    let matchingRecordScope: MatchingRecordScope
    let reviewSource: StudyReviewSource
    /// Когда false — чистая практика: учебный прогресс и review events не сохраняются.
    /// Matching-рекорд управляется отдельно через `matchingRecordScope`.
    let savesProgress: Bool
    let matchingTotalPairCount: Int
    let matchingStartedAt: Date?
    private(set) var queue: [StudyQueueItem]
    /// Cards queued at session start — stable MCQ distractor pool for the whole session.
    let sessionChoicePool: [WordCardContent]
    /// Full deck — fills remaining distractor slots when the session pool is too small.
    let deckChoicePool: [WordCardContent]
    private var matchingScheduler: MatchingPairScheduler?
    private var dailyUsage: DeckDailyUsage?
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

    var matchingElapsed: TimeInterval {
        guard let matchingStartedAt else { return 0 }
        return Date().timeIntervalSince(matchingStartedAt)
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
        deckChoicePool = deckCards
        if mode.isMatching {
            let pairs = queue.flatMap { MatchingPair.pairs(from: $0) }
            matchingTotalPairCount = pairs.count
            matchingStartedAt = Date()
            self.queue = []
            var rng = SystemRandomNumberGenerator()
            matchingScheduler = MatchingPairScheduler(pairs: pairs, rng: &rng)
        } else {
            matchingTotalPairCount = 0
            matchingStartedAt = nil
            self.queue = queue
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
        onSave: (_ progress: CardProgress, _ wasNew: Bool) throws -> Void,
        onReview: ((_ event: StudyReviewEvent) throws -> Void)? = nil,
        onPracticeReview: ((_ event: PracticeReviewEvent) throws -> Void)? = nil
    ) throws {
        guard let item = current else { return }
        let reviewedAt = Date()
        let wasNew = item.progress.fsrsCard.state == .new
        let updated: CardProgress
        if mode == .recall, outcome == .forgot {
            updated = CardProgress.newCard(cardID: item.progress.cardID, now: reviewedAt)
        } else {
            updated = try engine.applyReview(progress: item.progress, outcome: outcome, now: reviewedAt)
        }
        if savesProgress {
            let eventDeckID = item.deckID ?? deckID
            try onSave(updated, wasNew && outcome.passed)
            if mode.recordsStudyReview {
                try onReview?(
                    StudyReviewEvent(
                        cardID: item.card.id,
                        deckID: eventDeckID,
                        mode: mode,
                        outcome: outcome,
                        source: reviewSource,
                        reviewedAt: reviewedAt,
                        wasNew: wasNew,
                        previousState: String(describing: item.progress.fsrsCard.state),
                        newState: String(describing: updated.fsrsCard.state)
                    )
                )
            }
        } else if mode.recordsStudyReview {
            let eventDeckID = item.deckID ?? deckID
            try onPracticeReview?(
                PracticeReviewEvent(
                    cardID: item.card.id,
                    deckID: eventDeckID,
                    mode: mode,
                    outcome: outcome,
                    source: reviewSource,
                    practicedAt: reviewedAt
                )
            )
        }
        queue.removeFirst()
    }
}
