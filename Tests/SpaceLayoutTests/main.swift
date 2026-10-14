// Unit tests for SpaceLayout (pure logic, fixture data shaped like
// CGSCopyManagedDisplaySpaces output). Run: ./test.sh
import Foundation

var failures = 0
func check<T: Equatable>(_ got: T, _ want: T, _ what: String, line: Int = #line) {
    if got != want { failures += 1; print("FAIL line \(line): \(what): got \(got), want \(want)") }
}

/// A Space dict: desktop (type 0) or fullscreen app (type 4, optionally tiled).
func space(_ id: UInt64, fullscreen: Bool = false, tiled: Bool = false) -> [String: Any] {
    var d: [String: Any] = ["ManagedSpaceID": NSNumber(value: id), "id64": NSNumber(value: id),
                            "type": fullscreen ? 4 : 0]
    if tiled { d["TileLayoutManager"] = ["x": 1] }
    return d
}
func display(_ id: String, _ spaces: [[String: Any]], current: UInt64) -> [String: Any] {
    ["Display Identifier": id, "Spaces": spaces,
     "Current Space": spaces.first { ($0["id64"] as! NSNumber).uint64Value == current }!]
}
let main = SpaceLayout.Screen(key: "0.0,0.0", uuid: "UUID-A", isPrimary: true)
let ext = SpaceLayout.Screen(key: "1512.0,0.0", uuid: "UUID-B", isPrimary: false)

// 1. One monitor, one fullscreen app between desktops, fullscreen app is current.
do {
    let l = SpaceLayout(raw: [display("UUID-A", [space(1), space(5, fullscreen: true), space(2)], current: 5)],
                        screens: [main])
    check(l.desktopNumbers, [1: 1, 2: 2], "fullscreen Space not numbered")
    check(l.currentDesktop(onScreen: main.key), 0, "fullscreen current → desktop 0")
    check(l.label(onScreen: main.key), "Desk", "fullscreen label")
    check(l.fullscreenScreenKeys, [main.key], "bar hides on fullscreen screen")
    check(l.desktop(forSpaces: [5]), 0, "window on fullscreen Space → other box")
    check(l.desktop(forSpaces: [2]), 2, "desktop after fullscreen keeps its number")
    check(l.fullscreenSpaceIDs, [5], "fullscreen Space ids")
}
// 2. Same, desktop current again → bar back.
do {
    let l = SpaceLayout(raw: [display("UUID-A", [space(1), space(5, fullscreen: true), space(2)], current: 2)],
                        screens: [main])
    check(l.currentDesktop(onScreen: main.key), 2, "desktop 2 after a fullscreen Space")
    check(l.label(onScreen: main.key), "Desk 2", "label")
    check(l.fullscreenScreenKeys, [], "no fullscreen")
}
// 3. Two monitors, separate Spaces, fullscreen apps on both, many desktops.
do {
    let a = display("UUID-A", [space(1), space(2), space(9, fullscreen: true), space(3), space(4)], current: 3)
    let b = display("UUID-B", [space(10), space(11, fullscreen: true), space(12, tiled: true), space(13)], current: 11)
    let l = SpaceLayout(raw: [a, b], screens: [main, ext])
    check(l.desktopNumbers, [1: 1, 2: 2, 3: 3, 4: 4, 10: 5, 13: 6], "global numbering, fullscreen skipped")
    check(l.desktopCount, 6, "desktop count")
    check(l.currentDesktop(onScreen: main.key), 3, "main screen current")
    check(l.currentDesktop(onScreen: ext.key), 0, "external shows fullscreen")
    check(l.fullscreenScreenKeys, [ext.key], "only the external bar hides")
    check(l.label(onScreen: main.key), "Desk 3", "main label")
    check(l.currentSpaceIDs, [3, 11], "visible Spaces")
    check(l.desktop(forSpaces: [12]), 0, "tiled split-view Space isn't a desktop")
    check(l.desktop(forSpaces: [13]), 6, "external desktop numbered after main's")
    check(l.fullscreenSpaceIDs, [9, 11, 12], "fullscreen + tiled Spaces on both displays")
}
// 4. Primary keyed as "Main".
do {
    let l = SpaceLayout(raw: [display("Main", [space(1), space(2)], current: 2),
                              display("UUID-B", [space(3)], current: 3)], screens: [main, ext])
    check(l.currentDesktop(onScreen: main.key), 2, "\"Main\" → primary screen")
    check(l.currentDesktop(onScreen: ext.key), 3, "external by UUID")
}
// 5. "Displays have separate Spaces" off: one entry covers every screen.
do {
    let l = SpaceLayout(raw: [display("Main", [space(1), space(7, fullscreen: true)], current: 7)],
                        screens: [main, ext])
    check(l.fullscreenScreenKeys, [main.key, ext.key], "shared Space fullscreen hides all bars")
    check(l.currentDesktop(onScreen: ext.key), 0, "shared fullscreen")
}
// 6. Unmatched screen (unknown UUID) → safe defaults, no crash.
do {
    let l = SpaceLayout(raw: [display("UUID-X", [space(1)], current: 1),
                              display("UUID-Y", [space(2)], current: 2)], screens: [main])
    check(l.currentDesktop(onScreen: main.key), 0, "unmatched screen")
    check(l.label(onScreen: main.key), "Desk", "unmatched label")
    check(l.fullscreenScreenKeys, [], "unmatched not fullscreen")
}
// 7. Empty / garbage input (private API drift) → empty layout.
do {
    let l = SpaceLayout(raw: [["junk": 1]], screens: [main])
    check(l.desktopCount, 0, "garbage → no desktops")
    check(l.currentSpaceIDs, [], "garbage → no current")
}

// 8. Routes to a Space.
do {
    typealias R = SpaceLayout.Route
    // One display: [D1, D2, F(5), D3]; on D1.
    let one = SpaceLayout(raw: [display("UUID-A", [space(1), space(2), space(5, fullscreen: true), space(3)], current: 1)],
                          screens: [main])
    check(one.routes(to: 3, activeScreenKey: main.key), [R(jump: 3, arrows: 0), R(jump: nil, arrows: 3)],
          "desktop: jump first, arrows as fallback")
    check(one.routes(to: 5, activeScreenKey: main.key).first, R(jump: nil, arrows: 2), "fullscreen: arrow right twice from D1")
    check(one.routes(to: 5, activeScreenKey: main.key).last, R(jump: 2, arrows: 1), "fullscreen fallback: jump to nearest desktop, then arrow")
    // Two displays; target fullscreen Space on the external, mouse on main.
    let a = display("UUID-A", [space(1), space(2)], current: 1)
    let b = display("UUID-B", [space(10), space(11, fullscreen: true), space(12)], current: 12)
    let two = SpaceLayout(raw: [a, b], screens: [main, ext])
    check(two.routes(to: 11, activeScreenKey: main.key), [R(jump: 3, arrows: 1)],
          "other display: jump to its nearest desktop first (moves focus), then arrow")
    check(two.routes(to: 11, activeScreenKey: ext.key).first, R(jump: nil, arrows: -1),
          "same display: arrow left from current")
    check(two.routes(to: 99, activeScreenKey: main.key), [], "unknown Space → no route")
}

// 9. Update version comparison.
check(Updater.isNewer("1.3.2", than: "1.3.1"), true, "patch bump")
check(Updater.isNewer("1.10.0", than: "1.9.9"), true, "numeric, not lexical")
check(Updater.isNewer("1.3", than: "1.3.0"), false, "missing component = 0")
check(Updater.isNewer("1.3.1", than: "1.3.1"), false, "same version")
check(Updater.isNewer("1.2.9", than: "1.3.0"), false, "older")

print(failures == 0 ? "All SpaceLayout tests passed." : "\(failures) failure(s).")
exit(failures == 0 ? 0 : 1)
