import SwiftUI

/// ChatGPT-style image-gen ambient: blue circular dots on black with a drifting
/// illumination field (scale + opacity), not a color mesh/glow wash.
struct RecordingAmbientBackground: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Matches the reference frame (~#3A79C6 electric blue).
    private static let dotColor = Color(red: 58 / 255, green: 121 / 255, blue: 198 / 255)

    private let spacing: CGFloat = 11
    private let baseRadius: CGFloat = 1.9

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { timeline in
            let t = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black))

                let cols = Int(ceil(size.width / spacing)) + 2
                let rows = Int(ceil(size.height / spacing)) + 2
                let focus = focusPoint(at: t, in: size)

                for row in 0..<rows {
                    for col in 0..<cols {
                        let x = CGFloat(col) * spacing
                        let y = CGFloat(row) * spacing
                        let intensity = illumination(
                            at: CGPoint(x: x, y: y),
                            focus: focus,
                            size: size,
                            time: t,
                            col: col,
                            row: row
                        )
                        guard intensity > 0.02 else { continue }

                        let radius = baseRadius * (0.35 + 0.85 * intensity)
                        let rect = CGRect(
                            x: x - radius,
                            y: y - radius,
                            width: radius * 2,
                            height: radius * 2
                        )
                        let alpha = Double(0.08 + 0.92 * intensity)
                        context.fill(
                            Path(ellipseIn: rect),
                            with: .color(Self.dotColor.opacity(alpha))
                        )
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Soft spotlight that slowly drifts (static top-leading when motion is reduced).
    private func focusPoint(at t: TimeInterval, in size: CGSize) -> CGPoint {
        if reduceMotion {
            return CGPoint(x: size.width * 0.22, y: size.height * 0.18)
        }
        let nx = 0.28 + 0.42 * (0.5 + 0.5 * sin(t * 0.22))
        let ny = 0.22 + 0.38 * (0.5 + 0.5 * cos(t * 0.17 + 0.6))
        return CGPoint(x: size.width * nx, y: size.height * ny)
    }

    /// Radial falloff + slow diagonal wave + faint per-dot twinkle — the ChatGPT
    /// generating rhythm (illuminated region, not uniform blink).
    private func illumination(
        at point: CGPoint,
        focus: CGPoint,
        size: CGSize,
        time: TimeInterval,
        col: Int,
        row: Int
    ) -> CGFloat {
        let dx = point.x - focus.x
        let dy = point.y - focus.y
        let dist = sqrt(dx * dx + dy * dy)
        let radius = max(size.width, size.height) * 0.72
        let radial = max(0, 1 - dist / radius)
        let falloff = radial * radial

        guard !reduceMotion else { return falloff }

        let wave = 0.5 + 0.5 * sin(
            (point.x + point.y) * 0.045 - time * 1.15
        )
        let twinkle = 0.88 + 0.12 * sin(
            time * 2.4 + Double(col) * 0.73 + Double(row) * 1.17
        )
        return min(1, falloff * (0.55 + 0.45 * CGFloat(wave)) * CGFloat(twinkle))
    }
}
