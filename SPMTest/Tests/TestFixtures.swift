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
        let senseTranslations = WordCardContent.translationSenses(translation)
        let senses = senseTranslations.enumerated().map { index, senseTranslation in
            WordSenseContent(
                id: senseID(cardID: id, index: index),
                cardID: id,
                status: status,
                displayPattern: nil,
                translation: senseTranslation,
                note: nil,
                imageURL: nil,
                example: SenseExampleContent(
                    text: WordCardContent.fillTemplate(
                        clozePrompt,
                        with: clozeAnswer ?? WordCardContent.headword(from: word)
                    ),
                    translation: nil,
                    note: nil
                ),
                sentenceQuestion: SentenceQuestionContent(
                    template: clozePrompt,
                    answer: clozeAnswer ?? WordCardContent.headword(from: word),
                    answerFormKey: nil,
                    audioAnswerURL: nil
                ),
                distractors: distractors
            )
        }
        return WordCardContent(
            id: id,
            status: status,
            word: word,
            lemma: lemma,
            primarySenseID: senses.first?.id,
            senses: senses
        )
    }

    static func queueItem(
        card: WordCardContent,
        progress: CardProgress? = nil
    ) -> StudyQueueItem {
        let sense = card.primarySense!
        return StudyQueueItem(
            card: card,
            sense: sense,
            progress: progress ?? CardProgress.newSense(senseID: sense.id)
        )
    }

    static func pairs(
        word: String,
        translation: String,
        id: UUID = UUID()
    ) -> [MatchingPair] {
        let card = card(id: id, word: word, translation: translation)
        return StudyQueueBuilder.allItems(cards: [card], progressBySenseID: [:]).flatMap(MatchingPair.pairs)
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
            queue: StudyQueueBuilder.allItems(cards: cards, progressBySenseID: [:]),
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

    private static func senseID(cardID: UUID, index: Int) -> UUID {
        let hex = cardID.uuidString.replacingOccurrences(of: "-", with: "")
        let prefix = String(hex.prefix(28))
        let cardSuffix = String(hex.suffix(2))
        let senseSuffix = String(format: "%02x", index + 1)
        let combined = prefix + cardSuffix + senseSuffix
        let start = combined.startIndex
        let p1 = combined.index(start, offsetBy: 8)
        let p2 = combined.index(start, offsetBy: 12)
        let p3 = combined.index(start, offsetBy: 16)
        let p4 = combined.index(start, offsetBy: 20)
        return UUID(
            uuidString: "\(combined[start..<p1])-\(combined[p1..<p2])-\(combined[p2..<p3])-\(combined[p3..<p4])-\(combined[p4...])"
        )!
    }
}
