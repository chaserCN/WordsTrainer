import Testing
@testable import WordsTrainerLogic

/// Tests for the deterministic line-break layout used by the "Письмо" answer row.
/// Inputs are modeled as `isSeparator` flags — `true` marks a separator slot
/// (the dash standing in for a space), `false` marks a letter slot.
@Suite("Typing slot layout")
struct TypingSlotLayoutTests {

    // MARK: wordRanges

    @Test("single word has no separators and forms one range")
    func singleWord() {
        // "cat" → [c, a, t]
        let ranges = TypingSlotLayout.wordRanges(isSeparator: [false, false, false])
        #expect(ranges == [0..<3])
    }

    @Test("separator stays at the end of its word")
    func separatorTerminatesWord() {
        // "a_b" → [a, _, b] : "a_" then "b"
        let ranges = TypingSlotLayout.wordRanges(isSeparator: [false, true, false])
        #expect(ranges == [0..<2, 2..<3])
    }

    @Test("three words split on each separator")
    func threeWords() {
        // "have a nice" → letters 4 _ 1 _ 4
        let flags = [false, false, false, false, true, // have_
                     false, true,                       // a_
                     false, false, false, false]        // nice
        let ranges = TypingSlotLayout.wordRanges(isSeparator: flags)
        #expect(ranges == [0..<5, 5..<7, 7..<11])
        #expect(ranges.map(\.count) == [5, 2, 4])
    }

    @Test("empty input yields no words")
    func emptyInput() {
        #expect(TypingSlotLayout.wordRanges(isSeparator: []).isEmpty)
    }

    @Test("trailing separator forms its own word")
    func trailingSeparator() {
        // "a_" with nothing after → "a_" is one word, no empty word follows
        let ranges = TypingSlotLayout.wordRanges(isSeparator: [false, true])
        #expect(ranges == [0..<2])
    }

    @Test("leading separator forms a separator-only first word")
    func leadingSeparator() {
        // "_a" → "_" then "a"
        let ranges = TypingSlotLayout.wordRanges(isSeparator: [true, false])
        #expect(ranges == [0..<1, 1..<2])
    }

    @Test("consecutive separators each form their own word")
    func consecutiveSeparators() {
        // "a__b" → "a_", "_", "b"
        let ranges = TypingSlotLayout.wordRanges(isSeparator: [false, true, true, false])
        #expect(ranges == [0..<2, 2..<3, 3..<4])
    }

    @Test("ranges cover every slot exactly once and in order")
    func rangesPartitionAllSlots() {
        let flags = [false, true, false, false, true, false]
        let ranges = TypingSlotLayout.wordRanges(isSeparator: flags)
        let flattened = ranges.flatMap { Array($0) }
        #expect(flattened == Array(0..<flags.count))
    }

    // MARK: balancedBreakIndex

    @Test("no break for a single word")
    func noBreakSingleWord() {
        #expect(TypingSlotLayout.balancedBreakIndex(wordSlotCounts: [5]) == nil)
    }

    @Test("no break for empty input")
    func noBreakEmpty() {
        #expect(TypingSlotLayout.balancedBreakIndex(wordSlotCounts: []) == nil)
    }

    @Test("two equal words break after the first")
    func twoEqualWords() {
        // [3, 3] → break after index 0: lines 3 | 3
        #expect(TypingSlotLayout.balancedBreakIndex(wordSlotCounts: [3, 3]) == 0)
    }

    @Test("have a nice t___ breaks to balance 7 | 4")
    func realisticPhrase() {
        // counts: have_=5, a_=2, nice_=5, t___=4  (total 16)
        // prefixes: 5(|11 Δ6), 7(|9 Δ2), 12(|4 Δ8) → best after index 1
        let counts = [5, 2, 5, 4]
        #expect(TypingSlotLayout.balancedBreakIndex(wordSlotCounts: counts) == 1)
    }

    @Test("break favors the most even split")
    func mostEvenSplit() {
        // [1, 1, 10] total 12. prefixes: 1(Δ10), 2(Δ8) → best after index 1
        #expect(TypingSlotLayout.balancedBreakIndex(wordSlotCounts: [1, 1, 10]) == 1)
    }

    @Test("ties prefer the earlier break")
    func tiesPreferEarlier() {
        // [2, 2, 2] total 6. prefixes: 2(|4 Δ2), 4(|2 Δ2) — tie → earlier index 0
        #expect(TypingSlotLayout.balancedBreakIndex(wordSlotCounts: [2, 2, 2]) == 0)
    }

    @Test("first word longer than the rest still breaks after the first word")
    func dominantFirstWord() {
        // [10, 1, 1] total 12. prefixes: 10(Δ8), 11(Δ10) → best after index 0
        #expect(TypingSlotLayout.balancedBreakIndex(wordSlotCounts: [10, 1, 1]) == 0)
    }

    @Test("last word longer than the rest breaks just before it")
    func dominantLastWord() {
        // [1, 1, 1, 9] total 12. prefixes: 1,2,3 → closest to 6 is 3 at index 2
        #expect(TypingSlotLayout.balancedBreakIndex(wordSlotCounts: [1, 1, 1, 9]) == 2)
    }

    // MARK: integration — wordRanges + balancedBreakIndex

    @Test("break index is stable regardless of which letters are typed")
    func breakStableAcrossTyping() {
        // The flags depend only on the answer's structure, not on typed letters,
        // so the computed break must be identical for any typing progress.
        let flags = [false, false, false, false, true, // have_
                     false, true,                       // a_
                     false, false, false, false, true,  // nice_
                     false, false, false, false]        // trip
        let ranges = TypingSlotLayout.wordRanges(isSeparator: flags)
        let counts = ranges.map(\.count) // [5, 2, 5, 4]
        let breakIndex = TypingSlotLayout.balancedBreakIndex(wordSlotCounts: counts)
        // total 16, prefixes 5,7,12 → index 1 is closest to 8
        #expect(breakIndex == 1)
        // Re-running with the same structure yields the same result.
        #expect(TypingSlotLayout.balancedBreakIndex(wordSlotCounts: counts) == breakIndex)
    }
}
