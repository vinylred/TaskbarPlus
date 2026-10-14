import AppKit

/// Builds a Win95 Start-style NSMenu tree of applications from the app folders,
/// with nested subfolders as submenus. Apps launch on click.
final class AppMenuBuilder {

    /// Apps that ship with macOS (Mail, Notes, TextEdit, …) → "Pre-Installed".
    private static let systemRoot = URL(fileURLWithPath: "/System/Applications")
    /// User-installed apps → "Installed". Apple apps that merely appear here as links
    /// into /System (Safari) are moved to Pre-Installed.
    private static let customRoots: [URL] = [
        URL(fileURLWithPath: "/Applications"),
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
    ]
    private static var appRoots: [URL] { [systemRoot] + customRoots }
    /// Each group's "Utilities" subfolders are merged into one Utilities submenu.
    private static let utilitiesName = "Utilities"

    private static let iconSize = NSSize(width: 16, height: 16)
    /// Top-level group items (Pre-Installed / Installed / Dock) get large icons, like
    /// the Windows Start menu.
    private static let groupIconSize = NSSize(width: 32, height: 32)

    private var cachedMenu: NSMenu?
    private var cachedSignature = ""

    /// Cheap signature of the source folders (recursive mod-dates) to detect when a
    /// rebuild is actually needed. Scanning mod-dates is far faster than building the
    /// whole menu with icons.
    private func signature() -> String {
        let fm = FileManager.default
        var parts: [String] = []
        func scan(_ dir: URL, depth: Int) {
            // 3 = deep enough to cover every folder menuItems reads (Utilities is
            // itself one level down, plus `maxFolderDepth` levels under it).
            guard depth <= 3,
                  let entries = try? fm.contentsOfDirectory(
                    at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
                    options: [.skipsHiddenFiles]) else { return }
            if let m = (try? dir.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate {
                parts.append("\(dir.path):\(m.timeIntervalSince1970)")
            }
            for url in entries where url.pathExtension != "app" {
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    scan(url, depth: depth + 1)
                }
            }
        }
        Self.appRoots.forEach { scan($0, depth: 0) }
        // Pinning/unpinning in the Dock changes the "Dock" group.
        parts.append(DockModelService.dockPinnedApps().map { $0.url.path }.joined(separator: ","))
        return parts.joined(separator: "|")
    }

    /// Returns a cached menu, rebuilding only when the source folders changed.
    func menu() -> NSMenu {
        let sig = signature()
        if let cached = cachedMenu, sig == cachedSignature { return cached }
        let m = build()
        cachedMenu = m
        cachedSignature = sig
        return m
    }

    /// Pre-warm the cache shortly after launch so the first click is instant.
    /// NSMenu/icon work must stay on the main thread, so we just defer it to an idle
    /// moment rather than building on a background queue.
    func prewarm() {
        DispatchQueue.main.async { [weak self] in _ = self?.menu() }
    }

    /// Build the full menu: a "Pre-Installed" submenu (apps that ship with macOS), a
    /// "Installed" submenu (everything the user installed) — each with its apps and app
    /// subfolders alphabetically, then its own Utilities submenu — and a "Dock"
    /// submenu of the apps pinned in the real Dock, in Dock order.
    func build() -> NSMenu {
        // Split the custom folders' items: links into /System (Safari) are built-in.
        let customItems = Self.customRoots.map { menuItems(for: $0, skipping: Self.utilitiesName) }
        let linkedSystem = customItems.map { $0.filter(isSystemApp) }
        let custom = customItems.map { $0.filter { !isSystemApp($0) } }

        let menu = NSMenu()
        let groups: [(title: String, icon: NSImage, items: [[NSMenuItem]], utilityRoots: [URL])] = [
            // The Applications folder icon (the "A" folder) — /System/Applications
            // itself doesn't reliably carry it.
            ("Pre-Installed", icon(for: Self.customRoots[0], size: Self.groupIconSize),
             [menuItems(for: Self.systemRoot, skipping: Self.utilitiesName)] + linkedSystem, [Self.systemRoot]),
            // The Installer's package icon.
            ("Installed", icon(for: URL(fileURLWithPath: "/System/Library/CoreServices/Installer.app"),
                               size: Self.groupIconSize),
             custom, Self.customRoots),
        ]
        for group in groups {
            let items = merged(group.items)
            let utilityDirs = group.utilityRoots.map { $0.appendingPathComponent(Self.utilitiesName) }
            let utilities = merged(utilityDirs.map { menuItems(for: $0) })
            guard !items.isEmpty || !utilities.isEmpty else { continue }

            let groupMenu = NSMenu()
            items.forEach { groupMenu.addItem($0) }
            if !utilities.isEmpty {
                if !items.isEmpty { groupMenu.addItem(.separator()) }
                groupMenu.addItem(submenuItem(Self.utilitiesName, utilities,
                                              icon: icon(for: Self.systemRoot.appendingPathComponent(Self.utilitiesName))))
            }
            let groupItem = NSMenuItem(title: group.title, action: nil, keyEquivalent: "")
            groupItem.submenu = groupMenu
            groupItem.image = group.icon
            menu.addItem(groupItem)
        }

        // Dock: the apps pinned in the real Dock, kept in Dock order (not sorted).
        let dockApps = DockModelService.dockPinnedApps().map { appItem(title: $0.label, url: $0.url) }
        if !dockApps.isEmpty {
            let dockIcon = icon(for: URL(fileURLWithPath: "/System/Library/CoreServices/Dock.app"),
                                size: Self.groupIconSize)
            menu.addItem(submenuItem("Dock", dockApps, icon: dockIcon))
        }
        return menu
    }

    /// An app item whose bundle actually lives under /System (e.g. /Applications/Safari.app
    /// is a link into the system's cryptex volume).
    private func isSystemApp(_ item: NSMenuItem) -> Bool {
        guard item.submenu == nil, let url = item.representedObject as? URL else { return false }
        return url.resolvingSymlinksInPath().path.hasPrefix("/System/")
    }

    private func submenuItem(_ title: String, _ items: [NSMenuItem], icon: NSImage) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let sub = NSMenu()
        items.forEach { sub.addItem($0) }
        item.submenu = sub
        item.image = icon
        return item
    }

    /// Merge item lists from several folders: drop same-named duplicates (earlier
    /// folder wins), then subfolders first, then apps, each alphabetical.
    private func merged(_ lists: [[NSMenuItem]]) -> [NSMenuItem] {
        var seen = Set<String>()
        var folders: [NSMenuItem] = []
        var apps: [NSMenuItem] = []
        for item in lists.joined() where seen.insert(item.title.lowercased()).inserted {
            if item.submenu != nil { folders.append(item) } else { apps.append(item) }
        }
        folders.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        apps.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        return folders + apps
    }

    /// Items for a folder: apps as leaves, subfolders as submenus (recursive).
    /// Subfolder levels shown under a root (deeper folders are ignored). Must stay
    /// within what `signature()` scans, or changes there wouldn't refresh the menu.
    private static let maxFolderDepth = 2

    private func menuItems(for folder: URL, skipping skipName: String? = nil, depth: Int = 0) -> [NSMenuItem] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]) else { return [] }

        var apps: [NSMenuItem] = []
        var folders: [NSMenuItem] = []

        for url in entries {
            if url.pathExtension == "app" {
                apps.append(appItem(title: url.deletingPathExtension().lastPathComponent, url: url))
            } else if depth < Self.maxFolderDepth, url.lastPathComponent != skipName,
                      (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                let children = menuItems(for: url, depth: depth + 1)
                guard !children.isEmpty else { continue }
                let sub = NSMenuItem(title: url.lastPathComponent, action: nil, keyEquivalent: "")
                let subMenu = NSMenu()
                children.forEach { subMenu.addItem($0) }
                sub.submenu = subMenu
                sub.image = icon(for: url)
                folders.append(sub)
            }
        }
        // Subfolders first, then apps, each alphabetical (like the real Programs menu).
        folders.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        apps.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        return folders + apps
    }

    /// A leaf item that launches the app at `url`.
    private func appItem(title: String, url: URL) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(launch(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = url
        item.image = icon(for: url)
        return item
    }

    private func icon(for url: URL, size: NSSize = AppMenuBuilder.iconSize) -> NSImage {
        sized(NSWorkspace.shared.icon(forFile: url.path), size)
    }

    private func sized(_ img: NSImage, _ size: NSSize) -> NSImage {
        img.size = size
        return img
    }

    @objc private func launch(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: cfg)
    }
}
