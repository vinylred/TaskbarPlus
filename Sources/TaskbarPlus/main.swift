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
    private var latestDesktop = ""

    private func key(_ origin: CGPoint) -> String { "\(origin.x),\(origin.y)" }

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
        // Current desktop name shown under the Apps button (same on all bars).
        service.onDesktopChange = { [weak self] name in
            self?.latestDesktop = name
            self?.panels.values.forEach { $0.updateDesktop(name) }
        }

        // Recreate panels when displays change (plug/unplug, resolution).
        NotificationCenter.default.addObserver(
            self, selector: #selector(displaysChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)

        WindowControl.requestPermissions()
        dockModel.start()
        service.start()
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
            if !latestDesktop.isEmpty { panel.updateDesktop(latestDesktop) }
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
