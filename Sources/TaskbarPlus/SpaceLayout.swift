import CoreGraphics
import Foundation

/// A snapshot of the Spaces layout — one `CGSCopyManagedDisplaySpaces` result mapped
/// onto the current screens — with every Space/desktop question answered from it.
/// Pure (no system calls), so it's unit-tested with fixture data in Tests/.
///
/// What it must get right on complex setups (many desktops, fullscreen apps — each
/// its own Space — and several monitors with "Displays have separate Spaces"):
/// - Desktop numbers match macOS (Mission Control "Desktop N" and the "Switch to
///   Desktop N" shortcuts): only real desktops count (`type` 0; fullscreen-app Spaces
///   are skipped), numbered 1…N continuously across displays in CGS order.
/// - Each screen's current Space comes from ITS display entry; a screen whose current
///   Space is a fullscreen app has desktop 0 and is reported as fullscreen.
/// - With "Displays have separate Spaces" off there's ONE entry covering every screen.
struct SpaceLayout {

    /// The parts of an NSScreen the mapping needs (kept plain for tests).
    struct Screen {
        let key: String       // NSScreen.key
        let uuid: String?     // NSScreen.displayUUID
        let isPrimary: Bool   // frame origin == .zero
    }

    struct Space {
        let id: UInt64
        /// Real desktop (`type` 0) vs. a fullscreen-app / tiled Space.
        let isDesktop: Bool
    }

    struct Display {
        let identifier: String?
        let spaces: [Space]
        let currentSpace: UInt64?
        /// The current Space is a fullscreen app (or a tiled fullscreen pair).
        let showsFullscreen: Bool
        /// Screens (by key) this entry covers.
        let screenKeys: [String]
    }

    let displays: [Display]
    /// Space id → desktop number (desktops only).
    let desktopNumbers: [UInt64: Int]

    init(raw: [[String: Any]], screens: [Screen]) {
        var numbers: [UInt64: Int] = [:]
        displays = raw.map { entry in
            let identifier = entry["Display Identifier"] as? String
            let spaces: [Space] = ((entry["Spaces"] as? [[String: Any]]) ?? []).compactMap { s in
                guard let id = Self.spaceID(from: s) else { return nil }
                return Space(id: id, isDesktop: Self.isDesktop(s))
            }
            for s in spaces where s.isDesktop { numbers[s.id] = numbers.count + 1 }
            let current = entry["Current Space"] as? [String: Any]
            let keys: [String]
            if raw.count == 1 {
                keys = screens.map { $0.key }   // Spaces shared across all screens
            } else {
                keys = screens.filter {
                    (identifier == "Main" && $0.isPrimary) || (identifier != nil && $0.uuid == identifier)
                }.map { $0.key }
            }
            return Display(identifier: identifier, spaces: spaces,
                           currentSpace: current.flatMap(Self.spaceID(from:)),
                           showsFullscreen: current.map { !Self.isDesktop($0) } ?? false,
                           screenKeys: keys)
        }
        desktopNumbers = numbers
    }

    /// The visible Space on each display.
    var currentSpaceIDs: Set<UInt64> { Set(displays.compactMap { $0.currentSpace }) }

    /// Fullscreen-app (and tiled split-view) Spaces, on any display.
    var fullscreenSpaceIDs: Set<UInt64> {
        Set(displays.flatMap { $0.spaces.filter { !$0.isDesktop }.map { $0.id } })
    }

    /// Total desktops (fullscreen-app Spaces excluded).
    var desktopCount: Int { desktopNumbers.count }

    /// Screens whose current Space is a fullscreen app (their bars hide).
    var fullscreenScreenKeys: Set<String> {
        Set(displays.filter { $0.showsFullscreen }.flatMap { $0.screenKeys })
    }

    private func display(forScreen key: String) -> Display? {
        displays.first { $0.screenKeys.contains(key) }
    }

    /// Desktop number of the current Space on that screen; 0 if it shows a fullscreen
    /// app or the screen can't be matched.
    func currentDesktop(onScreen key: String) -> Int {
        display(forScreen: key)?.currentSpace.flatMap { desktopNumbers[$0] } ?? 0
    }

    /// Bar label for that screen: "Desk N", or "Desk" when there's no number.
    func label(onScreen key: String) -> String {
        let n = currentDesktop(onScreen: key)
        return n > 0 ? "Desk \(n)" : "Desk"
    }

    /// Desktop a window belongs to, from its Space ids (lowest if on several — e.g.
    /// "all desktops" windows); 0 if it's only on fullscreen-app Spaces / none.
    func desktop(forSpaces ids: Set<UInt64>) -> Int {
        ids.compactMap { desktopNumbers[$0] }.min() ?? 0
    }

    static func spaceID(from dict: [String: Any]) -> UInt64? {
        if let n = dict["ManagedSpaceID"] as? NSNumber { return n.uint64Value }
        if let n = dict["id64"] as? NSNumber { return n.uint64Value }
        return nil
    }

    /// `type` 0 = user desktop; 4 = fullscreen app. A `TileLayoutManager` marks a
    /// tiled (split-view) fullscreen Space.
    private static func isDesktop(_ space: [String: Any]) -> Bool {
        (space["type"] as? Int ?? 0) == 0 && space["TileLayoutManager"] == nil
    }
}
