import Foundation

/// Best matching-columns time for a deck (same `pair_count` as when the record was set).
nonisolated struct DeckMatchingRecord: Sendable, Equatable {
    let deckID: UUID
    let deckVersionID: UUID?
    let bestDuration: TimeInterval
    let pairCount: Int
    let achievedAt: Date

    init(
        deckID: UUID,
        deckVersionID: UUID? = nil,
        bestDuration: TimeInterval,
        pairCount: Int,
        achievedAt: Date
    ) {
        self.deckID = deckID
        self.deckVersionID = deckVersionID
        self.bestDuration = bestDuration
        self.pairCount = pairCount
        self.achievedAt = achievedAt
    }
}

nonisolated struct MatchingRecordSummary: Sendable, Equatable {
    let bestDuration: TimeInterval
    let pairCount: Int
    let achievedAt: Date
}

nonisolated struct MatchingAttemptEvent: Sendable, Equatable {
    let id: UUID
    let deckID: UUID?
    let deckVersionID: UUID?
    let mode: StudyMode
    let source: StudyReviewSource
    let completedAt: Date
    let duration: TimeInterval
    let pairCount: Int

    init(
        id: UUID = UUID(),
        deckID: UUID?,
        deckVersionID: UUID? = nil,
        mode: StudyMode,
        source: StudyReviewSource,
        completedAt: Date = .now,
        duration: TimeInterval,
        pairCount: Int
    ) {
        self.id = id
        self.deckID = deckID
        self.deckVersionID = deckVersionID
        self.mode = mode
        self.source = source
        self.completedAt = completedAt
        self.duration = duration
        self.pairCount = pairCount
    }
}

nonisolated enum MatchingRecordScope: Sendable, Hashable {
    case none
    case deck(UUID)
}

extension DeckMatchingRecord {
    var summary: MatchingRecordSummary {
        MatchingRecordSummary(bestDuration: bestDuration, pairCount: pairCount, achievedAt: achievedAt)
    }
}

enum StudyDurationFormat {
    static func string(_ duration: TimeInterval) -> String {
        let totalSeconds = max(0, Int(duration.rounded(.down)))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
