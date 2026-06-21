import Foundation
import Testing
@testable import WordsTrainerLogic

@Suite("Study session factory")
struct StudySessionFactoryTests {
    @Test("today deck session disables matching record scope")
    @MainActor
    func todayDeckSessionDisablesMatchingRecordScope() {
        let card = TestFixtures.card(word: "above", translation: "над")
        let deck = deck(title: "English", cards: [card])

        let session = StudySessionFactory.todayDeckSession(
            deck: deck,
            mode: .matching,
            progressBySenseID: [:],
            dailyUsage: nil,
            engine: StudySessionEngine()
        )

        #expect(session.reviewSource == .todayQueue)
        #expect(session.matchingRecordScope == .none)
        #expect(session.savesProgress == true)
        #expect(session.matchingTotalPairCount == 1)
    }

    @Test("all-cards matching session keeps deck record scope")
    @MainActor
    func allCardsMatchingSessionKeepsDeckRecordScope() {
        let card = TestFixtures.card(word: "above", translation: "над")
        let deck = deck(title: "English", cards: [card])

        let session = StudySessionFactory.allCardsSession(
            deck: deck,
            mode: .matching,
            progressBySenseID: [:],
            dailyUsage: nil,
            engine: StudySessionEngine()
        )

        #expect(session.reviewSource == .deckSession)
        #expect(session.matchingRecordScope == .deck(deck.id))
        #expect(session.savesProgress == true)
        #expect(session.matchingTotalPairCount == 1)
    }

    @Test("weak matching session uses synthetic deck and skips progress")
    @MainActor
    func weakMatchingSessionUsesSyntheticDeckAndSkipsProgress() throws {
        let first = TestFixtures.queueItem(card: TestFixtures.card(word: "above", translation: "над"))
        let second = TestFixtures.queueItem(card: TestFixtures.card(word: "below", translation: "под"))

        let session = try #require(
            StudySessionFactory.weakMatchingSession(
                queue: [first, second],
                engine: StudySessionEngine()
            )
        )

        #expect(session.deckID == WeakCardsPractice.deckID)
        #expect(session.reviewSource == .weakCards)
        #expect(session.matchingRecordScope == .none)
        #expect(session.savesProgress == false)
        #expect(session.matchingTotalPairCount == 2)
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
