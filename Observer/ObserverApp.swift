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
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        AppState.shared.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
