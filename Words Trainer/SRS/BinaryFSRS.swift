import Foundation
import FSRS

/// Binary outcomes → FSRS ratings (Again / Good only).
enum BinaryFSRS {
    static func rating(passed: Bool) -> Rating {
        passed ? .good : .again
    }

    static func review(
        scheduler: FSRS,
        card: Card,
        passed: Bool,
        now: Date = .now
    ) throws -> Card {
        try scheduler.next(card: card, now: now, grade: rating(passed: passed)).card
    }
}
