import AppKit
import Foundation

/// Global + local shortcut to open the Dashboard.
final class GlobalHotkeyMonitor: @unchecked Sendable {
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private let keyCode: UInt16
    private let modifiers: NSEvent.ModifierFlags
    private let handler: @Sendable () -> Void

    init(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, handler: @escaping @Sendable () -> Void) {
        self.keyCode = keyCode
        self.modifiers = modifiers.intersection([.command, .option, .control, .shift])
        self.handler = handler
    }

    func start() {
        stop()
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.matches(event) else { return event }
            self.handler()
            return nil
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.matches(event) else { return }
            self.handler()
        }
    }

    func stop() {
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
    }

    deinit {
        stop()
    }

    private func matches(_ event: NSEvent) -> Bool {
        guard event.keyCode == keyCode else { return false }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        return flags == modifiers
    }
}
