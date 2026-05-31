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

// MARK: - iOS pretty palette (matching screen)

/// oklch(L C H) → sRGB. Позволяет задавать палитру ровно по дизайн-токенам (CSS oklch).
func oklch(_ l: Double, _ c: Double, _ h: Double, _ opacity: Double = 1) -> Color {
    let hr = h * .pi / 180
    let a = c * cos(hr)
    let b = c * sin(hr)
    let l_ = l + 0.3963377774 * a + 0.2158037573 * b
    let m_ = l - 0.1055613458 * a - 0.0638541728 * b
    let s_ = l - 0.0894841775 * a - 1.2914855480 * b
    let lc = l_ * l_ * l_, mc = m_ * m_ * m_, sc = s_ * s_ * s_
    let r = 4.0767416621 * lc - 3.3077115913 * mc + 0.2309699292 * sc
    let g = -1.2684380046 * lc + 2.6097574011 * mc - 0.3413193965 * sc
    let bl = -0.0041960863 * lc - 0.7034186147 * mc + 1.7076147010 * sc
    func gamma(_ x: Double) -> Double {
        let v = min(max(x, 0), 1)
        return v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055
    }
    return Color(.sRGB, red: gamma(r), green: gamma(g), blue: gamma(bl), opacity: opacity)
}

/// Дизайн-токены светлой темы (из Lovable).
enum MatchPalette {
    static let foreground = oklch(0.18, 0.015, 260)
    static let cardForeground = oklch(0.16, 0.015, 260)
    static let muted = oklch(0.55, 0.015, 260)
    static let primary = oklch(0.62, 0.19, 255)
    static let success = oklch(0.72, 0.12, 160)
    static let destructive = oklch(0.62, 0.22, 25)
    static let accent = oklch(0.70, 0.18, 30)
    static let shadow = oklch(0.18, 0.05, 260)

    static let progressStart = oklch(0.72, 0.19, 35)
    static let progressEnd = oklch(0.68, 0.22, 12)
    static let paceAheadStart = oklch(0.74, 0.14, 155)
    static let paceAheadEnd = oklch(0.66, 0.15, 162)
}

/// Мягкий пастельный mesh-фон (персик/розовый/голубой/зелёный по углам).
struct MatchingBackground: View {
    var body: some View {
        MeshGradient(
            width: 3,
            height: 3,
            points: [
                .init(0, 0), .init(0.5, 0), .init(1, 0),
                .init(0, 0.5), .init(0.5, 0.5), .init(1, 0.5),
                .init(0, 1), .init(0.5, 1), .init(1, 1),
            ],
            colors: [
                oklch(0.92, 0.08, 30), oklch(0.93, 0.05, 5), oklch(0.90, 0.10, 350),
                oklch(0.985, 0.005, 240), oklch(0.985, 0.005, 240), oklch(0.985, 0.005, 240),
                oklch(0.92, 0.08, 145), oklch(0.92, 0.05, 250), oklch(0.90, 0.09, 250),
            ]
        )
        .ignoresSafeArea()
    }
}

/// Горизонтальная тряска для неверного выбора.
struct ShakeEffect: GeometryEffect {
    var travel: CGFloat = 6
    var shakes: CGFloat = 3
    var animatableData: CGFloat

    func effectValue(size: CGSize) -> ProjectionTransform {
        let dx = travel * sin(animatableData * .pi * shakes * 2)
        return ProjectionTransform(CGAffineTransform(translationX: dx, y: 0))
    }
}
