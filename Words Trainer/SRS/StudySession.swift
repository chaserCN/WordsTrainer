import Foundation
import FSRS

@Observable
@MainActor
final class StudySession {
    let deckID: UUID
    let mode: StudyMode
    private(set) var queue: [StudyQueueItem]
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

    init(
        deckID: UUID,
        mode: StudyMode,
        queue: [StudyQueueItem],
        dailyUsage: DeckDailyUsage?,
        engine: StudySessionEngine
    ) {
        self.deckID = deckID
        self.mode = mode
        self.dailyUsage = dailyUsage
        self.engine = engine
        self.queue = mode == .matching ? [] : queue
        if mode == .matching {
            var rng = SystemRandomNumberGenerator()
            let pairs = queue.flatMap { MatchingPair.pairs(from: $0) }
            matchingScheduler = MatchingPairScheduler(pairs: pairs, rng: &rng)
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
        let updated = try engine.applyReview(progress: item.progress, outcome: outcome)
        try onSave(updated, wasNew && outcome.passed)
        queue.removeFirst()
    }
}
