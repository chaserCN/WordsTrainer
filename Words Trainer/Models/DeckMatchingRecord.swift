import Foundation

/// Best matching-columns time for a deck (same `pair_count` as when the record was set).
struct DeckMatchingRecord: Sendable, Equatable {
    let deckID: UUID
    let bestDuration: TimeInterval
    let pairCount: Int
    let achievedAt: Date
}

enum StudyDurationFormat {
    static func string(_ duration: TimeInterval) -> String {
        let totalSeconds = max(0, Int(duration.rounded(.down)))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
