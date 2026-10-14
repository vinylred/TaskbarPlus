import AppKit

/// Keeps maximised windows clear of the taskbar, like Windows does.
///
/// macOS only reserves space for the real Dock + menu bar (`visibleFrame`); third
/// parties can't add to that. So a zoomed / "Fill"-tiled window extends under our
/// bar. On each poll we find windows that start at the top of the usable area and
/// reach down into a bar (full height = maximised, whatever the width — Safari's
/// zoom only widens to fit the page), and shorten them (via AX) so their bottom edge
/// sits just above the bar's top edge (see `gap`). Floating windows that don't
/// start at the top (e.g. one the user dragged down over the bar) are left alone.
final class WindowFitter {

    /// How close (pt) to the top of the usable area a maximised window must start.
    private static let topSlack: CGFloat = 40
    /// Overlap (pt) below which we don't bother resizing (sub-point rounding noise).
    private static let minOverlap: CGFloat = 0.5
    /// Gap left between a fitted window's bottom edge and the bar. macOS's window
    /// resize zone extends a few points OUTSIDE the window edge; flush against the bar,
    /// that zone lies over the bar and the owning app keeps setting the resize cursor
    /// there (fighting the bar's arrow). The gap keeps the zone off the bar.
    private static let gap: CGFloat = 6

    /// Window number → the frame we saw when we last tried to fit it. If the window
    /// still has that exact frame on the next poll, the app refused / clamped the
    /// resize (min size, character-cell rounding), so we stop retrying until the
    /// user changes the window again. Prevents a resize tug-of-war.
    private var attempted: [Int: CGRect] = [:]

    /// Window number → times we resized it recently. An app that keeps re-asserting
    /// its full-height frame (some Electron/Java apps) would otherwise be shrunk again
    /// every poll forever; after `maxFits` within `fitWindow` seconds we give up on it.
    private var fitTimes: [Int: [Date]] = [:]
    private static let maxFits = 3
    private static let fitWindow: TimeInterval = 30

    private let debug = ProcessInfo.processInfo.environment["TBP_DEBUG"] != nil

    /// - Parameters:
    ///   - windows: freshly scanned windows (CG global coords, top-left origin).
    ///   - bars: the visible bar frames (Cocoa coords, bottom-left origin).
    ///   - isOnOtherSpace: whether a window is on a Space that isn't visible. Those are
    ///     invisible to AX, and resizing them is never wanted anyway.
    func fit(_ windows: [WindowInfo], bars: [NSRect], isOnOtherSpace: (Int) -> Bool) {
        guard AXIsProcessTrusted(), !bars.isEmpty else {
            if debug { NSLog("TaskbarPlus[fit] skipped: axTrusted=\(AXIsProcessTrusted()) bars=\(bars.count)") }
            return
        }
        // Never resize while the user is dragging/resizing a window (mid-gesture).
        guard NSEvent.pressedMouseButtons == 0 else { return }
        let primaryH = NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height
            ?? NSScreen.screens.first?.frame.height ?? 0

        var seen = Set<Int>()
        for w in windows {
            seen.insert(w.windowNumber)
            guard let screen = w.screen else { continue }
            let screenCG = WindowInfo.cgFrame(of: screen)
            // Native fullscreen windows cover the whole screen — the bar hides then;
            // never shrink them.
            if w.frame.height >= screenCG.height - 1 { continue }

            // The bar on this window's screen (bars are full-width on their screen).
            guard let bar = bars.first(where: { screen.frame.intersects($0) }) else { continue }
            // Where fitted windows must end: just above the bar, minus the gap.
            let limitCG = primaryH - bar.maxY - Self.gap
            let vf = screen.visibleFrame
            let vfTopCG = primaryH - vf.maxY

            // Starts at the top of the usable area (within slack either way — a window
            // poking up into a display above isn't "maximised" on this one).
            let maximised = abs(w.frame.minY - vfTopCG) <= Self.topSlack
            let overlap = w.frame.maxY - limitCG
            guard maximised, overlap > Self.minOverlap else {
                attempted[w.windowNumber] = nil
                continue
            }
            if attempted[w.windowNumber] == w.frame { continue }   // already tried; app refused
            let now = Date()
            let recent = (fitTimes[w.windowNumber] ?? []).filter { now.timeIntervalSince($0) < Self.fitWindow }
            fitTimes[w.windowNumber] = recent
            if recent.count >= Self.maxFits { continue }            // app keeps re-maximising; give up
            if isOnOtherSpace(w.windowNumber) { continue }
            attempted[w.windowNumber] = w.frame
            fitTimes[w.windowNumber] = recent + [now]

            let newHeight = limitCG - w.frame.minY
            guard newHeight >= 100 else { continue }
            let ok = WindowControl.setSize(CGSize(width: w.frame.width, height: newHeight),
                                  windowNumber: w.windowNumber, pid: w.pid)
            if debug { NSLog("TaskbarPlus[fit] \(w.ownerName) \(w.frame) overlap=\(overlap) -> h=\(newHeight) ok=\(ok)") }
        }
        attempted = attempted.filter { seen.contains($0.key) }   // forget closed windows
        fitTimes = fitTimes.filter { seen.contains($0.key) }
    }
}
