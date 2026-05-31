import SwiftUI

struct RecallStudyView: View {
    let card: WordCardContent
    let onAnswer: (ReviewOutcome) -> Void

    var body: some View {
        VStack(spacing: 32) {
            Spacer()
            Text(card.word)
                .font(.largeTitle.bold())
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
            Spacer()
            HStack(spacing: 16) {
                Button("Забыл") {
                    onAnswer(.forgot)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)

                Button("Помню") {
                    onAnswer(.remembered)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
            }
            .controlSize(.large)
            .padding(.horizontal, 20)
            .padding(.bottom, 32)
        }
    }
}
