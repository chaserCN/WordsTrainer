import Foundation
import FSRS

nonisolated struct StudyQueueItem: Identifiable, Sendable {
    let id: UUID
    let deckID: UUID?
    let cardID: UUID
    let senseID: UUID
    let card: WordCardContent
    let sense: WordSenseContent
    let progress: CardProgress

    init(card: WordCardContent, sense: WordSenseContent, progress: CardProgress, deckID: UUID? = nil) {
        self.id = sense.id
        self.deckID = deckID
        self.cardID = sense.cardID
        self.senseID = sense.id
        self.sense = sense
        self.card = card.focused(on: sense)
        self.progress = progress
    }

    func withDeckID(_ deckID: UUID) -> StudyQueueItem {
        StudyQueueItem(card: card, sense: sense, progress: progress, deckID: deckID)
    }
}

/// One word sense paired with one translation line in matching columns.
struct MatchingPair: Identifiable, Sendable, Hashable {
    let cardID: UUID
    let senseID: UUID
    let deckID: UUID?
    let card: WordCardContent
    let translation: String
    var progress: CardProgress

    var id: String { senseID.uuidString }

    init(
        cardID: UUID,
        senseID: UUID,
        deckID: UUID? = nil,
        card: WordCardContent,
        translation: String,
        progress: CardProgress? = nil
    ) {
        self.cardID = cardID
        self.senseID = senseID
        self.deckID = deckID
        self.card = card
        self.translation = translation
        self.progress = progress ?? CardProgress.newSense(senseID: senseID)
    }

    static func pairs(from item: StudyQueueItem) -> [MatchingPair] {
        [
            MatchingPair(
                cardID: item.cardID,
                senseID: item.senseID,
                deckID: item.deckID,
                card: item.card,
                translation: item.sense.translation,
                progress: item.progress
            ),
        ]
    }
}

nonisolated enum StudyQueueBuilder {
    static func allItems(
        cards: [WordCardContent],
        progressBySenseID: [UUID: CardProgress],
        deckID: UUID? = nil,
        now: Date = .now
    ) -> [StudyQueueItem] {
        cards.flatMap { card in
            card.activeSenses.map { sense in
                StudyQueueItem(
                    card: card,
                    sense: sense,
                    progress: progressBySenseID[sense.id] ?? CardProgress.newSense(senseID: sense.id, now: now),
                    deckID: deckID
                )
            }
        }
    }

    static func build(
        deck: DeckContent,
        progressBySenseID: [UUID: CardProgress],
        dailyUsage: DeckDailyUsage?,
        now: Date = .now
    ) -> [StudyQueueItem] {
        var rng = SystemRandomNumberGenerator()
        return build(
            deck: deck,
            progressBySenseID: progressBySenseID,
            dailyUsage: dailyUsage,
            now: now,
            using: &rng
        )
    }

    static func build<RNG: RandomNumberGenerator>(
        deck: DeckContent,
        progressBySenseID: [UUID: CardProgress],
        dailyUsage: DeckDailyUsage?,
        now: Date = .now,
        using rng: inout RNG
    ) -> [StudyQueueItem] {
        guard deck.isActive else { return [] }

        var learning: [StudyQueueItem] = []
        var review: [StudyQueueItem] = []
        // New senses grouped by card so the daily new-card budget is spent per
        // card, not per sense: a card with several senses still counts as one
        // new card and introduces all of its senses together.
        var newSensesByCardID: [UUID: [StudyQueueItem]] = [:]
        var newCardOrder: [UUID] = []

        let studiedToday = dailyUsage?.newCardsStudied ?? 0
        let newSlotsLeft = max(0, deck.newCardsPerDay - studiedToday)
        // A card due any time today is available from the start of the study day
        // (Anki-style), not only once its exact due time has passed. Without this
        // a card reviewed at, say, 18:00 yesterday reappears only after 18:00
        // today, so the queue looks empty all morning even though the day's plan
        // lists it. Compare against the end of the current study day instead of
        // the current instant.
        let studyDayEnd = StudyDay.end(for: now)

        for content in deck.activeCards {
            var cardNew: [StudyQueueItem] = []
            var cardHasDue = false

            for sense in content.activeSenses {
                let progress = progressBySenseID[sense.id]
                    ?? CardProgress.newSense(senseID: sense.id, now: now)
                let fsrs = progress.fsrsCard
                let due = ReviewSchedule.availableDate(for: fsrs.due)
                let item = StudyQueueItem(card: content, sense: sense, progress: progress)

                switch fsrs.state {
                case .new:
                    cardNew.append(item)
                case .learning, .relearning:
                    if due < studyDayEnd {
                        learning.append(item)
                        cardHasDue = true
                    }
                case .review:
                    if due < studyDayEnd {
                        review.append(item)
                        cardHasDue = true
                    }
                }
            }

            // A card's new senses only consume a daily new-card slot when the
            // card isn't already due for learning/review today. This mirrors
            // DeckStatsCalculator's per-card bucket priority (a due card is
            // counted as learning/review, not new), so the queue and the stats
            // badge agree on the card count.
            if !cardNew.isEmpty && !cardHasDue {
                newCardOrder.append(content.id)
                newSensesByCardID[content.id] = cardNew
            }
        }

        learning.shuffle(using: &rng)
        review.shuffle(using: &rng)
        newCardOrder.shuffle(using: &rng)

        let takenReview = Array(review.prefix(min(review.count, deck.reviewCardsPerDay)))
        let takenNew = newCardOrder.prefix(newSlotsLeft).flatMap { newSensesByCardID[$0] ?? [] }
        return learning + takenReview + takenNew
    }
}

extension StudyMode {
    var savesProgressByDefault: Bool {
        self != .pictureChoice
    }

    var disablesMatchingRecordScope: Bool {
        isMatching || self == .pictureChoice
    }

    var requiresImagedSenseQueue: Bool {
        self == .pictureChoice
    }

    func preparedTodayQueue<RNG: RandomNumberGenerator>(
        _ items: [StudyQueueItem],
        using rng: inout RNG
    ) -> [StudyQueueItem] {
        var queue = items
        queue.shuffle(using: &rng)
        return filteredQueue(queue)
    }

    func preparedScheduledQueue(_ items: [StudyQueueItem]) -> [StudyQueueItem] {
        let queue = filteredQueue(items)
        // The scheduled "today deck" queue emits a card's new senses as a block
        // (see StudyQueueBuilder.build), so without this they appear back-to-back.
        // Shuffle for the same modes as the deck/practice queues to spread them
        // out; ordering within a session is irrelevant to FSRS scheduling.
        return shouldShuffleDeckQueue ? queue.shuffled() : queue
    }

    func preparedPracticeQueue(_ items: [StudyQueueItem]) -> [StudyQueueItem] {
        let queue = filteredQueue(items)
        return shouldShufflePracticeQueue ? queue.shuffled() : queue
    }

    func preparedDeckQueue(_ items: [StudyQueueItem]) -> [StudyQueueItem] {
        let queue = filteredQueue(items)
        return shouldShuffleDeckQueue ? queue.shuffled() : queue
    }

    private func filteredQueue(_ items: [StudyQueueItem]) -> [StudyQueueItem] {
        guard requiresImagedSenseQueue else { return items }
        return items.filter { $0.sense.imageURL != nil }
    }

    private var shouldShufflePracticeQueue: Bool {
        isMatching || self == .recall || self == .clozeMultipleChoice || self == .clozeMultipleChoiceReverse || self == .clozeTyping || self == .translationTyping || self == .pictureChoice
    }

    private var shouldShuffleDeckQueue: Bool {
        self == .recall || self == .clozeMultipleChoice || self == .clozeMultipleChoiceReverse || self == .clozeTyping || self == .translationTyping || self == .pictureChoice
    }
}

final class StudySessionEngine: @unchecked Sendable {
    let scheduler: FSRS

    init(parameters: FSRSParameters = FSRSParameters(enableShortTerm: false)) {
        self.scheduler = FSRS(parameters: parameters)
    }

    func applyReview(
        progress: CardProgress,
        outcome: ReviewOutcome,
        now: Date = .now
    ) throws -> CardProgress {
        var updated = try BinaryFSRS.review(
            scheduler: scheduler,
            card: progress.fsrsCard,
            passed: outcome.passed,
            now: now
        )
        updated.due = ReviewSchedule.availableDate(for: updated.due)
        return CardProgress(senseID: progress.senseID, fsrsCard: updated, updatedAt: now)
    }

    func recordNewCardStudied(previous: DeckDailyUsage?) -> DeckDailyUsage {
        let key = DeckDailyUsage.todayKey()
        var usage = previous ?? DeckDailyUsage(dayKey: key)
        if usage.dayKey != key {
            usage = DeckDailyUsage(dayKey: key)
        }
        usage.newCardsStudied += 1
        return usage
    }
}
