import AppKit

/// Horizontal zone a section is anchored in.
enum Zone: String {
    case left, center, right
}

/// Which monitors show the taskbar.
enum Monitors: String {
    case dock   // only the main (menu-bar, origin-zero) monitor (default)
    case all    // one bar per monitor, each scoped to that monitor's windows
}

/// Which windows the task switcher lists, and how they're grouped.
enum SpaceMode: String {
    case currentSpace   // only windows on the current Space (default)
    case allSpaces      // all windows across every Space, one flat list
    case grouped        // all windows, segmented into a bordered box per desktop

    /// Cycle order for the toggle (label click).
    var next: SpaceMode {
        switch self {
        case .currentSpace: return .allSpaces
        case .allSpaces:    return .grouped
        case .grouped:      return .currentSpace
        }
    }
}

/// Bar appearance.
enum Theme: String {
    case auto   // follow the system appearance (default)
    case light
    case dark

    /// The NSAppearance to force, or nil to follow the system.
    var appearance: NSAppearance? {
        switch self {
        case .auto:  return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark:  return NSAppearance(named: .darkAqua)
        }
    }
}

/// The logical sections of the bar.
enum Section: String, CaseIterable {
    case launcher  // Win95-style Start button → app menu
    case pinned    // persistent app launchers
    case running   // running-only apps (not pinned)
    case others    // folder stacks + Trash
    case switcher  // Win95-style window task switcher
}

/// User settings, persisted in ~/.taskbarplus.json:
///   { "taskbarOnly": false, "spaceMode": "currentSpace", "groupByApp": false, "compact": false,
///     "monitors": "dock", "theme": "auto", "autoUpdate": true }
/// The bar's layout itself is fixed (`zones`) — not user-configurable. Unknown
/// keys (e.g. per-section placements from older versions) are ignored; a missing or
/// invalid file falls back to defaults.
struct LayoutConfig {
    var monitors: Monitors
    var theme: Theme
    var spaceMode: SpaceMode
    /// Use alongside the real macOS Dock: hide pinned/running/folders/Trash (the Dock
    /// shows them). With a bottom Dock the switcher pins right; otherwise it's centered.
    var taskbarOnly: Bool
    /// Keep each app's windows next to each other in the window switcher.
    var groupByApp: Bool = false
    /// One-row (shorter) bar instead of the standard two-row bar.
    var compact: Bool = false
    /// Install new releases automatically (see Updater).
    var autoUpdate: Bool = true

    /// The one built-in layout, Windows-style: Start + app icons on the left, window
    /// buttons in the middle (expanding to fill the gap — see
    /// TaskbarPanel.applySwitcherExpand), folders + Trash on the right.
    private static let zones: [Section: Zone] = [
        .launcher: .left, .pinned: .left, .running: .left, .others: .right, .switcher: .center,
    ]

    static let configPath = URL(fileURLWithPath: NSString("~/.taskbarplus.json").expandingTildeInPath)

    static let defaults = LayoutConfig(monitors: .dock, theme: .auto, spaceMode: .currentSpace,
                                       taskbarOnly: false)

    static func load() -> LayoutConfig {
        guard let data = try? Data(contentsOf: configPath),
              let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return defaults }

        let monitors = (raw["monitors"] as? String).flatMap(Monitors.init) ?? .dock
        let theme = (raw["theme"] as? String).flatMap(Theme.init) ?? .auto
        let spaceMode = (raw["spaceMode"] as? String).flatMap(SpaceMode.init) ?? .currentSpace
        // "splitMode" is the old name of this key; still honoured so existing configs keep working.
        let taskbarOnly = (raw["taskbarOnly"] as? Bool) ?? (raw["splitMode"] as? Bool) ?? false
        let groupByApp = (raw["groupByApp"] as? Bool) ?? false
        let compact = (raw["compact"] as? Bool) ?? false
        let autoUpdate = (raw["autoUpdate"] as? Bool) ?? true
        return LayoutConfig(monitors: monitors, theme: theme, spaceMode: spaceMode,
                            taskbarOnly: taskbarOnly, groupByApp: groupByApp, compact: compact,
                            autoUpdate: autoUpdate)
    }

    /// Zone a section renders in. In taskbar-only mode the switcher moves to the right
    /// zone (TaskbarPanel centers it instead when the Dock isn't at the bottom).
    func effectiveZone(for section: Section) -> Zone {
        if taskbarOnly && section == .switcher { return .right }
        return Self.zones[section] ?? .center
    }

    /// Whether a section renders at all. Taskbar-only mode shows only launcher +
    /// switcher; the Dock provides pinned/running/folders/Trash.
    func sectionIsVisible(_ section: Section) -> Bool {
        guard taskbarOnly else { return true }
        return section == .launcher || section == .switcher
    }

    /// Serialize to ~/.taskbarplus.json (pretty-printed, sorted keys).
    func save() {
        let root: [String: Any] = [
            "monitors": monitors.rawValue, "theme": theme.rawValue,
            "spaceMode": spaceMode.rawValue, "taskbarOnly": taskbarOnly, "groupByApp": groupByApp,
            "compact": compact, "autoUpdate": autoUpdate,
        ]
        if let data = try? JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: Self.configPath)
        }
    }
}
