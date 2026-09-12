import AppKit
import SwiftUI

enum ObserverTheme {
    // MARK: - Surfaces (content layer) — follow System Appearance
    static let canvas = adaptive(
        light: (246 / 255, 247 / 255, 250 / 255),
        dark: (10 / 255, 11 / 255, 13 / 255)
    )
    static let surface = adaptive(
        light: (255 / 255, 255 / 255, 255 / 255),
        dark: (18 / 255, 20 / 255, 26 / 255)
    )
    static let surfaceElevated = adaptive(
        light: (255 / 255, 255 / 255, 255 / 255),
        dark: (24 / 255, 27 / 255, 34 / 255)
    )
    static let surfaceSunken = adaptive(
        light: (236 / 255, 238 / 255, 243 / 255),
        dark: (13 / 255, 14 / 255, 18 / 255)
    )

    static let hairline = adaptiveHairline(strong: false)
    static let hairlineStrong = adaptiveHairline(strong: true)

    // MARK: - Accent (Iris) — same in light and dark
    static let irisStart = Color(red: 91 / 255, green: 108 / 255, blue: 255 / 255)
    static let irisEnd = Color(red: 138 / 255, green: 91 / 255, blue: 255 / 255)
    static let irisSolid = Color(red: 107 / 255, green: 114 / 255, blue: 255 / 255)

    static let mint = Color(red: 70 / 255, green: 224 / 255, blue: 176 / 255)
    static let amber = Color(red: 245 / 255, green: 181 / 255, blue: 70 / 255)
    static let red = Color(red: 255 / 255, green: 92 / 255, blue: 92 / 255)

    static let textPrimary = adaptive(
        light: (17 / 255, 19 / 255, 24 / 255),
        dark: (242 / 255, 243 / 255, 245 / 255)
    )
    static let textSecondary = adaptive(
        light: (88 / 255, 94 / 255, 108 / 255),
        dark: (154 / 255, 160 / 255, 172 / 255)
    )
    static let textTertiary = adaptive(
        light: (120 / 255, 126 / 255, 140 / 255),
        dark: (107 / 255, 114 / 255, 128 / 255)
    )

    /// Legacy aliases used across HUD / panels.
    static let accent = irisSolid
    static let accentStart = irisStart
    static let accentMid = irisSolid
    static let accentEnd = irisEnd
    static let cardRadius: CGFloat = 22

    static let accentGradient = LinearGradient(
        colors: [irisStart, irisEnd],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let irisGradient = LinearGradient(
        colors: [irisStart, irisEnd],
        startPoint: UnitPoint(x: 0, y: 0),
        endPoint: UnitPoint(x: 1, y: 1)
    )

    // MARK: - Radii
    static let radiusChip: CGFloat = 6
    static let radiusControl: CGFloat = 10
    static let radiusCard: CGFloat = 14
    static let radiusPanel: CGFloat = 20

    static func hairline(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.08)
    }

    static func fillSubtle(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.04) : Color.black.opacity(0.04)
    }

    static func fillQuiet(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.028) : Color.black.opacity(0.03)
    }

    static func bubbleOther(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.14) : Color.black.opacity(0.06)
    }

    static func panelFallback(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.black.opacity(0.45) : Color.white.opacity(0.55)
    }

    static func stroke(for scheme: ColorScheme, emphasized: Bool = false) -> Color {
        if scheme == .dark {
            return Color.white.opacity(emphasized ? 0.14 : 0.08)
        }
        return Color.black.opacity(emphasized ? 0.12 : 0.08)
    }

    // MARK: - Dynamic colors

    private static func adaptive(
        light: (CGFloat, CGFloat, CGFloat),
        dark: (CGFloat, CGFloat, CGFloat),
        alpha: CGFloat = 1
    ) -> Color {
        Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let rgb = isDark ? dark : light
            return NSColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: alpha)
        }))
    }

    private static func adaptiveHairline(strong: Bool) -> Color {
        Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            if isDark {
                return NSColor(white: 1, alpha: strong ? 0.14 : 0.08)
            }
            return NSColor(white: 0, alpha: strong ? 0.12 : 0.08)
        }))
    }
}

/// Nested glass sections inside a window that is not itself an `NSGlassEffectView`.
struct GlassCard<Content: View>: View {
    var padding: CGFloat = 20
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

extension View {
    /// Standard Liquid Glass capsule — secondary actions.
    func observerGlassButton() -> some View {
        self
            .buttonStyle(.glass)
            .buttonBorderShape(.capsule)
    }

    /// Filled Liquid Glass capsule — primary actions, branded tint.
    func observerGlassProminentButton() -> some View {
        self
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.capsule)
            .tint(ObserverTheme.irisSolid)
    }

    /// Opaque content card (never glass in the content layer).
    func observerSurfaceCard(elevated: Bool = false) -> some View {
        self
            .background(
                elevated ? ObserverTheme.surfaceElevated : ObserverTheme.surface,
                in: RoundedRectangle(cornerRadius: ObserverTheme.radiusCard, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: ObserverTheme.radiusCard, style: .continuous)
                    .strokeBorder(ObserverTheme.hairline, lineWidth: 1)
            )
    }

    func observerDashboardCanvas() -> some View {
        self.background {
            ZStack {
                ObserverTheme.canvas
                RadialGradient(
                    colors: [
                        ObserverTheme.irisEnd.opacity(0.06),
                        ObserverTheme.irisStart.opacity(0.03),
                        .clear
                    ],
                    center: .topLeading,
                    startRadius: 20,
                    endRadius: 520
                )
            }
            .ignoresSafeArea()
        }
    }
}

extension TimeInterval {
    var observerClock: String {
        let total = max(0, Int(self))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    var observerShortDuration: String {
        let total = max(0, Int(self))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(max(1, minutes))m"
    }
}
