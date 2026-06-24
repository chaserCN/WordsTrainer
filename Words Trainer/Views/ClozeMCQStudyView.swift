import SwiftUI

struct ClozeMCQStudyView: View {
    let card: WordCardContent
    let promptMode: ClozePromptMode
    let sessionChoicePool: [WordCardContent]
    let deckChoicePool: [WordCardContent]
    let totalCount: Int
    let remainingCount: Int
    let onAnswer: (ReviewOutcome, UUID?) -> Void

    @State private var displayedRoundID: UUID?
    @State private var selected: String?
    @State private var answered = false
    @State private var choices: [ClozeChoice] = []
    @State private var shakeCount: CGFloat = 0
    @State private var previewPair: MatchingPair?
    @State private var suppressedOptionTap: String?
    @State private var previousCorrectOption: String?
    @State private var optionFeedbackTrigger = false
    @State private var nextFeedbackTrigger = false

    private var passed: Bool {
        guard let selected else { return false }
        return selected.compare(
            card.effectiveClozeAnswer,
            options: [.caseInsensitive, .diacriticInsensitive]
        ) == .orderedSame
    }

    private var roundID: UUID {
        card.primarySenseID ?? card.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            StudyProgressHeader(totalCount: totalCount, remainingCount: remainingCount)

            VStack(alignment: .leading, spacing: 14) {
                sentenceCard

                VStack(spacing: 10) {
                    ForEach(choices) { choice in
                        let option = choice.text
                        ClozeChoiceButton(
                            option: option,
                            showResult: answered,
                            isSelected: selected == option,
                            isCorrect: answered && optionsMatch(option, card.effectiveClozeAnswer),
                            isWrong: answered && selected == option && !optionsMatch(option, card.effectiveClozeAnswer),
                            isDimmed: answered && selected != option && !optionsMatch(option, card.effectiveClozeAnswer),
                            isReplayOnly: answered && optionsMatch(option, card.effectiveClozeAnswer)
                        ) {
                            optionFeedbackTrigger.toggle()
                            select(option)
                        }
                        .simultaneousGesture(
                            LongPressGesture(minimumDuration: 0.45)
                                .onEnded { _ in
                                    guard answered else { return }
                                    guard let pair = previewPair(for: option) else { return }
                                    suppressedOptionTap = option
                                    withAnimation(.easeOut(duration: 0.18)) {
                                        previewPair = pair
                                    }
                                }
                        )
                    }
                }

                VStack(spacing: 16) {
                    answerTranslation
                        .frame(maxWidth: .infinity)
                        .opacity(answered ? 1 : 0)

                    ZStack {
                        ClozeForgetButton {
                            revealAnswerAsForgotten()
                        }
                        .opacity(answered ? 0 : 1)
                        .disabled(answered)
                        .accessibilityHidden(answered)

                        Button("Дальше") {
                            nextFeedbackTrigger.toggle()
                            advance()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(MatchPalette.primary)
                        .controlSize(.large)
                        .frame(maxWidth: .infinity)
                        .sensoryFeedback(.selection, trigger: nextFeedbackTrigger)
                        .opacity(answered ? 1 : 0)
                        .disabled(!answered)
                        .accessibilityHidden(!answered)
                    }
                }
                .padding(.top, 20)

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .sensoryFeedback(.selection, trigger: optionFeedbackTrigger)
        .onAppear {
            resetRoundIfNeeded()
        }
        .onChange(of: roundID) { _, _ in
            resetRound()
        }
        .overlay {
            if let previewPair {
                MatchingFlashcardPreviewOverlay(pair: previewPair) {
                    withAnimation(.easeOut(duration: 0.18)) {
                        self.previewPair = nil
                    }
                    suppressedOptionTap = nil
                }
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.18), value: previewPair?.id)
    }

    @ViewBuilder
    private var answerTranslation: some View {
        // In reverse mode the sentence card already shows the Russian prompt, so the
        // helper line below must reveal the English sentence with the answer filled in
        // (mirrors the normal mode, where the card is English and this line is Russian).
        if promptMode == .translation, let parts = card.clozeSentenceParts {
            ClozeAnswerSentenceText(parts: parts, answer: card.effectiveClozeAnswer)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 22)
        } else if let translation = answerTranslationHTML {
            HTMLText(
                html: translation,
                foregroundColor: MatchPalette.foreground,
                font: .subheadline,
                emphasisColor: StudyTargetHighlight.translationColor
            )
            .multilineTextAlignment(.center)
            .frame(minHeight: 22)
        } else {
            Text(" ")
                .font(.subheadline)
                .frame(minHeight: 22)
        }
    }

    private var answerTranslationHTML: String? {
        if let questionTranslation = card.clozeQuestionTranslation?.trimmingCharacters(in: .whitespacesAndNewlines),
           !questionTranslation.isEmpty {
            return questionTranslation
        }
        let translation = card.translation.trimmingCharacters(in: .whitespacesAndNewlines)
        return translation.isEmpty ? nil : "<b>\(Self.escapedHTML(translation))</b>"
    }

    private var sentenceCard: some View {
        Group {
            if promptMode == .translation, let translationPromptHTML {
                ClozeTranslationPromptText(html: translationPromptHTML)
            } else if let parts = card.clozeSentenceParts {
                ClozeSentenceText(
                    parts: parts,
                    filledWord: answered && passed ? selected : nil
                )
            } else {
                HTMLText(
                    html: card.clozePromptWithGap,
                    foregroundColor: ClozeSentencePalette.text,
                    font: .title3.weight(.semibold)
                )
            }
        }
        .multilineTextAlignment(.leading)
        .lineSpacing(4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 16)
        .background(
            clozeSentenceShape
                .fill(clozeSentenceGradient)
                .overlay {
                    Circle()
                        .fill(oklch(0.7, 0.18, 245, 0.25))
                        .frame(width: 180, height: 180)
                        .blur(radius: 50)
                        .offset(x: 80, y: -70)
                }
                .clipShape(clozeSentenceShape)
        )
        .overlay(clozeSentenceShape.strokeBorder(.white.opacity(0.06), lineWidth: 0.5))
        .compositingGroup()
        .shadow(color: oklch(0.2, 0.12, 265, 0.4), radius: 18, x: 0, y: 12)
        .modifier(ShakeEffect(animatableData: shakeCount))
        .animation(.linear(duration: 0.4), value: shakeCount)
    }

    private func select(_ option: String) {
        if suppressedOptionTap == option {
            suppressedOptionTap = nil
            return
        }
        if answered {
            if optionsMatch(option, card.effectiveClozeAnswer) {
                WordAudioPlayer.shared.playClozeAnswer(from: card)
            }
            return
        }
        selected = option
        let isCorrect = optionsMatch(option, card.effectiveClozeAnswer)
        withAnimation(.easeInOut(duration: 0.28)) {
            answered = true
        }
        if !isCorrect {
            shakeCount += 1
        } else {
            WordAudioPlayer.shared.playClozeAnswer(from: card)
        }
    }

    private func revealAnswerAsForgotten() {
        guard !answered else { return }
        selected = nil
        withAnimation(.easeInOut(duration: 0.28)) {
            answered = true
        }
    }

    private func resetRoundIfNeeded() {
        guard displayedRoundID != roundID else { return }
        resetRound()
    }

    private func resetRound() {
        displayedRoundID = roundID
        selected = nil
        answered = false
        choices = card
            .clozeChoices(
                sessionPool: sessionChoicePool,
                deckPool: deckChoicePool,
                excluding: previousCorrectOption.map { [$0] } ?? []
            )
            .shuffled()
            .map { ClozeChoice(text: $0) }
        previewPair = nil
        suppressedOptionTap = nil
    }

    private func advance() {
        previousCorrectOption = card.effectiveClozeAnswer
        let additionalFailureSenseID = passed ? nil : selected.flatMap { previewCard(for: $0)?.primarySenseID }
        onAnswer(passed ? .correct : .incorrect, additionalFailureSenseID)
    }

    private func optionsMatch(_ lhs: String, _ rhs: String) -> Bool {
        lhs.compare(rhs, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }

    private static func escapedHTML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private var translationPromptHTML: String? {
        guard let questionTranslation = card.clozeQuestionTranslation?.trimmingCharacters(in: .whitespacesAndNewlines),
              !questionTranslation.isEmpty else {
            return nil
        }
        return questionTranslation
    }

    private func previewPair(for option: String) -> MatchingPair? {
        if optionsMatch(option, card.effectiveClozeAnswer) {
            return MatchingPair(
                cardID: card.id,
                senseID: card.primarySenseID ?? card.id,
                card: card,
                translation: card.translation
            )
        }

        guard let previewCard = previewCard(for: option) else { return nil }
        return MatchingPair(
            cardID: previewCard.id,
            senseID: previewCard.primarySenseID ?? previewCard.id,
            card: previewCard,
            translation: previewCard.translation
        )
    }

    private func previewCard(for option: String) -> WordCardContent? {
        let pools = [sessionChoicePool, deckChoicePool]
        var seen: Set<UUID> = [card.primarySenseID ?? card.id]

        for candidate in pools.flatMap({ $0 }) where seen.insert(candidate.primarySenseID ?? candidate.id).inserted {
            if optionsMatch(option, candidate.effectiveClozeAnswer)
                || candidate.forms.contains(where: { optionsMatch(option, $0.text) }) {
                return candidate
            }
        }

        return nil
    }
}

nonisolated enum ClozePromptMode: Sendable {
    case cloze
    case translation
}

private struct ClozeChoice: Identifiable {
    let id = UUID()
    let text: String
}

private let clozeCardShape = RoundedRectangle(cornerRadius: 18, style: .continuous)
private let clozeSentenceShape = RoundedRectangle(cornerRadius: 24, style: .continuous)

/// Тёмный сине-фиолетовый градиент карточки предложения (как лицо флешкарты).
private let clozeSentenceGradient = LinearGradient(
    gradient: Gradient(stops: [
        .init(color: oklch(0.25, 0.04, 265), location: 0),
        .init(color: oklch(0.19, 0.04, 265), location: 0.6),
        .init(color: oklch(0.15, 0.05, 270), location: 1),
    ]),
    startPoint: .topLeading,
    endPoint: .bottomTrailing
)

/// Цвета текста предложения на тёмной карточке.
private enum ClozeSentencePalette {
    static let text = Color.white.opacity(0.92)
    static let filled = StudyTargetHighlight.color
}

private struct ClozeSentenceText: View {
    let parts: ClozeSentenceParts
    let filledWord: String?

    var body: some View {
        Text(styledSentence)
    }

    private var styledSentence: AttributedString {
        var sentence = AttributedString(parts.prefix)
        sentence.font = .title3.weight(.semibold)
        sentence.foregroundColor = ClozeSentencePalette.text

        sentence.append(gapSegment)

        var suffix = AttributedString(parts.suffix)
        suffix.font = .title3.weight(.semibold)
        suffix.foregroundColor = ClozeSentencePalette.text

        sentence.append(suffix)
        return sentence
    }

    private var gapSegment: AttributedString {
        if let filledWord {
            var word = AttributedString(filledWord)
            word.font = .title3.weight(.bold)
            word.foregroundColor = ClozeSentencePalette.filled
            return word
        }

        var blanks = AttributedString("___")
        blanks.font = .title3.weight(.semibold)
        blanks.foregroundColor = ClozeSentencePalette.text
        return blanks
    }
}

/// The English example sentence with the correct answer filled in and highlighted,
/// shown in the helper line beneath the choices in reverse ("наоборот") mode.
private struct ClozeAnswerSentenceText: View {
    let parts: ClozeSentenceParts
    let answer: String

    var body: some View {
        Text(styledSentence)
            // Без этого Text в зажатом по высоте VStack обрезается в одну строку
            // с многоточием вместо переноса — даём ему расти по вертикали.
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var styledSentence: AttributedString {
        var sentence = AttributedString(parts.prefix)
        sentence.font = .subheadline
        sentence.foregroundColor = MatchPalette.foreground

        var word = AttributedString(answer)
        word.font = .subheadline.weight(.bold)
        word.foregroundColor = StudyTargetHighlight.translationColor
        sentence.append(word)

        var suffix = AttributedString(parts.suffix)
        suffix.font = .subheadline
        suffix.foregroundColor = MatchPalette.foreground
        sentence.append(suffix)

        return sentence
    }
}

private struct ClozeTranslationPromptText: View {
    let html: String

    var body: some View {
        Text(styledText)
    }

    private var styledText: AttributedString {
        let parsed = WordCardContent.plainTextWithBoldRange(fromHTMLFragment: html)
        var text = AttributedString(parsed.text)
        text.font = .title3.weight(.medium)
        text.foregroundColor = ClozeSentencePalette.text

        if let boldRange = parsed.boldRange,
           let range = Range(boldRange, in: text) {
            text[range].font = .title3.weight(.bold)
            text[range].foregroundColor = StudyTargetHighlight.color
        }

        return text
    }
}

private struct ClozeChoiceButton: View {
    let option: String
    let showResult: Bool
    let isSelected: Bool
    let isCorrect: Bool
    let isWrong: Bool
    let isDimmed: Bool
    let isReplayOnly: Bool
    let action: () -> Void

    var body: some View {
        Button {
            action()
        } label: {
            HStack(spacing: 10) {
                Text(option)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(MatchPalette.cardForeground)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                    .frame(maxWidth: .infinity, alignment: .leading)

                ZStack {
                    if showResult && (isSelected || isCorrect) {
                        Image(systemName: isWrong ? "xmark.circle.fill" : "checkmark.circle.fill")
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(isWrong ? MatchPalette.destructive : MatchPalette.success)
                    }
                }
                .frame(width: 22, height: 22)
            }
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(clozeCardShape.fill(cardFill))
            .overlay(clozeCardShape.strokeBorder(ringColor, lineWidth: ringWidth))
            .compositingGroup()
            .shadow(color: primaryShadow.color, radius: primaryShadow.radius, x: 0, y: primaryShadow.y)
        }
        .buttonStyle(.plain)
        .opacity(isDimmed || isReplayOnly ? 0.62 : 1)
        .modifier(ShakeEffect(animatableData: isWrong ? 1 : 0))
        .animation(.linear(duration: 0.4), value: isWrong)
    }

    private var cardFill: LinearGradient {
        if isCorrect {
            return LinearGradient(
                colors: [oklch(0.95, 0.04, 160, 0.95), oklch(0.88, 0.08, 160, 0.85)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        return LinearGradient(
            colors: [.white, oklch(0.995, 0.003, 250)],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var ringColor: Color {
        if isWrong { return MatchPalette.destructive }
        if isCorrect { return MatchPalette.success }
        if isSelected { return MatchPalette.primary }
        return MatchPalette.shadow.opacity(0.10)
    }

    private var ringWidth: CGFloat {
        if isCorrect { return 2 }
        if isWrong || isSelected { return 1.5 }
        return 0.5
    }

    private var primaryShadow: (color: Color, radius: CGFloat, y: CGFloat) {
        if isReplayOnly { return (.clear, 0, 0) }
        if isSelected { return (MatchPalette.primary.opacity(0.28), 8, 5) }
        if isCorrect { return (MatchPalette.success.opacity(0.32), 10, 4) }
        if isWrong { return (MatchPalette.destructive.opacity(0.28), 8, 5) }
        return (MatchPalette.shadow.opacity(0.12), 6, 4)
    }
}

private struct ClozeForgetButton: View {
    let action: () -> Void

    var body: some View {
        Button {
            action()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .heavy))
                    .foregroundStyle(MatchPalette.destructive)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(MatchPalette.destructive.opacity(0.14)))

                Text(L10n.text("Не помню"))
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(MatchPalette.destructive)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(clozeCardShape.fill(cardFill))
            .overlay(clozeCardShape.strokeBorder(MatchPalette.shadow.opacity(0.10), lineWidth: 0.5))
            .compositingGroup()
            .shadow(color: MatchPalette.shadow.opacity(0.12), radius: 6, x: 0, y: 4)
        }
        .buttonStyle(.plain)
    }

    private var cardFill: LinearGradient {
        LinearGradient(
            colors: [.white, oklch(0.995, 0.003, 250)],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}
