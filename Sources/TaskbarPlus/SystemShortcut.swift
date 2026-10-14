import CoreGraphics
import Foundation

/// Triggers macOS system shortcuts ("symbolic hotkeys" — Spotlight, Switch to
/// Desktop N, …) by synthesizing their keystroke AS CURRENTLY CONFIGURED in System
/// Settings → Keyboard → Shortcuts, so a user's custom binding is honoured.
enum SystemShortcut {

    /// Symbolic-hotkey ids (keys of `AppleSymbolicHotKeys` in com.apple.symbolichotkeys).
    static let spotlight = 64
    /// "Switch to Desktop 1"; Desktop N is `desktop1 + N - 1` (up to Desktop 16).
    static let desktop1 = 118

    static func hotkeys() -> [String: Any] {
        CFPreferencesAppSynchronize("com.apple.symbolichotkeys" as CFString)
        return UserDefaults(suiteName: "com.apple.symbolichotkeys")?
            .dictionary(forKey: "AppleSymbolicHotKeys") ?? [:]
    }

    /// Post hotkey `id` with its configured key + modifiers. If the user never
    /// customized it there's no entry, so `defaultBinding` (macOS's stock one) is used.
    /// Returns false (posting nothing) if it's disabled, or missing with no default.
    @discardableResult
    static func post(_ id: Int, defaultBinding: (key: CGKeyCode, flags: CGEventFlags)?) -> Bool {
        let key: CGKeyCode
        let flags: CGEventFlags
        if let entry = hotkeys()[String(id)] as? [String: Any] {
            // parameters = [ascii char, virtual key code, modifier mask]; the mask uses
            // the same bits as CGEventFlags.
            guard (entry["enabled"] as? Bool) == true,
                  let params = (entry["value"] as? [String: Any])?["parameters"] as? [Int],
                  params.count == 3 else { return false }
            key = CGKeyCode(params[1])
            flags = CGEventFlags(rawValue: UInt64(params[2]))
        } else if let d = defaultBinding {
            (key, flags) = d
        } else {
            return false
        }
        let src = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: down) else { continue }
            e.flags = flags
            e.post(tap: .cghidEventTap)
        }
        return true
    }

    /// Open Spotlight search (default ⌘Space).
    static func openSpotlight() {
        post(spotlight, defaultBinding: (key: 49, flags: .maskCommand))
    }
}
