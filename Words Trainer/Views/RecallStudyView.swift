import SwiftUI

struct RecallStudyView: View {
    let card: WordCardContent
    let totalCount: Int
    let remainingCount: Int
    let onAnswer: (ReviewOutcome) -> Void

    var body: some View {
        VStack(spacing: 0) {
            StudyProgressHeader(totalCount: totalCount, remainingCount: remainingCount)
                .padding(.horizontal, 16)
                .padding(.top, 8)

            Spacer()

            VStack(spacing: 32) {
                Text(card.word)
                    .font(.largeTitle.bold())
                    .foregroundStyle(MatchPalette.cardForeground)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)

                ReviewOutcomeControls(onAnswer: onAnswer)
            }
            .padding(.horizontal, 16)

            Spacer()
            Spacer(minLength: 56)
        }
        .padding(.bottom, 10)
    }
}
