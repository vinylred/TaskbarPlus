import AppKit

/// Builds a Win95 Start-style NSMenu tree of applications from the app folders,
/// with nested subfolders as submenus. Apps launch on click.
final class AppMenuBuilder {

    /// Source folders, in order. (/Applications first, then Utilities.)
    private static let roots: [URL] = [
        URL(fileURLWithPath: "/Applications"),
        URL(fileURLWithPath: "/System/Applications/Utilities"),
    ]

    private static let iconSize = NSSize(width: 16, height: 16)

    private var cachedMenu: NSMenu?
    private var cachedSignature = ""

    /// Cheap signature of the source folders (recursive mod-dates) to detect when a
    /// rebuild is actually needed. Scanning mod-dates is far faster than building the
    /// whole menu with icons.
    private func signature() -> String {
        let fm = FileManager.default
        var parts: [String] = []
        func scan(_ dir: URL, depth: Int) {
            guard depth <= 2,
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
        Self.roots.forEach { scan($0, depth: 0) }
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

    /// Build the full menu. Each leaf is an app; each subfolder is a submenu.
    func build() -> NSMenu {
        let menu = NSMenu()
        for (i, root) in Self.roots.enumerated() {
            let items = menuItems(for: root)
            guard !items.isEmpty else { continue }
            if i > 0 { menu.addItem(.separator()) }
            // Utilities gets grouped under its own submenu; /Applications is flat.
            if root.lastPathComponent == "Utilities" {
                let sub = NSMenuItem(title: "Utilities", action: nil, keyEquivalent: "")
                let subMenu = NSMenu()
                items.forEach { subMenu.addItem($0) }
                sub.submenu = subMenu
                sub.image = icon(for: root)
                menu.addItem(sub)
            } else {
                items.forEach { menu.addItem($0) }
            }
        }
        return menu
    }

    /// Items for a folder: apps as leaves, subfolders as submenus (recursive).
    private func menuItems(for folder: URL) -> [NSMenuItem] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]) else { return [] }

        var apps: [NSMenuItem] = []
        var folders: [NSMenuItem] = []

        for url in entries {
            if url.pathExtension == "app" {
                let item = NSMenuItem(title: url.deletingPathExtension().lastPathComponent,
                                      action: #selector(launch(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = url
                item.image = icon(for: url)
                apps.append(item)
            } else if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                let children = menuItems(for: url)
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

    private func icon(for url: URL) -> NSImage {
        let img = NSWorkspace.shared.icon(forFile: url.path)
        img.size = Self.iconSize
        return img
    }

    @objc private func launch(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: cfg)
    }
}
