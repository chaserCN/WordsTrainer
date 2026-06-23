import Foundation
import FSRS
import Testing
@testable import WordsTrainerLogic

@Suite("Today study session builder")
struct TodayStudySessionBuilderTests {
    @Test(
        "study mode session policies are centralized",
        arguments: StudyMode.allCases
    )
    func studyModeSessionPolicies(mode: StudyMode) {
        #expect(mode.savesProgressByDefault == (mode != .pictureChoice))
        #expect(mode.requiresImagedSenseQueue == (mode == .pictureChoice))
        #expect(mode.disablesMatchingRecordScope == (mode.isMatching || mode == .pictureChoice))
    }

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
                    TodayStudyDeckSnapshot(deck: firstDeck, progressBySenseID: [:], dailyUsage: nil),
                    TodayStudyDeckSnapshot(deck: secondDeck, progressBySenseID: [:], dailyUsage: nil),
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

    @Test("new-card budget counts distinct cards, not senses")
    func newCardBudgetCountsDistinctCards() {
        // Four brand-new cards, each carrying two senses (8 new senses total).
        let cards = (0..<4).map { index in
            TestFixtures.card(word: "word-\(index)", translation: "sense-a; sense-b")
        }
        for card in cards {
            #expect(card.activeSenses.count == 2)
        }
        let studyDeck = deck(title: "New", newCardsPerDay: 2, cards: cards)
        var rng = SeededRNG(seed: 11)

        let queue = StudyQueueBuilder.build(
            deck: studyDeck,
            progressBySenseID: [:],
            dailyUsage: nil,
            using: &rng
        )

        // The budget of 2 should admit exactly 2 distinct cards, with all of
        // their senses, rather than 2 senses cut across cards.
        let distinctCards = Set(queue.map(\.cardID))
        #expect(distinctCards.count == 2)
        #expect(queue.count == 4)
        // Each admitted card contributes both of its senses.
        for cardID in distinctCards {
            #expect(queue.filter { $0.cardID == cardID }.count == 2)
        }
    }

    @Test("a card already due is not also counted against the new-card budget")
    func dueCardDoesNotConsumeNewBudget() {
        // Pin to daytime: a due time inside quiet hours (22:00–08:00) is pushed
        // forward by ReviewSchedule.availableDate, which would otherwise make
        // this test flaky depending on the wall-clock hour it runs at.
        let now = Calendar.current.date(from: DateComponents(year: 2026, month: 6, day: 3, hour: 12))!
        // Card with two senses: one already due for review, one still new.
        let mixedCard = TestFixtures.card(word: "cast", translation: "бросать; гипс")
        let dueSense = mixedCard.activeSenses[0]
        let dueCard = Card(
            due: now.addingTimeInterval(-60),
            stability: 1,
            difficulty: 1,
            reps: 1,
            state: .review,
            lastReview: now.addingTimeInterval(-86_400)
        )
        let progressBySenseID = [
            dueSense.id: CardProgress(senseID: dueSense.id, fsrsCard: dueCard),
        ]
        // A second, purely-new card competes for the single new-card slot.
        let newCard = TestFixtures.card(word: "word", translation: "слово")
        let studyDeck = deck(title: "Mixed", newCardsPerDay: 1, cards: [mixedCard, newCard])
        var rng = SeededRNG(seed: 3)

        let queue = StudyQueueBuilder.build(
            deck: studyDeck,
            progressBySenseID: progressBySenseID,
            dailyUsage: nil,
            now: now,
            using: &rng
        )

        // The mixed card rides in as a review (its new sibling sense stays
        // deferred and does not eat the slot), so the lone new slot goes to the
        // purely-new card. The queue's distinct-card count matches DeckStats.
        let stats = DeckStatsCalculator.compute(
            deck: studyDeck,
            progressBySenseID: progressBySenseID,
            dailyUsage: nil,
            now: now
        )
        #expect(Set(queue.map { $0.cardID }).count == stats.studyTotal)
        #expect(stats.reviewDue == 1)
        #expect(stats.newAvailable == 1)
        #expect(queue.contains { $0.senseID == dueSense.id })
        #expect(queue.contains { $0.cardID == newCard.id })
        // The mixed card's new sibling is not introduced today.
        #expect(!queue.contains { $0.cardID == mixedCard.id && $0.senseID != dueSense.id })
    }

    @Test("deck choice pool keeps each sense example focused")
    @MainActor
    func deckChoicePoolKeepsSenseExamplesFocused() throws {
        let cardID = UUID()
        let noiseSenseID = UUID()
        let nervesSenseID = UUID()
        let card = WordCardContent(
            id: cardID,
            word: "to rattle",
            lemma: "rattle",
            partOfSpeech: "verb",
            primarySenseID: noiseSenseID,
            senses: [
                WordSenseContent(
                    id: noiseSenseID,
                    cardID: cardID,
                    status: .active,
                    displayPattern: "to rattle",
                    translation: "дребезжать",
                    note: nil,
                    imageURL: nil,
                    example: SenseExampleContent(
                        text: "The old windows rattle.",
                        translation: "Старые окна дребезжат.",
                        note: nil
                    ),
                    sentenceQuestion: SentenceQuestionContent(
                        template: "The old windows {{blank}}.",
                        answer: "rattle",
                        answerFormKey: "base",
                        audioAnswerURL: nil
                    ),
                    distractors: []
                ),
                WordSenseContent(
                    id: nervesSenseID,
                    cardID: cardID,
                    status: .active,
                    displayPattern: "to rattle someone",
                    translation: "нервировать",
                    note: nil,
                    imageURL: nil,
                    example: SenseExampleContent(
                        text: "The sudden question rattled him.",
                        translation: "Неожиданный вопрос выбил его из равновесия.",
                        note: nil
                    ),
                    sentenceQuestion: SentenceQuestionContent(
                        template: "The sudden question {{blank}} him.",
                        answer: "rattled",
                        answerFormKey: "past",
                        audioAnswerURL: nil
                    ),
                    distractors: []
                ),
            ]
        )
        let session = StudySession(
            deckID: UUID(),
            mode: .clozeMultipleChoice,
            queue: [StudyQueueBuilder.allItems(cards: [card], progressBySenseID: [:])[0]],
            deckCards: [card],
            dailyUsage: nil,
            engine: StudySessionEngine()
        )

        let poolBySenseID = Dictionary(uniqueKeysWithValues: session.deckChoicePool.map { card in
            (card.primarySenseID, card)
        })

        #expect(session.deckChoicePool.count == 2)
        #expect(poolBySenseID[noiseSenseID]?.word == "to rattle")
        #expect(poolBySenseID[noiseSenseID]?.clozeExamplePlainText == "The old windows rattle.")
        #expect(poolBySenseID[nervesSenseID]?.word == "to rattle someone")
        #expect(poolBySenseID[nervesSenseID]?.clozeExamplePlainText == "The sudden question rattled him.")
    }

    @Test("today practice session uses only cards reviewed today")
    @MainActor
    func todayPracticeUsesReviewedCardsOnly() throws {
        let reviewedCard = TestFixtures.card(word: "cat", translation: "кот")
        let untouchedCard = TestFixtures.card(word: "dog", translation: "собака")
        let reviewedSense = try #require(reviewedCard.primarySense)
        let activeDeck = deck(title: "Active", cards: [reviewedCard, untouchedCard])
        let inactiveDeck = deck(status: .inactive, title: "Inactive", cards: [
            TestFixtures.card(word: "bird", translation: "птица"),
        ])
        let inactiveSenseIDs = inactiveDeck.cards.flatMap { $0.activeSenses.map(\.id) }
        let snapshots = [
            TodayStudyDeckSnapshot(
                deck: activeDeck,
                progressBySenseID: [:],
                dailyUsage: nil,
                reviewedSenseIDs: [reviewedSense.id]
            ),
            TodayStudyDeckSnapshot(
                deck: inactiveDeck,
                progressBySenseID: [:],
                dailyUsage: nil,
                reviewedSenseIDs: inactiveSenseIDs
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

    @Test("picture-choice today session keeps only imaged senses and skips progress")
    @MainActor
    func pictureChoiceTodaySessionFiltersImagedSenses() throws {
        let imagedCard = TestFixtures.card(
            word: "apple",
            translation: "яблоко",
            imageURL: URL(string: "https://example.com/apple.png")
        )
        let plainCard = TestFixtures.card(word: "stone", translation: "камень")
        let activeDeck = deck(title: "Images", cards: [imagedCard, plainCard])
        var rng = SeededRNG(seed: 17)

        let session = try #require(
            TodayStudySessionBuilder.todaySession(
                snapshots: [
                    TodayStudyDeckSnapshot(deck: activeDeck, progressBySenseID: [:], dailyUsage: nil),
                ],
                mode: .pictureChoice,
                dayKey: "2026-06-02",
                engine: StudySessionEngine(),
                using: &rng
            )
        )

        #expect(session.queue.map(\.card.id) == [imagedCard.id])
        #expect(session.savesProgress == false)
        #expect(session.matchingRecordScope == .none)
    }

    @Test("picture-choice practice session returns nil when reviewed senses have no images")
    @MainActor
    func pictureChoicePracticeRequiresImages() throws {
        let reviewedCard = TestFixtures.card(word: "stone", translation: "камень")
        let reviewedSense = try #require(reviewedCard.primarySense)
        let activeDeck = deck(title: "No images", cards: [reviewedCard])

        let session = TodayStudySessionBuilder.todayPracticeSession(
            snapshots: [
                TodayStudyDeckSnapshot(
                    deck: activeDeck,
                    progressBySenseID: [:],
                    dailyUsage: nil,
                    reviewedSenseIDs: [reviewedSense.id]
                ),
            ],
            mode: .pictureChoice,
            dayKey: "2026-06-02",
            engine: StudySessionEngine()
        )

        #expect(session == nil)
    }

    @Test("deck practice session does not keep a matching record scope")
    @MainActor
    func deckPracticeDoesNotKeepMatchingRecordScope() throws {
        let reviewedCard = TestFixtures.card(word: "cat", translation: "кот")
        let reviewedSense = try #require(reviewedCard.primarySense)
        let sourceDeck = deck(title: "Deck", cards: [reviewedCard])
        let snapshot = TodayStudyDeckSnapshot(
            deck: sourceDeck,
            progressBySenseID: [:],
            dailyUsage: nil,
            reviewedSenseIDs: [reviewedSense.id]
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
                    TodayStudyDeckSnapshot(deck: firstDeck, progressBySenseID: [:], dailyUsage: nil),
                    TodayStudyDeckSnapshot(deck: secondDeck, progressBySenseID: [:], dailyUsage: nil),
                    TodayStudyDeckSnapshot(deck: inactiveDeck, progressBySenseID: [:], dailyUsage: nil),
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
            TodayStudyDeckSnapshot(deck: activeDeck, progressBySenseID: [:], dailyUsage: nil),
            TodayStudyDeckSnapshot(deck: inactiveDeck, progressBySenseID: [:], dailyUsage: nil),
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
            snapshots: [TodayStudyDeckSnapshot(deck: activeDeck, progressBySenseID: [:], dailyUsage: nil)],
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
                    TodayStudyDeckSnapshot(deck: sourceDeck, progressBySenseID: [:], dailyUsage: nil),
                ],
                cards: selected,
                mode: .flashcards,
                engine: StudySessionEngine()
            )
        )

        #expect(session.queue.map(\.card.id) == selected.map(\.id))
        #expect(session.queue.compactMap(\.deckID) == [sourceDeck.id, sourceDeck.id, sourceDeck.id])
    }

    @Test("random picture-choice session keeps only imaged senses and skips progress")
    @MainActor
    func randomPictureChoiceSessionFiltersImagedSenses() throws {
        let imagedCard = TestFixtures.card(
            word: "apple",
            translation: "яблоко",
            imageURL: URL(string: "https://example.com/apple.png")
        )
        let plainCard = TestFixtures.card(word: "stone", translation: "камень")
        let sourceDeck = deck(title: "Images", cards: [imagedCard, plainCard])

        let session = try #require(
            RandomStudySessionBuilder.session(
                snapshots: [
                    TodayStudyDeckSnapshot(deck: sourceDeck, progressBySenseID: [:], dailyUsage: nil),
                ],
                cards: [plainCard, imagedCard],
                mode: .pictureChoice,
                engine: StudySessionEngine()
            )
        )

        #expect(session.queue.map(\.card.id) == [imagedCard.id])
        #expect(session.savesProgress == false)
        #expect(session.matchingRecordScope == .none)
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
