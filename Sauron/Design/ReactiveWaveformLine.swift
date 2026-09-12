import SwiftUI

/// Tunables for the reactive presence line (see Design & Implementation Spec).
struct WaveConfig: Sendable {
    var ratios: [Double] = [1.0, 2.3, 3.7]
    var weights: [Double] = [0.6, 0.27, 0.13]
    var speeds: [Double] = [1.4, 2.1, 2.8]
    var baseFrequency: Double = 1.15
    var maxAmplitude: Double = 1.0
    var windowExponent: Double = 1.45
    var wavelengthCoupling: Double = 0.75
    var idlePhaseScale: Double = 0.4
    var lineWidth: Double = 1.6
    /// Snappy follow — amplitude should mirror speaking volume.
    var targetTau: Double = 0.035
    var attackTau: Double = 0.04
    var releaseTau: Double = 0.09
    var silenceEpsilon: Double = 0.003
}

/// Reference box so phase/amplitude persist without SwiftUI @State thrash.
private final class WaveRuntime: @unchecked Sendable {
    var phases: [Double] = []
    var smoothedTarget: Double = 0
    var amplitude: Double = 0
    var lastTime: TimeInterval?
    let lock = NSLock()
}

/// Option A layered sine blend — straight at rest, organic when audio is present.
struct ReactiveWaveformLine: View {
    /// Normalized target level 0…1 (smoothing happens inside).
    var level: Double
    var config: WaveConfig = WaveConfig()
    var isAlert: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var runtime = WaveRuntime()

    private var strokeColor: Color {
        isAlert ? Color.orange : SauronTheme.accent
    }

    var body: some View {
        Group {
            if reduceMotion {
                StaticWaveBaseline(lineWidth: config.lineWidth, color: strokeColor)
                    .opacity(0.4 + 0.6 * min(max(level, 0), 1))
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: false)) { timeline in
                    let now = timeline.date.timeIntervalSinceReferenceDate
                    let amplitude = step(now: now)
                    Canvas { context, size in
                        let path = makePath(in: size, amplitude: amplitude, phases: snapshotPhases())
                        context.stroke(
                            path,
                            with: .linearGradient(
                                Gradient(colors: [
                                    SauronTheme.accentStart.opacity(isAlert ? 0.6 : 0.9),
                                    strokeColor
                                ]),
                                startPoint: .zero,
                                endPoint: CGPoint(x: size.width, y: 0)
                            ),
                            style: StrokeStyle(
                                lineWidth: config.lineWidth,
                                lineCap: .round,
                                lineJoin: .round
                            )
                        )
                    }
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func snapshotPhases() -> [Double] {
        runtime.lock.lock()
        defer { runtime.lock.unlock() }
        return runtime.phases
    }

    @discardableResult
    private func step(now: TimeInterval) -> Double {
        runtime.lock.lock()
        defer { runtime.lock.unlock() }

        if runtime.phases.count != config.ratios.count {
            runtime.phases = config.ratios.indices.map { Double($0) * 1.7 }
        }

        let previous = runtime.lastTime ?? now
        // Clamp huge gaps (first frame / sleep) so we don't jump a hitch.
        let dt = min(max(now - previous, 0), 1.0 / 30.0)
        runtime.lastTime = now
        guard dt > 0 else { return runtime.amplitude }

        let rawTarget = min(max(level, 0), 1)
        // Pre-smooth the audio target so mic/system peaks don't snap the shape.
        let targetAlpha = 1 - exp(-dt / config.targetTau)
        runtime.smoothedTarget += (rawTarget - runtime.smoothedTarget) * targetAlpha

        let target = runtime.smoothedTarget
        let tau = target > runtime.amplitude ? config.attackTau : config.releaseTau
        let alpha = 1 - exp(-dt / tau)
        runtime.amplitude += (target - runtime.amplitude) * alpha

        if runtime.amplitude < config.silenceEpsilon && target < config.silenceEpsilon {
            runtime.amplitude = 0
            runtime.smoothedTarget = 0
        }

        // Keep phase motion gentle so the morph stays fluid, not twitchy.
        let scale = config.idlePhaseScale + (1 - config.idlePhaseScale) * runtime.amplitude
        for i in runtime.phases.indices {
            runtime.phases[i] += config.speeds[i] * dt * scale
            if runtime.phases[i] > .pi * 2_000 { runtime.phases[i] -= .pi * 2_000 }
        }
        return runtime.amplitude
    }

    private func makePath(in size: CGSize, amplitude: Double, phases: [Double]) -> Path {
        let midY = size.height / 2
        var path = Path()

        guard amplitude > 0, phases.count == config.ratios.count else {
            path.move(to: CGPoint(x: 0, y: midY))
            path.addLine(to: CGPoint(x: size.width, y: midY))
            return path
        }

        let n = min(max(Int(size.width / 3), 48), 160)
        let a = amplitude
        let lambda = 1 + config.wavelengthCoupling * a
        let peak = config.maxAmplitude * midY

        var pts: [CGPoint] = []
        pts.reserveCapacity(n + 1)
        for i in 0...n {
            let x = Double(i) / Double(n)
            let window = pow(sin(.pi * x), config.windowExponent)
            var sum = 0.0
            for k in config.ratios.indices {
                let f = config.baseFrequency * config.ratios[k] * lambda
                sum += config.weights[k] * sin(2 * .pi * f * x - phases[k])
            }
            let y = midY - a * window * sum * peak
            pts.append(CGPoint(x: x * size.width, y: y))
        }

        path.move(to: pts[0])
        for i in 1..<pts.count {
            let prev = pts[i - 1]
            let cur = pts[i]
            let mid = CGPoint(x: (prev.x + cur.x) / 2, y: (prev.y + cur.y) / 2)
            path.addQuadCurve(to: mid, control: prev)
        }
        path.addLine(to: pts[pts.count - 1])
        return path
    }
}

private struct StaticWaveBaseline: View {
    let lineWidth: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            Path { path in
                let y = geo.size.height / 2
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: geo.size.width, y: y))
            }
            .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
        }
    }
}
