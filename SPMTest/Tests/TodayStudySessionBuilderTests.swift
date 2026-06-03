import Foundation
import Testing
@testable import WordsTrainerLogic

@Suite("Today study session builder")
struct TodayStudySessionBuilderTests {
    @Test("today session mixes active deck queues and keeps source deck ids")
    @MainActor
    func todaySessionMixesActiveDeckQueues() throws {
        let firstCard = TestFixtures.card(word: "cat", translation: "кот")
        let secondCard = TestFixtures.card(word: "dog", translation: "собака")
        let firstDeck = deck(title: "First", cards: [firstCard])
        let secondDeck = deck(title: "Second", cards: [secondCard])
        var rng = SeededRNG(seed: 7)

        let session = try #require(
            TodayStudySessionBuilder.todaySession(
                snapshots: [
                    TodayStudyDeckSnapshot(deck: firstDeck, progressByCardID: [:], dailyUsage: nil),
                    TodayStudyDeckSnapshot(deck: secondDeck, progressByCardID: [:], dailyUsage: nil),
                ],
                mode: .flashcards,
                dayKey: "2026-06-02",
                engine: StudySessionEngine(),
                using: &rng
            )
        )

        #expect(session.deckID == TodayStudySessionBuilder.deckID)
        #expect(session.matchingRecordScope == .today(dayKey: "2026-06-02"))
        #expect(Set(session.queue.compactMap(\.deckID)) == [firstDeck.id, secondDeck.id])
        #expect(Set(session.queue.map(\.card.id)) == [firstCard.id, secondCard.id])
        #expect(Set(session.deckChoicePool.map(\.id)) == [firstCard.id, secondCard.id])
    }

    @Test("today practice session uses only cards reviewed today")
    @MainActor
    func todayPracticeUsesReviewedCardsOnly() throws {
        let reviewedCard = TestFixtures.card(word: "cat", translation: "кот")
        let untouchedCard = TestFixtures.card(word: "dog", translation: "собака")
        let activeDeck = deck(title: "Active", cards: [reviewedCard, untouchedCard])
        let inactiveDeck = deck(status: .inactive, title: "Inactive", cards: [
            TestFixtures.card(word: "bird", translation: "птица"),
        ])
        let snapshots = [
            TodayStudyDeckSnapshot(
                deck: activeDeck,
                progressByCardID: [:],
                dailyUsage: nil,
                reviewedCardIDs: [reviewedCard.id]
            ),
            TodayStudyDeckSnapshot(
                deck: inactiveDeck,
                progressByCardID: [:],
                dailyUsage: nil,
                reviewedCardIDs: inactiveDeck.cards.map(\.id)
            ),
        ]

        let session = try #require(
            TodayStudySessionBuilder.todayPracticeSession(
                snapshots: snapshots,
                mode: .flashcards,
                dayKey: "2026-06-02",
                engine: StudySessionEngine()
            )
        )

        #expect(session.savesProgress == false)
        #expect(session.reviewSource == .todayPractice)
        #expect(session.matchingRecordScope == .today(dayKey: "2026-06-02"))
        #expect(session.queue.map(\.card.id) == [reviewedCard.id])
        #expect(session.queue.compactMap(\.deckID) == [activeDeck.id])
        #expect(TodayStudySessionBuilder.todayPracticeCardCount(snapshots: snapshots) == 1)
    }

    @Test("deck practice session keeps deck record scope")
    @MainActor
    func deckPracticeKeepsDeckRecordScope() throws {
        let reviewedCard = TestFixtures.card(word: "cat", translation: "кот")
        let sourceDeck = deck(title: "Deck", cards: [reviewedCard])
        let snapshot = TodayStudyDeckSnapshot(
            deck: sourceDeck,
            progressByCardID: [:],
            dailyUsage: nil,
            reviewedCardIDs: [reviewedCard.id]
        )

        let session = try #require(
            TodayStudySessionBuilder.todayPracticeSession(
                snapshot: snapshot,
                mode: .flashcards,
                engine: StudySessionEngine()
            )
        )

        #expect(session.deckID == sourceDeck.id)
        #expect(session.matchingRecordScope == .deck(sourceDeck.id))
        #expect(session.queue.compactMap(\.deckID) == [sourceDeck.id])
    }

    private func deck(
        id: UUID = UUID(),
        status: ContentStatus = .active,
        title: String,
        cards: [WordCardContent]
    ) -> DeckContent {
        DeckContent(
            id: id,
            status: status,
            title: title,
            avatarSystemName: nil,
            languageCode: "en",
            newCardsPerDay: 20,
            reviewCardsPerDay: 200,
            cards: cards
        )
    }
}
