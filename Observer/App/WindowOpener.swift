import AppKit
import SwiftUI

struct WindowOpener: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .accessibilityHidden(true)
            .onAppear(perform: sync)
            .onChange(of: appState.reportToken) { _, token in
                if token != nil {
                    openWindow(id: "report")
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
            .onChange(of: appState.wantsOnboarding) { _, wants in
                if wants { appState.showOnboarding() }
            }
    }

    private func sync() {
        appState.start()
    }
}
