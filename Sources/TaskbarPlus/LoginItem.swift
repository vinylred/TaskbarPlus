import ServiceManagement

/// Wraps SMAppService to launch TaskbarPlus at login (the modern Login Items API).
enum LoginItem {

    /// Whether the app is currently registered to launch at login.
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Register/unregister the app as a login item. Returns true on success.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                try SMAppService.mainApp.unregister()
            }
            return true
        } catch {
            NSLog("TaskbarPlus: login-item \(enabled ? "register" : "unregister") failed: \(error)")
            return false
        }
    }
}
