import AppKit

/// One open window on the current Space — the unit of the Win95-style task switcher.
struct WindowInfo {
    let windowNumber: Int
    let pid: pid_t
    let ownerName: String
    /// Window title; empty if Screen Recording permission hasn't been granted.
    let title: String
    let icon: NSImage
    /// Window frame in CoreGraphics global coords (top-left origin), as returned by
    /// CGWindowListCopyWindowInfo. Used to assign the window to a display.
    let frame: CGRect

    /// What the switcher button displays.
    var displayTitle: String {
        title.isEmpty ? ownerName : title
    }

    /// The screen this window predominantly sits on, matched in CG space (so it
    /// works for displays positioned above/left of the primary).
    var screen: NSScreen? {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        return NSScreen.screens.first { Self.cgFrame(of: $0).contains(center) }
            ?? NSScreen.screens.max { a, b in
                Self.cgFrame(of: a).intersection(frame).area < Self.cgFrame(of: b).intersection(frame).area
            }
    }

    /// An NSScreen's frame converted to CG global (top-left origin) coordinates.
    static func cgFrame(of screen: NSScreen) -> CGRect {
        let primaryH = NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height
            ?? NSScreen.screens.first?.frame.height ?? 0
        let f = screen.frame
        return CGRect(x: f.minX, y: primaryH - f.maxY, width: f.width, height: f.height)
    }
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}
