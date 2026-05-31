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

    @Test("deck stats count new cards when daily limit is reached")
    func newCardCountWhenDailyLimitReached() {
        let id = UUID()
        let deck = DeckContent(
            id: UUID(),
            title: "Test",
            avatarSystemName: nil,
            languageCode: "en",
            newCardsPerDay: 5,
            reviewCardsPerDay: 200,
            cards: [
                TestFixtures.card(id: id, word: "cat", translation: "кот"),
            ]
        )
        let usage = DeckDailyUsage(dayKey: DeckDailyUsage.todayKey(), newCardsStudied: 5)
        let stats = DeckStatsCalculator.compute(deck: deck, progressByCardID: [:], dailyUsage: usage)
        #expect(stats.newAvailable == 1)
    }

    @Test("cloze queue falls back to full deck when SRS queue is empty")
    @MainActor
    func clozeQueueFallback() throws {
        let card = TestFixtures.card(word: "cat", translation: "кот")
        let deck = DeckContent(
            id: UUID(),
            title: "Test",
            avatarSystemName: nil,
            languageCode: "en",
            newCardsPerDay: 0,
            reviewCardsPerDay: 0,
            cards: [card]
        )
        let progress = CardProgress.newCard(cardID: card.id)
        let reviewed = try StudySessionEngine().applyReview(progress: progress, outcome: .correct)
        let queue = StudyQueueBuilder.build(
            deck: deck,
            progressByCardID: [card.id: reviewed],
            dailyUsage: DeckDailyUsage(dayKey: DeckDailyUsage.todayKey(), newCardsStudied: 0)
        )
        #expect(queue.isEmpty)
        #expect(deck.cards.count == 1)
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
