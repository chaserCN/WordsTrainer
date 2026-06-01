import SwiftUI

struct ClozeMCQStudyView: View {
    let card: WordCardContent
    let sessionChoicePool: [WordCardContent]
    let deckChoicePool: [WordCardContent]
    let totalCount: Int
    let remainingCount: Int
    let onAnswer: (ReviewOutcome) -> Void

    @State private var displayedCardID: UUID?
    @State private var selected: String?
    @State private var answered = false
    @State private var choices: [String] = []
    @State private var shakeCount: CGFloat = 0

    private var passed: Bool {
        guard let selected else { return false }
        return selected.compare(
            card.effectiveClozeAnswer,
            options: [.caseInsensitive, .diacriticInsensitive]
        ) == .orderedSame
    }

    private var hasAudio: Bool {
        card.audioExampleURL != nil || !card.clozeExamplePlainText.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            StudyProgressHeader(totalCount: totalCount, remainingCount: remainingCount)

            VStack(alignment: .leading, spacing: 14) {
                sentenceCard

                VStack(spacing: 10) {
                    ForEach(choices, id: \.self) { option in
                        ClozeChoiceButton(
                            option: option,
                            showResult: answered,
                            isSelected: selected == option,
                            isCorrect: answered && optionsMatch(option, card.effectiveClozeAnswer),
                            isWrong: answered && selected == option && !optionsMatch(option, card.effectiveClozeAnswer),
                            isDimmed: answered && selected != option && !optionsMatch(option, card.effectiveClozeAnswer)
                        ) {
                            select(option)
                        }
                        .disabled(answered)
                    }
                }

                if answered {
                    VStack(spacing: 16) {
                        if let translation = card.clozeExampleTranslation?.trimmingCharacters(in: .whitespacesAndNewlines),
                           !translation.isEmpty {
                            HTMLText(
                                html: translation,
                                foregroundColor: MatchPalette.foreground,
                                font: .subheadline
                            )
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                        }

                        Button("Дальше") {
                            onAnswer(passed ? .correct : .incorrect)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(MatchPalette.primary)
                        .controlSize(.large)
                        .frame(maxWidth: .infinity)
                    }
                    .padding(.top, 20)
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .onAppear {
            resetRoundIfNeeded()
        }
        .onChange(of: card.id) { _, _ in
            resetRound()
        }
    }

    private var sentenceCard: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let parts = card.clozeSentenceParts {
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
            .padding(.trailing, hasAudio ? 46 : 16)

            if hasAudio {
                Button {
                    WordAudioPlayer.shared.playExample(from: card)
                } label: {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(ClozeSentencePalette.audioTint)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(oklch(0.62, 0.2, 245, 0.18)))
                        .opacity(answered ? 1 : 0.4)
                }
                .buttonStyle(.plain)
                .disabled(!answered)
                .padding(10)
                .accessibilityLabel("Прослушать")
            }
        }
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
        .shadow(color: oklch(0.2, 0.12, 265, 0.4), radius: 18, x: 0, y: 12)
        .modifier(ShakeEffect(animatableData: shakeCount))
        .animation(.linear(duration: 0.4), value: shakeCount)
    }

    private func select(_ option: String) {
        guard !answered else { return }
        selected = option
        let isCorrect = optionsMatch(option, card.effectiveClozeAnswer)
        withAnimation(.easeInOut(duration: 0.28)) {
            answered = true
        }
        if !isCorrect {
            shakeCount += 1
        }
    }

    private func resetRoundIfNeeded() {
        guard displayedCardID != card.id else { return }
        resetRound()
    }

    private func resetRound() {
        displayedCardID = card.id
        selected = nil
        answered = false
        choices = card.clozeChoices(
            sessionPool: sessionChoicePool,
            deckPool: deckChoicePool
        ).shuffled()
    }

    private func optionsMatch(_ lhs: String, _ rhs: String) -> Bool {
        lhs.compare(rhs, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }
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
    static let filled = oklch(0.78, 0.16, 155)
    static let audioTint = oklch(0.78, 0.18, 245)
}

private struct ClozeSentenceText: View {
    let parts: ClozeSentenceParts
    let filledWord: String?

    var body: some View {
        Text(styledSentence)
            .transaction { transaction in
                transaction.animation = nil
            }
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

private struct ClozeChoiceButton: View {
    let option: String
    let showResult: Bool
    let isSelected: Bool
    let isCorrect: Bool
    let isWrong: Bool
    let isDimmed: Bool
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
            .shadow(color: primaryShadow.color, radius: primaryShadow.radius, x: 0, y: primaryShadow.y)
        }
        .buttonStyle(.plain)
        .opacity(isDimmed ? 0.62 : 1)
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
        if isSelected { return (MatchPalette.primary.opacity(0.28), 8, 5) }
        if isCorrect { return (MatchPalette.success.opacity(0.32), 10, 4) }
        if isWrong { return (MatchPalette.destructive.opacity(0.28), 8, 5) }
        return (MatchPalette.shadow.opacity(0.12), 6, 4)
    }
}
