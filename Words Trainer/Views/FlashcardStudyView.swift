import SwiftUI

struct FlashcardStudyView: View {
    let card: WordCardContent
    let totalCount: Int
    let remainingCount: Int
    let isAnswerEnabled: Bool
    let onAnswer: (ReviewOutcome) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isFlipped = false
    @State private var isExampleExpanded = false
    @State private var frontCardContentHeight: CGFloat = 0
    @State private var backCardContentHeight: CGFloat = 0
    @State private var expandedCardContentHeight: CGFloat = 0
    @State private var cardRotation: Double = 0
    @State private var cardChangeDirection: StudyCardChangeDirection = .right
    @State private var isFlipAnimating = false
    @State private var flipGeneration = 0
    @State private var progressHeaderBottom: CGFloat = 0
    @State private var collapsedCardTop: CGFloat = 0

    private static let cardHeightFraction: CGFloat = 0.34
    private static let verticalGap: CGFloat = 16
    private static let controlsHeight: CGFloat = 118
    private static let actionGap: CGFloat = 20
    private static let flipHalfDuration = 0.18
    private static let flipPerspective: CGFloat = 0.25
    private static let mediaProgressGap: CGFloat = 30
    private static let mediaCardGap: CGFloat = 20
    private static let minMediaImageSize: CGFloat = 72
    private static let maxMediaImageSize: CGFloat = 180
    private static let fallbackProgressHeaderBottom: CGFloat = 21
    private static let fallbackActionHeight: CGFloat = 56
    private static let layoutCoordinateSpace = "FlashcardStudyLayout"

    private var hasWordAudio: Bool {
        card.audioWordURL != nil
    }

    private var notesText: String? {
        card.explanation?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
    }

    private var cardImageURL: URL? {
        card.imageURL ?? card.clozeExampleImageURL
    }

    var body: some View {
        GeometryReader { proxy in
            let maxCardHeight = max(
                210,
                proxy.size.height - Self.controlsHeight - Self.actionGap - Self.verticalGap * 2
            )
            let baseCardHeight = max(
                210,
                min(maxCardHeight, (proxy.size.height - 132) * Self.cardHeightFraction)
            )

            ZStack(alignment: .top) {
                if let cardImageURL {
                    backgroundMediaImage(
                        url: cardImageURL,
                        containerSize: proxy.size,
                        baseCardHeight: baseCardHeight
                    )
                }

                VStack(spacing: 0) {
                    StudyProgressHeader(totalCount: totalCount, remainingCount: remainingCount)
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                        .background(progressHeaderMeasurement)

                    Spacer(minLength: Self.verticalGap)

                    VStack(spacing: Self.actionGap) {
                        flashcard(baseHeight: baseCardHeight, maxHeight: maxCardHeight)
                            .background(collapsedCardTopMeasurement)

                        actionButtons
                    }
                    .padding(.horizontal, 16)
                    .studyCardChangeTransition(cardID: card.id, direction: cardChangeDirection)

                    Spacer(minLength: Self.verticalGap)
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
            .coordinateSpace(.named(Self.layoutCoordinateSpace))
        }
        .task(id: card.id) {
            resetForNewCard()
            WordAudioPlayer.shared.playWord(from: card)
        }
    }

    private var actionButtons: some View {
        ReviewOutcomeControls(
            forgotTitle: "Снова",
            rememberedTitle: "Хорошо",
            verticalPadding: 14,
            isEnabled: isAnswerEnabled,
            onAnswer: answer
        )
    }

    private var progressHeaderMeasurement: some View {
        GeometryReader { proxy in
            Color.clear
                .preference(
                    key: FlashcardProgressBottomPreferenceKey.self,
                    value: proxy.frame(in: .named(Self.layoutCoordinateSpace)).maxY
                )
        }
        .onPreferenceChange(FlashcardProgressBottomPreferenceKey.self) { bottom in
            guard bottom > 0 else { return }
            progressHeaderBottom = bottom
        }
    }

    private var collapsedCardTopMeasurement: some View {
        GeometryReader { proxy in
            Color.clear
                .preference(
                    key: FlashcardCollapsedTopPreferenceKey.self,
                    value: proxy.frame(in: .named(Self.layoutCoordinateSpace)).minY
                )
        }
        .onPreferenceChange(FlashcardCollapsedTopPreferenceKey.self) { top in
            guard top > 0, !isExampleExpanded else { return }
            collapsedCardTop = top
        }
    }

    private func backgroundMediaImage(url: URL, containerSize: CGSize, baseCardHeight: CGFloat) -> some View {
        let progressBottom = progressHeaderBottom > 0
            ? progressHeaderBottom
            : Self.fallbackProgressHeaderBottom
        let cardTop = collapsedCardTop > 0
            ? collapsedCardTop
            : fallbackCollapsedCardTop(in: containerSize.height, progressBottom: progressBottom, baseCardHeight: baseCardHeight)
        let imageTopLimit = progressBottom + Self.mediaProgressGap
        let imageBottomLimit = max(imageTopLimit, cardTop - Self.mediaCardGap)
        let availableImageHeight = max(0, imageBottomLimit - imageTopLimit)
        let availableImageWidth = max(0, containerSize.width - 96)
        let rawImageSize = min(Self.maxMediaImageSize, availableImageWidth, availableImageHeight)
        let imageSize = availableImageHeight >= Self.minMediaImageSize
            ? max(Self.minMediaImageSize, rawImageSize)
            : rawImageSize

        return FlashcardMediaImage(url: url)
            .frame(width: imageSize, height: imageSize)
            .position(x: containerSize.width / 2, y: imageBottomLimit - imageSize / 2)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private func fallbackCollapsedCardTop(
        in height: CGFloat,
        progressBottom: CGFloat,
        baseCardHeight: CGFloat
    ) -> CGFloat {
        let studyBlockHeight = baseCardHeight + Self.actionGap + Self.fallbackActionHeight
        let availableSpacerHeight = height - progressBottom - studyBlockHeight
        let spacerHeight = max(Self.verticalGap, availableSpacerHeight / 2)
        return progressBottom + spacerHeight
    }

    private func flashcard(baseHeight: CGFloat, maxHeight: CGFloat) -> some View {
        let cardHeight = resolvedCardHeight(baseHeight: baseHeight, maxHeight: maxHeight)

        return ZStack(alignment: .topTrailing) {
            Group {
                if isFlipped {
                    if isExampleExpanded {
                        if expandedCardContentHeight > maxHeight {
                            ScrollView(.vertical, showsIndicators: false) {
                                expandedCardBody(minHeight: baseHeight)
                            }
                            .scrollBounceBehavior(.basedOnSize)
                            .frame(height: maxHeight, alignment: .top)
                        } else {
                            expandedCardBody(minHeight: baseHeight)
                                .frame(height: cardHeight, alignment: .top)
                        }
                    } else {
                        cardBody(isBack: true, minHeight: baseHeight, layout: .fixed)
                            .frame(height: cardHeight, alignment: .top)
                    }
                } else {
                    cardBody(isBack: false, minHeight: baseHeight, layout: .fixed)
                        .frame(height: cardHeight, alignment: .top)
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.86), value: isExampleExpanded)

            if hasWordAudio {
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
                .padding(12)
                .accessibilityLabel("Прослушать")
            }
        }
        .background(cardHeightMeasurementViews(baseHeight: baseHeight))
        .frame(maxWidth: .infinity, alignment: .top)
        .background(
            flashcardShape
                .fill(cardGradient)
                .overlay { cardGlow }
                .clipShape(flashcardShape)
        )
        .overlay(flashcardShape.strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5))
        .rotation3DEffect(
            .degrees(cardRotation),
            axis: (x: 0, y: 1, z: 0),
            perspective: Self.flipPerspective
        )
        .allowsHitTesting(!isFlipAnimating)
        .shadow(color: MatchPalette.shadow.opacity(0.18), radius: 10, x: 0, y: 6)
        .shadow(color: MatchPalette.shadow.opacity(0.08), radius: 4, x: 0, y: 2)
    }

    /// Передняя сторона — холодный сине-фиолетовый, обратная — мягкая сирень (как в Lovable).
    private var cardGradient: LinearGradient {
        let stops: [Gradient.Stop] = isFlipped
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

    /// Цвет точки-индикатора перед словом: синий спереди, сиреневый на обороте.
    private var wordDotColor: Color {
        isFlipped ? oklch(0.72, 0.14, 300) : oklch(0.65, 0.2, 245)
    }

    /// Мягкое цветное свечение в углу карты.
    private var cardGlow: some View {
        Circle()
            .fill(isFlipped ? oklch(0.65, 0.18, 300, 0.22) : oklch(0.7, 0.18, 245, 0.25))
            .frame(width: 200, height: 200)
            .blur(radius: 55)
            .offset(x: isFlipped ? -70 : 80, y: isFlipped ? 90 : -70)
    }

    private func cardHeightMeasurementViews(baseHeight: CGFloat) -> some View {
        ZStack {
            measuredCardBody(isBack: false, minHeight: baseHeight, layout: .fixed) { height in
                frontCardContentHeight = height
            }

            measuredCardBody(isBack: true, minHeight: baseHeight, layout: .fixed) { height in
                backCardContentHeight = height
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

    private func expandedCardBody(minHeight: CGFloat) -> some View {
        cardBody(isBack: true, minHeight: minHeight, layout: .expanded)
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .preference(key: ExpandedFlashcardHeightKey.self, value: proxy.size.height)
                }
            )
            .onPreferenceChange(ExpandedFlashcardHeightKey.self) { height in
                guard height > 0 else { return }
                expandedCardContentHeight = height
            }
    }

    private func measuredExpandedCardHeight(maxHeight: CGFloat) -> CGFloat? {
        guard expandedCardContentHeight > 0 else { return nil }
        return min(expandedCardContentHeight, maxHeight)
    }

    private func resolvedCardHeight(baseHeight: CGFloat, maxHeight: CGFloat) -> CGFloat {
        let sideHeight = max(frontCardContentHeight, backCardContentHeight)
        let expandedHeight = isExampleExpanded ? measuredExpandedCardHeight(maxHeight: maxHeight) ?? 0 : 0
        return min(max(baseHeight, sideHeight, expandedHeight), maxHeight)
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
            Button {
                flipCard()
            } label: {
                flipLabel(isBack: isBack, minHeight: minHeight, layout: layout)
            }
            .buttonStyle(.plain)

            if isBack {
                exampleToggleButton
                    .padding(.horizontal, 18)
                    .padding(.top, layout == .expanded ? 12 : 4)

                if isExampleExpanded {
                    exampleDetails
                        .padding(.horizontal, 18)
                        .padding(.top, 12)
                        .padding(.bottom, 20)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                } else if layout == .fixed {
                    Spacer(minLength: 0)
                        .frame(minHeight: 12)
                }
            }
        }
    }

    @ViewBuilder
    private func flipLabel(isBack: Bool, minHeight: CGFloat, layout: CardBodyLayout) -> some View {
        if layout == .fixed {
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
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Circle()
                    .fill(wordDotColor)
                    .frame(width: 10, height: 10)
                    .shadow(color: wordDotColor.opacity(0.7), radius: 5)
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                Text(card.word)
                    .font(.title2.bold())
                    .foregroundStyle(FlashcardPalette.primaryText)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, hasWordAudio ? 40 : 0)
            }

            if isBack {
                Text(card.translation)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(FlashcardPalette.primaryText)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(1)
            } else {
                Text(frontExample)
                    .lineLimit(nil)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(1)
            }

            if layout == .fixed {
                Spacer(minLength: 0)
            }
        }
    }

    private func flipAreaMinHeight(isBack: Bool, cardMinHeight: CGFloat) -> CGFloat {
        let headerPadding: CGFloat = 18 + 12
        let exampleControls: CGFloat = isBack ? 52 : 0
        return max(80, cardMinHeight - headerPadding - exampleControls - 20)
    }

    private var exampleToggleButton: some View {
        Button {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                isExampleExpanded.toggle()
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "text.quote")
                    .font(.subheadline.weight(.semibold))
                Text("Пример")
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 0)
                Image(systemName: isExampleExpanded ? "chevron.up" : "chevron.down")
                    .font(.caption.weight(.bold))
            }
            .foregroundStyle(FlashcardPalette.primaryText)
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var exampleDetails: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(card.clozeExamplePlainText)
                .font(.body)
                .foregroundStyle(FlashcardPalette.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let translation = card.clozeExampleTranslation?.trimmingCharacters(in: .whitespacesAndNewlines),
               !translation.isEmpty {
                Text(translation)
                    .font(.body)
                    .foregroundStyle(FlashcardPalette.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let notesText {
                Text(notesText)
                    .font(.subheadline)
                    .foregroundStyle(FlashcardPalette.mutedText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var frontExample: AttributedString {
        let example = card.clozeExamplePlainText
        var attributed = AttributedString(example)
        attributed.font = .title3.weight(.medium)
        attributed.foregroundColor = FlashcardPalette.primaryText

        let answer = card.effectiveClozeAnswer
        if let stringRange = example.range(of: answer, options: [.caseInsensitive, .diacriticInsensitive]),
           let range = Range(stringRange, in: attributed) {
            attributed[range].font = .title3.weight(.bold)
        }
        return attributed
    }

    private func flipCard() {
        guard !isFlipAnimating else { return }

        if reduceMotion {
            isFlipped.toggle()
            return
        }

        isFlipAnimating = true
        flipGeneration += 1

        let generation = flipGeneration
        let targetIsBack = !isFlipped
        let outgoingAngle = targetIsBack ? 90.0 : -90.0
        let incomingAngle = targetIsBack ? -90.0 : 90.0

        withAnimation(.easeIn(duration: Self.flipHalfDuration)) {
            cardRotation = outgoingAngle
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.flipHalfDuration) {
            guard generation == flipGeneration else { return }

            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                isFlipped = targetIsBack
                cardRotation = incomingAngle
            }

            withAnimation(.easeOut(duration: Self.flipHalfDuration)) {
                cardRotation = 0
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + Self.flipHalfDuration) {
                guard generation == flipGeneration else { return }
                isFlipAnimating = false
            }
        }
    }

    private func answer(_ outcome: ReviewOutcome) {
        switch outcome {
        case .forgot, .incorrect:
            cardChangeDirection = .left
        case .remembered, .correct:
            cardChangeDirection = .right
        }
        onAnswer(outcome)
    }

    private func resetForNewCard() {
        flipGeneration += 1
        isFlipped = false
        isExampleExpanded = false
        frontCardContentHeight = 0
        backCardContentHeight = 0
        expandedCardContentHeight = 0
        cardRotation = 0
        isFlipAnimating = false
        collapsedCardTop = 0
    }
}

private struct ExpandedFlashcardHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct FlashcardProgressBottomPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct FlashcardCollapsedTopPreferenceKey: PreferenceKey {
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

private struct FlashcardMediaImage: View {
    let url: URL

    var body: some View {
        Group {
            if url.isFileURL, let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
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
        .shadow(color: MatchPalette.shadow.opacity(0.18), radius: 14, x: 0, y: 8)
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
