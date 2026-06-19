import CoreGraphics
import Foundation

/// Switches macOS Spaces by synthesizing the "switch to Desktop N" keyboard
/// shortcut (Ctrl+N). This is the only mechanism that still works on macOS 26 —
/// the private CGS/SLS space-switch APIs were disabled (same lockdown that broke
/// yabai). Requires the Ctrl+Number shortcuts to be enabled in System Settings,
/// which `ensureShortcutsEnabled()` does once.
enum DesktopSwitcher {

    /// macOS virtual key codes for the number row 1…9 (used for Ctrl+N).
    private static let numberKeyCodes: [CGKeyCode] = [18, 19, 20, 21, 23, 22, 26, 28, 25]

    /// Switch to desktop `index` (1-based) by posting Ctrl+index. No-op if out of range.
    static func switchTo(desktop index: Int) {
        guard index >= 1, index <= numberKeyCodes.count else { return }
        let key = numberKeyCodes[index - 1]
        let src = CGEventSource(stateID: .combinedSessionState)
        if let down = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: true) {
            down.flags = .maskControl
            down.post(tap: .cghidEventTap)
        }
        if let up = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: false) {
            up.flags = .maskControl
            up.post(tap: .cghidEventTap)
        }
    }

    /// Enable the "switch to Desktop 1…9" shortcuts (Ctrl+1…9) in System Settings if
    /// not already set, so the synthesized keystrokes actually switch. Writes to
    /// com.apple.symbolichotkeys (hotkey IDs 118…126) and re-activates settings.
    /// Note: a fresh login is required for newly-written shortcuts to take effect.
    static func ensureShortcutsEnabled() {
        let defaults = UserDefaults(suiteName: "com.apple.symbolichotkeys")
        var hotkeys = (defaults?.dictionary(forKey: "AppleSymbolicHotKeys")) ?? [:]
        var changed = false
        for i in 0..<numberKeyCodes.count {
            let id = String(118 + i)                  // 118 = Desktop 1
            if hotkeys[id] != nil { continue }         // respect any existing binding
            hotkeys[id] = [
                "enabled": 1,
                "value": [
                    "parameters": [65535, Int(numberKeyCodes[i]), 262144],  // 262144 = Control
                    "type": "standard",
                ],
            ]
            changed = true
        }
        guard changed else { return }
        defaults?.set(hotkeys, forKey: "AppleSymbolicHotKeys")
        // Re-activate so the shortcuts register without a full relogin where possible.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings")
        p.arguments = ["-u"]
        try? p.run()
    }
}
