import SwiftUI
import UIKit

/// Возвращает имя SF Symbol, если он есть в системе, иначе fallback.
/// Защита от устаревших/невалидных имён в данных колод (например «character.book.fill»).
func deckSymbol(_ name: String?, fallback: String = "books.vertical.fill") -> String {
    guard let name, !name.isEmpty, UIImage(systemName: name) != nil else { return fallback }
    return name
}

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

enum LovableSurface {
    static let foreground = oklch(0.18, 0.015, 260)
    static let muted = oklch(0.55, 0.03, 260)
    static let panelTop = oklch(0.25, 0.04, 265, 0.7)
    static let panelBottom = oklch(0.18, 0.04, 270, 0.6)
    static let primary = oklch(0.62, 0.17, 248)
    static let primaryDeep = oklch(0.5, 0.19, 258)
    static let blueText = oklch(0.78, 0.18, 235)
    static let amberText = oklch(0.78, 0.15, 65)
}

enum LovableBackgroundVariant: Hashable {
    case today
    case decks
    case stats
    case flashcards
}

/// Фон экрана. Содержимое (MeshGradient + размытые орбы) для каждого варианта при
/// фиксированном на запуск `hueShift` — статичная картинка, поэтому рендерим её
/// один раз в `UIImage` и показываем как `Image`.
///
/// Это важно для навигации: раньше при каждом push'е создавался свежий
/// `LovableBackground`, и его `drawingGroup` приходилось впервые растеризовать
/// офскрин-проходом прямо во время перехода. На лёгком экране (режимы «Сегодня»)
/// фон прокрашивался на кадр позже → полупрозрачные панели мелькали «белесыми»
/// поверх белого окна; на тяжёлом (DeckDetailView) растеризация блокировала
/// главный поток → дёрганый слайд. Готовая картинка композитится мгновенно и
/// убирает оба артефакта.
struct LovableBackground: View {
    let variant: LovableBackgroundVariant

    var body: some View {
        Group {
            if let image = LovableBackgroundImageCache.image(for: variant) {
                // Растягиваем (а не scaledToFill): заполняет фрейм край-в-край без
                // центрирования, иначе субпиксельный зазор даёт белую полоску у низа.
                Image(uiImage: image)
                    .resizable()
            } else {
                // Фолбэк (нулевой размер экрана и т.п.): живой рендер.
                LovableBackgroundContent(variant: variant)
                    .drawingGroup()
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

/// Кэш заранее отрендеренных фонов по вариантам. Картинка для варианта рендерится
/// один раз (лениво при первом обращении или прогревается на старте) и переиспользуется
/// всеми экранами и всеми переходами.
@MainActor
enum LovableBackgroundImageCache {
    private static var images: [LovableBackgroundVariant: UIImage] = [:]

    static func image(for variant: LovableBackgroundVariant) -> UIImage? {
        if let cached = images[variant] { return cached }
        let size = screenSize
        guard size.width > 0, size.height > 0 else { return nil }
        let renderer = ImageRenderer(
            content: LovableBackgroundContent(variant: variant)
                .frame(width: size.width, height: size.height)
        )
        renderer.scale = screenScale
        guard let image = renderer.uiImage else { return nil }
        images[variant] = image
        return image
    }

    /// Прогревает фоны заранее, чтобы первый показ/переход не платил за рендер.
    static func warm(_ variants: [LovableBackgroundVariant]) {
        for variant in variants {
            _ = image(for: variant)
        }
    }

    private static var screenSize: CGSize {
        if let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })
            ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            return scene.screen.bounds.size
        }
        return UIScreen.main.bounds.size
    }

    private static var screenScale: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.screen.scale ?? UIScreen.main.scale
    }
}

/// Живой рендер фона (MeshGradient + орбы). Используется как источник для растеризации
/// в `UIImage` и как фолбэк.
private struct LovableBackgroundContent: View {
    let variant: LovableBackgroundVariant

    var body: some View {
        ZStack {
            MeshGradient(
                width: 3,
                height: 3,
                points: [
                    .init(0, 0), .init(0.5, 0), .init(1, 0),
                    .init(0, 0.5), .init(0.5, 0.5), .init(1, 0.5),
                    .init(0, 1), .init(0.5, 1), .init(1, 1),
                ],
                colors: meshColors
            )

            ForEach(Array(orbs.enumerated()), id: \.offset) { _, orb in
                Circle()
                    .fill(orb.color)
                    .frame(width: orb.size.width, height: orb.size.height)
                    .blur(radius: 60)
                    .offset(orb.offset)
            }
        }
        .clipped()
    }

    /// Цвет фона с учётом случайного оттенка текущего запуска.
    /// Поворачиваем H на общий угол → гармония между углами сохраняется,
    /// меняется только общий тон. Серединки (низкая chroma) визуально не меняются.
    private func amb(_ l: Double, _ c: Double, _ h: Double, _ a: Double = 1) -> Color {
        oklch(l, c, h + LovableAmbience.hueShift, a)
    }

    private var meshColors: [Color] {
        switch variant {
        case .today, .flashcards:
            [
                amb(0.92, 0.08, 30), amb(0.93, 0.05, 5), amb(0.90, 0.10, 350),
                amb(0.985, 0.005, 240), amb(0.985, 0.005, 240), amb(0.985, 0.005, 240),
                amb(0.92, 0.08, 145), amb(0.92, 0.05, 250), amb(0.90, 0.09, 250),
            ]
        case .decks:
            [
                amb(0.88, 0.10, 280), amb(0.91, 0.08, 310), amb(0.90, 0.09, 340),
                amb(0.985, 0.005, 240), amb(0.985, 0.005, 240), amb(0.98, 0.006, 250),
                amb(0.93, 0.05, 250), amb(0.91, 0.07, 275), amb(0.90, 0.08, 315),
            ]
        case .stats:
            [
                amb(0.90, 0.08, 220), amb(0.91, 0.08, 200), amb(0.92, 0.07, 185),
                amb(0.985, 0.005, 240), amb(0.985, 0.005, 240), amb(0.98, 0.006, 250),
                amb(0.91, 0.07, 180), amb(0.91, 0.07, 220), amb(0.90, 0.08, 240),
            ]
        }
    }

    private var orbs: [LovableOrb] {
        switch variant {
        case .today, .flashcards:
            [
                LovableOrb(size: .init(width: 420, height: 420), offset: .init(width: -150, height: -310), color: amb(0.9, 0.1, 30, 0.5)),
                LovableOrb(size: .init(width: 460, height: 460), offset: .init(width: 180, height: -150), color: amb(0.88, 0.12, 350, 0.45)),
                LovableOrb(size: .init(width: 480, height: 480), offset: .init(width: -150, height: 330), color: amb(0.9, 0.1, 160, 0.4)),
                LovableOrb(size: .init(width: 420, height: 420), offset: .init(width: 160, height: 320), color: amb(0.88, 0.1, 250, 0.5)),
            ]
        case .decks:
            [
                LovableOrb(size: .init(width: 400, height: 400), offset: .init(width: -140, height: -300), color: amb(0.85, 0.12, 280, 0.5)),
                LovableOrb(size: .init(width: 440, height: 440), offset: .init(width: 175, height: -130), color: amb(0.82, 0.14, 310, 0.45)),
                LovableOrb(size: .init(width: 460, height: 460), offset: .init(width: -150, height: 330), color: amb(0.8, 0.15, 340, 0.4)),
                LovableOrb(size: .init(width: 400, height: 400), offset: .init(width: 160, height: 320), color: amb(0.85, 0.1, 250, 0.5)),
            ]
        case .stats:
            [
                LovableOrb(size: .init(width: 420, height: 420), offset: .init(width: -150, height: -300), color: amb(0.86, 0.1, 220, 0.5)),
                LovableOrb(size: .init(width: 460, height: 460), offset: .init(width: 180, height: -140), color: amb(0.84, 0.12, 200, 0.45)),
                LovableOrb(size: .init(width: 480, height: 480), offset: .init(width: -140, height: 330), color: amb(0.82, 0.1, 180, 0.4)),
                LovableOrb(size: .init(width: 420, height: 420), offset: .init(width: 170, height: 320), color: amb(0.86, 0.1, 240, 0.5)),
            ]
        }
    }
}

/// Случайный сдвиг оттенка фона, выбирается один раз за запуск приложения
/// и не меняется при переходах между экранами (стабильно в пределах сессии).
enum LovableAmbience {
    static let hueShift: Double = .random(in: 0..<360)
}

private struct LovableOrb {
    let size: CGSize
    let offset: CGSize
    let color: Color
}

struct LovablePanel: ViewModifier {
    let cornerRadius: CGFloat
    var showsShadow: Bool = true

    func body(content: Content) -> some View {
        let panel = content
            .background(
                LinearGradient(
                    colors: [LovableSurface.panelTop, LovableSurface.panelBottom],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(.white.opacity(0.06), lineWidth: 0.5)
            }

        if showsShadow {
            // compositingGroup сплющивает панель в один слой, иначе .shadow
            // рисует тень для каждого текста/иконки внутри — это рушит FPS
            // пуш-переходов на экранах с несколькими панелями.
            panel
                .compositingGroup()
                .shadow(color: oklch(0.1, 0.05, 265, 0.32), radius: 18, x: 0, y: 10)
        } else {
            panel
        }
    }
}

extension View {
    func lovablePanel(cornerRadius: CGFloat = 24, showsShadow: Bool = true) -> some View {
        modifier(LovablePanel(cornerRadius: cornerRadius, showsShadow: showsShadow))
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
    /// Зелёный для текста на светлой карточке — темнее success, выше контраст.
    static let successText = oklch(0.55, 0.15, 155)
    static let destructive = oklch(0.62, 0.22, 25)
    static let accent = oklch(0.70, 0.18, 30)
    static let shadow = oklch(0.18, 0.05, 260)

    static let progressStart = oklch(0.72, 0.19, 35)
    static let progressEnd = oklch(0.68, 0.22, 12)
    static let paceAheadStart = oklch(0.74, 0.14, 155)
    static let paceAheadEnd = oklch(0.66, 0.15, 162)
    /// Бирюзовый прогресс изучения — в тон выбранному табу (cyan).
    static let studyProgressStart = oklch(0.80, 0.13, 200)
    static let studyProgressEnd = oklch(0.72, 0.15, 220)
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
