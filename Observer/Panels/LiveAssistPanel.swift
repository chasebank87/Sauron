import AppKit
import SwiftUI

struct LiveAssistPanelView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Live Assist", systemImage: "sparkles")
                    .font(.headline)
                Spacer()
                if !appState.settings.liveResearchEnabled {
                    Text("Insights only")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if appState.settings.providerKind.providesBuiltInWebResearch {
                    Text(appState.settings.providerKind.displayName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if appState.assistCards.isEmpty {
                ContentUnavailableView(
                    "Listening…",
                    systemImage: "ear",
                    description: Text(assistEmptyDescription)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(appState.assistCards) { card in
                            AssistCardView(card: card)
                        }
                    }
                    .padding(.vertical, 4)
                    .padding(.trailing, 12)
                }
                .scrollIndicators(.visible, axes: .vertical)
                .safeAreaPadding(.trailing, 2)
            }
        }
        .padding(16)
        .frame(width: GlassChrome.assistSize.width, height: GlassChrome.assistSize.height)
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
            .foregroundStyle(.secondary)

            Text(card.body)
                .font(.callout)
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
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        }
    }

    private func verdictColor(_ verdict: FactCheckVerdict) -> Color {
        switch verdict {
        case .supported: .green
        case .contested: .orange
        case .unclear: .secondary
        }
    }
}
