import SwiftUI

let studyCardShape = RoundedRectangle(cornerRadius: 24, style: .continuous)
private let studyActionShape = RoundedRectangle(cornerRadius: 18, style: .continuous)

struct RecallOutcomeButton: View {
    let title: String
    let systemImage: String
    let titleColor: Color
    let iconColor: Color
    let iconBackground: Color
    var verticalPadding: CGFloat = 16
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
            .padding(.vertical, verticalPadding)
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

struct ReviewOutcomeControls: View {
    var forgotTitle = "Забыл"
    var rememberedTitle = "Помню"
    var verticalPadding: CGFloat = 16
    var isEnabled = true
    let onAnswer: (ReviewOutcome) -> Void

    var body: some View {
        HStack(spacing: 10) {
            RecallOutcomeButton(
                title: forgotTitle,
                systemImage: "xmark",
                titleColor: MatchPalette.destructive,
                iconColor: MatchPalette.destructive,
                iconBackground: MatchPalette.destructive.opacity(0.14),
                verticalPadding: verticalPadding
            ) {
                onAnswer(.forgot)
            }
            .frame(maxWidth: .infinity)

            RecallOutcomeButton(
                title: rememberedTitle,
                systemImage: "checkmark",
                titleColor: MatchPalette.successText,
                iconColor: MatchPalette.successText,
                iconBackground: MatchPalette.success.opacity(0.22),
                verticalPadding: verticalPadding
            ) {
                onAnswer(.remembered)
            }
            .frame(maxWidth: .infinity)
        }
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.62)
    }
}

struct StudyProgressHeader: View {
    let totalCount: Int
    let remainingCount: Int

    private var completedCount: Int {
        max(0, totalCount - remainingCount)
    }

    var body: some View {
        StudySessionProgressBar(completed: completedCount, total: totalCount)
    }
}

enum StudyCardChangeDirection {
    case left
    case right
}

struct StudyCardChangeTransition: ViewModifier {
    let cardID: UUID
    var direction: StudyCardChangeDirection = .right

    private var removalOffset: CGSize {
        direction == .left
            ? CGSize(width: 6, height: -3)
            : CGSize(width: -6, height: -3)
    }

    private var insertionOffset: CGSize {
        direction == .left
            ? CGSize(width: -6, height: 3)
            : CGSize(width: 6, height: 3)
    }

    func body(content: Content) -> some View {
        content
            .id(cardID)
            .transition(
                .asymmetric(
                    insertion: .opacity.combined(with: .offset(x: insertionOffset.width, y: insertionOffset.height)),
                    removal: .opacity.combined(with: .offset(x: removalOffset.width, y: removalOffset.height))
                )
            )
            .animation(.easeOut(duration: 0.18), value: cardID)
    }
}

extension View {
    func studyCardChangeTransition(
        cardID: UUID,
        direction: StudyCardChangeDirection = .right
    ) -> some View {
        modifier(StudyCardChangeTransition(cardID: cardID, direction: direction))
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
