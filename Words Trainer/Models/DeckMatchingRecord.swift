import Foundation

/// Best matching-columns time for a deck (same `pair_count` as when the record was set).
struct DeckMatchingRecord: Sendable, Equatable {
    let deckID: UUID
    let bestDuration: TimeInterval
    let pairCount: Int
    let achievedAt: Date
}

struct MatchingRecordSummary: Sendable, Equatable {
    let bestDuration: TimeInterval
    let pairCount: Int
    let achievedAt: Date
}

struct MatchingAttemptEvent: Sendable, Equatable {
    let id: UUID
    let deckID: UUID?
    let mode: StudyMode
    let source: StudyReviewSource
    let completedAt: Date
    let duration: TimeInterval
    let pairCount: Int

    init(
        id: UUID = UUID(),
        deckID: UUID?,
        mode: StudyMode,
        source: StudyReviewSource,
        completedAt: Date = .now,
        duration: TimeInterval,
        pairCount: Int
    ) {
        self.id = id
        self.deckID = deckID
        self.mode = mode
        self.source = source
        self.completedAt = completedAt
        self.duration = duration
        self.pairCount = pairCount
    }
}

enum MatchingRecordScope: Sendable, Hashable {
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
