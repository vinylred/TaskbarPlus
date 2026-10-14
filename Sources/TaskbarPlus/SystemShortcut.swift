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
    /// "Move left / right a space" (default ⌃← / ⌃→).
    static let moveLeftSpace = 79
    static let moveRightSpace = 81

    typealias Binding = (key: CGKeyCode, flags: CGEventFlags)
    /// Arrow keys carry the secondary-fn flag alongside Control (as stored by macOS).
    private static let controlArrow = CGEventFlags(rawValue: 0x840000)
    static let defaultMoveLeft: Binding = (key: 123, flags: controlArrow)
    static let defaultMoveRight: Binding = (key: 124, flags: controlArrow)

    static func hotkeys() -> [String: Any] {
        CFPreferencesAppSynchronize("com.apple.symbolichotkeys" as CFString)
        return UserDefaults(suiteName: "com.apple.symbolichotkeys")?
            .dictionary(forKey: "AppleSymbolicHotKeys") ?? [:]
    }

    /// The binding hotkey `id` currently has: its configured key + modifiers; or, if
    /// the user never customized it (no entry, or an entry with no `value` — macOS
    /// stores "enabled, default keys" that way), `defaultBinding`. nil if disabled or
    /// there's nothing to post.
    static func binding(_ id: Int, defaultBinding: Binding?) -> Binding? {
        guard let entry = hotkeys()[String(id)] as? [String: Any] else { return defaultBinding }
        guard (entry["enabled"] as? Bool) == true else { return nil }
        // parameters = [ascii char, virtual key code, modifier mask]; the mask uses the
        // same bits as CGEventFlags.
        guard let params = (entry["value"] as? [String: Any])?["parameters"] as? [Int], params.count == 3
        else { return defaultBinding }
        return (CGKeyCode(params[1]), CGEventFlags(rawValue: UInt64(params[2])))
    }

    /// Post hotkey `id` with its current binding (see `binding`). Returns false
    /// (posting nothing) if it's disabled, or unbound with no default.
    @discardableResult
    static func post(_ id: Int, defaultBinding: Binding?) -> Bool {
        guard let (key, flags) = binding(id, defaultBinding: defaultBinding) else { return false }
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
