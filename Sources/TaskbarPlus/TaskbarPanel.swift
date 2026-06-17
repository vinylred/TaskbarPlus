import AppKit
import CSkyLight

/// A borderless, non-activating panel that floats a Dock-style row of icons along
/// the bottom edge of the main screen and stays visible on every Space.
///
/// Layout mirrors the real Dock: [pinned] | [running-only] | [folders + Trash],
/// with separators only between non-empty sections and a running-dot under each
/// running app. Each icon hosts a right-click context menu.
final class TaskbarPanel: NSPanel {

    static let iconSize: CGFloat = 40
    private static let barHeight: CGFloat = 60
    private static let horizontalPadding: CGFloat = 14

    private let config: LayoutConfig

    // Three horizontal zones the sections are distributed into.
    private let leftZone = NSStackView()
    private let centerZone = NSStackView()
    private let rightZone = NSStackView()

    // Per-section content containers (filled by update*, then placed into a zone).
    private let launcherStack = NSStackView()
    private let launcherButton = LauncherButton()
    private let pinnedStack = NSStackView()
    private let runningStack = NSStackView()
    private let othersStack = NSStackView()

    /// Win95-style task switcher: one button per window, across two rows.
    private let switcherStack = NSStackView()
    private let switcherRow1 = NSStackView()
    private let switcherRow2 = NSStackView()

    /// The screen this bar lives on. Resolved fresh by frame on each reposition so
    /// it survives display reconfiguration.
    private let targetFrameOrigin: CGPoint

    init(screen: NSScreen, config: LayoutConfig) {
        self.targetFrameOrigin = screen.frame.origin
        self.config = config
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        worksWhenModal = false
        // ARC owns the panel (we keep it in a dictionary). Without this, AppKit would
        // release it on close and ARC would over-release; with it, dropping our
        // reference + orderOut lets it deallocate cleanly on reconfig.
        isReleasedWhenClosed = false
        // Theme: nil = follow the OS (auto); else force light/dark. This drives the
        // visual-effect view, label colors, and the Win95 buttons' effectiveAppearance.
        appearance = config.theme.appearance

        let blur = NSVisualEffectView()
        // `.sidebar` adapts cleanly to both light and dark (the old `.hudWindow` was
        // always dark regardless of appearance).
        blur.material = .sidebar
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.translatesAutoresizingMaskIntoConstraints = false
        contentView = blur

        for s in [launcherStack, pinnedStack, runningStack, othersStack] {
            s.orientation = .horizontal
            s.alignment = .centerY
            s.spacing = 8
        }
        launcherStack.addArrangedSubview(launcherButton)

        // Switcher: vertical stack of two horizontal rows.
        for row in [switcherRow1, switcherRow2] {
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 4
        }
        switcherStack.orientation = .vertical
        switcherStack.alignment = .trailing
        switcherStack.spacing = 4
        switcherStack.addArrangedSubview(switcherRow1)
        switcherStack.addArrangedSubview(switcherRow2)

        // Three zones across the bar: left edge, center, right edge.
        for z in [leftZone, centerZone, rightZone] {
            z.orientation = .horizontal
            z.alignment = .centerY
            z.spacing = 10
            z.translatesAutoresizingMaskIntoConstraints = false
            blur.addSubview(z)
            z.centerYAnchor.constraint(equalTo: blur.centerYAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            leftZone.leadingAnchor.constraint(equalTo: blur.leadingAnchor, constant: Self.horizontalPadding),
            centerZone.centerXAnchor.constraint(equalTo: blur.centerXAnchor),
            rightZone.trailingAnchor.constraint(equalTo: blur.trailingAnchor, constant: -Self.horizontalPadding),
            // Hard no-overlap guards: zones must keep clear of their neighbours so a
            // crowded zone can never render on top of another.
            centerZone.leadingAnchor.constraint(greaterThanOrEqualTo: leftZone.trailingAnchor, constant: 16),
            rightZone.leadingAnchor.constraint(greaterThanOrEqualTo: centerZone.trailingAnchor, constant: 16),
        ])

        reposition()
        NotificationCenter.default.addObserver(
            self, selector: #selector(reposition),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)

        orderFront(nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // Never become key/main, so clicking an icon doesn't deactivate the user's frontmost app.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    @objc private func reposition() {
        // Re-resolve our screen by its frame origin (survives reconfiguration);
        // fall back to primary if it's gone.
        let screen = NSScreen.screens.first(where: { $0.frame.origin == targetFrameOrigin })
            ?? NSScreen.screens.first(where: { $0.frame.origin == .zero })
            ?? NSScreen.screens.first
        guard let screen else { return }
        let vf = screen.visibleFrame
        let frame = NSRect(x: vf.minX, y: vf.minY, width: vf.width, height: Self.barHeight)
        setFrame(frame, display: true)
    }

    // MARK: - Update

    private var lastWindows: [WindowInfo] = []
    private var dockSignature = ""

    /// Update the desktop-name label under the Apps button.
    func updateDesktop(_ name: String) {
        launcherButton.setDesktop(name)
    }

    func update(items: [DockItem]) {
        // Skip the (relatively expensive) view rebuild when nothing changed — this
        // is called many times per second under activity. Signature covers identity,
        // label, section, and running-dot state.
        let signature = items.map {
            let id: String
            switch $0.kind {
            case .app(_, let url): id = url.path
            case .folder(let url): id = url.path
            case .trash: id = "trash"
            }
            return "\($0.section):\(id):\($0.label):\($0.isRunning)"
        }.joined(separator: "|")
        guard signature != dockSignature else { return }
        dockSignature = signature

        for stack in [pinnedStack, runningStack, othersStack] {
            for v in stack.arrangedSubviews { stack.removeView(v) }
        }
        for item in items {
            let view = DockIconView(item: item, panel: self)
            switch item.section {
            case .pinned:  pinnedStack.addArrangedSubview(view)
            case .running: runningStack.addArrangedSubview(view)
            case .others:  othersStack.addArrangedSubview(view)
            }
        }
        reassembleZones()
        // If the Dock's icon count changed, its width changed, so the switcher's
        // capacity must be recomputed. Otherwise leave the switcher untouched.
        let count = dockStacks().reduce(0) { $0 + $1.arrangedSubviews.count }
        if count != lastDockCount {
            lastDockCount = count
            rebuildSwitcher(lastWindows, force: true)
        }
    }

    private var lastDockCount = -1

    /// The content container view for each logical section.
    private func container(for section: Section) -> NSView {
        switch section {
        case .launcher: return launcherStack
        case .pinned:   return pinnedStack
        case .running:  return runningStack
        case .others:   return othersStack
        case .switcher: return switcherStack
        }
    }

    private func isEmpty(_ section: Section) -> Bool {
        switch section {
        case .launcher:
            return false   // the Start button is always present
        case .pinned, .running, .others:
            return (container(for: section) as! NSStackView).arrangedSubviews.isEmpty
        case .switcher:
            return switcherRow1.arrangedSubviews.isEmpty && switcherRow2.arrangedSubviews.isEmpty
        }
    }

    /// Place each non-empty section into its configured zone, in a fixed section
    /// order, with separators between adjacent sections inside a zone.
    private func reassembleZones() {
        for zone in [leftZone, centerZone, rightZone] {
            for v in zone.arrangedSubviews { zone.removeView(v) }
        }
        // Stable section order within any zone.
        let order: [Section] = [.launcher, .pinned, .running, .others, .switcher]
        for zoneKind in [Zone.left, .center, .right] {
            let stack = zoneStack(zoneKind)
            let members = order.filter { config.zone(for: $0) == zoneKind && !isEmpty($0) }
            for (i, section) in members.enumerated() {
                if i > 0 { stack.addArrangedSubview(makeSeparator()) }
                stack.addArrangedSubview(container(for: section))
            }
        }
        applySwitcherExpand()
    }

    private var switcherExpandConstraints: [NSLayoutConstraint] = []

    /// If the switcher is configured to expand, pull it OUT of its zone stack and
    /// pin its edges directly to the blur so it spans exactly the gap toward the
    /// expand edge — its buttons then stretch (.fillEqually) to fill it. No feedback
    /// loop, no overshoot. If not expanding, it stays a normal zone member.
    private func applySwitcherExpand() {
        NSLayoutConstraint.deactivate(switcherExpandConstraints)
        switcherExpandConstraints = []

        let expand = config.expand(for: .switcher)
        let align = config.align(for: .switcher)

        switcherRow1.distribution = .fill
        switcherRow2.distribution = .fill
        // Vertical stack's horizontal alignment positions the button rows within the
        // switcher's area, per `align`.
        switch align {
        case .left:   switcherStack.alignment = .leading
        case .center: switcherStack.alignment = .centerX
        case .right:  switcherStack.alignment = .trailing
        }

        // Pin the switcher to its available AREA (the gap between the flanking Dock
        // zones) whenever expand is set OR a non-default align is requested — both
        // need room wider than the buttons to act within. Otherwise it stays a
        // normal content-sized zone member.
        let needsArea = (expand != nil || align != .left) && !isEmpty(.switcher)
        guard needsArea, let blur = contentView else { return }

        (switcherStack.superview as? NSStackView)?.removeView(switcherStack)
        if switcherStack.superview == nil { blur.addSubview(switcherStack) }
        switcherStack.translatesAutoresizingMaskIntoConstraints = false

        let pad = Self.horizontalPadding
        let gap: CGFloat = 16
        let leftEdge = pad + dockZoneWidth(.left) + (dockZoneWidth(.left) > 0 ? gap : 0)
        let rightEdge = pad + dockZoneWidth(.right) + (dockZoneWidth(.right) > 0 ? gap : 0)

        // The area spans from the left flank's right edge to the right flank's left
        // edge. expand:left/right would bias the area, but since we now always span
        // the full gap and use `align` to position content, both behave the same.
        let cons: [NSLayoutConstraint] = [
            switcherStack.centerYAnchor.constraint(equalTo: blur.centerYAnchor),
            switcherStack.leadingAnchor.constraint(equalTo: blur.leadingAnchor, constant: leftEdge),
            switcherStack.trailingAnchor.constraint(equalTo: blur.trailingAnchor, constant: -rightEdge),
        ]
        NSLayoutConstraint.activate(cons)
        switcherExpandConstraints = cons
    }

    /// Estimated rendered width of the Dock sections in a given zone.
    private func dockZoneWidth(_ zone: Zone) -> CGFloat {
        let secs: [Section] = [.pinned, .running, .others].filter {
            config.zone(for: $0) == zone && !isEmpty($0)
        }
        guard !secs.isEmpty else { return 0 }
        let icons = secs.reduce(0) { $0 + ((container(for: $1) as? NSStackView)?.arrangedSubviews.count ?? 0) }
        return CGFloat(icons) * (Self.iconSize + 8) + CGFloat(secs.count - 1) * 20
    }

    private func zoneStack(_ zone: Zone) -> NSStackView {
        switch zone {
        case .left:   return leftZone
        case .center: return centerZone
        case .right:  return rightZone
        }
    }

    private var switcherSignature = ""

    /// Entry point from the window service.
    func updateWindows(_ windows: [WindowInfo]) {
        lastWindows = windows
        rebuildSwitcher(windows, force: false)
    }

    /// Rebuild the Win95-style task-switcher strip. Skips work when the window set
    /// is unchanged (unless `force`, e.g. the Dock width changed so capacity must
    /// be recomputed).
    private func rebuildSwitcher(_ windows: [WindowInfo], force: Bool) {
        let signature = windows.map { "\($0.windowNumber):\($0.displayTitle)" }.joined(separator: "|")
        if !force, signature == switcherSignature { return }
        switcherSignature = signature

        for v in switcherRow1.arrangedSubviews { switcherRow1.removeView(v) }
        for v in switcherRow2.arrangedSubviews { switcherRow2.removeView(v) }

        let avail = switcherAvailableWidth()
        let spacing = switcherRow1.spacing

        // How many buttons fit in one row at the minimum width — that's the most a
        // single row can hold; two rows hold double. Fit ALL windows by shrinking
        // buttons; only drop windows if even min-width can't hold them across 2 rows.
        let maxPerRow = max(1, Int((avail + spacing) / (WindowButton.minWidth + spacing)))
        let capacity = maxPerRow * 2
        let shown = Array(windows.prefix(capacity))

        // Buttons per row to balance the two rows, then the width that exactly fills
        // the available row width (clamped to [min, preferred]).
        let perRow = max(1, Int(ceil(Double(shown.count) / 2.0)))
        let rawWidth = (avail - CGFloat(perRow - 1) * spacing) / CGFloat(perRow)
        let buttonWidth = max(WindowButton.minWidth, min(WindowButton.preferredWidth, rawWidth))

        let topCount = min(perRow, shown.count)
        for (i, w) in shown.enumerated() {
            let row = i < topCount ? switcherRow1 : switcherRow2
            row.addArrangedSubview(WindowButton(info: w, panel: self, width: buttonWidth))
        }
        switcherRow2.isHidden = switcherRow2.arrangedSubviews.isEmpty
        reassembleZones()

        if ProcessInfo.processInfo.environment["TBP_DEBUG"] != nil {
            NSLog("switcher: panelW=\(frame.width) perRow=\(perRow) width=\(Int(buttonWidth)) shown=\(shown.count)/\(windows.count)")
        }
    }

    /// Width available to ONE switcher row, given the switcher's zone and the space
    /// the Dock sections consume. Buttons are sized to fill this so the strip never
    /// overflows the screen, wherever the switcher is placed.
    private func switcherAvailableWidth() -> CGFloat {
        let screenW = frame.width > 0 ? frame.width : (NSScreen.screens.first?.frame.width ?? 1512)
        let pad = Self.horizontalPadding
        let gap: CGFloat = 16

        // Estimated width of the Dock sections (pinned/running/others) per zone, from
        // icon COUNT (timing-independent, unlike fittingSize before first layout).
        func dockWidth(in zone: Zone) -> CGFloat {
            let secs: [Section] = [.pinned, .running, .others].filter {
                config.zone(for: $0) == zone && !isEmpty($0)
            }
            guard !secs.isEmpty else { return 0 }
            let icons = secs.reduce(0) { sum, s in
                sum + ((container(for: s) as? NSStackView)?.arrangedSubviews.count ?? 0)
            }
            return CGFloat(icons) * (Self.iconSize + 8) + CGFloat(secs.count - 1) * 20
        }

        switch config.zone(for: .switcher) {
        case .center:
            let halfClear = screenW / 2 - max(dockWidth(in: .left), dockWidth(in: .right)) - gap - pad
            return max(WindowButton.minWidth, halfClear * 2)
        case .left:
            return max(WindowButton.minWidth, screenW - dockWidth(in: .center) - dockWidth(in: .right) - 2 * pad - 2 * gap)
        case .right:
            return max(WindowButton.minWidth, screenW - dockWidth(in: .center) - dockWidth(in: .left) - 2 * pad - 2 * gap)
        }
    }

    private func dockStacks() -> [NSStackView] { [pinnedStack, runningStack, othersStack] }

    /// Raise a specific window (task-switcher click).
    func raiseWindow(_ info: WindowInfo) {
        WindowControl.raise(windowNumber: info.windowNumber, pid: info.pid)
    }

    private func makeSeparator() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            box.widthAnchor.constraint(equalToConstant: 1),
            box.heightAnchor.constraint(equalToConstant: 30),
        ])
        return box
    }

    // MARK: - Left-click

    func activate(_ item: DockItem) {
        switch item.kind {
        case .app(_, let url):
            if let pid = item.runningPID, let app = NSRunningApplication(processIdentifier: pid) {
                app.activate()
            } else {
                let cfg = NSWorkspace.OpenConfiguration()
                cfg.activates = true
                NSWorkspace.shared.openApplication(at: url, configuration: cfg)
            }
        case .folder(let url):
            NSWorkspace.shared.open(url)
        case .trash:
            NSWorkspace.shared.open(URL(fileURLWithPath: NSString("~/.Trash").expandingTildeInPath))
        }
    }

    /// Trigger App Exposé for a running app's item.
    func expose(_ item: DockItem) {
        guard let pid = item.runningPID,
              let app = NSRunningApplication(processIdentifier: pid) else { return }
        app.unhide()
        app.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            CoreDockSendNotification("com.apple.expose.front.awake" as CFString, 0)
        }
    }

    // MARK: - Context menu

    func makeMenu(for item: DockItem) -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, _ selector: Selector) {
            let mi = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            mi.target = self
            mi.representedObject = item
            menu.addItem(mi)
        }

        switch item.kind {
        case .app:
            if item.isRunning {
                add("Show All Windows", #selector(menuShowAll(_:)))
                add("Hide", #selector(menuHide(_:)))
                menu.addItem(.separator())
                add("Show in Finder", #selector(menuShowInFinder(_:)))
                menu.addItem(.separator())
                add("Quit", #selector(menuQuit(_:)))
            } else {
                add("Open", #selector(menuOpen(_:)))
                add("Show in Finder", #selector(menuShowInFinder(_:)))
            }
        case .folder:
            add("Open", #selector(menuOpen(_:)))
            add("Open in Finder", #selector(menuShowInFinder(_:)))
        case .trash:
            add("Open", #selector(menuOpen(_:)))
            add("Empty Trash", #selector(menuEmptyTrash(_:)))
        }
        return menu
    }

    private func item(from sender: NSMenuItem) -> DockItem? {
        sender.representedObject as? DockItem
    }

    @objc private func menuOpen(_ sender: NSMenuItem) {
        if let item = item(from: sender) { activate(item) }
    }
    @objc private func menuShowAll(_ sender: NSMenuItem) {
        if let item = item(from: sender) { expose(item) }
    }
    @objc private func menuHide(_ sender: NSMenuItem) {
        if let pid = item(from: sender)?.runningPID {
            NSRunningApplication(processIdentifier: pid)?.hide()
        }
    }
    @objc private func menuQuit(_ sender: NSMenuItem) {
        if let pid = item(from: sender)?.runningPID {
            NSRunningApplication(processIdentifier: pid)?.terminate()
        }
    }
    @objc private func menuShowInFinder(_ sender: NSMenuItem) {
        guard let item = item(from: sender) else { return }
        switch item.kind {
        case .app(_, let url), .folder(let url):
            NSWorkspace.shared.activateFileViewerSelecting([url])
        case .trash:
            NSWorkspace.shared.open(URL(fileURLWithPath: NSString("~/.Trash").expandingTildeInPath))
        }
    }
    @objc private func menuEmptyTrash(_ sender: NSMenuItem) {
        let script = NSAppleScript(source: "tell application \"Finder\" to empty the trash")
        var err: NSDictionary?
        script?.executeAndReturnError(&err)
    }

    // MARK: - Window (task-switcher) context menu

    /// Boxes a WindowInfo so it can ride in NSMenuItem.representedObject.
    private final class WindowBox { let info: WindowInfo; init(_ i: WindowInfo) { info = i } }

    func makeWindowMenu(for info: WindowInfo) -> NSMenu {
        let menu = NSMenu()
        let box = WindowBox(info)
        func add(_ title: String, _ selector: Selector) {
            let mi = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            mi.target = self
            mi.representedObject = box
            menu.addItem(mi)
        }
        add("Raise Window", #selector(winRaise(_:)))
        add("Show All Windows", #selector(winShowAll(_:)))
        add("Hide", #selector(winHide(_:)))
        menu.addItem(.separator())
        add("Show in Finder", #selector(winShowInFinder(_:)))
        menu.addItem(.separator())
        add("Close", #selector(winClose(_:)))
        return menu
    }

    private func win(from sender: NSMenuItem) -> WindowInfo? {
        (sender.representedObject as? WindowBox)?.info
    }

    @objc private func winRaise(_ sender: NSMenuItem) {
        if let w = win(from: sender) { raiseWindow(w) }
    }
    @objc private func winShowAll(_ sender: NSMenuItem) {
        guard let pid = win(from: sender)?.pid,
              let app = NSRunningApplication(processIdentifier: pid) else { return }
        app.unhide(); app.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            CoreDockSendNotification("com.apple.expose.front.awake" as CFString, 0)
        }
    }
    @objc private func winHide(_ sender: NSMenuItem) {
        if let pid = win(from: sender)?.pid {
            NSRunningApplication(processIdentifier: pid)?.hide()
        }
    }
    @objc private func winClose(_ sender: NSMenuItem) {
        if let w = win(from: sender) {
            WindowControl.close(windowNumber: w.windowNumber, pid: w.pid)
            // Update the taskbar immediately rather than waiting for the poll.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.onCloseRequested?()
            }
        }
    }

    /// Set by the controller to force an immediate window-list refresh.
    var onCloseRequested: (() -> Void)?
    @objc private func winShowInFinder(_ sender: NSMenuItem) {
        if let pid = win(from: sender)?.pid,
           let url = NSRunningApplication(processIdentifier: pid)?.bundleURL {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}

/// One Dock icon: an image-only button plus a running-dot drawn beneath it.
/// Hosts the per-item context menu via `self.menu`, so right-click / control-click
/// / two-finger-tap all work automatically.
final class DockIconView: NSView {

    private static let badgeSize: CGFloat = 14

    private let item: DockItem
    private weak var panel: TaskbarPanel?
    private let imageView = NSImageView()

    /// The icon occupies the top `iconSize` square; the bottom 6pt holds the dot.
    private var iconRect: NSRect {
        let size = TaskbarPanel.iconSize
        return NSRect(x: 0, y: bounds.height - size, width: size, height: size)
    }

    /// Exposé badge, top-right corner of the icon. Only meaningful when running.
    private var badgeRect: NSRect {
        let b = Self.badgeSize
        let icon = iconRect
        return NSRect(x: icon.maxX - b, y: icon.maxY - b, width: b, height: b)
    }

    init(item: DockItem, panel: TaskbarPanel) {
        self.item = item
        self.panel = panel
        super.init(frame: .zero)

        let size = TaskbarPanel.iconSize
        imageView.image = item.icon
        imageView.imageScaling = .scaleProportionallyUpOrDown
        // Let mouse events fall through to this view so we can hit-test the badge.
        imageView.refusesFirstResponder = true
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)

        toolTip = item.label
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: size),
            heightAnchor.constraint(equalToConstant: size + 6),
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.widthAnchor.constraint(equalToConstant: size),
            imageView.heightAnchor.constraint(equalToConstant: size),
        ])

        self.menu = panel.makeMenu(for: item)
    }

    required init?(coder: NSCoder) { fatalError() }

    // The image view would otherwise swallow the click; route everything through here.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return bounds.contains(local) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        // Click on the Exposé badge (running apps only) → App Exposé; else regular.
        if item.isRunning, badgeRect.insetBy(dx: -3, dy: -3).contains(p) {
            panel?.expose(item)
        } else {
            panel?.activate(item)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard item.isRunning else { return }

        // Running dot, centered along the bottom edge.
        let d: CGFloat = 4
        let dot = NSRect(x: (bounds.width - d) / 2, y: 0, width: d, height: d)
        NSColor.labelColor.withAlphaComponent(0.65).setFill()
        NSBezierPath(ovalIn: dot).fill()

        // Exposé badge: a small rounded square with a grid glyph, top-right.
        let badge = badgeRect
        let bg = NSBezierPath(roundedRect: badge, xRadius: 3, yRadius: 3)
        NSColor(white: 0.15, alpha: 0.45).setFill()
        bg.fill()
        drawExposeGlyph(in: badge.insetBy(dx: 4, dy: 4))
    }

    /// A 2×2 grid of small rects — the App Exposé motif.
    private func drawExposeGlyph(in rect: NSRect) {
        let gap: CGFloat = 1.2
        let cellW = (rect.width - gap) / 2
        let cellH = (rect.height - gap) / 2
        NSColor.white.withAlphaComponent(0.7).setFill()
        for col in 0..<2 {
            for row in 0..<2 {
                let cell = NSRect(
                    x: rect.minX + CGFloat(col) * (cellW + gap),
                    y: rect.minY + CGFloat(row) * (cellH + gap),
                    width: cellW, height: cellH)
                NSBezierPath(roundedRect: cell, xRadius: 0.6, yRadius: 0.6).fill()
            }
        }
    }
}

/// A single Win95-style task-switcher button: raised bevel, small icon + title.
/// Click raises that specific window.
final class WindowButton: NSView {

    private static let height: CGFloat = 24
    static let preferredWidth: CGFloat = 140
    /// Buttons shrink down to this (icon + a few chars) before any window is dropped.
    static let minWidth: CGFloat = 44

    private let info: WindowInfo
    private weak var panel: TaskbarPanel?
    private var pressed = false

    init(info: WindowInfo, panel: TaskbarPanel, width: CGFloat) {
        self.info = info
        self.panel = panel
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        let iconView = NSImageView(image: info.icon)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: info.displayTitle)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        addSubview(iconView)
        addSubview(label)
        self.menu = panel.makeWindowMenu(for: info)

        // Width is decided by the panel (shrinks to fit all windows before any are
        // dropped). The label truncates within whatever width we get.
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            widthAnchor.constraint(equalToConstant: width),
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    // The panel is a non-key, non-activating window, so AppKit's built-in .toolTip
    // never fires. Use an explicit tracking area + a custom floating tooltip instead.
    private var hoverTimer: Timer?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeAlways],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        hoverTimer?.invalidate()
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            guard let self else { return }
            TooltipWindow.shared.show(self.info.displayTitle, below: self)
        }
    }

    override func mouseExited(with event: NSEvent) {
        hoverTimer?.invalidate(); hoverTimer = nil
        TooltipWindow.shared.hide()
    }

    private func setPressed(_ v: Bool) {
        guard pressed != v else { return }
        pressed = v
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        setPressed(true)
    }

    override func mouseDragged(with event: NSEvent) {
        // Track whether the cursor is still over the button while held.
        setPressed(bounds.contains(convert(event.locationInWindow, from: nil)))
    }

    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        // Clear the pressed look BEFORE raising the window — raising changes focus
        // and can interrupt the run loop, which previously left the button stuck.
        setPressed(false)
        hoverTimer?.invalidate(); TooltipWindow.shared.hide()
        if inside { panel?.raiseWindow(info) }
    }

    // Right-click / control-click shows the context menu via `self.menu`; ensure the
    // pressed state never sticks if a right-click interrupts a left-press.
    override func rightMouseDown(with event: NSEvent) {
        setPressed(false)
        super.rightMouseDown(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        // Bevel colors adapt to the effective appearance (light vs dark theme).
        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let face: NSColor
        let light: NSColor
        let dark: NSColor
        if isDark {
            face = pressed ? NSColor(white: 0.22, alpha: 0.95) : NSColor(white: 0.32, alpha: 0.95)
            light = NSColor(white: 0.55, alpha: 0.9)   // raised highlight
            dark  = NSColor(white: 0.10, alpha: 0.9)   // raised shadow
        } else {
            face = pressed ? NSColor(white: 0.78, alpha: 0.9) : NSColor(white: 0.86, alpha: 0.9)
            light = NSColor.white.withAlphaComponent(0.9)
            dark  = NSColor(white: 0.45, alpha: 0.9)
        }

        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        face.setFill()
        NSBezierPath(rect: r).fill()

        let topLeft = pressed ? dark : light
        let bottomRight = pressed ? light : dark

        topLeft.setStroke()
        let tl = NSBezierPath()
        tl.move(to: NSPoint(x: r.minX, y: r.minY)); tl.line(to: NSPoint(x: r.minX, y: r.maxY))
        tl.line(to: NSPoint(x: r.maxX, y: r.maxY)); tl.lineWidth = 1; tl.stroke()

        bottomRight.setStroke()
        let br = NSBezierPath()
        br.move(to: NSPoint(x: r.minX, y: r.minY)); br.line(to: NSPoint(x: r.maxX, y: r.minY))
        br.line(to: NSPoint(x: r.maxX, y: r.maxY)); br.lineWidth = 1; br.stroke()
    }
}

/// Win95 Start-style launcher: a button that pops up the application menu built
/// from /Applications + Utilities. Rebuilds the menu fresh on each click so newly
/// installed apps show up.
final class LauncherButton: NSView {

    private let builder = AppMenuBuilder()
    private let button = NSButton()
    private let desktopLabel = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImage(systemSymbolName: "square.grid.2x2.fill",
                           accessibilityDescription: "Applications")
        button.image = icon
        button.imagePosition = .imageLeading
        button.title = "Apps"
        button.font = .boldSystemFont(ofSize: 11)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.target = self
        button.action = #selector(showMenu)
        button.translatesAutoresizingMaskIntoConstraints = false
        addSubview(button)

        desktopLabel.font = .systemFont(ofSize: 9)
        desktopLabel.textColor = .secondaryLabelColor
        desktopLabel.alignment = .center
        desktopLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(desktopLabel)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: TaskbarPanel.iconSize),
            // Apps button on top, desktop label centered beneath it.
            button.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.trailingAnchor.constraint(equalTo: trailingAnchor),
            button.heightAnchor.constraint(equalToConstant: 24),
            desktopLabel.topAnchor.constraint(equalTo: button.bottomAnchor, constant: 1),
            desktopLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            desktopLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Update the desktop-name label (e.g. "Desktop 2").
    func setDesktop(_ name: String) {
        desktopLabel.stringValue = name
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { builder.prewarm() }   // build the menu before first click
    }

    @objc private func showMenu() {
        // Cached: only rebuilds when /Applications actually changed.
        let menu = builder.menu()
        // Pop up just above the button (the bar sits at the screen's bottom edge).
        let origin = NSPoint(x: 0, y: bounds.height + 4)
        menu.popUp(positioning: nil, at: origin, in: self)
    }
}

/// A small floating tooltip used because the bar's non-key panel can't trigger
/// AppKit's built-in .toolTip. Single shared instance, reused.
final class TooltipWindow {
    static let shared = TooltipWindow()

    private let panel: NSPanel
    private let label = NSTextField(labelWithString: "")

    private init() {
        panel = NSPanel(contentRect: .zero,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        panel.level = .popUpMenu
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false

        let bg = NSVisualEffectView()
        bg.material = .toolTip
        bg.blendingMode = .behindWindow
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 5
        bg.layer?.masksToBounds = true
        bg.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = bg

        label.font = .systemFont(ofSize: 11)
        label.textColor = .labelColor
        label.maximumNumberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 7),
            label.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -7),
            label.topAnchor.constraint(equalTo: bg.topAnchor, constant: 4),
            label.bottomAnchor.constraint(equalTo: bg.bottomAnchor, constant: -4),
        ])
    }

    /// Show `text` centered above the given view (the bar sits at the screen bottom).
    func show(_ text: String, below view: NSView) {
        guard let window = view.window else { return }
        label.stringValue = text
        panel.appearance = window.appearance
        panel.layoutIfNeeded()
        let size = panel.contentView!.fittingSize

        // Position centered horizontally over the button, just above the bar.
        let inWindow = view.convert(view.bounds, to: nil)
        let onScreen = window.convertToScreen(inWindow)
        let x = onScreen.midX - size.width / 2
        let y = onScreen.maxY + 4
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
        panel.orderFront(nil)
    }

    func hide() {
        panel.orderOut(nil)
    }
}
