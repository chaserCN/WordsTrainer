import SwiftUI

struct RecallStudyView: View {
    let card: WordCardContent
    let totalCount: Int
    let remainingCount: Int
    let onAnswer: (ReviewOutcome) -> Void

    private var completedCount: Int {
        max(0, totalCount - remainingCount)
    }

    var body: some View {
        VStack(spacing: 0) {
            StudySessionProgressBar(completed: completedCount, total: totalCount)
                .padding(.horizontal, 16)
                .padding(.top, 8)

            Spacer()

            VStack(spacing: 32) {
                Text(card.word)
                    .font(.largeTitle.bold())
                    .foregroundStyle(MatchPalette.cardForeground)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)

                HStack(spacing: 10) {
                    RecallOutcomeButton(
                        title: "Забыл",
                        systemImage: "xmark",
                        titleColor: MatchPalette.destructive,
                        iconColor: MatchPalette.destructive,
                        iconBackground: MatchPalette.destructive.opacity(0.14)
                    ) {
                        onAnswer(.forgot)
                    }
                    .frame(maxWidth: .infinity)

                    RecallOutcomeButton(
                        title: "Помню",
                        systemImage: "checkmark",
                        titleColor: MatchPalette.successText,
                        iconColor: MatchPalette.successText,
                        iconBackground: MatchPalette.success.opacity(0.22)
                    ) {
                        onAnswer(.remembered)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 16)

            Spacer()
            Spacer(minLength: 56)
        }
        .padding(.bottom, 10)
    }
}
