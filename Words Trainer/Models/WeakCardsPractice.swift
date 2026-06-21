import Foundation

nonisolated enum WeakCardsPractice {
    /// Синтетический id для игры «Забытые слова» — у неё нет реальной колоды.
    static let deckID = UUID(uuidString: "00000000-0000-0000-0000-0000DEADBEEF")!
    static let fetchLimit = 30
    static let displayLimit = 10
    static let gamePairLimit = 12
}
