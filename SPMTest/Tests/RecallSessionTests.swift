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
        var progress = CardProgress.newSense(senseID: cardID)
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
        var progress = CardProgress.newSense(senseID: cardID)
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

    @Test("whole-card flashcard review updates queued sibling senses")
    @MainActor
    func wholeCardFlashcardReviewUpdatesQueuedSiblingSenses() throws {
        let engine = StudySessionEngine()
        let card = TestFixtures.card(word: "cast", translation: "бросать; гипс")
        let other = TestFixtures.card(word: "load", translation: "груз")
        let queue = StudyQueueBuilder.allItems(cards: [card, other], progressBySenseID: [:])
        let session = StudySession(
            deckID: UUID(),
            mode: .flashcards,
            queue: queue,
            dailyUsage: nil,
            engine: engine
        )

        #expect(session.displayTotalCount(flashcardDisplayMode: .oneSense) == 3)
        #expect(session.displayRemainingCount(flashcardDisplayMode: .oneSense) == 3)
        #expect(session.displayTotalCount(flashcardDisplayMode: .wholeCard) == 2)
        #expect(session.displayRemainingCount(flashcardDisplayMode: .wholeCard) == 2)

        var savedSenseIDs: [UUID] = []
        var newCardStudyFlags: [Bool] = []
        var reviewSenseIDs: [UUID] = []
        try session.advanceAfterReview(
            outcome: .remembered,
            reviewsActiveCardSenses: true
        ) { progress, wasNew in
            savedSenseIDs.append(progress.senseID)
            newCardStudyFlags.append(wasNew)
        } onReview: { event in
            reviewSenseIDs.append(event.senseID)
        }

        let cardSenseIDs = card.activeSenses.map(\.id)
        #expect(savedSenseIDs == cardSenseIDs)
        #expect(newCardStudyFlags == [true, false])
        #expect(reviewSenseIDs == cardSenseIDs)
        #expect(session.remainingCount == 1)
        #expect(session.displayRemainingCount(flashcardDisplayMode: .wholeCard) == 1)
        #expect(session.current?.cardID == other.id)
    }

    @Test("cloze wrong answer can fail selected distractor progress too")
    @MainActor
    func clozeWrongAnswerFailsSelectedDistractorProgressToo() throws {
        let engine = StudySessionEngine()
        let currentID = UUID()
        let selectedID = UUID()
        let current = TestFixtures.card(id: currentID, word: "cat", translation: "кот")
        let currentSense = try #require(current.primarySense)
        let selectedProgress = CardProgress.newSense(senseID: selectedID)
        let session = StudySession(
            deckID: UUID(),
            mode: .clozeMultipleChoice,
            queue: [TestFixtures.queueItem(card: current)],
            dailyUsage: nil,
            engine: engine
        )

        var savedCurrent: CardProgress?
        var savedSelected: CardProgress?
        try session.advanceAfterReview(
            outcome: .incorrect,
            additionalFailureProgress: selectedProgress
        ) { progress, _ in
            savedCurrent = progress
        } onAdditionalFailureSave: { progress in
            savedSelected = progress
        }

        #expect(savedCurrent?.senseID == currentSense.id)
        #expect(savedSelected?.senseID == selectedID)
        #expect(savedSelected?.fsrsCard.reps ?? 0 > selectedProgress.fsrsCard.reps)
    }

    @Test("recall forgot makes card count as new in deck stats")
    @MainActor
    func recallForgotCountsAsNew() throws {
        let engine = StudySessionEngine()
        let cardID = UUID()
        let card = TestFixtures.card(id: cardID, word: "cat", translation: "кот")
        let senseID = card.primarySense!.id
        var progress = CardProgress.newSense(senseID: senseID)
        progress = try engine.applyReview(progress: progress, outcome: .remembered)

        let deck = DeckContent(
            id: UUID(),
            title: "Test",
            avatarSystemName: nil,
            languageCode: "en",
            newCardsPerDay: 20,
            reviewCardsPerDay: 200,
            cards: [card]
        )

        let before = DeckStatsCalculator.compute(deck: deck, progressBySenseID: [senseID: progress], dailyUsage: nil)
        #expect(before.newAvailable == 0)

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
            progressBySenseID: [senseID: saved!],
            dailyUsage: nil
        )
        #expect(after.newAvailable == 1)
    }

    @Test("recall remembered leaves progress unchanged")
    @MainActor
    func recallRememberedDoesNotUpdateProgress() throws {
        let engine = StudySessionEngine()
        let cardID = UUID()
        let progress = CardProgress.newSense(senseID: cardID)
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
        let sense = try #require(card.primarySense)
        let item = StudyQueueItem(
            card: card,
            sense: sense,
            progress: CardProgress.newSense(senseID: sense.id),
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
