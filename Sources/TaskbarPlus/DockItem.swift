import AppKit

/// Which section of the Dock an item belongs to.
enum DockSection {
    case pinned   // persistent launchers (left)
    case running  // running-only apps not pinned (middle)
    case others   // folder stacks + Trash (right)
}

/// The kind of thing an icon represents.
enum DockItemKind {
    case app(bundleID: String?, url: URL)
    case folder(url: URL)
    case trash
}

/// A single icon in the Dock-replacement bar. Value type, rebuilt each refresh.
struct DockItem {
    let kind: DockItemKind
    var label: String
    var icon: NSImage
    var isPinned: Bool
    /// Set when the app is running (anywhere). Drives the running-dot indicator.
    var runningPID: pid_t?
    var section: DockSection

    var isRunning: Bool { runningPID != nil }
}
