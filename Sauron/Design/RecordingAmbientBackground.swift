import SwiftUI

/// ChatGPT-style image-gen ambient: circular dots lit by two soft spotlights.
/// Adapts base plate to light/dark so the panel follows system appearance.
struct RecordingAmbientBackground: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    private let spacing: CGFloat = 11
    private let baseRadius: CGFloat = 1.9

    private var isDark: Bool { colorScheme == .dark }

    private var baseColor: Color {
        isDark
            ? Color.black
            : Color(red: 0.93, green: 0.94, blue: 0.97)
    }

    private var dotColor: Color {
        // Slightly deeper blue on light so dots stay visible on pale glass.
        isDark
            ? Color(red: 58 / 255, green: 121 / 255, blue: 198 / 255)
            : Color(red: 45 / 255, green: 98 / 255, blue: 190 / 255)
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { timeline in
            let t = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
            let dark = isDark
            Canvas { context, size in
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(baseColor))

                let cols = Int(ceil(size.width / spacing)) + 2
                let rows = Int(ceil(size.height / spacing)) + 2
                let spots = spotlights(at: t, in: size)
                let beam = max(size.width, size.height) * 0.38
                let floor = dark ? 0.06 : 0.10
                let gain = dark ? 0.94 : 0.78

                for row in 0..<rows {
                    for col in 0..<cols {
                        let point = CGPoint(x: CGFloat(col) * spacing, y: CGFloat(row) * spacing)
                        let intensity = illumination(at: point, spots: spots, beam: beam)
                        guard intensity > 0.02 else { continue }

                        let radius = baseRadius * (0.28 + 0.92 * intensity)
                        let rect = CGRect(
                            x: point.x - radius,
                            y: point.y - radius,
                            width: radius * 2,
                            height: radius * 2
                        )
                        context.fill(
                            Path(ellipseIn: rect),
                            with: .color(dotColor.opacity(Double(floor + gain * intensity)))
                        )
                    }
                }
            }
            .id(colorScheme) // Rebuild canvas when appearance flips.
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func spotlights(at t: TimeInterval, in size: CGSize) -> [CGPoint] {
        if reduceMotion {
            return [
                CGPoint(x: size.width * 0.28, y: size.height * 0.30),
                CGPoint(x: size.width * 0.68, y: size.height * 0.58)
            ]
        }

        let cx = size.width * 0.5
        let cy = size.height * 0.5
        let a = orbit(
            center: CGPoint(x: cx, y: cy),
            rx: size.width * 0.28,
            ry: size.height * 0.24,
            angle: t * 0.35
        )
        let b = orbit(
            center: CGPoint(x: cx, y: cy),
            rx: size.width * 0.26,
            ry: size.height * 0.30,
            angle: t * -0.28 + .pi * 0.85
        )
        return [a, b]
    }

    private func orbit(center: CGPoint, rx: CGFloat, ry: CGFloat, angle: Double) -> CGPoint {
        CGPoint(
            x: center.x + rx * CGFloat(cos(angle)),
            y: center.y + ry * CGFloat(sin(angle))
        )
    }

    private func illumination(at point: CGPoint, spots: [CGPoint], beam: CGFloat) -> CGFloat {
        var energy: CGFloat = 0
        for spot in spots {
            let dx = point.x - spot.x
            let dy = point.y - spot.y
            let dist = sqrt(dx * dx + dy * dy)
            let u = max(0, 1 - dist / beam)
            energy += u * u * u
        }
        return min(1, energy)
    }
}
