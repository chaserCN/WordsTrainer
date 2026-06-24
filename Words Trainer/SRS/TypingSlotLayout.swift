import Foundation

/// Pure, View-free layout logic for the typing answer row ("Письмо").
///
/// The answer is shown as a row of underscore "slots" — one per fillable letter
/// — with separator slots standing in for spaces between words. When the row is
/// too long for one line we wrap to a second line. The wrap point must be
/// computed deterministically from the *word structure* (which never changes as
/// the user types), not by the system's greedy word-wrap, otherwise the break
/// jumps between word boundaries on every keystroke as the row width wobbles.
///
/// This type contains exactly that deterministic logic so it can be unit-tested
/// without SwiftUI: group slots into words, then pick the break that balances
/// the two lines.
nonisolated enum TypingSlotLayout {
    /// Splits a slot sequence into words. A separator slot terminates the word
    /// it belongs to and stays at that word's end (mirroring the on-screen look
    /// `nice_`), so every word except the last ends with a separator slot.
    ///
    /// The result holds half-open index ranges into the original `slots` array.
    /// A trailing separator with no following letters still forms its own word
    /// (e.g. an answer ending in a space), which callers may choose to drop.
    static func wordRanges(isSeparator: [Bool]) -> [Range<Int>] {
        guard !isSeparator.isEmpty else { return [] }
        var words: [Range<Int>] = []
        var start = 0
        for index in isSeparator.indices where isSeparator[index] {
            words.append(start..<(index + 1))
            start = index + 1
        }
        if start < isSeparator.count {
            words.append(start..<isSeparator.count)
        }
        return words
    }

    /// Index of the word **after which** the line break should be inserted so the
    /// two resulting lines are as even as possible by slot count. Returns `nil`
    /// when there is nothing to break (zero or one word). Depends only on word
    /// sizes, so the chosen break is stable across keystrokes.
    ///
    /// Ties prefer the earlier break (so the first line is the shorter one),
    /// which keeps the wrap point from drifting between equally-balanced
    /// candidates.
    static func balancedBreakIndex(wordSlotCounts counts: [Int]) -> Int? {
        guard counts.count > 1 else { return nil }
        let total = counts.reduce(0, +)
        var prefix = 0
        var bestIndex = 0
        var bestDelta = Int.max
        for index in 0..<(counts.count - 1) {
            prefix += counts[index]
            let delta = abs(prefix - (total - prefix))
            if delta < bestDelta {
                bestDelta = delta
                bestIndex = index
            }
        }
        return bestIndex
    }
}
