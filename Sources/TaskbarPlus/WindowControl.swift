import AppKit
import ApplicationServices

/// Permission requests and per-window raising via the Accessibility API.
enum WindowControl {

    /// Ask for Screen Recording (needed for window titles) and Accessibility
    /// (needed to raise a specific window). Both show a one-time system prompt.
    static func requestPermissions() {
        // Screen Recording: prompts the first time only; no-op once granted.
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
        }

        // Accessibility: only prompt when not already trusted. Calling with
        // prompt:true unconditionally would re-show the dialog every launch.
        if !AXIsProcessTrusted() {
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        }
    }

    /// Bring a specific window to the front: activate its app, un-minimize and
    /// raise the matching AX window. Falls back to just activating the app if
    /// Accessibility isn't granted or the window can't be matched.
    static func raise(windowNumber: Int, pid: pid_t) {
        let app = NSRunningApplication(processIdentifier: pid)
        app?.unhide()
        app?.activate()

        guard let window = axWindow(windowNumber: windowNumber, pid: pid) else { return }
        var minimized: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimized) == .success,
           (minimized as? Bool) == true {
            AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    }

    /// Close ONLY the given window (not the whole app) by pressing its AX close
    /// button. No-op if Accessibility isn't granted or the window can't be matched.
    static func close(windowNumber: Int, pid: pid_t) {
        guard let window = axWindow(windowNumber: windowNumber, pid: pid) else { return }
        var btn: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXCloseButtonAttribute as CFString, &btn) == .success,
              let closeButton = btn, CFGetTypeID(closeButton) == AXUIElementGetTypeID() else { return }
        AXUIElementPerformAction(closeButton as! AXUIElement, kAXPressAction as CFString)
    }

    /// The AX window whose CGWindowID matches `windowNumber`, or nil.
    private static func axWindow(windowNumber: Int, pid: pid_t) -> AXUIElement? {
        guard AXIsProcessTrusted() else { return nil }
        let appElement = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return nil }
        for window in windows {
            var wid: CGWindowID = 0
            if _AXUIElementGetWindow(window, &wid) == .success, Int(wid) == windowNumber {
                return window
            }
        }
        return nil
    }
}

/// Private API: maps an AXUIElement window to its CGWindowID. Declared here since
/// it has no public header; resolves at link time against ApplicationServices.
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError
