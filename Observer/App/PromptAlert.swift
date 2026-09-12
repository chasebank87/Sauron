import AppKit
import Foundation

enum PromptAlert {
    /// Soft system chime when a meeting is detected.
    static func play() {
        // Prefer Glass; fall back through a few built-in alert sounds.
        let names = ["Glass", "Ping", "Tink", "Pop"]
        for name in names {
            if let sound = NSSound(named: NSSound.Name(name)) {
                sound.play()
                return
            }
        }
        NSSound.beep()
    }
}
