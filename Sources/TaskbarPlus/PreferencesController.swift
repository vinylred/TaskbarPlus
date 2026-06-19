import AppKit

/// A small Preferences window for editing the taskbar layout. Changes apply live
/// via the `onChange` callback (which persists the config and rebuilds the bars).
final class PreferencesController: NSObject {

    private let window: NSWindow
    private let onChange: (LayoutConfig) -> Void
    private var config: LayoutConfig

    // Per-section controls.
    private var zonePickers: [Section: NSSegmentedControl] = [:]
    private var expandPickers: [Section: NSSegmentedControl] = [:]
    private var alignPickers: [Section: NSSegmentedControl] = [:]
    private var monitorsPicker: NSSegmentedControl!
    private var themePicker: NSSegmentedControl!
    private var splitModeCheckbox: NSButton!

    private static let zones: [Zone] = [.left, .center, .right]
    private static let expands: [Expand?] = [nil, .left, .right]
    private static let aligns: [Align] = [.left, .center, .right]
    private static let themes: [Theme] = [.auto, .light, .dark]

    init(config: LayoutConfig, onChange: @escaping (LayoutConfig) -> Void) {
        self.config = config
        self.onChange = onChange

        let width: CGFloat = 620
        let rowH: CGFloat = 40
        let sections = Section.allCases
        // sections + Monitors + Theme + Mode + Startup rows.
        let height = CGFloat(sections.count + 4) * rowH + 90

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        window.title = "Taskbar Plus — Preferences"
        window.isReleasedWhenClosed = false

        super.init()
        buildUI(width: width, rowH: rowH, height: height, sections: sections)
    }

    func show() {
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - UI construction

    private func buildUI(width: CGFloat, rowH: CGFloat, height: CGFloat, sections: [Section]) {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))

        func label(_ text: String, _ frame: NSRect, bold: Bool = false) -> NSTextField {
            let l = NSTextField(labelWithString: text)
            l.frame = frame
            l.font = bold ? .boldSystemFont(ofSize: 12) : .systemFont(ofSize: 12)
            return l
        }

        // Column headers.
        var y = height - 36
        content.addSubview(label("Section", NSRect(x: 20, y: y, width: 90, height: 18), bold: true))
        content.addSubview(label("Position", NSRect(x: 120, y: y, width: 150, height: 18), bold: true))
        content.addSubview(label("Expand", NSRect(x: 290, y: y, width: 120, height: 18), bold: true))
        content.addSubview(label("Align", NSRect(x: 450, y: y, width: 150, height: 18), bold: true))

        let sectionTitles: [Section: String] = [
            .launcher: "App launcher", .pinned: "Pinned apps", .running: "Running apps",
            .others: "Folders + Trash", .switcher: "Window switcher",
        ]

        for section in sections {
            y -= rowH
            content.addSubview(label(sectionTitles[section] ?? section.rawValue,
                                     NSRect(x: 20, y: y, width: 95, height: 22)))

            // Zone picker.
            let zone = NSSegmentedControl(labels: ["Left", "Center", "Right"],
                                          trackingMode: .selectOne,
                                          target: self, action: #selector(changed))
            zone.frame = NSRect(x: 120, y: y - 2, width: 160, height: 24)
            zone.selectedSegment = Self.zones.firstIndex(of: config.zone(for: section)) ?? 1
            zone.tag = tag(section, kind: 0)
            content.addSubview(zone)
            zonePickers[section] = zone

            // Expand picker.
            let expand = NSSegmentedControl(labels: ["None", "←", "→"],
                                            trackingMode: .selectOne,
                                            target: self, action: #selector(changed))
            expand.frame = NSRect(x: 290, y: y - 2, width: 130, height: 24)
            expand.selectedSegment = Self.expands.firstIndex(of: config.expand(for: section)) ?? 0
            expand.tag = tag(section, kind: 1)
            content.addSubview(expand)
            expandPickers[section] = expand

            // Align picker.
            let align = NSSegmentedControl(labels: ["Left", "Center", "Right"],
                                           trackingMode: .selectOne,
                                           target: self, action: #selector(changed))
            align.frame = NSRect(x: 450, y: y - 2, width: 160, height: 24)
            align.selectedSegment = Self.aligns.firstIndex(of: config.align(for: section)) ?? 0
            align.tag = tag(section, kind: 2)
            content.addSubview(align)
            alignPickers[section] = align
        }

        // Monitors row.
        y -= rowH
        content.addSubview(label("Monitors", NSRect(x: 20, y: y, width: 95, height: 22), bold: true))
        let mon = NSSegmentedControl(labels: ["Dock monitor", "All monitors"],
                                     trackingMode: .selectOne,
                                     target: self, action: #selector(changed))
        mon.frame = NSRect(x: 120, y: y - 2, width: 220, height: 24)
        mon.selectedSegment = (config.monitors == .all) ? 1 : 0
        content.addSubview(mon)
        monitorsPicker = mon

        // Theme row.
        y -= rowH
        content.addSubview(label("Theme", NSRect(x: 20, y: y, width: 95, height: 22), bold: true))
        let theme = NSSegmentedControl(labels: ["Auto", "Light", "Dark"],
                                       trackingMode: .selectOne,
                                       target: self, action: #selector(changed))
        theme.frame = NSRect(x: 120, y: y - 2, width: 220, height: 24)
        theme.selectedSegment = Self.themes.firstIndex(of: config.theme) ?? 0
        content.addSubview(theme)
        themePicker = theme

        // Split-mode row (coexist with the real Dock).
        y -= rowH
        content.addSubview(label("Mode", NSRect(x: 20, y: y, width: 95, height: 22), bold: true))
        let split = NSButton(checkboxWithTitle: "Split mode (coexist with Dock)",
                             target: self, action: #selector(changed))
        split.frame = NSRect(x: 118, y: y - 2, width: 300, height: 24)
        split.state = config.splitMode ? .on : .off
        content.addSubview(split)
        splitModeCheckbox = split

        // Start-at-login row (system login item, not part of the JSON config).
        y -= rowH
        content.addSubview(label("Startup", NSRect(x: 20, y: y, width: 95, height: 22), bold: true))
        let login = NSButton(checkboxWithTitle: "Start at login",
                             target: self, action: #selector(toggleLogin(_:)))
        login.frame = NSRect(x: 118, y: y - 2, width: 220, height: 24)
        login.state = LoginItem.isEnabled ? .on : .off
        content.addSubview(login)

        window.contentView = content
    }

    @objc private func toggleLogin(_ sender: NSButton) {
        let ok = LoginItem.setEnabled(sender.state == .on)
        if !ok { sender.state = LoginItem.isEnabled ? .on : .off }  // revert on failure
    }

    // Encode (section, kind) into a control tag.
    private func tag(_ section: Section, kind: Int) -> Int {
        (Section.allCases.firstIndex(of: section) ?? 0) * 10 + kind
    }

    // MARK: - Live apply

    @objc private func changed() {
        var placements: [Section: Placement] = [:]
        for section in Section.allCases {
            let zone = Self.zones[zonePickers[section]?.selectedSegment ?? 1]
            let expand = Self.expands[expandPickers[section]?.selectedSegment ?? 0]
            let align = Self.aligns[alignPickers[section]?.selectedSegment ?? 0]
            placements[section] = Placement(zone: zone, expand: expand, align: align)
        }
        let monitors: Monitors = (monitorsPicker.selectedSegment == 1) ? .all : .dock
        let theme = Self.themes[themePicker.selectedSegment]
        // spaceMode is toggled via the bar's Desktop label, not here — preserve it.
        config = LayoutConfig(placements: placements, monitors: monitors, theme: theme,
                              spaceMode: config.spaceMode,
                              splitMode: splitModeCheckbox.state == .on)
        onChange(config)
    }
}
