import SwiftUI

enum ObserverTheme {
    static let cardRadius: CGFloat = 28

    /// Brand accent solid (#4770DF) — aligns with AccentColor asset / `.tint`.
    static let accent = Color(red: 71 / 255, green: 112 / 255, blue: 223 / 255)
    /// Gradient start (#5C52D2).
    static let accentStart = Color(red: 92 / 255, green: 82 / 255, blue: 210 / 255)
    /// Gradient mid/end (#4770DF).
    static let accentMid = accent
    static let accentEnd = accent

    /// Brand gradient: #5C52D2 → #4770DF → #4770DF.
    static let accentGradient = LinearGradient(
        colors: [accentStart, accentMid, accentEnd],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
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
            .tint(ObserverTheme.accent)
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
}
