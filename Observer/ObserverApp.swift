import AppKit
import SwiftData
import SwiftUI

@main
enum ObserverMain {
    static func main() {
        PermissionProbe.exitIfLaunchedAsProbe()
        ObserverApp.main()
    }
}

struct ObserverApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var appState = AppState.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environment(appState)
                .modelContainer(appState.modelContainer)
                .tint(ObserverTheme.accent)
        } label: {
            MenuBarLabel(status: appState.status)
                .environment(appState)
                .background(WindowOpener().environment(appState))
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(appState)
                .modelContainer(appState.modelContainer)
                .tint(ObserverTheme.accent)
        }

        Window("Meeting Report", id: "report") {
            ReportWindow()
                .environment(appState)
                .modelContainer(appState.modelContainer)
                .tint(ObserverTheme.accent)
        }
        .defaultSize(width: 720, height: 640)
        .windowStyle(.hiddenTitleBar)

        Window("Dashboard", id: "dashboard") {
            DashboardWindow()
                .environment(appState)
                .modelContainer(appState.modelContainer)
                .tint(ObserverTheme.accent)
        }
        .defaultSize(width: 1100, height: 720)
        .windowStyle(.automatic)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Follow System Settings → Appearance (never force dark/light).
        NSApp.appearance = nil
        NSApp.setActivationPolicy(.accessory)
        AppState.shared.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
