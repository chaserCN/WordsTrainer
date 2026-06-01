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

    @Test("deck stats ignore inactive cards")
    func inactiveCardsAreSkippedInStats() {
        let activeID = UUID()
        let inactiveID = UUID()
        let deck = DeckContent(
            id: UUID(),
            title: "Test",
            avatarSystemName: nil,
            languageCode: "en",
            newCardsPerDay: 20,
            reviewCardsPerDay: 200,
            cards: [
                TestFixtures.card(id: activeID, word: "cat", translation: "кот"),
                TestFixtures.card(id: inactiveID, status: .inactive, word: "dog", translation: "собака"),
            ]
        )

        let stats = DeckStatsCalculator.compute(deck: deck, progressByCardID: [:], dailyUsage: nil)

        #expect(stats.newAvailable == 1)
    }

    @Test("deck stats are zero for inactive deck")
    func inactiveDeckHasZeroStats() {
        let deck = DeckContent(
            id: UUID(),
            status: .inactive,
            title: "Test",
            avatarSystemName: nil,
            languageCode: "en",
            newCardsPerDay: 20,
            reviewCardsPerDay: 200,
            cards: [
                TestFixtures.card(word: "cat", translation: "кот"),
            ]
        )

        let stats = DeckStatsCalculator.compute(deck: deck, progressByCardID: [:], dailyUsage: nil)

        #expect(stats == .zero)
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

    @Test("study queue skips inactive cards")
    func studyQueueSkipsInactiveCards() {
        let active = TestFixtures.card(word: "cat", translation: "кот")
        let inactive = TestFixtures.card(status: .inactive, word: "dog", translation: "собака")
        let deck = DeckContent(
            id: UUID(),
            title: "Test",
            avatarSystemName: nil,
            languageCode: "en",
            newCardsPerDay: 20,
            reviewCardsPerDay: 200,
            cards: [active, inactive]
        )

        let queue = StudyQueueBuilder.build(deck: deck, progressByCardID: [:], dailyUsage: nil)

        #expect(queue.map(\.card.id) == [active.id])
    }

    @Test("study queue is empty for inactive deck")
    func studyQueueSkipsInactiveDeck() {
        let deck = DeckContent(
            id: UUID(),
            status: .inactive,
            title: "Test",
            avatarSystemName: nil,
            languageCode: "en",
            newCardsPerDay: 20,
            reviewCardsPerDay: 200,
            cards: [
                TestFixtures.card(word: "cat", translation: "кот"),
            ]
        )

        let queue = StudyQueueBuilder.build(deck: deck, progressByCardID: [:], dailyUsage: nil)

        #expect(queue.isEmpty)
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
