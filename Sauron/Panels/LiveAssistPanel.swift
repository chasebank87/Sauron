import AppKit
import SwiftUI

struct LiveAssistPanelView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme

    private var showsAmbient: Bool {
        appState.status == .recording
    }

    var body: some View {
        ZStack {
            if showsAmbient {
                RecordingAmbientBackground()
            } else {
                SauronTheme.panelFallback(for: colorScheme)
            }

            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: "sparkles")
                        .font(.headline)
                        .foregroundStyle(SauronTheme.irisGradient)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Live Assist")
                            .font(.headline)
                        Text(statusCaption)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    if appState.status == .recording {
                        Text(appState.elapsed.observerClock)
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }

                if appState.assistCards.isEmpty {
                    VStack(spacing: 10) {
                        Spacer(minLength: 0)
                        Image(systemName: "ear")
                            .font(.system(size: 28, weight: .medium))
                            .foregroundStyle(SauronTheme.textTertiary)
                        Text("Listening…")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(SauronTheme.textPrimary)
                        Text(assistEmptyDescription)
                            .font(.caption)
                            .foregroundStyle(SauronTheme.textSecondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 240)
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(appState.assistCards) { card in
                                AssistCardView(card: card)
                            }
                        }
                        .padding(.vertical, 4)
                        .padding(.trailing, 8)
                    }
                    .observerLiquidGlassScroll()
                    .contentMargins(.trailing, 2, for: .scrollContent)
                }

                GlassEffectContainer(spacing: 8) {
                    HStack(spacing: 8) {
                        Text(footerCaption)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Text("\(appState.assistCards.count)")
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .foregroundStyle(SauronTheme.textSecondary)
                    }
                }
            }
            .padding(18)
        }
        .clipShape(RoundedRectangle(cornerRadius: SauronTheme.cardRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: SauronTheme.cardRadius, style: .continuous)
                .strokeBorder(
                    SauronTheme.stroke(for: colorScheme, emphasized: showsAmbient),
                    lineWidth: 1
                )
        }
        .frame(width: GlassChrome.assistSize.width, height: GlassChrome.assistSize.height)
    }

    private var statusCaption: String {
        if !appState.settings.liveResearchEnabled {
            return "Insights only"
        }
        if appState.settings.providerKind.providesBuiltInWebResearch {
            return appState.settings.providerKind.displayName
        }
        return "Research on"
    }

    private var footerCaption: String {
        if appState.settings.providerKind.providesBuiltInWebResearch {
            return "\(appState.settings.providerKind.displayName) tools"
        }
        return appState.settings.liveResearchEnabled ? "Web research enabled" : "Local insights"
    }

    private var assistEmptyDescription: String {
        if !appState.settings.liveResearchEnabled {
            return "Enable Research in Settings for web fact-check. Insights still use your model."
        }
        if appState.settings.providerKind.providesBuiltInWebResearch {
            return "Insights and \(appState.settings.providerKind.displayName) research appear as the conversation unfolds."
        }
        return "Insights and fact-checks appear as the conversation unfolds."
    }
}

private struct AssistCardView: View {
    let card: LiveAssistCard

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: card.kind.systemImage)
                Text(card.title)
                    .font(.caption.weight(.semibold))
                if let verdict = card.verdict {
                    Text(verdict.title)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(verdictColor(verdict).opacity(0.18)))
                        .foregroundStyle(verdictColor(verdict))
                }
                Spacer()
            }
            .foregroundStyle(SauronTheme.textSecondary)

            Text(card.body)
                .font(.callout)
                .foregroundStyle(SauronTheme.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            if !card.sources.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(card.sources) { source in
                        if let url = URL(string: source.url) {
                            Link(source.title, destination: url)
                                .font(.caption)
                                .lineLimit(1)
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .observerSurfaceCard(elevated: true)
    }

    private func verdictColor(_ verdict: FactCheckVerdict) -> Color {
        switch verdict {
        case .supported: SauronTheme.mint
        case .contested: SauronTheme.amber
        case .unclear: SauronTheme.textSecondary
        }
    }
}
