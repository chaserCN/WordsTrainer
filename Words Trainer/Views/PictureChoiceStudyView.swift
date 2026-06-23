import SwiftUI

/// Picture → word: show the sense image and four word options in a 2×2 grid.
/// The correct word plays its audio when revealed; tapping a word plays it too.
struct PictureChoiceStudyView: View {
    let card: WordCardContent
    let sessionChoicePool: [WordCardContent]
    let deckChoicePool: [WordCardContent]
    let totalCount: Int
    let remainingCount: Int
    let onAnswer: (ReviewOutcome) -> Void

    @State private var displayedRoundID: UUID?
    @State private var selected: UUID?
    @State private var answered = false
    @State private var choices: [WordCardContent] = []
    @State private var optionFeedbackTrigger = false
    @State private var nextFeedbackTrigger = false
    @State private var previewPair: MatchingPair?
    @State private var suppressedOptionTap: UUID?
    // The previous card's correct lemma, excluded from the next card's options
    // so a repeated word can't carry its selected/shake state across cards.
    @State private var previousCorrectLemma: String?

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
    ]

    private var passed: Bool {
        selected == correctOptionID
    }

    private var correctOptionID: UUID {
        card.optionID
    }

    private var roundID: UUID {
        card.primarySenseID ?? card.id
    }

    /// True only once resetRound has caught up to the current card. The card
    /// prop changes the instant Next is tapped, but answered/selected are reset
    /// a beat later in .onChange(of: roundID). In that gap the previous card's
    /// answer must not paint onto the new card (e.g. a repeated distractor
    /// flashing red), so all answer state is read through this gate.
    private var isCurrentRound: Bool {
        displayedRoundID == roundID
    }

    private var effectiveAnswered: Bool {
        isCurrentRound && answered
    }

    private var effectiveSelected: UUID? {
        isCurrentRound ? selected : nil
    }

    var body: some View {
        VStack(spacing: 16) {
            StudyProgressHeader(totalCount: totalCount, remainingCount: remainingCount)

            if let imageURL = card.imageURL {
                PictureChoiceImage(url: imageURL)
                    .frame(maxWidth: .infinity)
                    .frame(maxHeight: .infinity)
            } else {
                // A picture-choice queue only contains senses with an image, so
                // this is a safety fallback rather than an expected state.
                Spacer(minLength: 0)
            }

            LazyVGrid(columns: columns, spacing: 12) {
                // optionID (sense id) keeps options distinct within a card and
                // drives all answer logic below. Cross-card freshness is handled
                // by the grid's .id(roundID).
                ForEach(choices, id: \.optionID) { choice in
                    let id = choice.optionID
                    PictureChoiceButton(
                        word: choice.word,
                        showResult: effectiveAnswered,
                        isSelected: effectiveSelected == id,
                        isCorrect: effectiveAnswered && id == correctOptionID,
                        isWrong: effectiveAnswered && effectiveSelected == id && id != correctOptionID,
                        isDimmed: effectiveAnswered && effectiveSelected != id && id != correctOptionID
                    ) {
                        optionFeedbackTrigger.toggle()
                        select(choice)
                    }
                    // Long-press any option, at any time, to peek at its full
                    // flashcard (same gesture as the sentence mode).
                    .simultaneousGesture(
                        LongPressGesture(minimumDuration: 0.45)
                            .onEnded { _ in
                                suppressedOptionTap = id
                                withAnimation(.easeOut(duration: 0.18)) {
                                    previewPair = MatchingPair(
                                        cardID: choice.id,
                                        senseID: id,
                                        card: choice,
                                        translation: choice.translation
                                    )
                                }
                            }
                    )
                }
            }
            // Give the whole grid a per-card identity so every card gets a fresh
            // set of buttons. Without this, an option that repeats on the next
            // card keeps its previous shake/selected state (jitter).
            .id(roundID)

            // The answer's translation, shown above Next once answered — same
            // place the sentence mode shows the example translation.
            answerTranslation
                .frame(maxWidth: .infinity)
                .opacity(effectiveAnswered ? 1 : 0)

            // Reserve one action slot so revealing an answer doesn't push the
            // grid and image upward; only the visible button changes.
            ZStack {
                CompactRecallOutcomeButton(
                    title: "Не помню",
                    systemImage: "xmark",
                    titleColor: MatchPalette.destructive,
                    iconColor: MatchPalette.destructive,
                    iconBackground: MatchPalette.destructive.opacity(0.14)
                ) {
                    revealAnswerAsForgotten()
                }
                .opacity(effectiveAnswered ? 0 : 1)
                .disabled(effectiveAnswered)
                .accessibilityHidden(effectiveAnswered)

                Button(L10n.text("Дальше")) {
                    nextFeedbackTrigger.toggle()
                    advance()
                }
                .buttonStyle(.borderedProminent)
                .tint(MatchPalette.primary)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
                .sensoryFeedback(.selection, trigger: nextFeedbackTrigger)
                .opacity(effectiveAnswered ? 1 : 0)
                .disabled(!effectiveAnswered)
                .accessibilityHidden(!effectiveAnswered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 28)
        .sensoryFeedback(.selection, trigger: optionFeedbackTrigger)
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
        .onAppear {
            resetRoundIfNeeded()
        }
        .onChange(of: roundID) { _, _ in
            resetRound()
        }
    }

    @ViewBuilder
    private var answerTranslation: some View {
        if let translation = answerTranslationHTML {
            HTMLText(
                html: translation,
                foregroundColor: MatchPalette.foreground,
                font: .subheadline
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
        let translation = card.translation.trimmingCharacters(in: .whitespacesAndNewlines)
        return translation.isEmpty ? nil : "<b>\(Self.escapedHTML(translation))</b>"
    }

    private static func escapedHTML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private func select(_ choice: WordCardContent) {
        // A long-press fires this option's tap too; swallow that one tap so
        // peeking at the card does not also count as an answer.
        if suppressedOptionTap == choice.optionID {
            suppressedOptionTap = nil
            return
        }
        guard !effectiveAnswered else {
            WordAudioPlayer.shared.playWord(from: choice)
            return
        }
        selected = choice.optionID
        answered = true
        // Play audio only on a correct answer; a wrong pick stays silent.
        if choice.optionID == correctOptionID {
            WordAudioPlayer.shared.playWord(from: card)
        }
    }

    private func revealAnswerAsForgotten() {
        guard !effectiveAnswered else { return }
        selected = nil
        withAnimation(.easeInOut(duration: 0.28)) {
            answered = true
        }
    }

    private func advance() {
        previousCorrectLemma = card.lemma
        onAnswer(passed ? .correct : .incorrect)
    }

    private func resetRoundIfNeeded() {
        guard displayedRoundID != roundID else { return }
        resetRound()
    }

    private func resetRound() {
        displayedRoundID = roundID
        selected = nil
        answered = false
        previewPair = nil
        suppressedOptionTap = nil
        choices = buildChoices()
    }

    /// One correct card plus up to three distractor words drawn first from the
    /// current session, then from the rest of the deck.
    private func buildChoices() -> [WordCardContent] {
        // Deduplicate by lemma, not surface word: "glass" and "a glass" share a
        // lemma and must not appear together as near-identical options.
        var seenLemmas = Set([normalized(card.lemma)])
        // Keep the previous card's correct lemma out of this card's distractors,
        // so SwiftUI can't carry a repeated button's selected/shake state over.
        if let previousCorrectLemma {
            seenLemmas.insert(normalized(previousCorrectLemma))
        }
        var distractors: [WordCardContent] = []

        for pool in [sessionChoicePool, deckChoicePool] {
            for candidate in pool.shuffled() where distractors.count < 3 {
                guard candidate.id != card.id else { continue }
                let key = normalized(candidate.lemma)
                guard !candidate.word.isEmpty, !seenLemmas.contains(key) else { continue }
                seenLemmas.insert(key)
                distractors.append(candidate)
            }
            if distractors.count >= 3 { break }
        }

        return ([card] + distractors).shuffled()
    }

    private func normalized(_ word: String) -> String {
        word.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension WordCardContent {
    /// Per-option identity. A queue item is one sense focused onto its card, so
    /// the sense id distinguishes two senses that share a card id.
    var optionID: UUID { primarySenseID ?? id }
}

private let pictureChoiceCardShape = RoundedRectangle(cornerRadius: 18, style: .continuous)

private struct PictureChoiceImage: View {
    let url: URL

    var body: some View {
        Group {
            if url.isFileURL, let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFit()
                    case .empty, .failure:
                        Color.white.opacity(0.10)
                    @unknown default:
                        Color.white.opacity(0.10)
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Color.white.opacity(0.22), lineWidth: 1)
        )
        .compositingGroup()
        .shadow(color: MatchPalette.shadow.opacity(0.18), radius: 14, x: 0, y: 8)
    }
}

private struct PictureChoiceButton: View {
    let word: String
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
            Text(word)
                .font(.headline.weight(.semibold))
                .foregroundStyle(MatchPalette.cardForeground)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, minHeight: 56)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(pictureChoiceCardShape.fill(cardFill))
                .overlay(pictureChoiceCardShape.strokeBorder(ringColor, lineWidth: ringWidth))
                .compositingGroup()
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
