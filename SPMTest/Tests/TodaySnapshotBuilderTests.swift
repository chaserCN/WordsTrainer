import Foundation
import Testing
@testable import WordsTrainerLogic

@Suite("Today snapshot builder")
struct TodaySnapshotBuilderTests {
    @Test("queue cards are rebuilt from snapshot progress")
    func queueCardsAreRebuiltFromSnapshotProgress() {
        let card = TestFixtures.card(word: "above", translation: "над")
        let sourceDeck = deck(title: "English", cards: [card])
        let snapshot = TodayStudyDeckSnapshot(
            deck: sourceDeck,
            progressBySenseID: [:],
            dailyUsage: nil
        )

        let cards = TodaySnapshotBuilder.queueCards(snapshot: snapshot)

        #expect(cards.map(\.id) == [card.id])
    }

    @Test("practice cards keep unique active cards from reviewed senses")
    func practiceCardsKeepUniqueActiveCardsFromReviewedSenses() {
        let multiSenseCard = TestFixtures.card(word: "cast", translation: "бросать; гипс")
        let otherCard = TestFixtures.card(word: "above", translation: "над")
        let sourceDeck = deck(title: "English", cards: [multiSenseCard, otherCard])
        let snapshot = TodayStudyDeckSnapshot(
            deck: sourceDeck,
            progressBySenseID: [:],
            dailyUsage: nil,
            reviewedSenseIDs: multiSenseCard.activeSenses.map(\.id)
        )

        let cards = TodaySnapshotBuilder.practiceCards(snapshot: snapshot)

        #expect(cards.map(\.id) == [multiSenseCard.id])
        #expect(TodaySnapshotBuilder.practiceCardCount(snapshot: snapshot) == 2)
    }

    @Test("practice cards ignore inactive deck")
    func practiceCardsIgnoreInactiveDeck() {
        let card = TestFixtures.card(word: "above", translation: "над")
        let sourceDeck = deck(status: .inactive, title: "Inactive", cards: [card])
        let snapshot = TodayStudyDeckSnapshot(
            deck: sourceDeck,
            progressBySenseID: [:],
            dailyUsage: nil,
            reviewedSenseIDs: card.activeSenses.map(\.id)
        )

        #expect(TodaySnapshotBuilder.practiceCards(snapshot: snapshot).isEmpty)
        #expect(TodaySnapshotBuilder.practiceCardCount(snapshot: snapshot) == 0)
    }

    @Test("unique cards keeps first occurrence order")
    func uniqueCardsKeepsFirstOccurrenceOrder() {
        let first = TestFixtures.card(word: "above", translation: "над")
        let second = TestFixtures.card(word: "below", translation: "под")

        let cards = TodaySnapshotBuilder.uniqueCards([first, second, first])

        #expect(cards.map(\.id) == [first.id, second.id])
    }

    private func deck(
        id: UUID = UUID(),
        status: ContentStatus = .active,
        title: String,
        newCardsPerDay: Int = 20,
        cards: [WordCardContent]
    ) -> DeckContent {
        DeckContent(
            id: id,
            status: status,
            title: title,
            avatarSystemName: nil,
            languageCode: "en",
            newCardsPerDay: newCardsPerDay,
            reviewCardsPerDay: 200,
            cards: cards
        )
    }
}
