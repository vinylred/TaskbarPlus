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

/// Which monitors show the taskbar.
enum Monitors: String {
    case dock   // only the primary / Dock monitor (default)
    case all    // one bar per monitor, each scoped to that monitor's windows
}

/// The four logical sections of the bar.
enum Section: String, CaseIterable {
    case pinned    // persistent app launchers
    case running   // running-only apps (not pinned)
    case others    // folder stacks + Trash
    case switcher  // Win95-style window task switcher
}

/// Per-section placement: an anchor zone plus an optional expand direction.
struct Placement {
    var zone: Zone
    var expand: Expand?
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
        .pinned:   Placement(zone: .left,  expand: nil),
        .running:  Placement(zone: .left,  expand: nil),
        .others:   Placement(zone: .right, expand: nil),
        .switcher: Placement(zone: .center, expand: .right),
    ], monitors: .dock)

    static func load() -> LayoutConfig {
        guard let data = try? Data(contentsOf: configPath),
              let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return defaults }

        var placements = defaults.placements
        for section in Section.allCases {
            guard let value = raw[section.rawValue] else { continue }
            if let z = value as? String, let zone = Zone(rawValue: z) {
                placements[section] = Placement(zone: zone, expand: nil)
            } else if let obj = value as? [String: String] {
                let zone = obj["zone"].flatMap(Zone.init) ?? placements[section]?.zone ?? .center
                let expand = obj["expand"].flatMap(Expand.init)
                placements[section] = Placement(zone: zone, expand: expand)
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
}
