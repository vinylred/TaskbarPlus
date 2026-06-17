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

    /// Called on the main thread with the windows open on the current Space,
    /// in stable left-to-right order (for the task switcher).
    var onWindowsChange: (([WindowInfo]) -> Void)?

    /// Called on the main thread with the current desktop label ("Desktop N") when
    /// it changes.
    var onDesktopChange: ((String) -> Void)?
    private var lastDesktopName = ""

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
        let names: [Notification.Name] = [
            NSWorkspace.activeSpaceDidChangeNotification,
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didHideApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification,
        ]
        for name in names {
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

        let desktop = currentDesktopName()
        if desktop != lastDesktopName {
            lastDesktopName = desktop
            onDesktopChange?(desktop)
        }
    }

    // MARK: - Current-Space detection (private APIs)

    /// All normal windows on the current Space (title, owner, icon), or nil if the
    /// private query path fails (signature drift / empty results).
    private func currentSpaceWindows() -> [WindowInfo]? {
        let currentSpaces = currentSpaceIDs()
        guard !currentSpaces.isEmpty else { return nil }

        // Public enumeration of on-screen windows. `kCGWindowName` (title) requires
        // Screen Recording permission; it comes back absent/empty otherwise.
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
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
                  let w = b["Width"] as? Double, let h = b["Height"] as? Double,
                  w > 1, h > 1 else { continue }
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

        // Keep only windows whose space is current.
        var icons: [pid_t: NSImage] = [:]
        var result: [WindowInfo] = []
        for r in raws {
            let ids = spaceIDs(forWindowNumbers: [r.num])
            guard ids.contains(where: { currentSpaces.contains($0) }) else { continue }
            let icon = icons[r.pid] ?? {
                let img = NSRunningApplication(processIdentifier: r.pid)?.icon
                    ?? NSImage(named: NSImage.applicationIconName)!
                icons[r.pid] = img
                return img
            }()
            result.append(WindowInfo(windowNumber: r.num, pid: r.pid,
                                     ownerName: r.owner, title: r.title, icon: icon, frame: r.frame))
        }
        return result.isEmpty ? nil : result
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

    /// Human label for the current Space, e.g. "Desktop 2" — the 1-based index of
    /// the active space within the primary display's ordered Spaces list. Fullscreen
    /// spaces count too (matching Mission Control's numbering). Falls back to "Desktop".
    func currentDesktopName() -> String {
        guard let raw = CGSCopyManagedDisplaySpaces(cid),
              let displays = (raw as NSArray) as? [[String: Any]],
              // Use the display that has the menu bar (primary) when there are several.
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
