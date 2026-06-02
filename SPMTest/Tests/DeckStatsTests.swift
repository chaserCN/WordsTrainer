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

    @Test("deck stats cap new cards by daily limit")
    func newCardCountIsCappedByDailyLimit() {
        let firstID = UUID()
        let secondID = UUID()
        let deck = DeckContent(
            id: UUID(),
            title: "Test",
            avatarSystemName: nil,
            languageCode: "en",
            newCardsPerDay: 1,
            reviewCardsPerDay: 200,
            cards: [
                TestFixtures.card(id: firstID, word: "cat", translation: "кот"),
                TestFixtures.card(id: secondID, word: "dog", translation: "собака"),
            ]
        )
        let usage = DeckDailyUsage(dayKey: DeckDailyUsage.todayKey(), newCardsStudied: 0)
        let stats = DeckStatsCalculator.compute(deck: deck, progressByCardID: [:], dailyUsage: usage)
        #expect(stats.newAvailable == 1)
    }

    @Test("deck stats show no new cards after daily limit is used")
    func newCardCountIsZeroWhenDailyLimitReached() {
        let deck = DeckContent(
            id: UUID(),
            title: "Test",
            avatarSystemName: nil,
            languageCode: "en",
            newCardsPerDay: 1,
            reviewCardsPerDay: 200,
            cards: [
                TestFixtures.card(word: "cat", translation: "кот"),
                TestFixtures.card(word: "dog", translation: "собака"),
            ]
        )
        let usage = DeckDailyUsage(dayKey: DeckDailyUsage.todayKey(), newCardsStudied: 1)
        let stats = DeckStatsCalculator.compute(deck: deck, progressByCardID: [:], dailyUsage: usage)
        #expect(stats.newAvailable == 0)
    }

    @Test("deck stats cap reviews by daily limit")
    func reviewCountIsCappedByDailyLimit() {
        let firstID = UUID()
        let secondID = UUID()
        let now = Date()
        let deck = DeckContent(
            id: UUID(),
            title: "Test",
            avatarSystemName: nil,
            languageCode: "en",
            newCardsPerDay: 20,
            reviewCardsPerDay: 1,
            cards: [
                TestFixtures.card(id: firstID, word: "cat", translation: "кот"),
                TestFixtures.card(id: secondID, word: "dog", translation: "собака"),
            ]
        )
        let dueCard = Card(
            due: now.addingTimeInterval(-60),
            stability: 1,
            difficulty: 1,
            reps: 1,
            state: .review,
            lastReview: now.addingTimeInterval(-86_400)
        )
        let progressByCardID = [
            firstID: CardProgress(cardID: firstID, fsrsCard: dueCard),
            secondID: CardProgress(cardID: secondID, fsrsCard: dueCard),
        ]

        let stats = DeckStatsCalculator.compute(
            deck: deck,
            progressByCardID: progressByCardID,
            dailyUsage: nil,
            now: now
        )

        #expect(stats.reviewDue == 1)
    }

    @Test("deck stats count cards due later today separately")
    func dueLaterTodayCount() {
        let dueNowID = UUID()
        let reviewLaterID = UUID()
        let learningLaterID = UUID()
        let tomorrowID = UUID()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(from: DateComponents(year: 2026, month: 6, day: 3, hour: 9))!
        let laterToday = calendar.date(from: DateComponents(year: 2026, month: 6, day: 3, hour: 21))!
        let tomorrow = calendar.date(from: DateComponents(year: 2026, month: 6, day: 4, hour: 9))!
        let deck = DeckContent(
            id: UUID(),
            title: "Test",
            avatarSystemName: nil,
            languageCode: "en",
            newCardsPerDay: 20,
            reviewCardsPerDay: 200,
            cards: [
                TestFixtures.card(id: dueNowID, word: "cat", translation: "кот"),
                TestFixtures.card(id: reviewLaterID, word: "dog", translation: "собака"),
                TestFixtures.card(id: learningLaterID, word: "bird", translation: "птица"),
                TestFixtures.card(id: tomorrowID, word: "fish", translation: "рыба"),
            ]
        )
        let progressByCardID = [
            dueNowID: CardProgress(cardID: dueNowID, fsrsCard: reviewCard(due: now.addingTimeInterval(-60), now: now)),
            reviewLaterID: CardProgress(cardID: reviewLaterID, fsrsCard: reviewCard(due: laterToday, now: now)),
            learningLaterID: CardProgress(cardID: learningLaterID, fsrsCard: learningCard(due: laterToday, now: now)),
            tomorrowID: CardProgress(cardID: tomorrowID, fsrsCard: reviewCard(due: tomorrow, now: now)),
        ]

        let stats = DeckStatsCalculator.compute(
            deck: deck,
            progressByCardID: progressByCardID,
            dailyUsage: nil,
            now: now,
            calendar: calendar
        )

        #expect(stats.reviewDue == 1)
        #expect(stats.dueLaterToday == 2)
        #expect(stats.studyTotal == 1)
    }

    @Test("deck stats cap review cards due later today by daily review limit")
    func dueLaterTodayReviewCountRespectsDailyLimit() {
        let dueNowID = UUID()
        let laterID = UUID()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(from: DateComponents(year: 2026, month: 6, day: 3, hour: 9))!
        let laterToday = calendar.date(from: DateComponents(year: 2026, month: 6, day: 3, hour: 21))!
        let deck = DeckContent(
            id: UUID(),
            title: "Test",
            avatarSystemName: nil,
            languageCode: "en",
            newCardsPerDay: 20,
            reviewCardsPerDay: 1,
            cards: [
                TestFixtures.card(id: dueNowID, word: "cat", translation: "кот"),
                TestFixtures.card(id: laterID, word: "dog", translation: "собака"),
            ]
        )
        let progressByCardID = [
            dueNowID: CardProgress(cardID: dueNowID, fsrsCard: reviewCard(due: now.addingTimeInterval(-60), now: now)),
            laterID: CardProgress(cardID: laterID, fsrsCard: reviewCard(due: laterToday, now: now)),
        ]

        let stats = DeckStatsCalculator.compute(
            deck: deck,
            progressByCardID: progressByCardID,
            dailyUsage: nil,
            now: now,
            calendar: calendar
        )

        #expect(stats.reviewDue == 1)
        #expect(stats.dueLaterToday == 0)
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

    private func reviewCard(due: Date, now: Date) -> Card {
        Card(
            due: due,
            stability: 1,
            difficulty: 1,
            reps: 1,
            state: .review,
            lastReview: now.addingTimeInterval(-86_400)
        )
    }

    private func learningCard(due: Date, now: Date) -> Card {
        Card(
            due: due,
            stability: 1,
            difficulty: 1,
            reps: 1,
            state: .learning,
            lastReview: now.addingTimeInterval(-3_600)
        )
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

    @Test("study queue samples review cards from shuffled due pool")
    func studyQueueSamplesReviewsFromShuffledPool() {
        let now = Date()
        let cards = (0..<6).map { index in
            TestFixtures.card(word: "word \(index)", translation: "перевод \(index)")
        }
        let deck = DeckContent(
            id: UUID(),
            title: "Test",
            avatarSystemName: nil,
            languageCode: "en",
            newCardsPerDay: 0,
            reviewCardsPerDay: 2,
            cards: cards
        )
        let dueCard = Card(
            due: now.addingTimeInterval(-60),
            stability: 1,
            difficulty: 1,
            reps: 1,
            state: .review,
            lastReview: now.addingTimeInterval(-86_400)
        )
        let progressByCardID = Dictionary(
            uniqueKeysWithValues: cards.map {
                ($0.id, CardProgress(cardID: $0.id, fsrsCard: dueCard))
            }
        )
        var firstRNG = SeededRNG(seed: 1)

        let firstQueue = StudyQueueBuilder.build(
            deck: deck,
            progressByCardID: progressByCardID,
            dailyUsage: nil,
            now: now,
            using: &firstRNG
        )

        #expect(firstQueue.count == 2)
        #expect(Set(firstQueue.map(\.card.id)).isSubset(of: Set(cards.map(\.id))))
        #expect(firstQueue.map(\.card.word) != ["word 0", "word 1"])
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
