import Foundation

enum StudyReviewSource: String, Codable, Sendable, Hashable {
    case todayQueue = "today_queue"
    case deckSession = "deck_session"
    case weakCards = "weak_cards"
    case todayPractice = "today_practice"
}

struct StudyReviewEvent: Sendable, Hashable {
    let id: UUID
    let cardID: UUID
    let deckID: UUID
    let mode: StudyMode
    let outcome: ReviewOutcome
    let source: StudyReviewSource
    let reviewedAt: Date
    let durationMS: Int?
    let wasNew: Bool
    let previousState: String
    let newState: String

    init(
        id: UUID = UUID(),
        cardID: UUID,
        deckID: UUID,
        mode: StudyMode,
        outcome: ReviewOutcome,
        source: StudyReviewSource = .deckSession,
        reviewedAt: Date,
        durationMS: Int? = nil,
        wasNew: Bool,
        previousState: String,
        newState: String
    ) {
        self.id = id
        self.cardID = cardID
        self.deckID = deckID
        self.mode = mode
        self.outcome = outcome
        self.source = source
        self.reviewedAt = reviewedAt
        self.durationMS = durationMS
        self.wasNew = wasNew
        self.previousState = previousState
        self.newState = newState
    }
}

struct StudyActivityDay: Identifiable, Hashable {
    let dayKey: String
    let reviewedCount: Int
    let passedCount: Int

    var id: String { dayKey }
    var failedCount: Int { max(0, reviewedCount - passedCount) }
    var accuracy: Double {
        reviewedCount == 0 ? 0 : Double(passedCount) / Double(reviewedCount)
    }
}

struct StudyReviewCount: Hashable {
    let total: Int
    let passed: Int

    static let zero = StudyReviewCount(total: 0, passed: 0)

    var failed: Int { max(0, total - passed) }
    var accuracy: Double {
        total == 0 ? 0 : Double(passed) / Double(total)
    }
}

struct WeakCardStat: Identifiable, Hashable {
    let cardID: UUID
    let deckID: UUID
    let word: String
    let translation: String
    let failedCount: Int
    let reviewedCount: Int
    let lastFailedAt: Date?

    var id: UUID { cardID }
    var failureRate: Double {
        reviewedCount == 0 ? 0 : Double(failedCount) / Double(reviewedCount)
    }
}

struct ScheduledReviewDay: Identifiable, Hashable {
    let dayKey: String
    let dueCount: Int

    var id: String { dayKey }
}
