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

    /// Called on the main thread with the switcher's windows (current Space, or all
    /// Spaces per `spaceMode`), in stable creation order.
    var onWindowsChange: (([WindowInfo]) -> Void)?

    /// Called on the main thread with the per-display desktop labels (keyed by
    /// display UUID) when any of them change.
    var onDesktopChange: (([String: String]) -> Void)?
    private var lastDesktopNames: [String: String] = [:]

    /// Called on the main thread when the set of screens showing fullscreen content
    /// changes (keyed by `NSScreen.key`; those screens' bars should hide).
    var onFullscreenChange: ((Set<String>) -> Void)?
    private var lastFullscreen: Set<String>?

    /// Called on the main thread on EVERY refresh with the freshly scanned windows
    /// (unordered, no hysteresis, not signature-guarded) — for consumers that care
    /// about live frames, e.g. keeping maximised windows clear of the bar.
    var onWindowsPolled: (([WindowInfo]) -> Void)?

    /// Signatures of the last EMITTED app / window payloads, so the 0.5s safety poll
    /// only fires the callbacks (and the downstream Dock-model rebuild + view diff)
    /// when the payload actually changed. Without these, every idle poll rebuilt the
    /// whole DockItem model and re-indexed all running apps for nothing.
    private var lastAppsSignature = ""
    private var lastWindowsSignature = ""

    /// Distinct app count from the last accepted window scan, used to detect the
    /// transient collapse to a single app during App Exposé / Mission Control.
    private var lastAppCount = 0
    /// Consecutive refreshes the single-app collapse has been skipped (so a real
    /// collapse eventually wins after ~6 × 0.5s ≈ 3s).
    private var collapseSkips = 0

    private let cid: CGSConnectionID = CGSMainConnectionID()
    private let ownPID = ProcessInfo.processInfo.processIdentifier

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
        // Fullscreen detection runs first and unconditionally — even when the window
        // scan would early-return — so the bar hides/shows promptly.
        let fullscreen = fullscreenScreens()
        if fullscreen != lastFullscreen {
            lastFullscreen = fullscreen
            onFullscreenChange?(fullscreen)
        }

        let windows = currentSpaceWindows()
        onWindowsPolled?(windows ?? [])

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
        // Only emit when the payload actually changed — the 0.5s poll otherwise drives
        // a full Dock-model rebuild + view diff twice a second at idle. (A Space switch
        // / explicit refreshNow still flows through here; if the content is genuinely
        // identical there's nothing to redraw anyway. The grouped-mode active-desktop
        // indicator is refreshed via onDesktopChange/setGrouped, not this guard.)
        let appsSig = apps.map { "\($0.processIdentifier)" }.joined(separator: ",")
        if appsSig != lastAppsSignature {
            lastAppsSignature = appsSig
            onChange?(apps)
        }
        // Include every display's current desktop so a Space switch (on any display)
        // still re-emits even when the window set is identical (grouped mode moves the
        // active-desktop indicator).
        let desktops = currentDesktopNames()
        let desktopsSig = desktops.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
        let winSig = "\(desktopsSig)|" + orderedWindows.map { "\($0.windowNumber):\($0.displayTitle):\($0.desktopIndex)" }.joined(separator: "|")
        if winSig != lastWindowsSignature {
            lastWindowsSignature = winSig
            onWindowsChange?(orderedWindows)
        }

        if desktops != lastDesktopNames {
            lastDesktopNames = desktops
            onDesktopChange?(desktops)
        }
    }

    // MARK: - Current-Space detection (private APIs)

    /// The switcher's windows (title, owner, icon): the current Space's (plus
    /// minimized ones, which belong to no Space) in currentSpace mode, or every
    /// Space's in all-spaces / grouped mode. Empty when there are genuinely no windows;
    /// nil only if the query itself fails (private-API drift), which triggers the
    /// all-apps fallback.
    private func currentSpaceWindows() -> [WindowInfo]? {
        // Both all-spaces and grouped modes enumerate every Space's windows.
        let allSpaces = (spaceMode == .allSpaces || spaceMode == .grouped)
        let currentSpaces = currentSpaceIDs()
        guard allSpaces || !currentSpaces.isEmpty else { return nil }

        // Enumerate ALL windows (not `.optionOnScreenOnly`), even in currentSpace mode:
        // on-screen-only drops minimized windows and hidden (Cmd-H) apps, which must
        // still get a button. The per-window Space filter below scopes it to the current
        // Space. `kCGWindowName` (title) requires Screen Recording; empty otherwise.
        let opts: CGWindowListOption = [.excludeDesktopElements]
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
            // Off-screen windows (minimized, hidden app, other Space) only count when
            // titled: apps also keep untitled off-screen 500×500 helper windows, which
            // would become ghost buttons when titles are unavailable.
            let onScreen = (info[kCGWindowIsOnscreen as String] as? Bool) ?? false
            if !onScreen && title.isEmpty { continue }
            raws.append(Raw(num: num, pid: pid_t(pid), owner: owner, title: title, frame: frame))
        }

        // When titles are available (Screen Recording granted), drop untitled
        // windows — they're usually palettes/helpers, not real document windows.
        // If NO window has a title (permission not granted), keep them all so the
        // switcher still works off app names.
        if raws.contains(where: { !$0.title.isEmpty }) {
            raws = raws.filter { !$0.title.isEmpty }
        }

        // Collapse helper overlays: some apps (e.g. Teams) report a main window plus a
        // WebView/helper window with the same title sitting INSIDE it. Only drop a
        // same-titled window whose frame lies within one already kept — genuinely
        // separate windows that share a title (two "zsh" Terminals, two Finder windows
        // on one folder) each keep their button. Untitled windows are never merged.
        var kept: [Raw] = []
        for r in raws {
            let isOverlay = !r.title.isEmpty && kept.contains {
                $0.pid == r.pid && $0.title == r.title && $0.frame.insetBy(dx: -2, dy: -2).contains(r.frame)
            }
            if !isOverlay { kept.append(r) }
        }
        raws = kept

        // Desktop index per window (for grouping and the click → switch-to-its-desktop
        // chain), and the current-Space filter in currentSpace mode — both need the
        // window's Space ids.
        let spaceIndex = allSpaces ? spaceIDToDesktopIndex() : [:]

        var icons: [pid_t: NSImage] = [:]
        var result: [WindowInfo] = []
        for r in raws {
            let ids = spaceIDs(forWindowNumbers: [r.num])
            // currentSpace mode: keep windows on a visible Space, plus minimized windows
            // (they belong to no Space; CGS returns none for them).
            if !allSpaces, !ids.isEmpty, !ids.contains(where: { currentSpaces.contains($0) }) { continue }
            let icon = icons[r.pid] ?? {
                let img = NSRunningApplication(processIdentifier: r.pid)?.icon
                    ?? NSImage(named: NSImage.applicationIconName) ?? NSImage()
                icons[r.pid] = img
                return img
            }()
            let desktopIdx = allSpaces ? (ids.compactMap { spaceIndex[$0] }.min() ?? 0) : 0
            result.append(WindowInfo(windowNumber: r.num, pid: r.pid,
                                     ownerName: r.owner, title: r.title, icon: icon,
                                     frame: r.frame, desktopIndex: desktopIdx))
        }
        return result
    }

    /// Whether a window lives on a Space other than a currently-visible one.
    /// (macOS 26 blocks programmatic Space switching, so a cross-Space click posts the
    /// Ctrl+N shortcut first — see DesktopSwitcher — this tells the panel which path.)
    func isWindowOnOtherSpace(_ windowNumber: Int) -> Bool {
        let target = spaceIDs(forWindowNumbers: [windowNumber])
        guard !target.isEmpty else { return false }
        let current = currentSpaceIDs()
        return !target.contains(where: { current.contains($0) })
    }

    /// Desktop numbering as macOS shows it (Mission Control labels, Ctrl+N shortcuts):
    /// only real desktops count (`type` 0 — fullscreen-app Spaces are skipped), numbered
    /// 1…N continuously across displays in CGSCopyManagedDisplaySpaces order (a second
    /// display's first desktop follows the main display's last). Space id → number.
    private func desktopNumbers(_ displays: [[String: Any]]) -> [UInt64: Int] {
        var map: [UInt64: Int] = [:]
        for display in displays {
            for s in (display["Spaces"] as? [[String: Any]]) ?? [] {
                guard (s["type"] as? Int ?? 0) == 0, let id = spaceID(from: s) else { continue }
                map[id] = map.count + 1
            }
        }
        return map
    }

    private func managedDisplays() -> [[String: Any]] {
        guard let raw = CGSCopyManagedDisplaySpaces(cid),
              let displays = (raw as NSArray) as? [[String: Any]] else { return [] }
        return displays
    }

    /// Map each Space id → its 1-based desktop number (see `desktopNumbers`).
    private func spaceIDToDesktopIndex() -> [UInt64: Int] {
        desktopNumbers(managedDisplays())
    }

    /// Desktop number of the current Space on the screen at `origin` (each display
    /// has its own current Space), or 0 (fullscreen-app Space / unknown screen).
    func currentDesktopIndex(onScreenAt origin: CGPoint) -> Int {
        let displays = managedDisplays()
        guard let screen = NSScreen.screens.first(where: { $0.frame.origin == origin }),
              let current = display(for: screen, in: displays)?["Current Space"] as? [String: Any],
              let id = spaceID(from: current) else { return 0 }
        return desktopNumbers(displays)[id] ?? 0
    }

    /// Screens (by `NSScreen.key`) currently showing fullscreen content — their bars
    /// hide; bars on other screens stay. Two signals:
    /// 1) The display's current Space is a fullscreen-app Space (`type` ≠ 0, or a
    ///    tiled fullscreen pair) — native green-button fullscreen, fullscreen video.
    /// 2) A slideshow-style app window that is exactly the screen's frame without a
    ///    fullscreen Space (PowerPoint/Keynote presenting). Only checked on screens
    ///    that reserve a menu bar or Dock: where `visibleFrame == frame`, a zoomed
    ///    window is screen-sized too and must not count.
    func fullscreenScreens() -> Set<String> {
        var result = Set<String>()
        let displays = managedDisplays()
        for display in displays {
            guard let current = display["Current Space"] as? [String: Any] else { continue }
            let type = current["type"] as? Int ?? 0
            if type != 0 || current["TileLayoutManager"] != nil {
                screens(for: display, displayCount: displays.count).forEach { result.insert($0.key) }
            }
        }
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let infoList = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]]
        else { return result }
        let candidates = NSScreen.screens.filter { $0.visibleFrame != $0.frame }
            .map { ($0.key, WindowInfo.cgFrame(of: $0)) }
        for info in infoList {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let b = info[kCGWindowBounds as String] as? [String: Any],
                  let x = b["X"] as? Double, let y = b["Y"] as? Double,
                  let w = b["Width"] as? Double, let h = b["Height"] as? Double else { continue }
            for (key, f) in candidates where abs(f.minX - x) < 4 && abs(f.minY - y) < 4
                && abs(f.width - w) < 4 && abs(f.height - h) < 4 {
                result.insert(key)
            }
        }
        return result
    }

    /// The NSScreens a CGS display entry covers. With "Displays have separate Spaces"
    /// off there's a single shared entry for every screen; otherwise the entry's
    /// identifier is the display UUID, or the literal "Main" for the primary display.
    private func screens(for display: [String: Any], displayCount: Int) -> [NSScreen] {
        if displayCount == 1 { return NSScreen.screens }
        let id = display["Display Identifier"] as? String
        return NSScreen.screens.filter {
            (id == "Main" && $0.frame.origin == .zero) || (id != nil && $0.displayUUID == id)
        }
    }

    /// The CGS display entry for a screen (see `screens(for:displayCount:)`).
    private func display(for screen: NSScreen, in displays: [[String: Any]]) -> [String: Any]? {
        displays.first { screens(for: $0, displayCount: displays.count).contains(screen) }
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

    /// Current-Space label ("Desk N") for EACH display, keyed by its display UUID
    /// string — each monitor has its own current Space (numbered per `desktopNumbers`).
    func currentDesktopNames() -> [String: String] {
        let displays = managedDisplays()
        let numbers = desktopNumbers(displays)
        var result: [String: String] = [:]
        for display in displays {
            guard let uuid = display["Display Identifier"] as? String,
                  let current = display["Current Space"] as? [String: Any],
                  let currentID = spaceID(from: current) else { continue }
            result[uuid] = numbers[currentID].map { "Desk \($0)" } ?? "Desk"
        }
        return result
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
    /// Apps in launch order (oldest first) — stable no matter which Space is shown or
    /// which app is frontmost, so icons never shuffle.
    private func orderStable(_ pids: [pid_t]) -> [pid_t] {
        func launched(_ pid: pid_t) -> Date {
            NSRunningApplication(processIdentifier: pid)?.launchDate ?? .distantFuture
        }
        return pids.sorted { (launched($0), $0) < (launched($1), $1) }
    }

    /// Windows in creation order (window ids only ever increase), with hysteresis so
    /// a single transient blip (a window flickering in/out of the Space for one
    /// refresh) doesn't add/remove a switcher button. New windows appear immediately
    /// at the end; a window is only dropped after it's been absent for
    /// `missThreshold` refreshes. Ordering by id — not by when we first saw it, nor
    /// by CGWindowList's front-to-back order — keeps the sequence fixed across Space
    /// switches, minimize/hide, and focus changes.
    private func orderStableWindows(_ windows: [WindowInfo], immediate: Bool = false) -> [WindowInfo] {
        // immediate → drop absent windows at once (no grace) for an authoritative update.
        let missThreshold = immediate ? 1 : 2
        let present = Set(windows.map { $0.windowNumber })

        // Refresh cached info for present windows; reset their miss count.
        for w in windows {
            cachedWindows[w.windowNumber] = w
            windowMisses[w.windowNumber] = 0
        }
        // Count misses for known windows that are absent now; drop once over threshold.
        for num in Array(cachedWindows.keys) where !present.contains(num) {
            let misses = (windowMisses[num] ?? 0) + 1
            if misses >= missThreshold {
                windowMisses[num] = nil
                cachedWindows[num] = nil
            } else {
                windowMisses[num] = misses
            }
        }
        return cachedWindows.values.sorted { $0.windowNumber < $1.windowNumber }
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

extension NSScreen {
    /// Stable key for a screen (its frame origin) — used to match bars to screens.
    var key: String { "\(frame.origin.x),\(frame.origin.y)" }

    /// The CGS display-UUID string, matching CGSCopyManagedDisplaySpaces identifiers.
    var displayUUID: String? {
        guard let num = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let cfUUID = CGDisplayCreateUUIDFromDisplayID(CGDirectDisplayID(num.uint32Value))?.takeRetainedValue()
        else { return nil }
        return CFUUIDCreateString(nil, cfUUID) as String
    }
}
