import SwiftUI

/// Конфетти-поздравление «из хлопушки»: кусочки вылетают снизу вверх и в стороны, затем под
/// действием гравитации падают вниз — параболическая дуга, видимая ~2 с. Чистый SwiftUI
/// (Canvas + физика), без зависимостей. Проигрывается один раз при появлении.
struct ConfettiView: View {
    /// Каждое увеличение `trigger` запускает новый залп. Вью держат смонтированной постоянно —
    /// так залп срабатывает надёжно (без гонки onAppear в момент перехода экрана).
    var trigger: Int
    var pieceCount: Int = 120

    private static let gravity: Double = 900 // pt/s²

    @State private var start = Date()
    @State private var pieces: [Piece] = []

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                let t = timeline.date.timeIntervalSince(start)
                for piece in pieces {
                    let opacity = piece.opacity(at: t)
                    guard opacity > 0 else { continue }

                    let pos = piece.position(at: t, gravity: Self.gravity, in: size)
                    var ctx = context
                    ctx.opacity = opacity
                    ctx.translateBy(x: pos.x, y: pos.y)
                    ctx.rotate(by: .degrees(piece.rotationSpeed * max(0, t - piece.delay)))
                    let rect = CGRect(
                        x: -piece.size / 2,
                        y: -piece.size * 0.45 / 2,
                        width: piece.size,
                        height: piece.size * 0.45
                    )
                    ctx.fill(Path(roundedRect: rect, cornerRadius: 1.5), with: .color(piece.color))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
        .ignoresSafeArea()
        .onChange(of: trigger) { _, _ in
            start = Date()
            pieces = (0..<pieceCount).map { _ in Piece.random() }
        }
    }

    struct Piece: Identifiable {
        let id = UUID()
        let vx: Double          // начальная горизонтальная скорость, pt/s
        let vy: Double          // начальная вертикальная скорость, pt/s (отрицательная = вверх)
        let color: Color
        let size: CGFloat
        let rotationSpeed: Double // deg/s
        let delay: Double         // задержка вылета, с
        let lifetime: Double      // время жизни после вылета, с

        /// Старт чуть ниже нижней кромки по центру (как хлопушка), дальше — баллистика.
        func position(at t: Double, gravity: Double, in size: CGSize) -> CGPoint {
            let originX = size.width / 2
            let originY = size.height + 20
            let te = max(0, t - delay)
            return CGPoint(
                x: originX + vx * te,
                y: originY + vy * te + 0.5 * gravity * te * te
            )
        }

        func opacity(at t: Double) -> Double {
            let te = t - delay
            guard te >= 0, te <= lifetime else { return 0 }
            let fadeStart = lifetime - 0.6
            guard te > fadeStart else { return 1 }
            return max(0, 1 - (te - fadeStart) / 0.6)
        }

        static func random() -> Piece {
            let palette: [Color] = [.red, .orange, .yellow, .green, .mint, .blue, .indigo, .purple, .pink]
            let angle = Double.random(in: -0.5...0.5) // отклонение от вертикали, рад
            let speed = Double.random(in: 820...1180)
            return Piece(
                vx: sin(angle) * speed,
                vy: -cos(angle) * speed,
                color: palette.randomElement()!,
                size: CGFloat.random(in: 9...16),
                rotationSpeed: Double.random(in: -300...300),
                delay: Double.random(in: 0...0.18),
                lifetime: Double.random(in: 2.6...3.6)
            )
        }
    }
}
