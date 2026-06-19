import AppKit

/// Builds the Dock-replacement model: reads pinned apps + folders from the real
/// Dock's preferences, merges in the running-app state from `SpaceWindowService`,
/// adds a synthetic Trash item, and emits an ordered `[DockItem]` on every change.
///
/// `SpaceWindowService` stays the source of truth for "running on the current
/// Space"; this layer sits above it and adds the persistent Dock structure.
final class DockModelService {

    /// Called on the main thread with the full ordered Dock model.
    var onChange: (([DockItem]) -> Void)?

    /// In split mode the real Dock provides pinned/running/folders/Trash, so this
    /// model emits nothing (the bar shows only the launcher + switcher).
    var splitMode = false { didSet { if splitMode != oldValue { rebuild() } } }

    private static let iconSize = NSSize(width: 40, height: 40)

    // Inputs that feed the merge.
    private var pinned: [ParsedApp] = []        // from persistent-apps (order preserved)
    private var folders: [ParsedFolder] = []    // from persistent-others
    private var currentSpaceApps: [NSRunningApplication] = []

    private var trashSource: DispatchSourceFileSystemObject?
    private var trashFD: Int32 = -1

    private let trashURL = URL(fileURLWithPath: NSString("~/.Trash").expandingTildeInPath)

    // MARK: - Parsed plist rows

    private struct ParsedApp {
        let bundleID: String?
        let url: URL
        let label: String
    }
    private struct ParsedFolder {
        let url: URL
        let label: String
    }

    // MARK: - Lifecycle

    func start() {
        readDockPlist()

        // Re-read the Dock config only when it actually changes. (We deliberately do
        // NOT re-read on every app activation — the pinned/folder config is static,
        // and re-reading the plist + reparsing on each app switch is wasteful for a
        // 24x7 process. Running-state changes flow in via updateRunning instead.)
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(dockPrefsChanged),
            name: NSNotification.Name("com.apple.dock.prefchanged"), object: nil)

        watchTrash()
        rebuild()
    }

    /// Fed by `SpaceWindowService.onChange`.
    func updateRunning(_ apps: [NSRunningApplication]) {
        currentSpaceApps = apps
        rebuild()
    }

    // MARK: - Reading the Dock preferences

    @objc private func dockPrefsChanged() {
        readDockPlist()
        rebuild()
    }

    /// Estimated on-screen width of the REAL macOS Dock's visible icon strip, in
    /// points — used to size the clear center gap in split mode. The Dock exposes no
    /// rect (its window spans the whole screen), so estimate from tilesize × tile
    /// count + the rounded-container end padding. Approximate but close; callers add
    /// a safety margin. Returns 0 if the Dock isn't bottom-oriented or is auto-hidden.
    func dockWidthEstimate() -> CGFloat {
        let d = UserDefaults(suiteName: "com.apple.dock")
        if (d?.string(forKey: "orientation") ?? "bottom") != "bottom" { return 0 }
        if d?.bool(forKey: "autohide") == true { return 0 }
        let tile = CGFloat(d?.integer(forKey: "tilesize") ?? 48)
        let recents = (d?.array(forKey: "recent-apps") as? [[String: Any]])?.count ?? 0
        let showRecents = d?.object(forKey: "show-recents") == nil || d?.bool(forKey: "show-recents") == true
        // Tiles: pinned apps + folders + Trash + recents (if shown). Running apps DO get
        // their own Dock tile, but counting them is unreliable (over-counts helpers and
        // double-counts pinned), and it made the gap balloon → panels too narrow. Use
        // the stable item count plus a modest running-app allowance.
        let runningRegular = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }.count
        let pinnedBundleIDs = Set(pinned.compactMap { $0.bundleID?.lowercased() })
        let runningNotPinned = max(0, runningRegular - pinnedBundleIDs.count)
        let tiles = pinned.count + folders.count + 1 + (showRecents ? recents : 0) + runningNotPinned
        guard tiles > 0 else { return 0 }
        // ~tile per icon + a little inter-icon spacing + end padding.
        return CGFloat(tiles) * (tile + 2) + tile
    }

    private func readDockPlist() {
        CFPreferencesAppSynchronize("com.apple.dock" as CFString)

        var apps = (UserDefaults(suiteName: "com.apple.dock")?
            .array(forKey: "persistent-apps") as? [[String: Any]]) ?? []
        var others = (UserDefaults(suiteName: "com.apple.dock")?
            .array(forKey: "persistent-others") as? [[String: Any]]) ?? []

        // Fallback: read the plist file directly if the suite came back empty.
        if apps.isEmpty && others.isEmpty {
            let url = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Preferences/com.apple.dock.plist")
            if let data = try? Data(contentsOf: url),
               let root = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any] {
                apps = (root["persistent-apps"] as? [[String: Any]]) ?? []
                others = (root["persistent-others"] as? [[String: Any]]) ?? []
            }
        }

        pinned = apps.compactMap { parseApp($0) }
        folders = others.compactMap { parseFolder($0) }
        // Dock config changed → app set may have changed; drop cached icons so they
        // re-resolve once (e.g. an app was replaced/updated).
        iconCache.removeAll()
    }

    private func parseApp(_ entry: [String: Any]) -> ParsedApp? {
        guard let tile = entry["tile-data"] as? [String: Any],
              let url = url(from: tile),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        let bundleID = tile["bundle-identifier"] as? String
        let label = (tile["file-label"] as? String) ?? url.deletingPathExtension().lastPathComponent
        return ParsedApp(bundleID: bundleID, url: url, label: label)
    }

    private func parseFolder(_ entry: [String: Any]) -> ParsedFolder? {
        guard let tile = entry["tile-data"] as? [String: Any],
              let url = url(from: tile),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        let label = (tile["file-label"] as? String) ?? url.lastPathComponent
        return ParsedFolder(url: url, label: label)
    }

    /// Decode the percent-encoded `file://` URL nested under `file-data._CFURLString`.
    private func url(from tile: [String: Any]) -> URL? {
        guard let fileData = tile["file-data"] as? [String: Any],
              let str = fileData["_CFURLString"] as? String else { return nil }
        return URL(string: str)
    }

    // MARK: - Trash watching

    private func watchTrash() {
        // Re-entrant safe: tear down any existing watch first (cancel closes its fd).
        trashSource?.cancel()
        trashSource = nil

        let fd = open(trashURL.path, O_EVTONLY)
        guard fd >= 0 else { return }
        trashFD = fd
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .delete, .rename], queue: .main)
        source.setEventHandler { [weak self] in self?.rebuild() }
        // Capture this source's own fd so a later re-watch can't close the wrong one.
        source.setCancelHandler { close(fd) }
        source.resume()
        trashSource = source
    }

    private var isTrashEmpty: Bool {
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: trashURL.path)) ?? []
        return contents.isEmpty
    }

    // MARK: - Icon resolution

    /// Path-keyed icon cache. rebuild() runs many times per second under activity;
    /// without this it would hit NSWorkspace.icon(forFile:) (disk + IconServices)
    /// for every pinned app/folder every time.
    private var iconCache: [String: NSImage] = [:]

    private func appIcon(for url: URL) -> NSImage {
        if let cached = iconCache[url.path] { return cached }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = Self.iconSize
        iconCache[url.path] = icon
        return icon
    }

    private func trashIcon() -> NSImage {
        let name = isTrashEmpty ? NSImage.trashEmptyName : NSImage.trashFullName
        let img = NSImage(named: name)
            ?? NSImage(systemSymbolName: isTrashEmpty ? "trash" : "trash.fill", accessibilityDescription: "Trash")
            ?? NSImage()
        img.size = Self.iconSize
        return img
    }

    // MARK: - Merge / dedup

    private func rebuild() {
        // Split mode: the real Dock owns pinned/running/folders/Trash → emit nothing.
        if splitMode {
            DispatchQueue.main.async { [weak self] in self?.onChange?([]) }
            return
        }
        // Index *all* running apps (any Space) for the running-anywhere dot decision.
        let everywhere = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
        var byBundle: [String: NSRunningApplication] = [:]
        var byPath: [String: NSRunningApplication] = [:]
        for app in everywhere {
            if let b = app.bundleIdentifier?.lowercased() { byBundle[b] = app }
            if let p = app.bundleURL?.standardizedFileURL.path { byPath[p] = app }
        }

        // Current-Space running set (for the middle section).
        let currentSpaceSet = Set(currentSpaceApps.map { $0.processIdentifier })

        var items: [DockItem] = []
        var consumedPIDs = Set<pid_t>()

        // 1) Pinned section — always shown; dot if running anywhere.
        for app in pinned {
            let running = matchRunning(app, byBundle: byBundle, byPath: byPath)
            if let r = running { consumedPIDs.insert(r.processIdentifier) }
            items.append(DockItem(
                kind: .app(bundleID: app.bundleID, url: app.url),
                label: app.label,
                icon: appIcon(for: app.url),
                isPinned: true,
                runningPID: running?.processIdentifier,
                section: .pinned))
        }

        // 2) Running section — current-Space apps not already shown as pinned.
        for app in currentSpaceApps {
            let pid = app.processIdentifier
            guard !consumedPIDs.contains(pid), currentSpaceSet.contains(pid) else { continue }
            guard let url = app.bundleURL else { continue }
            consumedPIDs.insert(pid)
            items.append(DockItem(
                kind: .app(bundleID: app.bundleIdentifier, url: url),
                label: app.localizedName ?? url.deletingPathExtension().lastPathComponent,
                icon: appIcon(for: url),
                isPinned: false,
                runningPID: pid,
                section: .running))
        }

        // 3) Others section — folders, then Trash.
        for folder in folders {
            items.append(DockItem(
                kind: .folder(url: folder.url),
                label: folder.label,
                icon: appIcon(for: folder.url),
                isPinned: true,
                runningPID: nil,
                section: .others))
        }
        items.append(DockItem(
            kind: .trash,
            label: "Trash",
            icon: trashIcon(),
            isPinned: true,
            runningPID: nil,
            section: .others))

        if ProcessInfo.processInfo.environment["TBP_DEBUG"] != nil {
            let pinned = items.filter { $0.section == .pinned }.map { "\($0.label)\($0.isRunning ? "•" : "")" }
            let running = items.filter { $0.section == .running }.map { $0.label }
            let others = items.filter { $0.section == .others }.map { $0.label }
            NSLog("DockModel pinned=\(pinned) running=\(running) others=\(others)")
        }

        DispatchQueue.main.async { [weak self] in
            self?.onChange?(items)
        }
    }

    private func matchRunning(_ app: ParsedApp,
                              byBundle: [String: NSRunningApplication],
                              byPath: [String: NSRunningApplication]) -> NSRunningApplication? {
        if let b = app.bundleID?.lowercased(), let r = byBundle[b] { return r }
        return byPath[app.url.standardizedFileURL.path]
    }
}
