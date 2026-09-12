import SwiftData
import SwiftUI

struct DashboardWindow: View {
    @Environment(AppState.self) private var appState
    @State private var pendingAskQuery: String?

    var body: some View {
        @Bindable var state = appState
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 280)
        } detail: {
            detail
                .observerDashboardCanvas()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(appState.dashboardSelectedTab.title)
        .toolbarBackground(.hidden, for: .windowToolbar)
        .frame(minWidth: 1040, minHeight: 720)
        .onChange(of: appState.dashboardSelectedTab) { _, tab in
            if tab != .ask {
                pendingAskQuery = nil
            }
        }
    }

    private var overdueAskCount: Int {
        TrackedItemStore.all(context: appState.modelContext)
            .filter { $0.status == .open && Date().timeIntervalSince($0.createdAt) > 7 * 86_400 }
            .count
    }

    private var sidebar: some View {
        @Bindable var state = appState
        return VStack(spacing: 0) {
            List(selection: $state.dashboardSelectedTab) {
                ForEach(DashboardNavSection.allCases) { section in
                    Section {
                        ForEach(section.tabs) { tab in
                            Label {
                                HStack {
                                    Text(tab.title)
                                    Spacer()
                                    if tab == .asks, overdueAskCount > 0 {
                                        Text("\(overdueAskCount)")
                                            .font(.system(size: 11, weight: .semibold).monospacedDigit())
                                            .foregroundStyle(ObserverTheme.textPrimary)
                                            .padding(.horizontal, 7)
                                            .padding(.vertical, 2)
                                            .background(ObserverTheme.irisSolid.opacity(0.35), in: Capsule())
                                    }
                                }
                            } icon: {
                                Image(systemName: tab.systemImage)
                            }
                            .tag(tab)
                        }
                    } header: {
                        Text(section.title)
                            .font(.system(size: 10, weight: .semibold))
                            .tracking(0.6)
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)

            captureStatusChip
                .padding(12)
        }
        .background(.ultraThinMaterial)
    }

    private var captureStatusChip: some View {
        Button {
            // Status chip is informational for now; recording HUD opens from menu bar flow.
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                Text(statusLabel)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(ObserverTheme.textPrimary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(.thinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(ObserverTheme.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var statusLabel: String {
        switch appState.status {
        case .idle:
            return "Idle"
        case .detecting:
            return "Watching"
        case .prompt:
            return "Meeting detected"
        case .recording:
            return "Recording \(appState.elapsed.observerClock)"
        case .processing:
            return "Processing…"
        }
    }

    private var statusColor: Color {
        switch appState.status {
        case .recording: ObserverTheme.red
        case .processing, .prompt: ObserverTheme.amber
        case .detecting: ObserverTheme.mint
        case .idle: ObserverTheme.textTertiary
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch appState.dashboardSelectedTab {
        case .home:
            DashboardHomeTab(
                onAsk: { query in
                    pendingAskQuery = query
                    appState.dashboardSelectedTab = .ask
                },
                onOpenLibrary: { appState.dashboardSelectedTab = .library },
                onOpenAsks: { appState.dashboardSelectedTab = .asks },
                onOpenInsights: { appState.dashboardSelectedTab = .insights }
            )
        case .insights:
            DashboardInsightsTab()
        case .library:
            DashboardLibraryTab()
        case .people:
            DashboardPeopleTab()
        case .asks:
            DashboardAsksTab()
        case .ask:
            DashboardAskTab(initialQuery: pendingAskQuery)
        case .memory:
            DashboardMemoryTab()
        }
    }
}
