import Foundation
import FSRS

@Observable
@MainActor
final class StudySession {
    let deckID: UUID
    let mode: StudyMode
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
        if mode == .matching {
            return matchingScheduler?.remainingCount ?? 0
        }
        return queue.count
    }
    var isFinished: Bool {
        if mode == .matching {
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
        engine: StudySessionEngine
    ) {
        self.deckID = deckID
        self.mode = mode
        self.dailyUsage = dailyUsage
        self.engine = engine
        sessionChoicePool = queue.map(\.card)
        deckChoicePool = deckCards
        if mode == .matching {
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
        guard mode == .matching else { return }
        var rng = SystemRandomNumberGenerator()
        matchingScheduler?.removeMatched(id: id, rng: &rng)
    }

    func advanceAfterReview(
        outcome: ReviewOutcome,
        onSave: (_ progress: CardProgress, _ wasNew: Bool) throws -> Void
    ) throws {
        guard let item = current else { return }
        let wasNew = item.progress.fsrsCard.state == .new
        let updated: CardProgress
        if mode == .recall, outcome == .forgot {
            updated = CardProgress.newCard(cardID: item.progress.cardID)
        } else {
            updated = try engine.applyReview(progress: item.progress, outcome: outcome)
        }
        try onSave(updated, wasNew && outcome.passed)
        queue.removeFirst()
    }
}
