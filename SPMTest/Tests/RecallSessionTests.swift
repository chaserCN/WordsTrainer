import Foundation
import FSRS
import Testing
@testable import WordsTrainerLogic

@Suite("Recall session")
struct RecallSessionTests {
    @Test("recall forgot resets card to new")
    @MainActor
    func recallForgotResetsToNew() throws {
        let engine = StudySessionEngine()
        let cardID = UUID()
        var progress = CardProgress.newCard(cardID: cardID)
        progress = try engine.applyReview(progress: progress, outcome: .remembered)
        #expect(progress.fsrsCard.state != .new)

        let card = TestFixtures.card(id: cardID, word: "cat", translation: "кот")
        let session = StudySession(
            deckID: UUID(),
            mode: .recall,
            queue: [TestFixtures.queueItem(card: card, progress: progress)],
            dailyUsage: nil,
            engine: engine
        )

        var saved: CardProgress?
        try session.advanceAfterReview(outcome: .forgot) { progress, _ in
            saved = progress
        }

        #expect(saved?.fsrsCard.state == .new)
    }

    @Test("flashcards forgot uses FSRS failure instead of reset")
    @MainActor
    func flashcardsForgotDoesNotResetToNew() throws {
        let engine = StudySessionEngine()
        let cardID = UUID()
        var progress = CardProgress.newCard(cardID: cardID)
        progress = try engine.applyReview(progress: progress, outcome: .remembered)
        #expect(progress.fsrsCard.state != .new)

        let card = TestFixtures.card(id: cardID, word: "cat", translation: "кот")
        let session = StudySession(
            deckID: UUID(),
            mode: .flashcards,
            queue: [TestFixtures.queueItem(card: card, progress: progress)],
            dailyUsage: nil,
            engine: engine
        )

        var saved: CardProgress?
        try session.advanceAfterReview(outcome: .forgot) { progress, _ in
            saved = progress
        }

        #expect(saved?.fsrsCard.state != .new)
    }

    @Test("recall forgot makes card count as new in deck stats")
    @MainActor
    func recallForgotCountsAsNew() throws {
        let engine = StudySessionEngine()
        let cardID = UUID()
        var progress = CardProgress.newCard(cardID: cardID)
        progress = try engine.applyReview(progress: progress, outcome: .remembered)

        let deck = DeckContent(
            id: UUID(),
            title: "Test",
            avatarSystemName: nil,
            languageCode: "en",
            newCardsPerDay: 20,
            reviewCardsPerDay: 200,
            cards: [TestFixtures.card(id: cardID, word: "cat", translation: "кот")]
        )

        let before = DeckStatsCalculator.compute(deck: deck, progressByCardID: [cardID: progress], dailyUsage: nil)
        #expect(before.newAvailable == 0)

        let card = deck.cards[0]
        let session = StudySession(
            deckID: deck.id,
            mode: .recall,
            queue: [TestFixtures.queueItem(card: card, progress: progress)],
            dailyUsage: nil,
            engine: engine
        )

        var saved: CardProgress?
        try session.advanceAfterReview(outcome: .forgot) { progress, _ in
            saved = progress
        }

        let after = DeckStatsCalculator.compute(
            deck: deck,
            progressByCardID: [cardID: saved!],
            dailyUsage: nil
        )
        #expect(after.newAvailable == 1)
    }

    @Test("recall remembered leaves progress unchanged")
    @MainActor
    func recallRememberedDoesNotUpdateProgress() throws {
        let engine = StudySessionEngine()
        let cardID = UUID()
        let progress = CardProgress.newCard(cardID: cardID)
        let card = TestFixtures.card(id: cardID, word: "cat", translation: "кот")
        let session = StudySession(
            deckID: UUID(),
            mode: .recall,
            queue: [TestFixtures.queueItem(card: card, progress: progress)],
            dailyUsage: nil,
            engine: engine
        )

        var saved: CardProgress?
        try session.advanceAfterReview(outcome: .remembered) { progress, _ in
            saved = progress
        }

        #expect(saved == nil)
        #expect(session.isFinished)
    }

    @Test("recall reset updates progress without creating a study review")
    @MainActor
    func recallResetDoesNotCreateStudyReview() throws {
        let engine = StudySessionEngine()
        let cardID = UUID()
        let card = TestFixtures.card(id: cardID, word: "cat", translation: "кот")
        let session = StudySession(
            deckID: UUID(),
            mode: .recall,
            queue: [TestFixtures.queueItem(card: card)],
            dailyUsage: nil,
            engine: engine
        )

        var didSaveProgress = false
        var didSaveReview = false
        try session.advanceAfterReview(outcome: .forgot) { _, _ in
            didSaveProgress = true
        } onReview: { _ in
            didSaveReview = true
        }

        #expect(didSaveProgress)
        #expect(!didSaveReview)
    }

    @Test("practice review advances without saving progress or review event")
    @MainActor
    func practiceReviewDoesNotSaveProgressOrReviewEvent() throws {
        let engine = StudySessionEngine()
        let cardID = UUID()
        let card = TestFixtures.card(id: cardID, word: "cat", translation: "кот")
        let session = StudySession(
            deckID: UUID(),
            mode: .flashcards,
            queue: [TestFixtures.queueItem(card: card)],
            dailyUsage: nil,
            engine: engine,
            savesProgress: false
        )

        var didSaveProgress = false
        var didSaveReview = false
        try session.advanceAfterReview(outcome: .remembered) { _, _ in
            didSaveProgress = true
        } onReview: { _ in
            didSaveReview = true
        }

        #expect(session.isFinished)
        #expect(!didSaveProgress)
        #expect(!didSaveReview)
    }

    @Test("practice review creates a separate practice event")
    @MainActor
    func practiceReviewCreatesPracticeEvent() throws {
        let engine = StudySessionEngine()
        let deckID = UUID()
        let cardID = UUID()
        let card = TestFixtures.card(id: cardID, word: "cat", translation: "кот")
        let session = StudySession(
            deckID: deckID,
            mode: .flashcards,
            queue: [TestFixtures.queueItem(card: card)],
            dailyUsage: nil,
            engine: engine,
            reviewSource: .todayPractice,
            savesProgress: false
        )

        var practiceEvent: PracticeReviewEvent?
        try session.advanceAfterReview(outcome: .remembered) { _, _ in } onReview: { _ in
            Issue.record("Practice should not create a study review")
        } onPracticeReview: { event in
            practiceEvent = event
        }

        #expect(practiceEvent?.cardID == cardID)
        #expect(practiceEvent?.deckID == deckID)
        #expect(practiceEvent?.source == .todayPractice)
        #expect(practiceEvent?.outcome == .remembered)
    }

    @Test("review event uses queue item deck id when session mixes decks")
    @MainActor
    func reviewEventUsesQueueItemDeckID() throws {
        let engine = StudySessionEngine()
        let sessionDeckID = UUID()
        let sourceDeckID = UUID()
        let cardID = UUID()
        let card = TestFixtures.card(id: cardID, word: "cat", translation: "кот")
        let item = StudyQueueItem(
            card: card,
            progress: CardProgress.newCard(cardID: cardID),
            deckID: sourceDeckID
        )
        let session = StudySession(
            deckID: sessionDeckID,
            mode: .flashcards,
            queue: [item],
            dailyUsage: nil,
            engine: engine,
            matchingRecordScope: MatchingRecordScope.none,
            reviewSource: .todayQueue
        )

        var reviewDeckID: UUID?
        var reviewSource: StudyReviewSource?
        try session.advanceAfterReview(outcome: .remembered) { _, _ in } onReview: { event in
            reviewDeckID = event.deckID
            reviewSource = event.source
        }

        #expect(reviewDeckID == sourceDeckID)
        #expect(reviewSource == .todayQueue)
    }
}
