import Foundation
import FSRS
import Testing
@testable import WordsTrainerLogic

@Suite("Deck stats and SRS")
struct DeckStatsTests {
    @Test("deck stats count new cards")
    func newCardCount() {
        let id = UUID()
        let deck = DeckContent(
            id: UUID(),
            title: "Test",
            avatarSystemName: nil,
            languageCode: "en",
            newCardsPerDay: 20,
            reviewCardsPerDay: 200,
            cards: [
                TestFixtures.card(id: id, word: "cat", translation: "кот"),
            ]
        )
        let stats = DeckStatsCalculator.compute(deck: deck, progressByCardID: [:], dailyUsage: nil)
        #expect(stats.newAvailable == 1)
    }

    @Test("binary review updates FSRS card")
    @MainActor
    func binaryReview() throws {
        let engine = StudySessionEngine()
        let id = UUID()
        var progress = CardProgress.newCard(cardID: id)
        progress = try engine.applyReview(progress: progress, outcome: .correct)
        #expect(progress.fsrsCard.reps > 0)
    }
}
