import Testing
@testable import WordsTrainerLogic

@Suite("WordCardContent")
struct WordCardContentTests {
    @Test("translationSenses splits on semicolons")
    func translationSensesSplit() {
        let senses = WordCardContent.translationSenses("бросать; кидать; метать")
        #expect(senses == ["бросать", "кидать", "метать"])
    }

    @Test("translationSenses trims whitespace")
    func translationSensesTrim() {
        let senses = WordCardContent.translationSenses(" a ; b ")
        #expect(senses == ["a", "b"])
    }

    @Test("headword strips article and part of speech")
    func headwordNormalization() {
        #expect(WordCardContent.headword(from: "cast (Verb, Transitive)") == "cast")
        #expect(WordCardContent.headword(from: "an apple") == "apple")
    }
}

@Suite("MatchingPair")
struct MatchingPairTests {
    @Test("one sense produces one pair")
    func singleSense() {
        let card = TestFixtures.card(word: "dog", translation: "собака")
        let pairs = MatchingPair.pairs(from: TestFixtures.queueItem(card: card))
        #expect(pairs.count == 1)
        #expect(pairs[0].translation == "собака")
    }

    @Test("multiple senses produce separate pairs")
    func multipleSenses() {
        let card = TestFixtures.card(word: "cast", translation: "бросать; кидать; метать")
        let pairs = MatchingPair.pairs(from: TestFixtures.queueItem(card: card))
        #expect(pairs.count == 3)
        #expect(pairs.map(\.translation) == ["бросать", "кидать", "метать"])
        #expect(Set(pairs.map(\.cardID)).count == 1)
        #expect(Set(pairs.map(\.id)).count == 3)
    }
}
