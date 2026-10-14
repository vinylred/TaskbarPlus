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

    /// Called on the main thread with each screen's desktop label (keyed by
    /// `NSScreen.key`) when any of them change.
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
    /// Off-screen windows on no Space are either minimized (real — keep) or closed
    /// windows an app keeps alive off-screen (e.g. Notes' main window — skip). AX
    /// tells them apart; the verdict is cached per window while it stays off-screen.
    private var liveOffscreen: [Int: Bool] = [:]
    /// Spaces layout, re-snapshotted at the start of every refresh (one CGS call).
    private(set) var layout = SpaceLayout(raw: [], screens: [])

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
        layout = snapshotLayout()
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
            NSLog("TaskbarPlus[\(mode)] spaces=\(layout.currentSpaceIDs.sorted()) fullscreen=\(fullscreen.sorted()) displays=\(layout.displays.map { "\($0.identifier ?? "?")→\($0.screenKeys) cur=\($0.currentSpace ?? 0) fs=\($0.showsFullscreen) spaces=\($0.spaces.map { "\($0.id)\($0.isDesktop ? "" : "F")" })" }) apps=\(apps.map { $0.localizedName ?? "?" }) windows=\(orderedWindows.count)")
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
        // Each screen's label ("Desk N"), keyed by NSScreen.key.
        let desktops = Dictionary(NSScreen.screens.map { ($0.key, layout.label(onScreen: $0.key)) },
                                  uniquingKeysWith: { a, _ in a })
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
        let currentSpaces = layout.currentSpaceIDs
        let fullscreenSpaces = layout.fullscreenSpaceIDs
        guard allSpaces || !currentSpaces.isEmpty else { return nil }

        // Enumerate ALL windows (not `.optionOnScreenOnly`), even in currentSpace mode:
        // on-screen-only drops minimized windows and hidden (Cmd-H) apps, which must
        // still get a button. The per-window Space filter below scopes it to the current
        // Space. `kCGWindowName` (title) requires Screen Recording; empty otherwise.
        let opts: CGWindowListOption = [.excludeDesktopElements]
        guard let infoList = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]],
              !infoList.isEmpty else { return nil }

        struct Raw { let num: Int; let pid: pid_t; let owner: String; let title: String; let frame: CGRect; let onScreen: Bool }
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
            raws.append(Raw(num: num, pid: pid_t(pid), owner: owner, title: title, frame: frame, onScreen: onScreen))
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

        var icons: [pid_t: NSImage] = [:]
        var result: [WindowInfo] = []
        // Forget cached verdicts for windows that came back on screen or are gone.
        let offscreenNow = Set(raws.filter { !$0.onScreen }.map { $0.num })
        liveOffscreen = liveOffscreen.filter { offscreenNow.contains($0.key) }
        for r in raws {
            let ids = spaceIDs(forWindowNumbers: [r.num])
            // On no Space: minimized (keep) or closed-but-retained (skip) — ask AX once.
            let noSpace = ids.isEmpty
            if noSpace && !r.onScreen {
                let live = liveOffscreen[r.num] ?? WindowControl.isOpen(windowNumber: r.num, pid: r.pid)
                liveOffscreen[r.num] = live
                if !live { continue }
            }
            // currentSpace mode: keep windows on a visible Space, minimized ones, and
            // fullscreen apps — each sits on its own Space, so it would otherwise drop off
            // the bar (unreachable but via Mission Control) as soon as you leave it.
            if !allSpaces, !noSpace, !ids.contains(where: { currentSpaces.contains($0) }),
               !ids.contains(where: { fullscreenSpaces.contains($0) }) { continue }
            let icon = icons[r.pid] ?? {
                let img = NSRunningApplication(processIdentifier: r.pid)?.icon
                    ?? NSImage(named: NSImage.applicationIconName) ?? NSImage()
                icons[r.pid] = img
                return img
            }()
            var info = WindowInfo(windowNumber: r.num, pid: r.pid,
                                  ownerName: r.owner, title: r.title, icon: icon,
                                  frame: r.frame, desktopIndex: 0)
            if allSpaces {
                // Minimized windows (no Space) belong with the desktop they'll restore
                // onto — the current one of their screen — not the "other" box.
                info.desktopIndex = noSpace
                    ? info.screen.map { currentDesktopIndex(onScreenAt: $0.frame.origin) } ?? 0
                    : layout.desktop(forSpaces: ids)
            }
            result.append(info)
        }
        return result
    }

    /// Whether a window lives on a Space other than a currently-visible one.
    /// (macOS 26 blocks programmatic Space switching, so a cross-Space click posts the
    /// Ctrl+N shortcut first — see DesktopSwitcher — this tells the panel which path.)
    func isWindowOnOtherSpace(_ windowNumber: Int) -> Bool {
        let target = spaceIDs(forWindowNumbers: [windowNumber])
        guard !target.isEmpty else { return false }
        let current = snapshotLayout().currentSpaceIDs   // fresh: called on click
        return !target.contains(where: { current.contains($0) })
    }

    /// One CGSCopyManagedDisplaySpaces call mapped onto the current screens.
    private func snapshotLayout() -> SpaceLayout {
        let raw = CGSCopyManagedDisplaySpaces(cid).flatMap { ($0 as NSArray) as? [[String: Any]] } ?? []
        let screens = NSScreen.screens.map {
            SpaceLayout.Screen(key: $0.key, uuid: $0.displayUUID, isPrimary: $0.frame.origin == .zero)
        }
        return SpaceLayout(raw: raw, screens: screens)
    }

    /// Desktop number of the current Space on the screen at `origin` (each display
    /// has its own current Space), or 0 (fullscreen-app Space / unknown screen).
    func currentDesktopIndex(onScreenAt origin: CGPoint) -> Int {
        layout.currentDesktop(onScreen: "\(origin.x),\(origin.y)")
    }

    /// Screens (by `NSScreen.key`) currently showing fullscreen content — their bars
    /// hide; bars on other screens stay. Two signals:
    /// 1) The display's current Space is a fullscreen-app Space (`SpaceLayout`) —
    ///    native green-button fullscreen, split view, fullscreen video.
    /// 2) A slideshow-style app window that is exactly the screen's frame without a
    ///    fullscreen Space (PowerPoint/Keynote presenting). Only checked on screens
    ///    that reserve a menu bar or Dock: where `visibleFrame == frame`, a zoomed
    ///    window is screen-sized too and must not count.
    private func fullscreenScreens() -> Set<String> {
        var result = layout.fullscreenScreenKeys
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
