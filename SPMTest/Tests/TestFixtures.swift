import Foundation
import Testing
@testable import WordsTrainerLogic

enum TestFixtures {
    static func card(
        id: UUID = UUID(),
        status: ContentStatus = .active,
        word: String,
        lemma: String? = nil,
        translation: String,
        clozePrompt: String = "___",
        clozeAnswer: String? = nil,
        distractors: [String] = []
    ) -> WordCardContent {
        WordCardContent(
            id: id,
            status: status,
            word: word,
            lemma: lemma,
            translation: translation,
            clozePrompt: clozePrompt,
            clozeAnswer: clozeAnswer,
            distractors: distractors
        )
    }

    static func queueItem(
        card: WordCardContent,
        progress: CardProgress? = nil
    ) -> StudyQueueItem {
        StudyQueueItem(
            card: card,
            progress: progress ?? CardProgress.newCard(cardID: card.id)
        )
    }

    static func pairs(
        word: String,
        translation: String,
        id: UUID = UUID()
    ) -> [MatchingPair] {
        MatchingPair.pairs(from: queueItem(card: card(id: id, word: word, translation: translation)))
    }

    static func scheduler(
        cards: [(word: String, translation: String, id: UUID)],
        seed: UInt64 = 42
    ) -> MatchingPairScheduler {
        let allPairs = cards.flatMap { pairs(word: $0.word, translation: $0.translation, id: $0.id) }
        return MatchingPairScheduler.forTesting(pairs: allPairs, seed: seed)
    }

    static func scheduler(
        cards: [(word: String, translation: String)],
        seed: UInt64 = 42
    ) -> MatchingPairScheduler {
        scheduler(cards: cards.map { (word: $0.0, translation: $0.1, id: UUID()) }, seed: seed)
    }

    static func scheduler(pairs: [MatchingPair], seed: UInt64 = 42) -> MatchingPairScheduler {
        MatchingPairScheduler.forTesting(pairs: pairs, seed: seed)
    }

    @MainActor
    static func matchingSession(cards: [WordCardContent]) -> StudySession {
        StudySession(
            deckID: UUID(),
            mode: .matching,
            queue: cards.map { queueItem(card: $0) },
            dailyUsage: nil,
            engine: StudySessionEngine()
        )
    }

    static func matchAllDeterministically(
        _ scheduler: inout MatchingPairScheduler,
        seed: UInt64 = 99
    ) {
        var rng = SeededRNG(seed: seed)
        while !scheduler.isFinished {
            guard let id = scheduler.visible.first?.id else {
                Issue.record("Scheduler finished unexpectedly with empty visible set")
                return
            }
            scheduler.removeMatched(id: id, rng: &rng)
        }
    }

    static func totalPairCount(for cards: [(word: String, translation: String)]) -> Int {
        cards.reduce(0) { $0 + pairs(word: $1.word, translation: $1.translation).count }
    }
}
