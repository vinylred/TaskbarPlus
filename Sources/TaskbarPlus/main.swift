import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var config = LayoutConfig.load()
    private let service = SpaceWindowService()
    private let dockModel = DockModelService()
    private let fitter = WindowFitter()
    private var prefs: PreferencesController?
    private var statusItem: NSStatusItem?

    /// One panel per target screen, keyed by `NSScreen.key` (its frame origin;
    /// CGPoint isn't Hashable before macOS 15).
    private var panels: [String: TaskbarPanel] = [:]
    private var latestItems: [DockItem] = []
    private var latestWindows: [WindowInfo] = []
    private var latestDesktops: [String: String] = [:]   // display UUID -> "Desk N"
    /// Screens (by `NSScreen.key`) showing fullscreen content — their bars hide.
    private var fullscreenScreens = Set<String>()

    /// Hide the bar on screens showing fullscreen content; show the others.
    /// Use alphaValue (not orderOut/orderFront) — ordering fights the panels'
    /// `.canJoinAllSpaces` behavior and left a bar stuck hidden after Space switches.
    private func applyVisibility() {
        for (key, panel) in panels {
            let hidden = fullscreenScreens.contains(key)
            panel.alphaValue = hidden ? 0 : 1
            panel.ignoresMouseEvents = hidden   // don't eat clicks while hidden
            panel.settleHoverLevel()
        }
    }

    /// The desktop name for a screen. CGSCopyManagedDisplaySpaces keys the primary
    /// display as the literal "Main" (not a UUID), so fall back to that for the
    /// primary screen (frame origin .zero) when the UUID doesn't match. With
    /// "Displays have separate Spaces" off there's a single shared entry ("Main") —
    /// every screen shows that one.
    private func desktopName(for screen: NSScreen) -> String? {
        if let uuid = screen.displayUUID, let n = latestDesktops[uuid] { return n }
        if screen.frame.origin == .zero, let n = latestDesktops["Main"] { return n }
        if latestDesktops.count == 1 { return latestDesktops.values.first }
        return nil
    }

    /// Push each panel its own screen's desktop name.
    private func applyDesktopNames() {
        // In all-spaces / grouped modes every bar shows a mode label; in current-Space
        // mode each shows its own current desktop.
        switch config.spaceMode {
        case .allSpaces:
            panels.values.forEach { $0.updateDesktop("All Desks") }
            return
        case .grouped:
            panels.values.forEach { $0.updateDesktop("Grouped") }
            return
        case .currentSpace:
            break
        }
        for screen in NSScreen.screens {
            // Always set something: a stale "Grouped" or an empty (unclickable) label
            // would otherwise remain on a screen we can't name.
            let name = desktopName(for: screen) ?? "Desk"
            panels[screen.key]?.updateDesktop(name)
        }
    }

    /// Cycle current-Space → all-Spaces → grouped, persist, and refresh.
    private func toggleSpaceMode() {
        config.spaceMode = config.spaceMode.next
        config.save()
        // Label first (it changes the launcher's width, which the chips are sized
        // against), then the grouped flag, then the service refresh — so the panels
        // rebuild once, with the new mode and final geometry.
        applyDesktopNames()
        panels.values.forEach { $0.setGrouped(config.spaceMode == .grouped) }
        service.spaceMode = config.spaceMode   // triggers refreshNow()
        prefs?.syncConfig(config)   // so a later prefs edit doesn't revert the mode
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        rebuildPanels()

        // Dock model is shared across all bars (same Dock content everywhere).
        dockModel.onChange = { [weak self] items in
            guard let self else { return }
            self.latestItems = items
            self.panels.values.forEach { $0.update(items: items) }
        }
        service.onChange = { [weak dockModel] apps in
            dockModel?.updateRunning(apps)
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
        // Hide a screen's bar while it shows fullscreen content (presentation,
        // fullscreen video, etc.); show it again on exit. Other screens keep theirs.
        service.onFullscreenChange = { [weak self] screens in
            self?.fullscreenScreens = screens
            self?.applyVisibility()
        }
        // Keep maximised windows from extending under the bar. Only visible bars count
        // (a screen showing fullscreen content has its bar hidden — nothing to avoid).
        service.onWindowsPolled = { [weak self] windows in
            guard let self else { return }
            let bars = self.panels.filter { !self.fullscreenScreens.contains($0.key) }.map { $0.value.frame }
            self.fitter.fit(windows, bars: bars,
                            isOnOtherSpace: { [weak self] in self?.service.isWindowOnOtherSpace($0) ?? true })
        }

        // Recreate panels when displays change (plug/unplug, resolution).
        NotificationCenter.default.addObserver(
            self, selector: #selector(displaysChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)

        WindowControl.requestPermissions()
        DesktopSwitcher.ensureShortcutsEnabled()   // Ctrl+N desktop shortcuts for cross-space clicks
        service.spaceMode = config.spaceMode   // restore persisted mode
        dockModel.taskbarOnly = config.taskbarOnly // taskbar-only mode hides Dock-provided sections
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
        // Update service modes BEFORE rebuilding so the first model emission carries
        // the right sections for the new config.
        service.spaceMode = config.spaceMode
        dockModel.taskbarOnly = config.taskbarOnly
        // Panels read config at init, so recreate them all. close() (with
        // isReleasedWhenClosed=false) removes them from AppKit's window list so ARC
        // can deallocate once we drop our reference.
        panels.values.forEach { $0.close() }
        panels = [:]
        rebuildPanels()
        panels.values.forEach { $0.update(items: latestItems) }
        distributeWindows()
        applyDesktopNames()
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
        let wantedKeys = Set(wanted.map { $0.key })

        // Drop panels no longer wanted (screen gone, or monitors setting changed).
        for (k, panel) in panels where !wantedKeys.contains(k) {
            panel.close()
            panels[k] = nil
        }
        // Create panels for newly-wanted screens.
        for screen in wanted where panels[screen.key] == nil {
            panels[screen.key] = makePanel(screen: screen)
        }
    }

    private func makePanel(screen: NSScreen) -> TaskbarPanel {
        let panel = TaskbarPanel(screen: screen, config: config)
        panel.onCloseRequested = { [weak self] in self?.service.refreshNow() }
        panel.onToggleSpaceMode = { [weak self] in self?.toggleSpaceMode() }
        panel.onIsWindowOnOtherSpace = { [weak self] num in
            self?.service.isWindowOnOtherSpace(num) ?? false
        }
        // Each bar's own screen's current desktop (displays have separate Spaces).
        let origin = screen.frame.origin
        panel.activeDesktop = { [weak self] in self?.service.currentDesktopIndex(onScreenAt: origin) ?? 0 }
        panel.setGrouped(config.spaceMode == .grouped)
        if config.spaceMode == .allSpaces {
            panel.updateDesktop("All Desks")
        } else if config.spaceMode == .grouped {
            panel.updateDesktop("Grouped")
        } else {
            panel.updateDesktop(desktopName(for: screen) ?? "Desk")
        }
        if fullscreenScreens.contains(screen.key) {   // stay hidden if created during fullscreen
            panel.alphaValue = 0
            panel.ignoresMouseEvents = true
        }
        return panel
    }

    /// Send each panel the windows whose screen matches that panel (or all windows
    /// to the single bar when only the main monitor is shown).
    private func distributeWindows() {
        let all = config.groupByApp ? Self.groupedByApp(latestWindows) : latestWindows
        for screen in targetScreens() {
            let windows: [WindowInfo]
            switch config.monitors {
            case .dock: windows = all
            case .all:  windows = all.filter { $0.screen?.frame.origin == screen.frame.origin }
            }
            panels[screen.key]?.updateWindows(windows)
        }
    }

    /// Reorder so each app's windows sit next to each other (plain buttons, no
    /// sub-menu). Apps keep the order they first appear in; windows keep their
    /// relative order within an app. Stable, so buttons don't shuffle on refresh.
    private static func groupedByApp(_ windows: [WindowInfo]) -> [WindowInfo] {
        var appRank: [pid_t: Int] = [:]
        for w in windows where appRank[w.pid] == nil { appRank[w.pid] = appRank.count }
        return windows.enumerated()
            .sorted { (appRank[$0.element.pid]!, $0.offset) < (appRank[$1.element.pid]!, $1.offset) }
            .map { $0.element }
    }
}

let app = NSApplication.shared
// Agent app: no Dock icon, never the foreground app.
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
