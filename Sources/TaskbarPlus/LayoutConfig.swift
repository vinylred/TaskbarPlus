import Foundation

/// Horizontal zone a section is anchored in.
enum Zone: String {
    case left, center, right
}

/// Optional direction a section stretches to fill spare space.
enum Expand: String {
    case left   // grow toward the left edge
    case right  // grow toward the right edge
}

/// How a section's items align horizontally within its available area.
enum Align: String {
    case left, center, right
}

/// Which monitors show the taskbar.
enum Monitors: String {
    case dock   // only the primary / Dock monitor (default)
    case all    // one bar per monitor, each scoped to that monitor's windows
}

/// The logical sections of the bar.
enum Section: String, CaseIterable {
    case launcher  // Win95-style Start button → app menu
    case pinned    // persistent app launchers
    case running   // running-only apps (not pinned)
    case others    // folder stacks + Trash
    case switcher  // Win95-style window task switcher
}

/// Per-section placement: an anchor zone, optional expand direction, and how items
/// align within the section's area.
struct Placement {
    var zone: Zone
    var expand: Expand?
    var align: Align = .left
}

/// Layout loaded from ~/.taskbarplus.json. Each section's value is either:
///   - a zone string:           "switcher": "right"
///   - or an object with expand: "switcher": { "zone": "left", "expand": "right" }
///
/// `expand` makes the section stretch to fill the gap toward that edge (up to the
/// neighbouring section). Missing/invalid file falls back to defaults.
struct LayoutConfig {
    var placements: [Section: Placement]
    var monitors: Monitors

    static let configPath = URL(fileURLWithPath: NSString("~/.taskbarplus.json").expandingTildeInPath)

    static let defaults = LayoutConfig(placements: [
        .launcher: Placement(zone: .left,  expand: nil, align: .left),
        .pinned:   Placement(zone: .left,  expand: nil, align: .left),
        .running:  Placement(zone: .left,  expand: nil, align: .left),
        .others:   Placement(zone: .right, expand: nil, align: .right),
        .switcher: Placement(zone: .center, expand: .right, align: .left),
    ], monitors: .dock)

    static func load() -> LayoutConfig {
        guard let data = try? Data(contentsOf: configPath),
              let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return defaults }

        var placements = defaults.placements
        for section in Section.allCases {
            guard let value = raw[section.rawValue] else { continue }
            let fallback = placements[section] ?? Placement(zone: .center, expand: nil)
            if let z = value as? String, let zone = Zone(rawValue: z) {
                placements[section] = Placement(zone: zone, expand: nil, align: fallback.align)
            } else if let obj = value as? [String: String] {
                let zone = obj["zone"].flatMap(Zone.init) ?? fallback.zone
                let expand = obj["expand"].flatMap(Expand.init)
                let align = obj["align"].flatMap(Align.init) ?? fallback.align
                placements[section] = Placement(zone: zone, expand: expand, align: align)
            }
        }
        let monitors = (raw["monitors"] as? String).flatMap(Monitors.init) ?? .dock
        return LayoutConfig(placements: placements, monitors: monitors)
    }

    func placement(for section: Section) -> Placement {
        placements[section] ?? Placement(zone: .center, expand: nil)
    }

    func zone(for section: Section) -> Zone { placement(for: section).zone }
    func expand(for section: Section) -> Expand? { placement(for: section).expand }
    func align(for section: Section) -> Align { placement(for: section).align }

    /// Serialize to ~/.taskbarplus.json (pretty-printed, sorted keys).
    func save() {
        var root: [String: Any] = ["monitors": monitors.rawValue]
        for section in Section.allCases {
            let p = placement(for: section)
            // Use the compact string form only when there's nothing but a zone.
            if p.expand == nil && p.align == .left {
                root[section.rawValue] = p.zone.rawValue
            } else {
                var obj: [String: String] = ["zone": p.zone.rawValue, "align": p.align.rawValue]
                if let expand = p.expand { obj["expand"] = expand.rawValue }
                root[section.rawValue] = obj
            }
        }
        if let data = try? JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: Self.configPath)
        }
    }
}
