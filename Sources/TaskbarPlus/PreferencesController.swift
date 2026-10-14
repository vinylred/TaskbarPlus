import AppKit

/// A small Preferences window. Changes apply live via the `onChange` callback (which
/// persists the config and rebuilds the bars).
final class PreferencesController: NSObject {

    private let window: NSWindow
    private let onChange: (LayoutConfig) -> Void
    private var config: LayoutConfig

    private var dockPicker: NSSegmentedControl!
    private var heightPicker: NSSegmentedControl!
    private var spaceModePicker: NSSegmentedControl!
    private var monitorsPicker: NSSegmentedControl!
    private var themePicker: NSSegmentedControl!
    private var groupByAppCheckbox: NSButton!
    private var loginCheckbox: NSButton!
    private var autoUpdateCheckbox: NSButton!

    private static let spaceModes: [SpaceMode] = [.currentSpace, .allSpaces, .grouped]
    private static let themes: [Theme] = [.auto, .light, .dark]

    init(config: LayoutConfig, onChange: @escaping (LayoutConfig) -> Void) {
        self.config = config
        self.onChange = onChange

        let width: CGFloat = 480
        let rowH: CGFloat = 40
        // Dock + Height + Windows shown + Group by app + Monitors + Theme + Startup +
        // Updates rows.
        let height = 8 * rowH + 30

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        window.title = "Taskbar Plus — Preferences"
        window.isReleasedWhenClosed = false

        super.init()
        buildUI(width: width, rowH: rowH, height: height)
    }

    func show() {
        // The login item can be changed in System Settings while we're cached.
        loginCheckbox.state = LoginItem.isEnabled ? .on : .off
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Keep the controller's config in sync with changes made OUTSIDE the prefs pane
    /// (e.g. the bar's Desktop label cycling spaceMode). Without this, the next change
    /// in the pane would write back the stale spaceMode and revert the bar's mode.
    func syncConfig(_ newConfig: LayoutConfig) {
        config = newConfig
        spaceModePicker.selectedSegment = Self.spaceModes.firstIndex(of: config.spaceMode) ?? 0
    }

    // MARK: - UI construction

    private func buildUI(width: CGFloat, rowH: CGFloat, height: CGFloat) {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        var y = height - 20

        /// One labelled row with a segmented control.
        func row(_ title: String, _ labels: [String], selected: Int) -> NSSegmentedControl {
            y -= rowH
            let l = NSTextField(labelWithString: title)
            l.frame = NSRect(x: 20, y: y, width: 110, height: 22)
            l.font = .boldSystemFont(ofSize: 12)
            content.addSubview(l)
            let picker = NSSegmentedControl(labels: labels, trackingMode: .selectOne,
                                            target: self, action: #selector(changed))
            picker.frame = NSRect(x: 135, y: y - 2, width: width - 155, height: 24)
            picker.selectedSegment = selected
            content.addSubview(picker)
            return picker
        }

        dockPicker = row("Dock", ["Replace Dock", "Use alongside Dock"],
                         selected: config.taskbarOnly ? 1 : 0)
        heightPicker = row("Height", ["Standard (2 rows)", "Compact (1 row)"],
                           selected: config.compact ? 1 : 0)
        spaceModePicker = row("Windows shown", ["This desktop", "All desktops", "Grouped"],
                              selected: Self.spaceModes.firstIndex(of: config.spaceMode) ?? 0)
        y -= rowH
        let group = NSButton(checkboxWithTitle: "Group windows by app",
                             target: self, action: #selector(changed))
        group.frame = NSRect(x: 133, y: y - 2, width: 300, height: 24)
        group.state = config.groupByApp ? .on : .off
        content.addSubview(group)
        groupByAppCheckbox = group

        monitorsPicker = row("Monitors", ["Main only", "All monitors"],
                             selected: config.monitors == .all ? 1 : 0)
        themePicker = row("Theme", ["Auto", "Light", "Dark"],
                          selected: Self.themes.firstIndex(of: config.theme) ?? 0)

        // Start-at-login row (system login item, not part of the JSON config).
        y -= rowH
        let login = NSButton(checkboxWithTitle: "Start at login",
                             target: self, action: #selector(toggleLogin(_:)))
        login.frame = NSRect(x: 133, y: y - 2, width: 220, height: 24)
        login.state = LoginItem.isEnabled ? .on : .off
        content.addSubview(login)
        loginCheckbox = login

        y -= rowH
        let update = NSButton(checkboxWithTitle: "Install updates automatically",
                              target: self, action: #selector(changed))
        update.frame = NSRect(x: 133, y: y - 2, width: 300, height: 24)
        update.state = config.autoUpdate ? .on : .off
        content.addSubview(update)
        autoUpdateCheckbox = update

        window.contentView = content
    }

    @objc private func toggleLogin(_ sender: NSButton) {
        let ok = LoginItem.setEnabled(sender.state == .on)
        if !ok { sender.state = LoginItem.isEnabled ? .on : .off }  // revert on failure
    }

    // MARK: - Live apply

    @objc private func changed() {
        config = LayoutConfig(
            monitors: monitorsPicker.selectedSegment == 1 ? .all : .dock,
            theme: Self.themes[themePicker.selectedSegment],
            spaceMode: Self.spaceModes[spaceModePicker.selectedSegment],
            taskbarOnly: dockPicker.selectedSegment == 1,
            groupByApp: groupByAppCheckbox.state == .on,
            compact: heightPicker.selectedSegment == 1,
            autoUpdate: autoUpdateCheckbox.state == .on)
        onChange(config)
    }
}
