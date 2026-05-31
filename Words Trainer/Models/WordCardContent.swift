import Foundation

struct WordForm: Codable, Hashable {
    let formKey: String
    let text: String
}

struct ClozeSentenceParts: Equatable, Hashable {
    let prefix: String
    let suffix: String
}

/// Card content from server or local seed (no SRS state).
struct WordCardContent: Codable, Identifiable, Hashable {
    static let blankToken = "{{blank}}"

    let id: UUID
    let word: String
    let lemma: String
    let partOfSpeech: String?
    let translation: String
    let clozePrompt: String
    let clozeTemplate: String?
    /// Override when the gap uses a different form than `word` (e.g. went vs go).
    let clozeAnswer: String?
    /// Russian translation of the example sentence (`card_examples.translation`).
    let clozeExampleTranslation: String?
    let answerFormKey: String?
    let shortDefinition: String?
    let memoryHint: String?
    let etymology: String?
    let usageNote: String?
    let synonymNote: String?
    let grammarNote: String?
    let explanation: String?
    let imageURL: URL?
    let audioWordURL: URL?
    let audioExampleURL: URL?
    let distractors: [String]
    let forms: [WordForm]

    init(
        id: UUID = UUID(),
        word: String,
        lemma: String? = nil,
        partOfSpeech: String? = nil,
        translation: String,
        clozePrompt: String,
        clozeTemplate: String? = nil,
        clozeAnswer: String? = nil,
        clozeExampleTranslation: String? = nil,
        answerFormKey: String? = nil,
        shortDefinition: String? = nil,
        memoryHint: String? = nil,
        etymology: String? = nil,
        usageNote: String? = nil,
        synonymNote: String? = nil,
        grammarNote: String? = nil,
        explanation: String? = nil,
        imageURL: URL? = nil,
        audioWordURL: URL? = nil,
        audioExampleURL: URL? = nil,
        distractors: [String] = [],
        forms: [WordForm] = []
    ) {
        self.id = id
        self.word = word
        self.lemma = lemma ?? Self.headword(from: word)
        self.partOfSpeech = partOfSpeech
        self.translation = translation
        self.clozePrompt = clozePrompt
        self.clozeTemplate = clozeTemplate
        self.clozeAnswer = clozeAnswer
        self.clozeExampleTranslation = clozeExampleTranslation
        self.answerFormKey = answerFormKey
        self.shortDefinition = shortDefinition
        self.memoryHint = memoryHint
        self.etymology = etymology
        self.usageNote = usageNote
        self.synonymNote = synonymNote
        self.grammarNote = grammarNote
        self.explanation = explanation
        self.imageURL = imageURL
        self.audioWordURL = audioWordURL
        self.audioExampleURL = audioExampleURL
        self.distractors = distractors
        self.forms = forms
    }

    /// Answer accepted in cloze exercises when `clozeAnswer` is nil.
    var effectiveClozeAnswer: String {
        if let explicitAnswer = Self.trimmedNonEmpty(clozeAnswer) {
            return explicitAnswer
        }
        if let promptAnswer = Self.boldClozeAnswer(from: clozePrompt) {
            return promptAnswer
        }
        return Self.headword(from: word)
    }

    /// Cloze prompt rendered with the highlighted answer hidden.
    var clozePromptWithGap: String {
        if let clozeTemplate {
            return Self.fillTemplate(clozeTemplate, with: "___")
        }
        if clozePrompt.contains(Self.blankToken) || clozePrompt.contains("___") {
            return Self.fillTemplate(clozePrompt, with: "___")
        }
        return Self.clozePromptWithGap(from: clozePrompt)
    }

    /// Multiple-choice options before presentation-level shuffling.
    var clozeChoices: [String] {
        Self.uniqueChoices(correctAnswer: effectiveClozeAnswer, distractors: distractors)
    }

    func clozeChoices(answerPool: [WordCardContent], targetCount: Int = 4) -> [String] {
        clozeChoices(sessionPool: answerPool, deckPool: [], targetCount: targetCount)
    }

    /// Builds MCQ options from today's session first, then the full deck if needed.
    func clozeChoices(
        sessionPool: [WordCardContent],
        deckPool: [WordCardContent],
        targetCount: Int = 4
    ) -> [String] {
        let sessionOthers = sessionPool.filter { $0.id != id }
        var distractors = distractorTexts(from: sessionOthers)
        var choices = Self.uniqueChoices(
            correctAnswer: effectiveClozeAnswer,
            distractors: distractors
        )

        if choices.count < targetCount {
            let sessionIDs = Set(sessionPool.map(\.id))
            let deckOthers = deckPool.filter { $0.id != id && !sessionIDs.contains($0.id) }
            distractors += distractorTexts(from: deckOthers)
            choices = Self.uniqueChoices(
                correctAnswer: effectiveClozeAnswer,
                distractors: distractors
            )
        }

        return Array(choices.prefix(max(1, targetCount)))
    }

    private func distractorTexts(from otherCards: [WordCardContent]) -> [String] {
        let exactMatches = otherCards.compactMap { card -> (UUID, String)? in
            guard let text = card.choiceText(exactlyMatching: answerFormKey) else { return nil }
            return (card.id, text)
        }
        let exactFormDistractors = exactMatches.map(\.1)
        let exactCardIDs = Set(exactMatches.map(\.0))
        let fallbackDistractors = otherCards
            .filter { !exactCardIDs.contains($0.id) }
            .compactMap { $0.fallbackChoiceText() }
        return distractors + exactFormDistractors + fallbackDistractors
    }

    func clozePromptFilled(with answer: String) -> String {
        if let clozeTemplate {
            return Self.fillTemplate(clozeTemplate, with: answer)
        }
        if clozePrompt.contains(Self.blankToken) || clozePrompt.contains("___") {
            return Self.fillTemplate(clozePrompt, with: answer)
        }
        return Self.clozePromptWithGap(from: clozePrompt, gap: answer)
    }

    /// Prefix and suffix around the single blank in the example sentence.
    var clozeSentenceParts: ClozeSentenceParts? {
        Self.clozeSentenceParts(in: clozeTemplate ?? clozePrompt)
    }

    static func clozeSentenceParts(in source: String) -> ClozeSentenceParts? {
        if let range = source.range(of: blankToken) {
            return parts(prefix: String(source[..<range.lowerBound]), suffix: String(source[range.upperBound...]))
        }
        if let range = source.range(of: "___") {
            return parts(prefix: String(source[..<range.lowerBound]), suffix: String(source[range.upperBound...]))
        }
        return nil
    }

    private static func parts(prefix: String, suffix: String) -> ClozeSentenceParts {
        ClozeSentenceParts(
            prefix: plainText(fromHTMLFragment: prefix),
            suffix: plainText(fromHTMLFragment: suffix)
        )
    }

    /// Semicolon-separated senses in `translation` (trimmed, non-empty).
    static func translationSenses(_ translation: String) -> [String] {
        translation.split(separator: ";", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    static func clozePromptWithGap(from prompt: String, gap: String = "___") -> String {
        boldTagRegex.stringByReplacingMatches(
            in: prompt,
            range: NSRange(prompt.startIndex..., in: prompt),
            withTemplate: gap
        )
    }

    static func fillTemplate(_ template: String, with answer: String) -> String {
        if template.contains(blankToken) {
            return template.replacingOccurrences(of: blankToken, with: answer)
        }
        if let range = template.range(of: "___") {
            var filled = template
            filled.replaceSubrange(range, with: answer)
            return filled
        }
        return template
    }

    /// Plain-text example sentence with the correct answer filled in.
    var clozeExamplePlainText: String {
        Self.plainText(fromHTMLFragment: clozePromptFilled(with: effectiveClozeAnswer))
    }

    static func boldClozeAnswer(from prompt: String) -> String? {
        let range = NSRange(prompt.startIndex..., in: prompt)
        guard let match = boldTagRegex.firstMatch(in: prompt, range: range),
              match.range(at: 1).location != NSNotFound,
              let swiftRange = Range(match.range(at: 1), in: prompt)
        else {
            return nil
        }

        let answer = plainText(fromHTMLFragment: String(prompt[swiftRange]))
        return trimmedNonEmpty(answer)
    }

    static func uniqueChoices(correctAnswer: String, distractors: [String]) -> [String] {
        var seen = Set<String>()
        return ([correctAnswer] + distractors).compactMap { choice in
            guard let trimmed = trimmedNonEmpty(choice) else { return nil }
            let key = trimmed.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            return seen.insert(key).inserted ? trimmed : nil
        }
    }

    private func choiceText(exactlyMatching formKey: String?) -> String? {
        if let formKey,
           let exact = forms.first(where: { $0.formKey == formKey }) {
            return exact.text
        }
        return nil
    }

    private func fallbackChoiceText() -> String? {
        if let base = forms.first(where: { $0.formKey == "base" || $0.formKey == "singular" }) {
            return base.text
        }
        return effectiveClozeAnswer
    }

    static func headword(from word: String) -> String {
        var plain = word.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        plain = plain.split(separator: "(", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? plain
        let lower = plain.lowercased()
        if lower.hasPrefix("an ") {
            plain = String(plain.dropFirst(3))
        } else if lower.hasPrefix("a ") {
            plain = String(plain.dropFirst(2))
        } else if lower.hasPrefix("the ") {
            plain = String(plain.dropFirst(4))
        }
        return plain.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let boldTagRegex = try! NSRegularExpression(
        pattern: #"<b\b[^>]*>(.*?)</b>"#,
        options: [.caseInsensitive, .dotMatchesLineSeparators]
    )

    private static func plainText(fromHTMLFragment html: String) -> String {
        html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
    }

    private static func trimmedNonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct DeckContent: Identifiable, Hashable {
    let id: UUID
    var title: String
    var avatarSystemName: String?
    var languageCode: String
    var newCardsPerDay: Int
    var reviewCardsPerDay: Int
    var cards: [WordCardContent]
}
