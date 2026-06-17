import Foundation

nonisolated enum StudyReviewSource: String, Codable, Sendable, Hashable {
    case todayQueue = "today_queue"
    case deckSession = "deck_session"
    case weakCards = "weak_cards"
    case todayPractice = "today_practice"
}

nonisolated struct StudyReviewEvent: Sendable, Hashable {
    let id: UUID
    let cardID: UUID
    let senseID: UUID
    let deckID: UUID
    let deckVersionID: UUID?
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
        senseID: UUID,
        deckID: UUID,
        deckVersionID: UUID? = nil,
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
        self.senseID = senseID
        self.deckID = deckID
        self.deckVersionID = deckVersionID
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

nonisolated struct PracticeReviewEvent: Sendable, Hashable {
    let id: UUID
    let cardID: UUID
    let senseID: UUID
    let deckID: UUID
    let deckVersionID: UUID?
    let mode: StudyMode
    let outcome: ReviewOutcome
    let source: StudyReviewSource
    let practicedAt: Date
    let durationMS: Int?

    init(
        id: UUID = UUID(),
        cardID: UUID,
        senseID: UUID,
        deckID: UUID,
        deckVersionID: UUID? = nil,
        mode: StudyMode,
        outcome: ReviewOutcome,
        source: StudyReviewSource,
        practicedAt: Date,
        durationMS: Int? = nil
    ) {
        self.id = id
        self.cardID = cardID
        self.senseID = senseID
        self.deckID = deckID
        self.deckVersionID = deckVersionID
        self.mode = mode
        self.outcome = outcome
        self.source = source
        self.practicedAt = practicedAt
        self.durationMS = durationMS
    }
}

nonisolated struct StudyActivityDay: Identifiable, Hashable, Sendable {
    let dayKey: String
    let reviewedCount: Int
    let passedCount: Int

    var id: String { dayKey }
    var failedCount: Int { max(0, reviewedCount - passedCount) }
    var accuracy: Double {
        reviewedCount == 0 ? 0 : Double(passedCount) / Double(reviewedCount)
    }
}

nonisolated struct StudyReviewCount: Hashable, Sendable {
    let total: Int
    let passed: Int

    static let zero = StudyReviewCount(total: 0, passed: 0)

    var failed: Int { max(0, total - passed) }
    var accuracy: Double {
        total == 0 ? 0 : Double(passed) / Double(total)
    }
}

nonisolated struct StudyTimeBreakdown: Hashable, Sendable {
    var flashcardsMilliseconds: Int
    var sentenceMilliseconds: Int
    var matchingMilliseconds: Int
    var matchingAudioMilliseconds: Int
    var pictureMilliseconds: Int

    static let zero = StudyTimeBreakdown(
        flashcardsMilliseconds: 0,
        sentenceMilliseconds: 0,
        matchingMilliseconds: 0,
        matchingAudioMilliseconds: 0,
        pictureMilliseconds: 0
    )

    var totalMilliseconds: Int {
        flashcardsMilliseconds + sentenceMilliseconds + matchingMilliseconds
            + matchingAudioMilliseconds + pictureMilliseconds
    }
}

nonisolated struct WeakCardStat: Identifiable, Hashable, Sendable {
    let cardID: UUID
    let senseID: UUID
    let deckID: UUID
    let word: String
    let translation: String
    let failedCount: Int
    let reviewedCount: Int
    let lastFailedAt: Date?

    var id: UUID { senseID }
    var failureRate: Double {
        reviewedCount == 0 ? 0 : Double(failedCount) / Double(reviewedCount)
    }
}

nonisolated struct ScheduledReviewDay: Identifiable, Hashable, Sendable {
    let dayKey: String
    let dueCount: Int

    var id: String { dayKey }
}
