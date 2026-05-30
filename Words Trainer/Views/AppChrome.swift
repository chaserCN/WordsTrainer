import SwiftUI

struct AppBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.05, green: 0.07, blue: 0.14),
                    Color(red: 0.09, green: 0.08, blue: 0.20),
                    Color(red: 0.03, green: 0.10, blue: 0.16),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .fill(.blue.opacity(0.26))
                .frame(width: 260, height: 260)
                .blur(radius: 70)
                .offset(x: -130, y: -260)

            Circle()
                .fill(.purple.opacity(0.24))
                .frame(width: 300, height: 300)
                .blur(radius: 85)
                .offset(x: 150, y: 280)
        }
        .ignoresSafeArea()
    }
}

struct LightCardBackground: View {
    let cornerRadius: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.96),
                        Color(red: 0.94, green: 0.96, blue: 1.0).opacity(0.94),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
    }
}

struct StudyScreenChrome<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        ZStack {
            AppBackground()
            content()
        }
    }
}
