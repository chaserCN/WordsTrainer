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
        #expect(session.matchingRecordScope == .none)
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
        #expect(session.matchingRecordScope == .none)
        #expect(session.queue.map(\.card.id) == [reviewedCard.id])
        #expect(session.queue.compactMap(\.deckID) == [activeDeck.id])
        #expect(TodayStudySessionBuilder.todayPracticeCardCount(snapshots: snapshots) == 1)
    }

    @Test("deck practice session does not keep a matching record scope")
    @MainActor
    func deckPracticeDoesNotKeepMatchingRecordScope() throws {
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
        #expect(session.matchingRecordScope == .none)
        #expect(session.queue.compactMap(\.deckID) == [sourceDeck.id])
    }

    @Test("random session samples up to thirty active cards and keeps source deck ids")
    @MainActor
    func randomSessionSamplesActiveCards() throws {
        let firstCards = (0..<24).map { TestFixtures.card(word: "first-\($0)", translation: "\($0)") }
        let secondCards = (0..<18).map { TestFixtures.card(word: "second-\($0)", translation: "\($0)") }
        let inactiveCard = TestFixtures.card(word: "inactive", translation: "x")
        let firstDeck = deck(title: "First", cards: firstCards)
        let secondDeck = deck(title: "Second", cards: secondCards)
        let inactiveDeck = deck(status: .inactive, title: "Inactive", cards: [inactiveCard])
        var rng = SeededRNG(seed: 13)

        let session = try #require(
            RandomStudySessionBuilder.randomSession(
                snapshots: [
                    TodayStudyDeckSnapshot(deck: firstDeck, progressByCardID: [:], dailyUsage: nil),
                    TodayStudyDeckSnapshot(deck: secondDeck, progressByCardID: [:], dailyUsage: nil),
                    TodayStudyDeckSnapshot(deck: inactiveDeck, progressByCardID: [:], dailyUsage: nil),
                ],
                mode: .flashcards,
                engine: StudySessionEngine(),
                using: &rng
            )
        )

        #expect(session.deckID == RandomStudySessionBuilder.deckID)
        #expect(session.queue.count == RandomStudySessionBuilder.defaultLimit)
        #expect(session.matchingRecordScope == .none)
        #expect(session.savesProgress)
        #expect(!session.queue.map(\.card.id).contains(inactiveCard.id))
        #expect(Set(session.queue.compactMap(\.deckID)).isSubset(of: [firstDeck.id, secondDeck.id]))
        #expect(Set(session.deckChoicePool.map(\.id)) == Set((firstCards + secondCards).map(\.id)))
    }

    @Test("random cards returns the same sampled list for a seeded generator")
    func randomCardsUsesSameSamplingRules() {
        let cards = (0..<35).map { TestFixtures.card(word: "card-\($0)", translation: "\($0)") }
        let activeDeck = deck(title: "Active", cards: cards)
        let inactiveDeck = deck(status: .inactive, title: "Inactive", cards: [
            TestFixtures.card(word: "inactive", translation: "x"),
        ])
        let snapshots = [
            TodayStudyDeckSnapshot(deck: activeDeck, progressByCardID: [:], dailyUsage: nil),
            TodayStudyDeckSnapshot(deck: inactiveDeck, progressByCardID: [:], dailyUsage: nil),
        ]
        var firstRNG = SeededRNG(seed: 21)
        var secondRNG = SeededRNG(seed: 21)

        let first = RandomStudySessionBuilder.randomCards(snapshots: snapshots, using: &firstRNG)
        let second = RandomStudySessionBuilder.randomCards(snapshots: snapshots, using: &secondRNG)

        #expect(first.count == RandomStudySessionBuilder.defaultLimit)
        #expect(first.map(\.id) == second.map(\.id))
        #expect(Set(first.map(\.id)).isSubset(of: Set(cards.map(\.id))))
    }

    @Test("random cards uses a custom user limit")
    func randomCardsUsesCustomLimit() {
        let cards = (0..<20).map { TestFixtures.card(word: "card-\($0)", translation: "\($0)") }
        let activeDeck = deck(title: "Active", cards: cards)
        var rng = SeededRNG(seed: 4)

        let sampled = RandomStudySessionBuilder.randomCards(
            snapshots: [TodayStudyDeckSnapshot(deck: activeDeck, progressByCardID: [:], dailyUsage: nil)],
            limit: 7,
            using: &rng
        )

        #expect(sampled.count == 7)
        #expect(Set(sampled.map(\.id)).isSubset(of: Set(cards.map(\.id))))
    }

    @Test("random session can be built from an already selected card list")
    @MainActor
    func randomSessionUsesProvidedCards() throws {
        let cards = (0..<8).map { TestFixtures.card(word: "card-\($0)", translation: "\($0)") }
        let selected = [cards[3], cards[1], cards[6]]
        let sourceDeck = deck(title: "Source", cards: cards)

        let session = try #require(
            RandomStudySessionBuilder.session(
                snapshots: [
                    TodayStudyDeckSnapshot(deck: sourceDeck, progressByCardID: [:], dailyUsage: nil),
                ],
                cards: selected,
                mode: .flashcards,
                engine: StudySessionEngine()
            )
        )

        #expect(session.queue.map(\.card.id) == selected.map(\.id))
        #expect(session.queue.compactMap(\.deckID) == [sourceDeck.id, sourceDeck.id, sourceDeck.id])
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
