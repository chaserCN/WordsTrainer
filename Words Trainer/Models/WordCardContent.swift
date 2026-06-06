import Foundation

nonisolated struct WordForm: Codable, Hashable, Sendable {
    let formKey: String
    let text: String
}

nonisolated struct ClozeSentenceParts: Equatable, Hashable, Sendable {
    let prefix: String
    let suffix: String
}

nonisolated enum ContentStatus: String, Codable, Hashable, Sendable {
    case active
    case inactive

    var isActive: Bool { self == .active }
}

/// Card content from server or local seed (no SRS state).
nonisolated struct WordCardContent: Codable, Identifiable, Hashable, Sendable {
    static let blankToken = "{{blank}}"

    let id: UUID
    let status: ContentStatus
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
    /// Optional image for the concrete example. Stored for future UI modes.
    let clozeExampleImageURL: URL?
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
        status: ContentStatus = .active,
        word: String,
        lemma: String? = nil,
        partOfSpeech: String? = nil,
        translation: String,
        clozePrompt: String,
        clozeTemplate: String? = nil,
        clozeAnswer: String? = nil,
        clozeExampleTranslation: String? = nil,
        clozeExampleImageURL: URL? = nil,
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
        self.status = status
        self.word = word
        self.lemma = lemma ?? Self.headword(from: word)
        self.partOfSpeech = partOfSpeech
        self.translation = translation
        self.clozePrompt = clozePrompt
        self.clozeTemplate = clozeTemplate
        self.clozeAnswer = clozeAnswer
        self.clozeExampleTranslation = clozeExampleTranslation
        self.clozeExampleImageURL = clozeExampleImageURL
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

    func clozeChoices(
        answerPool: [WordCardContent],
        targetCount: Int = 4,
        excluding excludedChoices: [String] = []
    ) -> [String] {
        clozeChoices(
            sessionPool: answerPool,
            deckPool: [],
            targetCount: targetCount,
            excluding: excludedChoices
        )
    }

    /// Builds MCQ options from today's session first, then the full deck if needed.
    func clozeChoices(
        sessionPool: [WordCardContent],
        deckPool: [WordCardContent],
        targetCount: Int = 4,
        excluding excludedChoices: [String] = []
    ) -> [String] {
        let requiredCount = max(1, targetCount)
        let sessionOthers = sessionPool.filter { $0.id != id }
        var distractors = distractors
        distractors += dynamicDistractorTexts(from: sessionOthers, salt: "session")
        var choices = Self.uniqueChoices(
            correctAnswer: effectiveClozeAnswer,
            distractors: distractors,
            excluding: excludedChoices
        )

        if choices.count < requiredCount {
            let sessionIDs = Set(sessionPool.map(\.id))
            let deckOthers = deckPool.filter { $0.id != id && !sessionIDs.contains($0.id) }
            distractors += dynamicDistractorTexts(from: deckOthers, salt: "deck")
            choices = Self.uniqueChoices(
                correctAnswer: effectiveClozeAnswer,
                distractors: distractors,
                excluding: excludedChoices
            )
        }

        if !excludedChoices.isEmpty, choices.count < requiredCount {
            choices = Self.uniqueChoices(correctAnswer: effectiveClozeAnswer, distractors: distractors)
        }

        return Array(choices.prefix(requiredCount))
    }

    private func dynamicDistractorTexts(from otherCards: [WordCardContent], salt: String) -> [String] {
        let exactMatches = otherCards.compactMap { card -> DynamicDistractor? in
            guard let text = card.choiceText(exactlyMatching: answerFormKey) else { return nil }
            return DynamicDistractor(cardID: card.id, text: text, matchesPartOfSpeech: matchesPartOfSpeech(card))
        }
        let exactFormDistractors = prioritizedDistractorTexts(from: exactMatches, salt: "\(salt)-exact")
        let exactCardIDs = Set(exactMatches.map(\.cardID))
        let fallbackDistractors = otherCards
            .filter { !exactCardIDs.contains($0.id) }
            .compactMap { card -> DynamicDistractor? in
                guard let text = card.fallbackChoiceText() else { return nil }
                return DynamicDistractor(cardID: card.id, text: text, matchesPartOfSpeech: matchesPartOfSpeech(card))
            }
        let fallbackTexts = prioritizedDistractorTexts(from: fallbackDistractors, salt: "\(salt)-fallback")
        return exactFormDistractors + fallbackTexts
    }

    private func prioritizedDistractorTexts(from distractors: [DynamicDistractor], salt: String) -> [String] {
        let samePartOfSpeech = distractors.filter(\.matchesPartOfSpeech).map(\.text)
        let otherPartOfSpeech = distractors.filter { !$0.matchesPartOfSpeech }.map(\.text)
        return rotated(samePartOfSpeech, salt: "\(salt)-same-pos")
            + rotated(otherPartOfSpeech, salt: "\(salt)-other-pos")
    }

    private func matchesPartOfSpeech(_ otherCard: WordCardContent) -> Bool {
        guard let target = Self.normalizedPartOfSpeech(partOfSpeech) else { return true }
        return Self.normalizedPartOfSpeech(otherCard.partOfSpeech) == target
    }

    private struct DynamicDistractor {
        let cardID: UUID
        let text: String
        let matchesPartOfSpeech: Bool
    }

    private func rotated(_ values: [String], salt: String) -> [String] {
        guard values.count > 1 else { return values }
        let offset = Self.stableOffset(seed: "\(id.uuidString)|\(effectiveClozeAnswer)|\(salt)", count: values.count)
        guard offset > 0 else { return values }
        return Array(values[offset...]) + values[..<offset]
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

    static func uniqueChoices(
        correctAnswer: String,
        distractors: [String],
        excluding excludedChoices: [String] = []
    ) -> [String] {
        var seen = Set<String>()
        let correctKey = choiceKey(correctAnswer)
        let excludedKeys = Set(excludedChoices.map(choiceKey)).subtracting([correctKey])
        return ([correctAnswer] + distractors).compactMap { choice in
            guard let trimmed = trimmedNonEmpty(choice) else { return nil }
            let key = choiceKey(trimmed)
            guard !excludedKeys.contains(key) else { return nil }
            return seen.insert(key).inserted ? trimmed : nil
        }
    }

    private static func choiceKey(_ choice: String) -> String {
        choice
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
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

    private static func normalizedPartOfSpeech(_ value: String?) -> String? {
        trimmedNonEmpty(value)?.lowercased()
    }

    private static func stableOffset(seed: String, count: Int) -> Int {
        guard count > 0 else { return 0 }
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in seed.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return Int(hash % UInt64(count))
    }
}

nonisolated struct DeckContent: Identifiable, Hashable, Sendable {
    let id: UUID
    let contentVersionID: UUID?
    var status: ContentStatus
    var title: String
    var avatarSystemName: String?
    var avatarImageURL: URL?
    var languageCode: String
    var newCardsPerDay: Int
    var reviewCardsPerDay: Int
    var cards: [WordCardContent]

    var isActive: Bool { status.isActive }
    var activeCards: [WordCardContent] { cards.filter(\.status.isActive) }

    init(
        id: UUID,
        contentVersionID: UUID? = nil,
        status: ContentStatus = .active,
        title: String,
        avatarSystemName: String?,
        avatarImageURL: URL? = nil,
        languageCode: String,
        newCardsPerDay: Int,
        reviewCardsPerDay: Int,
        cards: [WordCardContent]
    ) {
        self.id = id
        self.contentVersionID = contentVersionID
        self.status = status
        self.title = title
        self.avatarSystemName = avatarSystemName
        self.avatarImageURL = avatarImageURL
        self.languageCode = languageCode
        self.newCardsPerDay = newCardsPerDay
        self.reviewCardsPerDay = reviewCardsPerDay
        self.cards = cards
    }
}
