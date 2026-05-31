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

    @Test(
        "clozePromptWithGap hides bold answer",
        arguments: [
            (
                "The fisherman <b>cast</b> his net into the deep blue water.",
                "The fisherman ___ his net into the deep blue water."
            ),
            (
                "The teacher <B>rapped</B> on the table.",
                "The teacher ___ on the table."
            ),
            (
                "They <b class=\"target\">settle</b> in a quiet village.",
                "They ___ in a quiet village."
            ),
            (
                "It took them two hours to ___ all the furniture.",
                "It took them two hours to ___ all the furniture."
            ),
        ]
    )
    func clozePromptWithGap(prompt: String, expected: String) {
        #expect(WordCardContent.clozePromptWithGap(from: prompt) == expected)
    }

    @Test("effectiveClozeAnswer prefers explicit answer")
    func effectiveClozeAnswerPrefersExplicitAnswer() {
        let card = WordCardContent(
            word: "rap",
            translation: "стучать",
            clozePrompt: "The teacher <b>rapped</b> on the table.",
            clozeAnswer: "rap"
        )

        #expect(card.effectiveClozeAnswer == "rap")
    }

    @Test("effectiveClozeAnswer falls back to bold prompt answer")
    func effectiveClozeAnswerFallsBackToBoldPromptAnswer() {
        let card = WordCardContent(
            word: "rap",
            translation: "стучать",
            clozePrompt: "The teacher <b>rapped</b> on the table."
        )

        #expect(card.effectiveClozeAnswer == "rapped")
    }

    @Test("effectiveClozeAnswer falls back to headword")
    func effectiveClozeAnswerFallsBackToHeadword() {
        let card = WordCardContent(
            word: "an apple (Noun, Countable)",
            translation: "яблоко",
            clozePrompt: "I ate ___."
        )

        #expect(card.effectiveClozeAnswer == "apple")
    }

    @Test("clozeChoices trims empty values and deduplicates answer")
    func clozeChoicesDeduplicateAnswer() {
        let card = WordCardContent(
            word: "cast",
            translation: "бросать",
            clozePrompt: "The fisherman <b>cast</b> his net.",
            distractors: [" throw ", "", "CAST", "drop"]
        )

        #expect(card.clozeChoices == ["cast", "throw", "drop"])
    }

    @Test("clozeChoices can use answer pool")
    func clozeChoicesUseAnswerPool() {
        let card = WordCardContent(
            word: "hip",
            translation: "бедро",
            clozePrompt: "She stood with her hands on her <b>hips</b>.",
            answerFormKey: "plural",
            forms: [WordForm(formKey: "singular", text: "hip"), WordForm(formKey: "plural", text: "hips")]
        )
        let pool = [
            card,
            WordCardContent(
                word: "a load",
                translation: "груз",
                clozePrompt: "The truck carried heavy <b>loads</b>.",
                answerFormKey: "plural",
                forms: [WordForm(formKey: "singular", text: "load"), WordForm(formKey: "plural", text: "loads")]
            ),
            WordCardContent(
                word: "a heel",
                translation: "пятка",
                clozePrompt: "His <b>heels</b> hurt.",
                answerFormKey: "plural",
                forms: [WordForm(formKey: "singular", text: "heel"), WordForm(formKey: "plural", text: "heels")]
            ),
            WordCardContent(
                word: "settle",
                translation: "поселиться",
                clozePrompt: "They <b>settle</b> there.",
                answerFormKey: "base",
                forms: [WordForm(formKey: "base", text: "settle")]
            ),
        ]

        #expect(card.clozeChoices(answerPool: pool) == ["hips", "loads", "heels", "settle"])
    }

    @Test("clozeChoices prefer matching verb form")
    func clozeChoicesPreferMatchingVerbForm() {
        let card = WordCardContent(
            word: "rap",
            translation: "стучать",
            clozePrompt: "The teacher <b>rapped</b> on the table.",
            answerFormKey: "past",
            forms: [WordForm(formKey: "base", text: "rap"), WordForm(formKey: "past", text: "rapped")]
        )
        let pool = [
            card,
            WordCardContent(
                word: "load",
                translation: "грузить",
                clozePrompt: "They <b>loaded</b> the van.",
                answerFormKey: "past",
                forms: [WordForm(formKey: "base", text: "load"), WordForm(formKey: "past", text: "loaded")]
            ),
            WordCardContent(
                word: "cast",
                translation: "бросать",
                clozePrompt: "He <b>cast</b> the net.",
                answerFormKey: "past",
                forms: [WordForm(formKey: "base", text: "cast"), WordForm(formKey: "past", text: "cast")]
            ),
            WordCardContent(
                word: "settle",
                translation: "поселиться",
                clozePrompt: "They <b>settle</b> there.",
                answerFormKey: "base",
                forms: [WordForm(formKey: "base", text: "settle")]
            ),
        ]

        #expect(card.clozeChoices(answerPool: pool) == ["rapped", "loaded", "cast", "settle"])
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
