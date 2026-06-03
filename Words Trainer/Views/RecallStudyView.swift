import SwiftUI

struct RecallStudyView: View {
    let card: WordCardContent
    let totalCount: Int
    let remainingCount: Int
    let onAnswer: (ReviewOutcome) -> Void

    private static let verticalGap: CGFloat = 16
    private static let actionGap: CGFloat = 20

    var body: some View {
        VStack(spacing: 0) {
            StudyProgressHeader(totalCount: totalCount, remainingCount: remainingCount)
                .padding(.horizontal, 16)
                .padding(.top, 8)

            Spacer(minLength: Self.verticalGap)

            VStack(spacing: Self.actionGap) {
                wordCard
                    .studyCardChangeTransition(cardID: card.id)

                ReviewOutcomeControls(onAnswer: onAnswer)
            }
            .padding(.horizontal, 16)

            Spacer(minLength: Self.verticalGap)
        }
    }

    private var wordCard: some View {
        ZStack {
            // Синее свечение-гало за словом
            Ellipse()
                .fill(oklch(0.7, 0.18, 245, 0.28))
                .frame(width: 260, height: 120)
                .blur(radius: 50)

            VStack(spacing: 12) {
                Text(card.word)
                    .font(.system(size: 48, weight: .semibold))
                    .foregroundStyle(oklch(0.99, 0.01, 240))
                    .multilineTextAlignment(.center)
                    .lineLimit(1)
                    .minimumScaleFactor(0.35)
                    .allowsTightening(true)

                if !card.translation.isEmpty {
                    Text(card.translation)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(oklch(0.82, 0.03, 250, 0.75))
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                }
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 56)
            .frame(maxWidth: .infinity)
        }
        .background(
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .fill(
                    LinearGradient(
                        gradient: Gradient(stops: [
                            .init(color: oklch(0.27, 0.05, 265), location: 0),
                            .init(color: oklch(0.18, 0.05, 270), location: 0.6),
                            .init(color: oklch(0.14, 0.05, 275), location: 1),
                        ]),
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .strokeBorder(.white.opacity(0.07), lineWidth: 0.5)
        )
        .shadow(color: oklch(0.1, 0.05, 270, 0.5), radius: 24, x: 0, y: 16)
        .shadow(color: oklch(0.1, 0.05, 270, 0.3), radius: 8, x: 0, y: 6)
    }
}
