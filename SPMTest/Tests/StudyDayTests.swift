import Foundation
import Testing
@testable import WordsTrainerLogic

@Suite("Study day")
struct StudyDayTests {
    @Test("study day rolls over at 04:00")
    func rollsOverAtFour() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let lateNight = try #require(Self.date("2026-06-04T01:30:00Z"))
        let afterRollover = try #require(Self.date("2026-06-04T04:01:00Z"))

        #expect(StudyDay.key(for: lateNight, calendar: calendar) == "2026-06-03")
        #expect(StudyDay.key(for: afterRollover, calendar: calendar) == "2026-06-04")
    }

    private static func date(_ text: String) -> Date? {
        ISO8601DateFormatter().date(from: text)
    }
}

