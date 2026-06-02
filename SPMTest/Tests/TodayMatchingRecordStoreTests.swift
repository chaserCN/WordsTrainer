import Foundation
import Testing
@testable import WordsTrainerLogic

@Suite("Today matching record store")
struct TodayMatchingRecordStoreTests {
    @Test("records are scoped by user and current day")
    func recordsAreScopedByUserAndCurrentDay() throws {
        let suiteName = "today-matching-records-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let store = TodayMatchingRecordStore(defaults: defaults, storageKey: "records")
        let firstUser = UUID()
        let secondUser = UUID()

        let didSaveFirst = store.saveIfBest(
            userID: firstUser,
            dayKey: "2026-06-02",
            duration: 40,
            pairCount: 12
        )
        let didSaveSlower = store.saveIfBest(
            userID: firstUser,
            dayKey: "2026-06-02",
            duration: 45,
            pairCount: 12
        )
        let didSaveSecondUser = store.saveIfBest(
            userID: secondUser,
            dayKey: "2026-06-02",
            duration: 50,
            pairCount: 12
        )

        #expect(didSaveFirst)
        #expect(!didSaveSlower)
        #expect(didSaveSecondUser)
        #expect(store.record(userID: firstUser, dayKey: "2026-06-02")?.bestDuration == 40)
        #expect(store.record(userID: secondUser, dayKey: "2026-06-02")?.bestDuration == 50)
        #expect(store.record(userID: firstUser, dayKey: "2026-06-03") == nil)
    }

    @Test("different pair count replaces current day record")
    func differentPairCountReplacesCurrentDayRecord() throws {
        let suiteName = "today-matching-records-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let store = TodayMatchingRecordStore(defaults: defaults, storageKey: "records")
        let userID = UUID()

        _ = store.saveIfBest(userID: userID, dayKey: "2026-06-02", duration: 30, pairCount: 6)
        let didReplace = store.saveIfBest(
            userID: userID,
            dayKey: "2026-06-02",
            duration: 60,
            pairCount: 12
        )

        let record = try #require(store.record(userID: userID, dayKey: "2026-06-02"))
        #expect(didReplace)
        #expect(record.bestDuration == 60)
        #expect(record.pairCount == 12)
    }
}
