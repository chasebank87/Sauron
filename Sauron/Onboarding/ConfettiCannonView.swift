import SwiftUI

struct ConfettiCannonView: View {
    var token: UUID?

    @State private var particles: [ConfettiParticle] = []
    @State private var firedToken: UUID?

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: particles.isEmpty)) { timeline in
            Canvas { context, size in
                let now = timeline.date.timeIntervalSinceReferenceDate
                for particle in particles {
                    let t = now - particle.born
                    guard t >= 0, t < particle.life else { continue }
                    let fade = max(0, 1 - (t / particle.life))
                    let x = particle.startX * size.width + particle.vx * t
                    let y = particle.startY * size.height + particle.vy * t + 0.5 * particle.gravity * t * t
                    let rotation = Angle.radians(particle.spin * t)
                    let rect = CGRect(
                        x: -particle.size.width / 2,
                        y: -particle.size.height / 2,
                        width: particle.size.width,
                        height: particle.size.height
                    )
                    context.drawLayer { layer in
                        layer.opacity = fade
                        layer.translateBy(x: x, y: y)
                        layer.rotate(by: rotation)
                        layer.fill(
                            particle.rounded
                                ? Path(roundedRect: rect, cornerRadius: 1.8)
                                : Path(ellipseIn: rect),
                            with: .color(particle.color)
                        )
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .onChange(of: token) { _, newValue in
            fire(newValue)
        }
        .onAppear {
            fire(token)
        }
    }

    private func fire(_ token: UUID?) {
        guard let token, token != firedToken else { return }
        firedToken = token
        burst()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            if firedToken == token {
                particles.removeAll()
            }
        }
    }

    private func burst() {
        let now = Date.timeIntervalSinceReferenceDate
        let colors: [Color] = [
            Color(red: 1, green: 0.33, blue: 0.42),
            Color(red: 1, green: 0.82, blue: 0.40),
            Color(red: 0.15, green: 0.84, blue: 0.63),
            Color(red: 0.30, green: 0.79, blue: 0.94),
            Color(red: 0.97, green: 0.15, blue: 0.52),
            Color(red: 0.78, green: 0.49, blue: 1),
            .white
        ]
        let cannons: [(x: Double, y: Double, angle: Double)] = [
            (0.12, 0.93, -.pi / 2 + 0.58),
            (0.50, 0.97, -.pi / 2),
            (0.88, 0.93, -.pi / 2 - 0.58)
        ]

        var next: [ConfettiParticle] = []
        var id = 0
        for cannon in cannons {
            for index in 0..<42 {
                let spread = Double.random(in: -0.34...0.34)
                let speed = Double.random(in: 640...980)
                let angle = cannon.angle + spread
                next.append(
                    ConfettiParticle(
                        id: id,
                        startX: cannon.x + Double.random(in: -0.03...0.03),
                        startY: cannon.y,
                        vx: cos(angle) * speed,
                        vy: sin(angle) * speed,
                        gravity: Double.random(in: 980...1320),
                        born: now,
                        life: Double.random(in: 2.2...3.3),
                        color: colors[index % colors.count],
                        size: CGSize(
                            width: Double.random(in: 6...12),
                            height: Double.random(in: 4...8)
                        ),
                        spin: Double.random(in: -14...14),
                        rounded: index.isMultiple(of: 2)
                    )
                )
                id += 1
            }
        }
        particles = next
    }
}

private struct ConfettiParticle: Identifiable {
    var id: Int
    var startX: Double
    var startY: Double
    var vx: Double
    var vy: Double
    var gravity: Double
    var born: TimeInterval
    var life: TimeInterval
    var color: Color
    var size: CGSize
    var spin: Double
    var rounded: Bool
}
