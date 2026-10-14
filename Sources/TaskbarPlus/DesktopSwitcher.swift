import CoreGraphics
import Foundation

/// Switches macOS Spaces by synthesizing the "switch to Desktop N" keyboard
/// shortcut (Ctrl+N). This is the only mechanism that still works on macOS 26 —
/// the private CGS/SLS space-switch APIs were disabled (same lockdown that broke
/// yabai). Requires the Ctrl+Number shortcuts to be enabled in System Settings,
/// which `ensureShortcutsEnabled()` does once.
enum DesktopSwitcher {

    /// macOS virtual key codes for the number row 1…9 (the default Ctrl+N bindings).
    private static let numberKeyCodes: [CGKeyCode] = [18, 19, 20, 21, 23, 22, 26, 28, 25]
    private static let firstHotkeyID = SystemShortcut.desktop1
    /// Highest desktop with a "Switch to Desktop N" shortcut in System Settings.
    private static let maxDesktop = 16
    /// symbolichotkeys modifier mask for Control (same bit as CGEventFlags.maskControl).
    private static let controlMask = 262144

    /// Switch to desktop `index` (1-based) by posting its "Switch to Desktop N"
    /// shortcut as currently configured (key + modifiers — the user may have rebound
    /// it), falling back to the default Ctrl+N for 1…9. Returns false (and posts
    /// nothing) if that shortcut is disabled or doesn't exist.
    @discardableResult
    static func switchTo(desktop index: Int) -> Bool {
        guard index >= 1, index <= maxDesktop else { return false }
        let stock = index <= numberKeyCodes.count
            ? (key: numberKeyCodes[index - 1], flags: CGEventFlags.maskControl) : nil
        return SystemShortcut.post(firstHotkeyID + index - 1, defaultBinding: stock)
    }

    /// Make sure "Switch to Desktop 1…9" (Ctrl+1…9) are on in System Settings, so the
    /// synthesized keystrokes actually switch. Adds missing entries, and turns on
    /// entries that are present but disabled with the stock Ctrl+N binding (macOS
    /// ships them that way). Entries the user rebound to another key are left alone
    /// (switchTo posts their binding). Writes com.apple.symbolichotkeys and
    /// re-activates settings. A fresh login may be required for new shortcuts.
    static func ensureShortcutsEnabled() {
        let defaults = UserDefaults(suiteName: "com.apple.symbolichotkeys")
        var hotkeys = SystemShortcut.hotkeys()
        var changed = false
        for i in 0..<numberKeyCodes.count {
            let id = String(firstHotkeyID + i)
            let stock: [Int] = [65535, Int(numberKeyCodes[i]), controlMask]
            if let entry = hotkeys[id] as? [String: Any] {
                let params = (entry["value"] as? [String: Any])?["parameters"] as? [Int]
                guard (entry["enabled"] as? Bool) != true, params?.dropFirst() == stock.dropFirst() else { continue }
                var enabled = entry
                enabled["enabled"] = 1
                hotkeys[id] = enabled
            } else {
                hotkeys[id] = [
                    "enabled": 1,
                    "value": ["parameters": stock, "type": "standard"],
                ]
            }
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
