import AppKit
import CSkyLight

/// Discovers the apps that have windows on the *current* macOS Space and notifies
/// a listener whenever that set changes (Space switch, app launch/quit, etc.).
///
/// Reads Space membership through private CGS/SkyLight calls. All private access is
/// defensive: any nil/empty result falls back to "all regular running apps" so the
/// bar never goes blank if a private signature drifts on a future macOS release.
final class SpaceWindowService {

    /// Called on the main thread with the ordered list of apps to display.
    var onChange: (([NSRunningApplication]) -> Void)?

    /// Whether the switcher lists windows on the current Space only, or all Spaces.
    var spaceMode: SpaceMode = .currentSpace {
        didSet { if spaceMode != oldValue { refreshNow() } }
    }

    /// Called on the main thread with the windows open on the current Space,
    /// in stable left-to-right order (for the task switcher).
    var onWindowsChange: (([WindowInfo]) -> Void)?

    /// Called on the main thread with the per-display desktop labels (keyed by
    /// display UUID) when any of them change.
    var onDesktopChange: (([String: String]) -> Void)?
    private var lastDesktopNames: [String: String] = [:]

    /// Distinct app count from the last accepted window scan, used to detect the
    /// transient collapse to a single app during App Exposé / Mission Control.
    private var lastAppCount = 0
    /// Consecutive refreshes the single-app collapse has been skipped (so a real
    /// collapse eventually wins after ~6 × 0.5s ≈ 3s).
    private var collapseSkips = 0

    private let cid: CGSConnectionID = CGSMainConnectionID()
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    /// Stable left-to-right ordering: pids keep their slot once seen.
    private var orderedPIDs: [pid_t] = []
    /// Stable ordering for windows: window numbers keep their slot once seen.
    private var orderedWindowNumbers: [Int] = []
    /// Last-seen info per window number, retained briefly through transient misses.
    private var cachedWindows: [Int: WindowInfo] = [:]
    /// Consecutive refreshes a known window has been absent (hysteresis counter).
    private var windowMisses: [Int: Int] = [:]

    private var debounceTimer: Timer?
    private var safetyPoll: Timer?

    func start() {
        let wsCenter = NSWorkspace.shared.notificationCenter
        // A Space switch is a definitive event — refresh immediately (skip the
        // debounce + anti-flicker hysteresis) so the new windows appear at once.
        wsCenter.addObserver(self, selector: #selector(spaceChanged),
                             name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        // App-level events are debounced (they can arrive in bursts).
        let debounced: [Notification.Name] = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didHideApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification,
        ]
        for name in debounced {
            wsCenter.addObserver(self, selector: #selector(scheduleRefresh),
                                 name: name, object: nil)
        }

        // Safety net to catch window changes that emit no NSWorkspace notification
        // (new/closed/moved windows within an already-active app). 0.5s keeps the
        // taskbar responsive; the signature guard means unchanged polls are cheap.
        safetyPoll = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.refresh()
        }

        // Sanity check the private call once at startup.
        if CGSCopyManagedDisplaySpaces(cid) == nil {
            NSLog("TaskbarPlus: CGSCopyManagedDisplaySpaces returned nil — using all-apps fallback")
        }

        refresh()
    }

    @objc private func spaceChanged() { refreshNow() }

    /// Coalesce bursts of notifications (a Space switch emits several).
    @objc private func scheduleRefresh() {
        debounceTimer?.invalidate()
        debounceTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: false) { [weak self] _ in
            self?.refresh()
        }
    }

    /// Force an immediate, authoritative refresh that skips the anti-flicker
    /// hysteresis — used right after WE close a window, so the taskbar updates at
    /// once instead of waiting for the poll + miss-threshold + collapse-skip.
    func refreshNow() { refresh(immediate: true) }

    private func refresh(immediate: Bool = false) {
        let windows = currentSpaceWindows()

        // App Exposé / Mission Control transiently collapses the on-screen window
        // set to just the focused app. If we previously saw several apps and now
        // see only one, treat it as that transient and skip — but only briefly, so
        // a *genuine* collapse (user really closed the other apps) still updates
        // once it persists across a couple of refreshes. (Skipped when immediate.)
        if !immediate, let ws = windows {
            let appCount = Set(ws.map { $0.pid }).count
            if appCount <= 1 && lastAppCount > 1 && collapseSkips < 6 {
                collapseSkips += 1
                return
            }
            collapseSkips = 0
            lastAppCount = appCount
        } else if let ws = windows {
            lastAppCount = Set(ws.map { $0.pid }).count
            collapseSkips = 0
        }

        let detected = windows.map { Array(Set($0.map { $0.pid })) }
        let pids = detected ?? fallbackPIDs()
        let apps = resolveApps(orderStable(pids))

        let orderedWindows = orderStableWindows(windows ?? [], immediate: immediate)

        if ProcessInfo.processInfo.environment["TBP_DEBUG"] != nil {
            let mode = detected == nil ? "FALLBACK(all-apps)" : "current-space"
            NSLog("TaskbarPlus[\(mode)] spaces=\(currentSpaceIDs().sorted()) apps=\(apps.map { $0.localizedName ?? "?" }) windows=\(orderedWindows.count)")
        }
        onChange?(apps)
        onWindowsChange?(orderedWindows)

        let desktops = currentDesktopNames()
        if desktops != lastDesktopNames {
            lastDesktopNames = desktops
            onDesktopChange?(desktops)
        }
    }

    // MARK: - Current-Space detection (private APIs)

    /// All normal windows on the current Space (title, owner, icon), or nil if the
    /// private query path fails (signature drift / empty results).
    private func currentSpaceWindows() -> [WindowInfo]? {
        // Both all-spaces and grouped modes enumerate every Space's windows.
        let allSpaces = (spaceMode == .allSpaces || spaceMode == .grouped)
        let currentSpaces = currentSpaceIDs()
        guard allSpaces || !currentSpaces.isEmpty else { return nil }

        // `.optionOnScreenOnly` returns only the current Space's windows; omitting it
        // (all-spaces mode) returns windows across every Space. `kCGWindowName`
        // (title) requires Screen Recording permission; absent/empty otherwise.
        var opts: CGWindowListOption = [.excludeDesktopElements]
        if !allSpaces { opts.insert(.optionOnScreenOnly) }
        guard let infoList = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]],
              !infoList.isEmpty else { return nil }

        struct Raw { let num: Int; let pid: pid_t; let owner: String; let title: String; let frame: CGRect }
        var raws: [Raw] = []
        for info in infoList {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let num = info[kCGWindowNumber as String] as? Int,
                  let pid = info[kCGWindowOwnerPID as String] as? Int else { continue }
            if pid_t(pid) == ownPID { continue }
            if let alpha = info[kCGWindowAlpha as String] as? Double, alpha <= 0 { continue }
            guard let b = info[kCGWindowBounds as String] as? [String: Any],
                  let x = b["X"] as? Double, let y = b["Y"] as? Double,
                  let w = b["Width"] as? Double, let h = b["Height"] as? Double else { continue }
            // Real document windows are reasonably sized; tiny ones are usually
            // helper/agent panels (e.g. Google Drive's menu-bar window).
            guard w >= 80, h >= 80 else { continue }
            // Only windows belonging to regular (Dock-visible) apps — drops menu-bar
            // agents/accessories like Google Drive that have no real window.
            guard let runApp = NSRunningApplication(processIdentifier: pid_t(pid)),
                  runApp.activationPolicy == .regular else { continue }
            // Keep CGWindow bounds as-is (top-left origin, global CG space). Screen
            // matching is done in CG space too, avoiding a fragile coordinate flip
            // that breaks for displays positioned above/left of the primary.
            let frame = CGRect(x: x, y: y, width: w, height: h)
            let owner = (info[kCGWindowOwnerName as String] as? String) ?? ""
            let title = (info[kCGWindowName as String] as? String) ?? ""
            raws.append(Raw(num: num, pid: pid_t(pid), owner: owner, title: title, frame: frame))
        }
        guard !raws.isEmpty else { return nil }

        // When titles are available (Screen Recording granted), drop untitled
        // windows — they're usually palettes/helpers, not real document windows.
        // If NO window has a title (permission not granted), keep them all so the
        // switcher still works off app names.
        if raws.contains(where: { !$0.title.isEmpty }) {
            raws = raws.filter { !$0.title.isEmpty }
        }

        // Dedupe by (pid, title): some apps (e.g. Teams) report a main window plus a
        // WebView/helper window with the same title — collapse to one button.
        var seen = Set<String>()
        raws = raws.filter { seen.insert("\($0.pid):\($0.title)").inserted }

        // Multi-space modes need each window's desktop index (for grouping and for
        // the click → switch-to-its-desktop chain).
        let grouped = (spaceMode == .grouped)
        let multiSpace = allSpaces || grouped
        let spaceIndex = multiSpace ? spaceIDToDesktopIndex() : [:]

        var icons: [pid_t: NSImage] = [:]
        var result: [WindowInfo] = []
        // Per-window space ids needed for the current-Space filter (currentSpace mode)
        // and desktop tagging (all multi-space modes).
        let needSpaceIDs = !allSpaces || multiSpace
        for r in raws {
            let ids = needSpaceIDs ? spaceIDs(forWindowNumbers: [r.num]) : []
            if !allSpaces {
                guard ids.contains(where: { currentSpaces.contains($0) }) else { continue }
            }
            let icon = icons[r.pid] ?? {
                let img = NSRunningApplication(processIdentifier: r.pid)?.icon
                    ?? NSImage(named: NSImage.applicationIconName) ?? NSImage()
                icons[r.pid] = img
                return img
            }()
            let desktopIdx = multiSpace ? (ids.compactMap { spaceIndex[$0] }.min() ?? 0) : 0
            result.append(WindowInfo(windowNumber: r.num, pid: r.pid,
                                     ownerName: r.owner, title: r.title, icon: icon,
                                     frame: r.frame, desktopIndex: desktopIdx))
        }
        return result.isEmpty ? nil : result
    }

    /// Whether a window lives on a Space other than a currently-visible one.
    /// (macOS 26 blocks programmatic Space switching, so cross-Space clicks fall back
    /// to plain app activation — this just tells the panel which path to take.)
    func isWindowOnOtherSpace(_ windowNumber: Int) -> Bool {
        let target = spaceIDs(forWindowNumbers: [windowNumber])
        guard !target.isEmpty else { return false }
        let current = currentSpaceIDs()
        return !target.contains(where: { current.contains($0) })
    }

    /// Map each Space id → its 1-based desktop index, using the primary display's
    /// ordered Spaces list (matches the per-display numbering used elsewhere).
    private func spaceIDToDesktopIndex() -> [UInt64: Int] {
        guard let raw = CGSCopyManagedDisplaySpaces(cid),
              let displays = (raw as NSArray) as? [[String: Any]] else { return [:] }
        var map: [UInt64: Int] = [:]
        for display in displays {
            guard let spaces = display["Spaces"] as? [[String: Any]] else { continue }
            for (i, s) in spaces.enumerated() {
                if let id = spaceID(from: s) { map[id] = i + 1 }
            }
        }
        return map
    }

    /// Total desktop (Space) count on the primary display, for grouped segments.
    func desktopCount() -> Int {
        guard let raw = CGSCopyManagedDisplaySpaces(cid),
              let displays = (raw as NSArray) as? [[String: Any]],
              let display = displays.first,
              let spaces = display["Spaces"] as? [[String: Any]] else { return 0 }
        return spaces.count
    }

    /// 1-based index of the currently-active desktop on the primary display, or 0.
    func currentDesktopIndex() -> Int {
        guard let raw = CGSCopyManagedDisplaySpaces(cid),
              let displays = (raw as NSArray) as? [[String: Any]],
              let display = displays.first,
              let spaces = display["Spaces"] as? [[String: Any]],
              let current = display["Current Space"] as? [String: Any],
              let cid = spaceID(from: current),
              let idx = spaces.firstIndex(where: { spaceID(from: $0) == cid })
        else { return 0 }
        return idx + 1
    }

    /// The active space id on each display.
    private func currentSpaceIDs() -> Set<UInt64> {
        guard let raw = CGSCopyManagedDisplaySpaces(cid),
              let displays = (raw as NSArray) as? [[String: Any]] else { return [] }
        var result = Set<UInt64>()
        for display in displays {
            if let current = display["Current Space"] as? [String: Any],
               let id = spaceID(from: current) {
                result.insert(id)
            }
        }
        return result
    }

    private func spaceID(from dict: [String: Any]) -> UInt64? {
        if let n = dict["ManagedSpaceID"] as? NSNumber { return n.uint64Value }
        if let n = dict["id64"] as? NSNumber { return n.uint64Value }
        return nil
    }

    /// Current-Space label ("Desktop N") for EACH display, keyed by its display UUID
    /// string — each monitor has its own current Space and its own numbering.
    func currentDesktopNames() -> [String: String] {
        guard let raw = CGSCopyManagedDisplaySpaces(cid),
              let displays = (raw as NSArray) as? [[String: Any]] else { return [:] }
        var result: [String: String] = [:]
        for display in displays {
            guard let uuid = display["Display Identifier"] as? String,
                  let spaces = display["Spaces"] as? [[String: Any]],
                  let current = display["Current Space"] as? [String: Any],
                  let currentID = spaceID(from: current) else { continue }
            if let idx = spaces.firstIndex(where: { spaceID(from: $0) == currentID }) {
                result[uuid] = "Desktop \(idx + 1)"
            } else {
                result[uuid] = "Desktop"
            }
        }
        return result
    }

    /// Back-compat single-name (primary display).
    func currentDesktopName() -> String {
        guard let raw = CGSCopyManagedDisplaySpaces(cid),
              let displays = (raw as NSArray) as? [[String: Any]],
              let display = displays.first else { return "Desktop" }
        guard let spaces = display["Spaces"] as? [[String: Any]],
              let current = display["Current Space"] as? [String: Any],
              let currentID = spaceID(from: current) else { return "Desktop" }
        if let idx = spaces.firstIndex(where: { spaceID(from: $0) == currentID }) {
            return "Desktop \(idx + 1)"
        }
        return "Desktop"
    }

    /// Space ids that the given window numbers belong to.
    private func spaceIDs(forWindowNumbers numbers: [Int]) -> Set<UInt64> {
        let cfNumbers = numbers.map { NSNumber(value: $0) } as CFArray
        // 0x7 = current | other | all; we filter against the known current set ourselves.
        guard let result = CGSCopySpacesForWindows(cid, 0x7, cfNumbers),
              let raw = (result as NSArray) as? [NSNumber] else { return [] }
        return Set(raw.map { $0.uint64Value })
    }

    // MARK: - Fallback

    private func fallbackPIDs() -> [pid_t] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .map { $0.processIdentifier }
    }

    // MARK: - Ordering & resolution

    /// Keep a stable left-to-right order: existing pids hold their slot, new pids append.
    private func orderStable(_ pids: [pid_t]) -> [pid_t] {
        let live = Set(pids)
        orderedPIDs.removeAll { !live.contains($0) }
        let known = Set(orderedPIDs)
        for pid in pids where !known.contains(pid) {
            orderedPIDs.append(pid)
        }
        return orderedPIDs
    }

    /// Stable order for windows by window number, with hysteresis so a single
    /// transient blip (a window flickering in/out of the Space for one refresh)
    /// doesn't add/remove a switcher button. New windows appear immediately;
    /// a window is only dropped after it's been absent for `missThreshold` refreshes.
    private func orderStableWindows(_ windows: [WindowInfo], immediate: Bool = false) -> [WindowInfo] {
        // immediate → drop absent windows at once (no grace) for an authoritative update.
        let missThreshold = immediate ? 1 : 2
        let byNum = Dictionary(windows.map { ($0.windowNumber, $0) }, uniquingKeysWith: { a, _ in a })

        // Refresh cached info for present windows; reset their miss count.
        for w in windows {
            cachedWindows[w.windowNumber] = w
            windowMisses[w.windowNumber] = 0
        }
        // Increment misses for previously-known windows that are absent now; drop
        // once over threshold.
        for num in orderedWindowNumbers where byNum[num] == nil {
            let misses = (windowMisses[num] ?? 0) + 1
            if misses >= missThreshold {
                windowMisses[num] = nil
                cachedWindows[num] = nil
            } else {
                windowMisses[num] = misses
            }
        }
        // Rebuild order: drop fully-removed, append newly-seen.
        orderedWindowNumbers.removeAll { cachedWindows[$0] == nil }
        let known = Set(orderedWindowNumbers)
        for w in windows where !known.contains(w.windowNumber) {
            orderedWindowNumbers.append(w.windowNumber)
        }
        return orderedWindowNumbers.compactMap { cachedWindows[$0] }
    }

    private func resolveApps(_ pids: [pid_t]) -> [NSRunningApplication] {
        pids.compactMap { pid in
            guard pid != ownPID, let app = NSRunningApplication(processIdentifier: pid) else { return nil }
            switch app.activationPolicy {
            case .regular: return app
            default: return nil
            }
        }
    }
}
