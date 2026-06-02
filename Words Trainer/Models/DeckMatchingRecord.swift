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

enum MatchingRecordScope: Sendable, Hashable {
    case none
    case deck(UUID)
    case today(dayKey: String)
}

extension DeckMatchingRecord {
    var summary: MatchingRecordSummary {
        MatchingRecordSummary(bestDuration: bestDuration, pairCount: pairCount, achievedAt: achievedAt)
    }
}

struct TodayMatchingRecord: Codable, Sendable, Equatable {
    let dayKey: String
    let bestDuration: TimeInterval
    let pairCount: Int
    let achievedAt: Date

    var summary: MatchingRecordSummary {
        MatchingRecordSummary(bestDuration: bestDuration, pairCount: pairCount, achievedAt: achievedAt)
    }
}

struct TodayMatchingRecordStore {
    private static let defaultStorageKey = "todayMatchingRecordsByUser"

    private let defaults: UserDefaults
    private let storageKey: String

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = Self.defaultStorageKey
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
    }

    func record(userID: UUID, dayKey: String) -> MatchingRecordSummary? {
        guard let record = records()[userID.databaseString],
              record.dayKey == dayKey else { return nil }
        return record.summary
    }

    @discardableResult
    func saveIfBest(
        userID: UUID,
        dayKey: String,
        duration: TimeInterval,
        pairCount: Int,
        achievedAt: Date = .now
    ) -> Bool {
        var records = records()
        let key = userID.databaseString
        let existing = records[key]
        if let existing,
           existing.dayKey == dayKey,
           existing.pairCount == pairCount,
           duration >= existing.bestDuration {
            return false
        }

        records[key] = TodayMatchingRecord(
            dayKey: dayKey,
            bestDuration: duration,
            pairCount: pairCount,
            achievedAt: achievedAt
        )
        save(records)
        return true
    }

    private func records() -> [String: TodayMatchingRecord] {
        guard let data = defaults.data(forKey: storageKey),
              let records = try? JSONDecoder().decode([String: TodayMatchingRecord].self, from: data) else {
            return [:]
        }
        return records
    }

    private func save(_ records: [String: TodayMatchingRecord]) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        defaults.set(data, forKey: storageKey)
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
