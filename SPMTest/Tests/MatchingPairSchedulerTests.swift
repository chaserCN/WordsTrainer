import Foundation
import Testing
@testable import WordsTrainerLogic

@Suite("MatchingPairScheduler")
struct MatchingPairSchedulerTests {
    // MARK: - Empty and single-pair edge cases

    @Test("empty pool starts finished with zero remaining")
    func emptyPool() {
        let scheduler = TestFixtures.scheduler(pairs: [], seed: 1)
        #expect(scheduler.isFinished)
        #expect(scheduler.remainingCount == 0)
        #expect(scheduler.visible.isEmpty)
    }

    @Test("single pair is visible and finishes after one match")
    func singlePair() {
        var scheduler = TestFixtures.scheduler(cards: [("dog", "собака")], seed: 1)
        #expect(scheduler.remainingCount == 1)
        #expect(scheduler.visible.count == 1)
        #expect(!scheduler.isFinished)

        var rng = SeededRNG(seed: 2)
        scheduler.removeMatched(id: scheduler.visible[0].id, rng: &rng)

        #expect(scheduler.isFinished)
        #expect(scheduler.remainingCount == 0)
        #expect(scheduler.visible.isEmpty)
    }

    // MARK: - Remaining count (status)

    @Test("remaining count equals total pairs at start")
    func remainingCountAtStart() {
        let cards: [(String, String)] = [
            ("cast", "бросать; кидать; метать"),
            ("run", "бежать"),
            ("dog", "собака; пёс"),
        ]
        let scheduler = TestFixtures.scheduler(cards: cards, seed: 7)
        #expect(scheduler.remainingCount == TestFixtures.totalPairCount(for: cards))
        #expect(scheduler.remainingCount == 6)
    }

    @Test("remaining count drops by one after each match")
    func remainingCountDecrements() {
        let cards: [(String, String)] = [
            ("a", "1"),
            ("b", "2; 3"),
            ("c", "4"),
        ]
        var scheduler = TestFixtures.scheduler(cards: cards, seed: 11)
        var rng = SeededRNG(seed: 12)
        var expected = scheduler.remainingCount

        while !scheduler.isFinished {
            #expect(scheduler.remainingCount == expected)
            guard let id = scheduler.visible.first?.id else { break }
            scheduler.removeMatched(id: id, rng: &rng)
            expected -= 1
        }

        #expect(scheduler.remainingCount == 0)
    }

    @Test("remaining count always equals visible plus pool")
    func remainingCountInvariant() {
        let cards: [(String, String)] = [
            ("cast", "бросать; кидать; метать"),
            ("run", "бежать; бегать"),
            ("dog", "собака"),
        ]
        var scheduler = TestFixtures.scheduler(cards: cards, seed: 21)
        var rng = SeededRNG(seed: 22)

        while !scheduler.isFinished {
            #expect(scheduler.remainingCount == scheduler.visible.count + scheduler.pool.count)
            guard let id = scheduler.visible.first?.id else { break }
            scheduler.removeMatched(id: id, rng: &rng)
        }
    }

    // MARK: - Same-word constraint

    @Test("multi-sense card shows at most one pair on screen")
    func singleCardMultipleSenses() {
        let cardID = UUID()
        let pairs = TestFixtures.pairs(word: "cast", translation: "бросать; кидать; метать", id: cardID)
        let scheduler = TestFixtures.scheduler(pairs: pairs, seed: 3)

        #expect(scheduler.visible.count == 1)
        #expect(scheduler.visible[0].cardID == cardID)
        #expect(scheduler.remainingCount == 3)
        #expect(scheduler.visibleCardIDsAreUnique)
    }

    @Test("two cards with two senses each show at most two pairs")
    func twoCardsTwoSensesEach() {
        let cards: [(String, String)] = [
            ("cast", "бросать; кидать"),
            ("run", "бежать; бегать"),
        ]
        let scheduler = TestFixtures.scheduler(cards: cards, seed: 5)

        #expect(scheduler.visible.count == 2)
        #expect(scheduler.visibleCardIDsAreUnique)
        #expect(scheduler.remainingCount == 4)
    }

    @Test("same-word constraint holds through entire session")
    func sameWordConstraintThroughoutSession() {
        let cards: [(String, String)] = [
            ("cast", "бросать; кидать; метать"),
            ("run", "бежать; бегать"),
        ]
        var scheduler = TestFixtures.scheduler(cards: cards, seed: 31)
        var rng = SeededRNG(seed: 32)

        while !scheduler.isFinished {
            #expect(scheduler.visibleCardIDsAreUnique)
            guard let id = scheduler.visible.first?.id else { break }
            scheduler.removeMatched(id: id, rng: &rng)
        }
    }

    @Test("same lemma from different cards is not visible together")
    func sameLemmaFromDifferentCardsIsNotVisibleTogether() {
        let first = TestFixtures.card(
            word: "load (noun)",
            lemma: "load",
            translation: "груз"
        )
        let second = TestFixtures.card(
            word: "to load",
            lemma: "load",
            translation: "загружать"
        )
        let third = TestFixtures.card(
            word: "to run",
            lemma: "run",
            translation: "бежать"
        )
        let pairs = [first, second, third].flatMap { MatchingPair.pairs(from: TestFixtures.queueItem(card: $0)) }
        var scheduler = TestFixtures.scheduler(pairs: pairs, seed: 71)
        var rng = SeededRNG(seed: 72)

        while !scheduler.isFinished {
            #expect(scheduler.visibleLemmasAreUnique)
            guard let id = scheduler.visible.first?.id else { break }
            scheduler.removeMatched(id: id, rng: &rng)
        }
    }

    @Test("after matching one sense, only one sibling sense appears next")
    func refillShowsNextSenseOneAtATime() {
        var scheduler = TestFixtures.scheduler(
            cards: [("cast", "бросать; кидать; метать")],
            seed: 41
        )
        #expect(scheduler.visible.count == 1)
        #expect(scheduler.pool.count == 2)
        #expect(scheduler.remainingCount == 3)

        var rng = SeededRNG(seed: 42)
        scheduler.removeMatched(id: scheduler.visible[0].id, rng: &rng)

        #expect(scheduler.visible.count == 1)
        #expect(scheduler.pool.count == 1)
        #expect(scheduler.remainingCount == 2)
        #expect(scheduler.visibleCardIDsAreUnique)
        #expect(scheduler.visibleLemmasAreUnique)
    }

    // MARK: - Slot filling

    @Test("five unique single-sense cards fill all slots")
    func fiveUniqueCardsFillSlots() {
        let cards: [(String, String)] = [
            ("a", "1"),
            ("b", "2"),
            ("c", "3"),
            ("d", "4"),
            ("e", "5"),
        ]
        let scheduler = TestFixtures.scheduler(cards: cards, seed: 8)

        #expect(scheduler.visible.count == MatchingPairScheduler.slotCount)
        #expect(scheduler.visibleCardIDsAreUnique)
        #expect(scheduler.visibleLemmasAreUnique)
        #expect(scheduler.remainingCount == 5)
        #expect(scheduler.pool.isEmpty)
    }

    @Test("more than five unique cards leave remainder in pool")
    func sixCardsLeavePool() {
        let cards: [(String, String)] = [
            ("a", "1"),
            ("b", "2"),
            ("c", "3"),
            ("d", "4"),
            ("e", "5"),
            ("f", "6"),
        ]
        let scheduler = TestFixtures.scheduler(cards: cards, seed: 9)

        #expect(scheduler.visible.count == 5)
        #expect(scheduler.pool.count == 1)
        #expect(scheduler.remainingCount == 6)
        #expect(scheduler.visibleCardIDsAreUnique)
        #expect(scheduler.visibleLemmasAreUnique)
    }

    @Test("three cards with two senses each cap visible at three")
    func sixPairsThreeCardsCapVisibleAtThree() {
        let cards: [(String, String)] = [
            ("a", "1; 2"),
            ("b", "3; 4"),
            ("c", "5; 6"),
        ]
        let scheduler = TestFixtures.scheduler(cards: cards, seed: 10)

        #expect(scheduler.visible.count == 3)
        #expect(scheduler.pool.count == 3)
        #expect(scheduler.remainingCount == 6)
        #expect(scheduler.visibleCardIDsAreUnique)
        #expect(scheduler.visibleLemmasAreUnique)
    }

    // MARK: - Pick next / remove edge cases

    @Test("removeMatched with unknown id is a no-op")
    func removeUnknownId() {
        var scheduler = TestFixtures.scheduler(cards: [("dog", "собака")], seed: 13)
        let beforeVisible = scheduler.visible
        let beforePool = scheduler.pool
        let beforeRemaining = scheduler.remainingCount

        var rng = SeededRNG(seed: 14)
        scheduler.removeMatched(id: "missing-id", rng: &rng)

        #expect(scheduler.visible == beforeVisible)
        #expect(scheduler.pool == beforePool)
        #expect(scheduler.remainingCount == beforeRemaining)
    }

    @Test("deterministic seed produces stable initial layout")
    func deterministicInitialLayout() {
        let castID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let runID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let dogID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        let cards: [(word: String, translation: String, id: UUID)] = [
            ("cast", "бросать; кидать", castID),
            ("run", "бежать", runID),
            ("dog", "собака", dogID),
        ]
        let first = TestFixtures.scheduler(cards: cards, seed: 100)
        let second = TestFixtures.scheduler(cards: cards, seed: 100)

        #expect(first.visible.map(\.id) == second.visible.map(\.id))
        #expect(first.pool.map(\.id) == second.pool.map(\.id))
    }

    @Test("different seeds can produce different initial layouts")
    func differentSeedsCanDiffer() {
        let cards: [(String, String)] = [
            ("a", "1"),
            ("b", "2"),
            ("c", "3"),
            ("d", "4"),
            ("e", "5"),
        ]
        let layouts = (0..<20).map { seed in
            TestFixtures.scheduler(cards: cards, seed: UInt64(seed)).visible.map(\.id)
        }
        #expect(Set(layouts).count > 1)
    }

    // MARK: - Full session completion

    @Test("matching all pairs leaves scheduler finished with zero remaining")
    func fullSessionCompletion() {
        let cards: [(String, String)] = [
            ("cast", "бросать; кидать; метать"),
            ("run", "бежать; бегать"),
            ("dog", "собака"),
        ]
        var scheduler = TestFixtures.scheduler(cards: cards, seed: 51)
        TestFixtures.matchAllDeterministically(&scheduler, seed: 52)

        #expect(scheduler.isFinished)
        #expect(scheduler.remainingCount == 0)
        #expect(scheduler.visible.isEmpty)
        #expect(scheduler.pool.isEmpty)
    }

    @Test("every input pair appears exactly once before being matched")
    func pairConservation() {
        let castID = UUID(uuidString: "00000000-0000-0000-0000-000000000011")!
        let runID = UUID(uuidString: "00000000-0000-0000-0000-000000000012")!
        let cards: [(word: String, translation: String, id: UUID)] = [
            ("cast", "бросать; кидать", castID),
            ("run", "бежать; бегать", runID),
        ]
        let allIDs = Set(cards.flatMap { TestFixtures.pairs(word: $0.word, translation: $0.translation, id: $0.id).map(\.id) })
        var scheduler = TestFixtures.scheduler(cards: cards, seed: 61)
        var rng = SeededRNG(seed: 62)
        var matched: [String] = []

        while !scheduler.isFinished {
            let onScreen = Set(scheduler.visible.map(\.id))
            #expect(onScreen.isSubset(of: allIDs))
            guard let id = scheduler.visible.first?.id else { break }
            matched.append(id)
            scheduler.removeMatched(id: id, rng: &rng)
        }

        #expect(Set(matched) == allIDs)
        #expect(matched.count == allIDs.count)
    }

    // MARK: - Property-style invariant across seeds

    @Test("invariants hold across many random seeds")
    func invariantsAcrossSeeds() {
        let cards: [(String, String)] = [
            ("cast", "бросать; кидать; метать"),
            ("run", "бежать; бегать"),
            ("dog", "собака; пёс"),
            ("cat", "кот"),
        ]
        let total = TestFixtures.totalPairCount(for: cards)

        for seed in 0..<100 {
            var scheduler = TestFixtures.scheduler(cards: cards, seed: UInt64(seed))
            #expect(scheduler.remainingCount == total)
            #expect(scheduler.visible.count <= MatchingPairScheduler.slotCount)
            #expect(scheduler.visibleCardIDsAreUnique)
            #expect(scheduler.visibleLemmasAreUnique)

            var rng = SeededRNG(seed: UInt64(seed &+ 1000))
            var steps = total
            while !scheduler.isFinished, steps > 0 {
                #expect(scheduler.remainingCount == scheduler.visible.count + scheduler.pool.count)
                #expect(scheduler.visibleCardIDsAreUnique)
                #expect(scheduler.visibleLemmasAreUnique)
                #expect(scheduler.visible.count <= MatchingPairScheduler.slotCount)

                guard let id = scheduler.visible.first?.id else { break }
                scheduler.removeMatched(id: id, rng: &rng)
                steps -= 1
            }

            #expect(scheduler.isFinished)
            #expect(scheduler.remainingCount == 0)
        }
    }
}

@Suite("StudySession matching integration")
struct StudySessionMatchingTests {
    @Test("StudySession remaining count mirrors scheduler")
    @MainActor
    func sessionRemainingCount() {
        let card = TestFixtures.card(word: "cast", translation: "бросать; кидать; метать")
        let session = TestFixtures.matchingSession(cards: [card])
        #expect(session.remainingCount == 3)
        #expect(session.matchingVisibleItems.count == 1)
    }

    @Test("StudySession finishes after all pairs matched")
    @MainActor
    func sessionFinishes() {
        let cards = [
            TestFixtures.card(word: "a", translation: "1"),
            TestFixtures.card(word: "b", translation: "2; 3"),
        ]
        let session = TestFixtures.matchingSession(cards: cards)

        while !session.isFinished {
            guard let pair = session.matchingVisibleItems.first else { break }
            session.removeMatchedPair(id: pair.id)
        }

        #expect(session.isFinished)
        #expect(session.remainingCount == 0)
    }

    @Test("matching wrong selections do not mutate FSRS progress")
    @MainActor
    func matchingWrongSelectionsDoNotMutateProgress() throws {
        let card = TestFixtures.card(word: "cast", translation: "бросать; кидать")
        let session = TestFixtures.matchingSession(cards: [card])
        let pair = try #require(session.matchingVisibleItems.first)
        let before = pair.progress.fsrsCard

        session.removeMatchedPair(id: pair.id)
        let nextPair = try #require(session.matchingVisibleItems.first)

        #expect(nextPair.progress.fsrsCard == before)
    }

    @Test("practice matching does not mutate FSRS progress")
    @MainActor
    func practiceMatchingDoesNotMutateProgress() throws {
        let deckID = UUID()
        let card = TestFixtures.card(word: "cast", translation: "бросать; кидать")
        let progress = CardProgress.newCard(cardID: card.id)
        let session = StudySession(
            deckID: UUID(),
            mode: .matching,
            queue: [StudyQueueItem(card: card, progress: progress, deckID: deckID)],
            dailyUsage: nil,
            engine: StudySessionEngine(),
            savesProgress: false
        )
        let pair = try #require(session.matchingVisibleItems.first)

        session.removeMatchedPair(id: pair.id)
        let nextPair = try #require(session.matchingVisibleItems.first)

        #expect(nextPair.progress.fsrsCard == progress.fsrsCard)
    }

    @Test("non-matching mode uses queue for remaining count")
    @MainActor
    func nonMatchingRemainingCount() {
        let cards = [
            TestFixtures.card(word: "a", translation: "1"),
            TestFixtures.card(word: "b", translation: "2"),
        ]
        let session = StudySession(
            deckID: UUID(),
            mode: .recall,
            queue: cards.map { TestFixtures.queueItem(card: $0) },
            dailyUsage: nil,
            engine: StudySessionEngine()
        )
        #expect(session.remainingCount == 2)
        #expect(session.matchingVisibleItems.isEmpty)
    }
}
