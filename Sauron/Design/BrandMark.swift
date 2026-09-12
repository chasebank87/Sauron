import SwiftUI

/// Brand mark helpers. Geometry lives in `brand/` — never recolor or rotate the mark.
enum BrandMark {
    static let tagline = "The meeting assistant that never blinks."
}

struct SauronMarkView: View {
    var size: CGFloat = 28
    var simplified: Bool = false

    var body: some View {
        Image(simplified && size <= 32 ? "SauronMarkSimple" : "SauronMark")
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

struct SauronMenuBarMark: View {
    var status: AppStatus

    var body: some View {
        Image("MenuBarMark")
            .resizable()
            .renderingMode(.template)
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: 18, height: 18)
            .foregroundStyle(tint)
            .accessibilityLabel("Sauron")
    }

    private var tint: Color {
        switch status {
        case .recording:
            // Ember is reserved for live capture — same idea as the slit in the mark.
            SauronTheme.ember
        case .prompt:
            SauronTheme.irisSolid
        case .processing:
            SauronTheme.irisEnd
        case .idle, .detecting:
            Color.primary
        }
    }
}
