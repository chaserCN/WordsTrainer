import Foundation
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

    @Test("fillTemplate replaces blank token and legacy gap")
    func fillTemplateSupportsBlankMarkers() {
        #expect(
            WordCardContent.fillTemplate("She put her hands on her {{blank}}.", with: "hips")
            == "She put her hands on her hips."
        )
        #expect(
            WordCardContent.fillTemplate("He wore a plaster ___ on his arm.", with: "cast")
            == "He wore a plaster cast on his arm."
        )
    }

    @Test("clozeSentenceParts splits around blank markers")
    func clozeSentencePartsSplit() {
        let parts = WordCardContent.clozeSentenceParts(
            in: "After the accident, he wore a plaster {{blank}} on his arm."
        )
        #expect(parts?.prefix == "After the accident, he wore a plaster ")
        #expect(parts?.suffix == " on his arm.")

        let legacy = WordCardContent.clozeSentenceParts(
            in: "The fisherman ___ his net into the water."
        )
        #expect(legacy?.prefix == "The fisherman ")
        #expect(legacy?.suffix == " his net into the water.")
    }

    @Test("clozeExamplePlainText strips markup and fills answer")
    func clozeExamplePlainText() {
        let card = WordCardContent(
            word: "cast",
            translation: "гипс",
            clozePrompt: "After the accident, he wore a plaster ___ on his arm.",
            clozeAnswer: "cast"
        )
        #expect(card.clozeExamplePlainText == "After the accident, he wore a plaster cast on his arm.")
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

        let choices = card.clozeChoices(answerPool: pool)
        #expect(choices.first == "hips")
        #expect(Set(choices) == ["hips", "loads", "heels", "settle"])
    }

    @Test("clozeChoices vary dynamic distractors by card")
    func clozeChoicesVaryDynamicDistractorsByCard() {
        func baseCard(_ index: Int, _ answer: String) -> WordCardContent {
            WordCardContent(
                id: UUID(uuidString: "00000000-0000-4000-8000-\(String(format: "%012d", index))")!,
                word: answer,
                translation: answer,
                clozePrompt: "They ___ it.",
                clozeAnswer: answer,
                answerFormKey: "base",
                forms: [WordForm(formKey: "base", text: answer)]
            )
        }
        let pool = [
            baseCard(1, "dilute"),
            baseCard(2, "enclose"),
            baseCard(3, "hoist"),
            baseCard(4, "jeopardize"),
            baseCard(5, "outweigh"),
            baseCard(6, "sprawl"),
            baseCard(7, "tarnish"),
            baseCard(8, "mystify"),
        ]

        let first = pool[0].clozeChoices(answerPool: pool)
        let second = pool[1].clozeChoices(answerPool: pool)

        #expect(first.first == "dilute")
        #expect(second.first == "enclose")
        #expect(Set(first.dropFirst()) != Set(second.dropFirst()))
    }

    @Test("clozeChoices fall back to deck pool when session is nearly exhausted")
    func clozeChoicesFallBackToDeckPool() {
        let card = TestFixtures.card(
            word: "cast",
            translation: "гипс",
            clozePrompt: "He wore a plaster ___ on his arm.",
            clozeAnswer: "cast"
        )
        let sessionMate = TestFixtures.card(
            word: "load",
            translation: "груз",
            clozePrompt: "A heavy ___ of bricks.",
            clozeAnswer: "load"
        )
        let deckOnly = [
            TestFixtures.card(word: "hip", translation: "бедро", clozePrompt: "Hands on her ___", clozeAnswer: "hips"),
            TestFixtures.card(word: "heel", translation: "пятка", clozePrompt: "Back of her ___", clozeAnswer: "heel"),
            TestFixtures.card(word: "settle", translation: "осесть", clozePrompt: "They ___ there.", clozeAnswer: "settle"),
        ]

        let fromSessionOnly = card.clozeChoices(sessionPool: [card, sessionMate], deckPool: [])
        #expect(fromSessionOnly == ["cast", "load"])

        let withDeckFallback = card.clozeChoices(
            sessionPool: [card, sessionMate],
            deckPool: deckOnly + [card, sessionMate]
        )
        #expect(withDeckFallback.count == 4)
        #expect(withDeckFallback.first == "cast")
    }

    @Test("clozeChoices prefer matching verb form")
    func clozeChoicesPreferMatchingVerbForm() {
        let card = WordCardContent(
            word: "rap",
            partOfSpeech: "verb",
            translation: "стучать",
            clozePrompt: "The teacher <b>rapped</b> on the table.",
            answerFormKey: "past",
            forms: [WordForm(formKey: "base", text: "rap"), WordForm(formKey: "past", text: "rapped")]
        )
        let pool = [
            card,
            WordCardContent(
                word: "load",
                partOfSpeech: "verb",
                translation: "грузить",
                clozePrompt: "They <b>loaded</b> the van.",
                answerFormKey: "past",
                forms: [WordForm(formKey: "base", text: "load"), WordForm(formKey: "past", text: "loaded")]
            ),
            WordCardContent(
                word: "cast",
                partOfSpeech: "verb",
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

        let choices = card.clozeChoices(answerPool: pool)
        #expect(choices.first == "rapped")
        #expect(Set(choices.dropFirst()) == ["loaded", "cast", "settle"])
    }

    @Test("clozeChoices prefer matching part of speech")
    func clozeChoicesPreferMatchingPartOfSpeech() {
        func card(_ index: Int, _ answer: String, _ partOfSpeech: String) -> WordCardContent {
            WordCardContent(
                id: UUID(uuidString: "00000000-0000-4000-8001-\(String(format: "%012d", index))")!,
                word: answer,
                partOfSpeech: partOfSpeech,
                translation: answer,
                clozePrompt: "They ___ it.",
                clozeAnswer: answer,
                answerFormKey: "base",
                forms: [WordForm(formKey: "base", text: answer)]
            )
        }
        let target = card(1, "dilute", "verb")
        let pool = [
            target,
            card(2, "feral", "adjective"),
            card(3, "dormant", "adjective"),
            card(4, "hoist", "verb"),
            card(5, "enclose", "verb"),
            card(6, "tarnish", "verb"),
            card(7, "vigorous", "adjective"),
        ]

        let choices = target.clozeChoices(answerPool: pool)

        #expect(choices.first == "dilute")
        #expect(Set(choices.dropFirst()) == ["hoist", "enclose", "tarnish"])
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
