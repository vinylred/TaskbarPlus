import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var config = LayoutConfig.load()
    private let service = SpaceWindowService()
    private let dockModel = DockModelService()
    private var prefs: PreferencesController?
    private var statusItem: NSStatusItem?

    /// One panel per target screen, keyed by a string of the screen's frame origin
    /// (CGPoint isn't Hashable before macOS 15).
    private var panels: [String: TaskbarPanel] = [:]
    private var latestItems: [DockItem] = []
    private var latestWindows: [WindowInfo] = []
    private var latestDesktops: [String: String] = [:]   // display UUID -> "Desktop N"

    private func key(_ origin: CGPoint) -> String { "\(origin.x),\(origin.y)" }

    /// The CGS display-UUID string for an NSScreen, to match service desktop names.
    private func displayUUID(of screen: NSScreen) -> String? {
        guard let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { return nil }
        let displayID = CGDirectDisplayID(num.uint32Value)
        guard let cfUUID = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue()
        else { return nil }
        return CFUUIDCreateString(nil, cfUUID) as String
    }

    /// The desktop name for a screen. CGSCopyManagedDisplaySpaces keys the primary
    /// display as the literal "Main" (not a UUID), so fall back to that for the
    /// primary screen (frame origin .zero) when the UUID doesn't match.
    private func desktopName(for screen: NSScreen) -> String? {
        if let uuid = displayUUID(of: screen), let n = latestDesktops[uuid] { return n }
        if screen.frame.origin == .zero, let n = latestDesktops["Main"] { return n }
        return nil
    }

    /// Push each panel its own screen's desktop name.
    private func applyDesktopNames() {
        // In all-spaces / grouped modes every bar shows a mode label; in current-Space
        // mode each shows its own current desktop.
        switch config.spaceMode {
        case .allSpaces:
            panels.values.forEach { $0.updateDesktop("All Desktops") }
            return
        case .grouped:
            panels.values.forEach { $0.updateDesktop("Grouped") }
            return
        case .currentSpace:
            break
        }
        for screen in NSScreen.screens {
            guard let panel = panels[key(screen.frame.origin)],
                  let name = desktopName(for: screen) else { continue }
            panel.updateDesktop(name)
        }
    }

    /// Cycle current-Space → all-Spaces → grouped, persist, and refresh.
    private func toggleSpaceMode() {
        config.spaceMode = config.spaceMode.next
        config.save()
        service.spaceMode = config.spaceMode   // triggers refreshNow()
        panels.values.forEach { $0.setGrouped(config.spaceMode == .grouped) }
        applyDesktopNames()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        rebuildPanels()

        // Dock model is shared across all bars (same Dock content everywhere).
        dockModel.onChange = { [weak self] items in
            self?.latestItems = items
            self?.panels.values.forEach { $0.update(items: items) }
        }
        service.onChange = { [dockModel] apps in
            dockModel.updateRunning(apps)
        }
        // Windows are routed to each panel filtered to that panel's screen.
        service.onWindowsChange = { [weak self] windows in
            self?.latestWindows = windows
            self?.distributeWindows()
        }
        // Per-display desktop name shown under each bar's Apps button (each monitor
        // has its own current Space / numbering).
        service.onDesktopChange = { [weak self] names in
            self?.latestDesktops = names
            self?.applyDesktopNames()
        }

        // Recreate panels when displays change (plug/unplug, resolution).
        NotificationCenter.default.addObserver(
            self, selector: #selector(displaysChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)

        WindowControl.requestPermissions()
        DesktopSwitcher.ensureShortcutsEnabled()   // Ctrl+N desktop shortcuts for cross-space clicks
        service.spaceMode = config.spaceMode   // restore persisted mode
        dockModel.start()
        service.start()
        applyDesktopNames()
    }

    @objc private func displaysChanged() {
        rebuildPanels()
        panels.values.forEach { $0.update(items: latestItems) }
        distributeWindows()
    }

    // MARK: - Status item + Preferences

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "menubar.dock.rectangle",
                                     accessibilityDescription: "Taskbar Plus")
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Taskbar Plus", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        let prefItem = NSMenuItem(title: "Preferences…", action: #selector(openPreferences), keyEquivalent: ",")
        prefItem.target = self
        menu.addItem(prefItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Taskbar Plus", action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
        item.menu = menu
        statusItem = item
    }

    @objc private func openPreferences() {
        if prefs == nil {
            prefs = PreferencesController(config: config) { [weak self] newConfig in
                self?.apply(newConfig)
            }
        }
        prefs?.show()
    }

    /// Live-apply a new config: persist it, swap it in, and rebuild the bars.
    private func apply(_ newConfig: LayoutConfig) {
        config = newConfig
        newConfig.save()
        // Panels read config at init, so recreate them all. close() (with
        // isReleasedWhenClosed=false) removes them from AppKit's window list so ARC
        // can deallocate once we drop our reference.
        panels.values.forEach { $0.close() }
        panels = [:]
        rebuildPanels()
        panels.values.forEach { $0.update(items: latestItems) }
        distributeWindows()
    }

    /// Target screens per config: just the primary/Dock monitor, or all of them.
    private func targetScreens() -> [NSScreen] {
        switch config.monitors {
        case .dock:
            let primary = NSScreen.screens.first(where: { $0.frame.origin == .zero })
                ?? NSScreen.screens.first
            return primary.map { [$0] } ?? []
        case .all:
            return NSScreen.screens
        }
    }

    private func rebuildPanels() {
        let wanted = targetScreens()
        let wantedKeys = Set(wanted.map { key($0.frame.origin) })

        // Drop panels for screens no longer targeted.
        for (k, panel) in panels where !wantedKeys.contains(k) {
            panel.close()
            panels[k] = nil
        }
        // Create panels for newly-targeted screens.
        for screen in wanted where panels[key(screen.frame.origin)] == nil {
            let panel = TaskbarPanel(screen: screen, config: config)
            panel.onCloseRequested = { [weak self] in self?.service.refreshNow() }
            panel.onToggleSpaceMode = { [weak self] in self?.toggleSpaceMode() }
            panel.onIsWindowOnOtherSpace = { [weak self] num in
                self?.service.isWindowOnOtherSpace(num) ?? false
            }
            panel.desktopCount = { [weak self] in self?.service.desktopCount() ?? 0 }
            panel.setGrouped(config.spaceMode == .grouped)
            if config.spaceMode == .allSpaces {
                panel.updateDesktop("All Desktops")
            } else if let name = desktopName(for: screen) {
                panel.updateDesktop(name)
            }
            panels[key(screen.frame.origin)] = panel
        }
    }

    /// Send each panel the windows whose screen matches that panel (or all windows
    /// to the single bar when only the Dock monitor is shown).
    private func distributeWindows() {
        switch config.monitors {
        case .dock:
            panels.values.forEach { $0.updateWindows(latestWindows) }
        case .all:
            for (k, panel) in panels {
                let onThisScreen = latestWindows.filter { w in
                    w.screen.map { key($0.frame.origin) } == k
                }
                panel.updateWindows(onThisScreen)
            }
        }
    }
}

let app = NSApplication.shared
// Agent app: no Dock icon, never the foreground app.
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
