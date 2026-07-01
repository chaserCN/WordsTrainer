import SwiftUI

struct FlashcardStudyView: View {
    let card: WordCardContent
    let displayMode: FlashcardDisplayMode
    let promptMode: FlashcardPromptMode
    let totalCount: Int
    let remainingCount: Int
    let isAnswerEnabled: Bool
    let onAnswer: (ReviewOutcome) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isFlipped = false
    @State private var hasExpandedForAnswer = false
    @State private var revealedCardID: String?
    @State private var measuredFrontCardHeight: CGFloat = 0
    @State private var measuredBackCardHeight: CGFloat = 0
    @State private var cardRotation: Double = 0
    @State private var cardChangeDirection: StudyCardChangeDirection = .right
    @State private var answerExitOffset: CGSize = .zero
    @State private var isAnswerExitAnimating = false
    @State private var answerExitGeneration = 0
    @State private var isFlipAnimating = false
    @State private var flipGeneration = 0
    @State private var renderedCardID: String?
    @State private var didAutoPlayReverseAudio = false

    private static let cardHeightFraction: CGFloat = 0.36
    private static let minimumCardHeight: CGFloat = 275
    private static let verticalGap: CGFloat = 16
    private static let progressHeaderHeight: CGFloat = 28
    private static let progressHeaderTopPadding: CGFloat = 8
    private static let progressHeaderReservedHeight = progressHeaderHeight + progressHeaderTopPadding
    private static let controlsHeight: CGFloat = 118
    private static let actionGap: CGFloat = 20
    private static let flipDuration = 0.26
    private static let answerPushDuration = 0.08
    private static let answerReturnDuration = 0.12
    private static let flipPerspective: CGFloat = 0.25

    private var hasWordAudio: Bool {
        card.audioWordURL != nil
    }

    private var notesText: String? {
        presentation.notesHTML?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
    }

    private var presentation: FlashcardPresentation {
        FlashcardPresentation(card: card, displayMode: displayMode, promptMode: promptMode)
    }

    private var presentationStateKey: String {
        "\(presentation.id):\(promptMode.stateKeyComponent)"
    }

    var body: some View {
        GeometryReader { proxy in
            let maxCardHeight = max(
                Self.minimumCardHeight,
                proxy.size.height
                    - Self.progressHeaderReservedHeight
                    - Self.controlsHeight
                    - Self.actionGap
                    - Self.verticalGap * 2
            )
            let baseCardHeight = max(
                Self.minimumCardHeight,
                min(
                    maxCardHeight,
                    (proxy.size.height - Self.progressHeaderReservedHeight - 132) * Self.cardHeightFraction
                )
            )

            ZStack(alignment: .top) {
                VStack(spacing: 0) {
                    StudyProgressHeader(totalCount: totalCount, remainingCount: remainingCount)
                        .padding(.horizontal, 16)
                        .frame(height: Self.progressHeaderHeight)
                        .padding(.top, Self.progressHeaderTopPadding)

                    Spacer(minLength: Self.verticalGap)

                    VStack(spacing: Self.actionGap) {
                        flashcard(baseHeight: baseCardHeight, maxHeight: maxCardHeight)

                        actionButtons
                    }
                    .padding(.horizontal, 16)
                    .offset(answerExitOffset)

                    Spacer(minLength: Self.verticalGap)
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
        }
        .task(id: presentationStateKey) {
            resetForNewCard()
            if promptMode == .word {
                WordAudioPlayer.shared.playWord(from: card)
            }
        }
    }

    private var isUsingCurrentCardState: Bool {
        renderedCardID == nil || renderedCardID == presentation.id
    }

    private var isShowingBack: Bool {
        isUsingCurrentCardState && isFlipped
    }

    private var actionButtons: some View {
        ReviewOutcomeControls(
            forgotTitle: "Снова",
            rememberedTitle: "Хорошо",
            verticalPadding: 14,
            isEnabled: isAnswerEnabled && !isAnswerExitAnimating,
            onAnswer: answer
        )
    }

    private func flashcard(baseHeight: CGFloat, maxHeight: CGFloat) -> some View {
        let cardHeight = resolvedCardHeight(baseHeight: baseHeight, maxHeight: maxHeight)

        return ZStack(alignment: .topTrailing) {
            ZStack(alignment: .top) {
                ZStack(alignment: .topTrailing) {
                    cardBody(isBack: false, minHeight: cardHeight, layout: .fixed)
                        .frame(height: cardHeight, alignment: .top)

                    if hasWordAudio && promptMode == .word {
                        audioButton
                            .padding(12)
                    }
                }
                    .frame(height: cardHeight, alignment: .top)
                    .modifier(FlashcardSideVisibility(rotation: cardRotation, side: .front))
                    .allowsHitTesting(!isShowingBack)

                ZStack(alignment: .topTrailing) {
                    Group {
                        if hasExpandedForAnswer {
                            ScrollView(.vertical, showsIndicators: false) {
                                cardBody(isBack: true, minHeight: baseHeight, layout: .expanded)
                                    .background(
                                        GeometryReader { proxy in
                                            Color.clear
                                                .preference(
                                                    key: ExpandedFlashcardHeightKey.self,
                                                    value: proxy.size.height
                                                )
                                        }
                                    )
                            }
                            .scrollBounceBehavior(.basedOnSize)
                            .onPreferenceChange(ExpandedFlashcardHeightKey.self) { height in
                                setMeasuredHeight(height, side: .back)
                            }
                        } else {
                            cardBody(isBack: true, minHeight: cardHeight, layout: .fixed)
                        }
                    }
                    .frame(height: cardHeight, alignment: .top)

                    if hasWordAudio {
                        audioButton
                            .padding(12)
                    }
                }
                .frame(height: cardHeight, alignment: .top)
                .rotation3DEffect(
                    .degrees(180),
                    axis: (x: 0, y: 1, z: 0),
                    perspective: Self.flipPerspective
                )
                .modifier(FlashcardSideVisibility(rotation: cardRotation, side: .back))
                .allowsHitTesting(isShowingBack)
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .background(cardHeightMeasurementViews(baseHeight: baseHeight))
        .frame(height: cardHeight, alignment: .top)
        .contentShape(flashcardShape)
        .onTapGesture {
            flipCard()
        }
        .background(
            flashcardShape
                .fill(cardGradient)
                .overlay { cardGlow }
                .clipShape(flashcardShape)
        )
        .overlay(flashcardShape.strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5))
        .rotation3DEffect(
            .degrees(isUsingCurrentCardState ? cardRotation : 0),
            axis: (x: 0, y: 1, z: 0),
            perspective: Self.flipPerspective
        )
        .allowsHitTesting(!isFlipAnimating)
        // No compositingGroup here: it flattens the 3D-rotated layer into an
        // offscreen bitmap every frame of the flip, which janks the animation
        // (and can collapse the two-phase rotation into a snap) and is costly
        // on device. The card shadows render fine without it.
        .shadow(color: MatchPalette.shadow.opacity(0.18), radius: 10, x: 0, y: 6)
        .shadow(color: MatchPalette.shadow.opacity(0.08), radius: 4, x: 0, y: 2)
    }

    private var audioButton: some View {
        Button {
            WordAudioPlayer.shared.playWord(from: card)
        } label: {
            Image(systemName: "speaker.wave.2.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(FlashcardPalette.audioTint)
                .frame(width: 34, height: 34)
                .background(
                    Circle()
                        .fill(FlashcardPalette.audioTint.opacity(0.16))
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Прослушать")
    }

    /// Передняя сторона — холодный сине-фиолетовый, обратная — мягкая сирень (как в Lovable).
    private var cardGradient: LinearGradient {
        let stops: [Gradient.Stop] = isShowingBack
            ? [
                .init(color: oklch(0.26, 0.05, 300), location: 0),
                .init(color: oklch(0.19, 0.05, 300), location: 0.6),
                .init(color: oklch(0.15, 0.06, 305), location: 1),
            ]
            : [
                .init(color: oklch(0.25, 0.04, 265), location: 0),
                .init(color: oklch(0.19, 0.04, 265), location: 0.6),
                .init(color: oklch(0.15, 0.05, 270), location: 1),
            ]
        return LinearGradient(gradient: Gradient(stops: stops), startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// Мягкое цветное свечение в углу карты.
    private var cardGlow: some View {
        Circle()
            .fill(isShowingBack ? oklch(0.65, 0.18, 300, 0.22) : oklch(0.7, 0.18, 245, 0.25))
            .frame(width: 200, height: 200)
            .blur(radius: 55)
            .offset(x: isShowingBack ? -70 : 80, y: isShowingBack ? 90 : -70)
    }

    private func cardHeightMeasurementViews(baseHeight: CGFloat) -> some View {
        ZStack {
            measuredCardBody(isBack: false, minHeight: baseHeight, layout: .fixed) { height in
                setMeasuredHeight(height, side: .front)
            }

            measuredCardBody(isBack: true, minHeight: baseHeight, layout: .expanded) { height in
                setMeasuredHeight(height, side: .back)
            }
        }
    }

    private func measuredCardBody(
        isBack: Bool,
        minHeight: CGFloat,
        layout: CardBodyLayout,
        onHeightChange: @escaping (CGFloat) -> Void
    ) -> some View {
        cardBody(isBack: isBack, minHeight: minHeight, layout: layout)
            .fixedSize(horizontal: false, vertical: true)
            .hidden()
            .accessibilityHidden(true)
            .allowsHitTesting(false)
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .preference(key: ExpandedFlashcardHeightKey.self, value: proxy.size.height)
                }
            )
            .onPreferenceChange(ExpandedFlashcardHeightKey.self) { height in
                guard height > 0 else { return }
                onHeightChange(height)
            }
    }

    private func resolvedCardHeight(baseHeight: CGFloat, maxHeight: CGFloat) -> CGFloat {
        let frontHeight = max(baseHeight, measuredFrontCardHeight)
        let backHeight = max(frontHeight, measuredBackCardHeight)
        let targetHeight = hasExpandedForAnswer ? backHeight : frontHeight
        return min(targetHeight, maxHeight)
    }

    private func setMeasuredHeight(_ height: CGFloat, side: CardMeasuredSide) {
        guard height > 0 else { return }

        switch side {
        case .front:
            guard abs(measuredFrontCardHeight - height) > 0.5 else { return }
        case .back:
            guard abs(measuredBackCardHeight - height) > 0.5 else { return }
        }

        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            switch side {
            case .front:
                measuredFrontCardHeight = height
            case .back:
                measuredBackCardHeight = height
            }
        }
    }

    private enum CardBodyLayout {
        case fixed
        case expanded
    }

    @ViewBuilder
    private func cardBody(isBack: Bool, minHeight: CGFloat, layout: CardBodyLayout) -> some View {
        if layout == .fixed {
            cardBodyContent(isBack: isBack, minHeight: minHeight, layout: layout)
                .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .topLeading)
        } else {
            cardBodyContent(isBack: isBack, minHeight: minHeight, layout: layout)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private func cardBodyContent(isBack: Bool, minHeight: CGFloat, layout: CardBodyLayout) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            flipLabel(isBack: isBack, minHeight: minHeight, layout: layout)

            if isBack {
                if notesText != nil {
                    exampleDetails
                        .padding(.horizontal, 18)
                        .padding(.top, 12)
                        .padding(.bottom, 20)
                }
            }
        }
    }

    @ViewBuilder
    private func flipLabel(isBack: Bool, minHeight: CGFloat, layout: CardBodyLayout) -> some View {
        if layout == .fixed && !isBack {
            flipLabelContent(isBack: isBack, layout: layout)
                .padding(.horizontal, 18)
                .padding(.top, 18)
                .frame(
                    maxWidth: .infinity,
                    minHeight: flipAreaMinHeight(isBack: isBack, cardMinHeight: minHeight),
                    alignment: .topLeading
                )
                .contentShape(Rectangle())
        } else {
            flipLabelContent(isBack: isBack, layout: layout)
                .padding(.horizontal, 18)
                .padding(.top, 18)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .contentShape(Rectangle())
        }
    }

    @ViewBuilder
    private func flipLabelContent(isBack: Bool, layout: CardBodyLayout) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 10) {
                Circle()
                    .fill(wordDotColor(isBack: isBack))
                    .frame(width: 10, height: 10)
                    .shadow(color: wordDotColor(isBack: isBack).opacity(0.7), radius: 5)
                Text(isBack ? presentation.backTitle : presentation.frontTitle)
                    .font(.title2.bold())
                    .foregroundStyle(FlashcardPalette.primaryText)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, isWordAudioAvailable(onBack: isBack) ? 40 : 0)
            }

            if isBack {
                bodyText(
                    presentation.backBody,
                    isHTML: presentation.backBodyIsHTML,
                    font: .title3.weight(.semibold),
                    color: FlashcardPalette.primaryText
                )
            } else {
                bodyText(
                    presentation.frontBody,
                    isHTML: presentation.frontBodyIsHTML,
                    font: .title3.weight(.medium),
                    color: FlashcardPalette.primaryText
                )
                if revealedCardID == presentation.id,
                   let exampleTranslation = presentation.frontRevealedHTML?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !exampleTranslation.isEmpty {
                    HTMLText(
                        html: exampleTranslation,
                        foregroundColor: FlashcardPalette.secondaryText,
                        font: .body,
                        emphasisColor: StudyTargetHighlight.color
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if layout == .fixed && !isBack {
                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder
    private func bodyText(_ value: String, isHTML: Bool, font: Font, color: Color) -> some View {
        if isHTML {
            HTMLText(
                html: value,
                foregroundColor: color,
                font: font,
                emphasisColor: StudyTargetHighlight.color
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
        } else {
            Text(attributedBodyText(value, font: font, color: color))
                .lineLimit(nil)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)
        }
    }

    private func flipAreaMinHeight(isBack: Bool, cardMinHeight: CGFloat) -> CGFloat {
        let headerPadding: CGFloat = 18 + 12
        let exampleControls: CGFloat = isBack ? 52 : 0
        return max(80, cardMinHeight - headerPadding - exampleControls - 20)
    }

    private func wordDotColor(isBack: Bool) -> Color {
        isBack ? oklch(0.72, 0.14, 300) : oklch(0.65, 0.2, 245)
    }

    private func isWordAudioAvailable(onBack isBack: Bool) -> Bool {
        hasWordAudio && (promptMode == .word || isBack)
    }

    private var exampleDetails: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let notesText {
                HTMLText(
                    html: notesText,
                    foregroundColor: FlashcardPalette.mutedText,
                    font: .subheadline
                )
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func attributedBodyText(_ source: String, font: Font, color: Color) -> AttributedString {
        let (example, boldRange) = WordCardContent.plainTextWithBoldRange(fromHTMLFragment: source)
        var attributed = AttributedString(example)
        attributed.font = font
        attributed.foregroundColor = color

        if let boldRange, let range = Range(boldRange, in: attributed) {
            attributed[range].font = font.weight(.bold)
            attributed[range].foregroundColor = StudyTargetHighlight.color
        } else if let stringRange = example.range(of: presentation.answer, options: [.caseInsensitive, .diacriticInsensitive]),
                  let range = Range(stringRange, in: attributed) {
            attributed[range].font = font.weight(.bold)
            attributed[range].foregroundColor = StudyTargetHighlight.color
        }
        return attributed
    }

    private func flipCard() {
        guard !isFlipAnimating else { return }
        FrameHitchMonitor.shared.mark("card flip")
        renderedCardID = presentation.id

        let targetIsBack = !isFlipped

        if reduceMotion {
            if targetIsBack {
                hasExpandedForAnswer = true
            }
            isFlipped = targetIsBack
            cardRotation = targetIsBack ? 180 : 0
            revealedCardID = presentation.id
            playWordAudioIfRevealing(back: targetIsBack)
            return
        }

        isFlipAnimating = true
        flipGeneration += 1

        let generation = flipGeneration

        withAnimation(.easeInOut(duration: Self.flipDuration)) {
            if targetIsBack {
                hasExpandedForAnswer = true
            }
            isFlipped = targetIsBack
            cardRotation = targetIsBack ? 180 : 0
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.flipDuration / 2) {
            guard generation == flipGeneration else { return }
            if targetIsBack {
                revealedCardID = presentation.id
                playWordAudioIfRevealing(back: true)
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.flipDuration) {
            guard generation == flipGeneration else { return }
            isFlipAnimating = false
        }
    }

    /// In reverse mode the English word lives on the back, so play its audio once
    /// the first time the flip reveals it — not on every subsequent flip back. (In
    /// forward mode the word is on the front and is already spoken on appear, so
    /// flipping to the translation stays silent.)
    private func playWordAudioIfRevealing(back: Bool) {
        guard back, promptMode == .translation else { return }
        guard !didAutoPlayReverseAudio else { return }
        didAutoPlayReverseAudio = true
        WordAudioPlayer.shared.playWord(from: card)
    }

    private func answer(_ outcome: ReviewOutcome) {
        guard !isAnswerExitAnimating else { return }

        switch outcome {
        case .forgot, .incorrect:
            cardChangeDirection = .left
        case .remembered, .correct:
            cardChangeDirection = .right
        }

        if reduceMotion {
            resetCardFaceBeforeAnswerSubmit()
            onAnswer(outcome)
            return
        }

        isAnswerExitAnimating = true
        answerExitGeneration += 1
        let generation = answerExitGeneration

        withAnimation(.easeOut(duration: Self.answerPushDuration)) {
            answerExitOffset = answerExitOffset(for: cardChangeDirection)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.answerPushDuration) {
            guard generation == answerExitGeneration else { return }

            withAnimation(.easeOut(duration: Self.answerReturnDuration)) {
                answerExitOffset = .zero
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.answerPushDuration + Self.answerReturnDuration) {
            guard generation == answerExitGeneration else { return }

            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                resetCardFaceBeforeAnswerSubmit()
                isAnswerExitAnimating = false
                onAnswer(outcome)
            }
        }
    }

    private func resetCardFaceBeforeAnswerSubmit() {
        flipGeneration += 1
        isFlipped = false
        hasExpandedForAnswer = false
        revealedCardID = nil
        cardRotation = 0
        isFlipAnimating = false
    }

    private func answerExitOffset(for direction: StudyCardChangeDirection) -> CGSize {
        switch direction {
        case .left:
            return CGSize(width: -22, height: 28)
        case .right:
            return CGSize(width: 22, height: 28)
        }
    }

    private func resetForNewCard() {
        flipGeneration += 1
        answerExitGeneration += 1
        renderedCardID = presentation.id
        isFlipped = false
        revealedCardID = nil
        hasExpandedForAnswer = false
        measuredFrontCardHeight = 0
        measuredBackCardHeight = 0
        cardRotation = 0
        isFlipAnimating = false
        answerExitOffset = .zero
        isAnswerExitAnimating = false
        didAutoPlayReverseAudio = false
    }
}

private enum FlashcardFlipSide {
    case front
    case back
}

private enum CardMeasuredSide {
    case front
    case back
}

private struct FlashcardSideVisibility: AnimatableModifier {
    var rotation: Double
    let side: FlashcardFlipSide

    var animatableData: Double {
        get { rotation }
        set { rotation = newValue }
    }

    func body(content: Content) -> some View {
        content
            .opacity(opacity)
            .accessibilityHidden(opacity == 0)
    }

    private var opacity: Double {
        switch side {
        case .front:
            return isBackVisible ? 0 : 1
        case .back:
            return isBackVisible ? 1 : 0
        }
    }

    private var isBackVisible: Bool {
        let normalized = ((rotation.truncatingRemainder(dividingBy: 360)) + 360)
            .truncatingRemainder(dividingBy: 360)
        return normalized >= 90 && normalized < 270
    }
}

private struct FlashcardPresentation {
    let id: String
    let frontTitle: String
    let frontBody: String
    let frontBodyIsHTML: Bool
    let frontRevealedHTML: String?
    let backTitle: String
    let backBody: String
    let backBodyIsHTML: Bool
    let notesHTML: String?
    let answer: String

    init(card: WordCardContent, displayMode: FlashcardDisplayMode, promptMode: FlashcardPromptMode) {
        let base = FlashcardBasePresentation(card: card, displayMode: displayMode)
        switch displayMode {
        case .oneSense:
            let sense = card.primarySense
            id = "\(card.id.uuidString):\(sense?.id.uuidString ?? card.id.uuidString):sense"
            notesHTML = Self.joinNotes([
                Self.etymologyNote(card.etymology),
                sense?.note,
                card.cardNotes,
            ])
        case .wholeCard:
            id = "\(card.id.uuidString):whole"
            notesHTML = Self.joinNotes([
                Self.etymologyNote(card.etymology),
                card.cardNotes,
            ])
        }
        answer = base.answer

        switch promptMode {
        case .word:
            frontTitle = base.word
            frontBody = base.exampleText
            frontBodyIsHTML = false
            frontRevealedHTML = base.exampleTranslation
            backTitle = base.word
            backBody = base.translation
            backBodyIsHTML = false
        case .translation:
            frontTitle = base.translation
            frontBody = base.exampleTranslation ?? ""
            frontBodyIsHTML = true
            frontRevealedHTML = nil
            backTitle = base.word
            backBody = base.exampleText
            backBodyIsHTML = false
        }
    }

    private static func etymologyNote(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return "<b>Этимология:</b> \(trimmed)"
    }

    private static func joinNotes(_ values: [String?]) -> String? {
        let notes = values.compactMap { value -> String? in
            guard let value else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        guard !notes.isEmpty else { return nil }
        return notes.joined(separator: "<br><br>")
    }
}

nonisolated enum FlashcardPromptMode: Sendable {
    case word
    case translation

    var stateKeyComponent: String {
        switch self {
        case .word:
            return "word"
        case .translation:
            return "translation"
        }
    }
}

private struct FlashcardBasePresentation {
    let word: String
    let translation: String
    let exampleText: String
    let exampleTranslation: String?
    let answer: String

    init(card: WordCardContent, displayMode: FlashcardDisplayMode) {
        switch displayMode {
        case .oneSense:
            let sense = card.primarySense
            word = sense?.displayPattern ?? card.word
            translation = sense?.translation ?? card.translation
            // Keep the raw example with its <b>…</b> so the deck's own highlight
            // range survives (e.g. <b>beads</b>). Stripping to plain text here
            // dropped it, and the fallback then bolded only the bare answer
            // ("bead"), leaving the plural "s" un-highlighted.
            exampleText = sense?.exampleText ?? card.clozeExamplePlainText
            exampleTranslation = Self.trimmedNonEmpty(sense?.clozeExampleTranslation ?? card.clozeExampleTranslation)
                ?? Self.trimmedNonEmpty(card.clozeQuestionTranslation)
            answer = card.effectiveClozeAnswer
        case .wholeCard:
            let activeSenses = card.activeSenses
            let exampleSense = card.primarySense ?? activeSenses.first
            word = card.baseWord
            translation = activeSenses.map(\.translation).joined(separator: "; ")
            exampleText = exampleSense?.exampleText ?? card.clozeExamplePlainText
            exampleTranslation = Self.trimmedNonEmpty(exampleSense?.clozeExampleTranslation)
                ?? Self.trimmedNonEmpty(card.clozeQuestionTranslation)
            answer = exampleSense?.clozeAnswer ?? card.effectiveClozeAnswer
        }
    }

    private static func trimmedNonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private struct ExpandedFlashcardHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private enum FlashcardPalette {
    static let primaryText = Color.white
    static let secondaryText = oklch(0.92, 0.01, 260)
    static let mutedText = oklch(0.72, 0.015, 260)
    static let audioTint = oklch(0.78, 0.18, 245)
}

private let flashcardShape = RoundedRectangle(cornerRadius: 28, style: .continuous)

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
