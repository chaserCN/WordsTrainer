import SwiftUI

let studyCardShape = RoundedRectangle(cornerRadius: 24, style: .continuous)
private let studyActionShape = RoundedRectangle(cornerRadius: 18, style: .continuous)

struct RecallOutcomeButton: View {
    let title: String
    let systemImage: String
    let titleColor: Color
    let iconColor: Color
    let iconBackground: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(iconColor)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(iconBackground))

                Text(title)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(titleColor)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .padding(.horizontal, 10)
            .background(studyActionShape.fill(cardFill))
            .overlay(studyActionShape.strokeBorder(MatchPalette.shadow.opacity(0.08), lineWidth: 0.5))
            .shadow(color: MatchPalette.shadow.opacity(0.10), radius: 8, x: 0, y: 4)
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

struct StudySessionProgressBar: View {
    let completed: Int
    let total: Int

    private var progress: Double {
        guard total > 0 else { return 0 }
        return Double(completed) / Double(total)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(MatchPalette.shadow.opacity(0.10))
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [MatchPalette.progressStart, MatchPalette.progressEnd],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: geo.size.width * progress)
                    .animation(.easeInOut(duration: 0.28), value: progress)
            }
        }
        .frame(height: 6)
    }
}
