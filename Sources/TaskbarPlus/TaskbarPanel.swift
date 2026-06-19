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
    /// Grouped mode: a horizontal row of bordered per-desktop segment boxes.
    private let segmentRow = NSStackView()

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
        // Grouped-mode segment row (sibling of the two rows; only one is shown).
        segmentRow.orientation = .horizontal
        segmentRow.alignment = .centerY
        segmentRow.spacing = 8
        segmentRow.isHidden = true
        switcherStack.addArrangedSubview(segmentRow)

        // Three zones across the bar: left edge, center, right edge.
        let debugBorders = ProcessInfo.processInfo.environment["TBP_BORDERS"] != nil
        let borderColors: [NSColor] = [.systemGreen, .systemBlue, .systemRed]  // left, center, right
        for (i, z) in [leftZone, centerZone, rightZone].enumerated() {
            z.orientation = .horizontal
            z.alignment = .centerY
            z.spacing = 10
            z.translatesAutoresizingMaskIntoConstraints = false
            blur.addSubview(z)
            z.centerYAnchor.constraint(equalTo: blur.centerYAnchor).isActive = true
            if debugBorders {
                z.wantsLayer = true
                z.layer?.borderColor = borderColors[i].cgColor
                z.layer?.borderWidth = 2
            }
        }
        if debugBorders {
            switcherStack.wantsLayer = true
            switcherStack.layer?.borderColor = NSColor.systemYellow.cgColor
            switcherStack.layer?.borderWidth = 2
        }
        // Zone edges pinned to the screen are REQUIRED and authoritative — the right
        // zone (Trash) always sits flush right. The no-overlap guards are slightly
        // lower priority so they can't override the edge pins and shove a zone
        // off-screen (which made the right zone vanish); the centered switcher's
        // width is capped separately so it stays clear without needing the guard.
        let leftPin = leftZone.leadingAnchor.constraint(equalTo: blur.leadingAnchor, constant: Self.horizontalPadding)
        let rightPin = rightZone.trailingAnchor.constraint(equalTo: blur.trailingAnchor, constant: -Self.horizontalPadding)
        leftPin.priority = .required
        rightPin.priority = .required
        let guardL = centerZone.leadingAnchor.constraint(greaterThanOrEqualTo: leftZone.trailingAnchor, constant: 16)
        let guardR = rightZone.leadingAnchor.constraint(greaterThanOrEqualTo: centerZone.trailingAnchor, constant: 16)
        guardL.priority = .defaultHigh
        guardR.priority = .defaultHigh
        NSLayoutConstraint.activate([
            leftPin, rightPin,
            centerZone.centerXAnchor.constraint(equalTo: blur.centerXAnchor),
            guardL, guardR,
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
    private var grouped = false
    /// Number of desktops to segment into (grouped mode). Provided by the controller.
    var desktopCount: () -> Int = { 0 }

    /// Update the desktop-name label under the Apps button.
    func updateDesktop(_ name: String) {
        launcherButton.setDesktop(name)
    }

    /// Switch grouped (per-desktop segmented) rendering on/off.
    func setGrouped(_ on: Bool) {
        grouped = on
        rebuildSwitcher(lastWindows, force: true)
    }

    /// Called when the desktop label is clicked (toggle space mode). Set by controller.
    var onToggleSpaceMode: (() -> Void)? {
        didSet { launcherButton.onToggleMode = onToggleSpaceMode }
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
            return switcherRow1.arrangedSubviews.isEmpty
                && switcherRow2.arrangedSubviews.isEmpty
                && segmentRow.arrangedSubviews.isEmpty
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

        // Only pull the switcher OUT of its zone for genuine `expand` (where it must
        // span a wider area than its content). For plain align — including the common
        // center case — leave it as a normal member of its zone: the zone constraints
        // (leftZone→left edge, centerZone→centerX, rightZone→right edge, with
        // no-overlap guards) already position it correctly and robustly. This avoids
        // the fragile edge-pinning that kept mispositioning the right zone.
        let needsArea = (expand != nil) && !isEmpty(.switcher)
        guard needsArea, let blur = contentView else { return }

        (switcherStack.superview as? NSStackView)?.removeView(switcherStack)
        if switcherStack.superview == nil { blur.addSubview(switcherStack) }
        switcherStack.translatesAutoresizingMaskIntoConstraints = false

        let gap: CGFloat = 16
        // Bound the switcher BETWEEN the flanking zones with inequalities, so it can
        // never overlap them or run off-screen — but does NOT stretch them (an
        // equality pin was forcing rightZone wide, pushing Trash off the right edge).
        // The switcher is content-sized; `align` positions it within these bounds via
        // the bias constraint below.
        let leadingBound = switcherStack.leadingAnchor.constraint(
            greaterThanOrEqualTo: leftZone.trailingAnchor, constant: gap)
        let trailingBound = switcherStack.trailingAnchor.constraint(
            lessThanOrEqualTo: rightZone.leadingAnchor, constant: -gap)

        // Position bias per align (breakable, so the hard bounds always win).
        let bias: NSLayoutConstraint
        switch align {
        case .left:
            bias = switcherStack.leadingAnchor.constraint(equalTo: leftZone.trailingAnchor, constant: gap)
        case .right:
            bias = switcherStack.trailingAnchor.constraint(equalTo: rightZone.leadingAnchor, constant: -gap)
        case .center:
            bias = switcherStack.centerXAnchor.constraint(equalTo: blur.centerXAnchor)
        }
        bias.priority = .defaultHigh

        let cons: [NSLayoutConstraint] = [
            switcherStack.centerYAnchor.constraint(equalTo: blur.centerYAnchor),
            leadingBound, trailingBound, bias,
        ]
        NSLayoutConstraint.activate(cons)
        switcherExpandConstraints = cons
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
        let signature = "\(grouped)|" + windows.map { "\($0.windowNumber):\($0.displayTitle):\($0.desktopIndex)" }.joined(separator: "|")
        if !force, signature == switcherSignature { return }
        switcherSignature = signature

        for v in switcherRow1.arrangedSubviews { switcherRow1.removeView(v) }
        for v in switcherRow2.arrangedSubviews { switcherRow2.removeView(v) }
        for v in segmentRow.arrangedSubviews { segmentRow.removeView(v) }

        if grouped {
            rebuildGrouped(windows)
            return
        }
        switcherRow1.isHidden = false
        switcherRow2.isHidden = false
        segmentRow.isHidden = true

        let avail = switcherAvailableWidth()
        let spacing = switcherRow1.spacing

        func fit(at width: CGFloat) -> Int { max(1, Int((avail + spacing) / (width + spacing))) }
        let fitPreferred = fit(at: WindowButton.preferredWidth)   // per row at full width
        let fitMin = fit(at: WindowButton.minWidth)               // per row at min width

        let count = windows.count
        let perRow: Int            // buttons in the (fuller) top row
        let buttonWidth: CGFloat
        let capacity = fitMin * 2  // absolute max across both rows

        if count <= fitPreferred {
            // Everything fits on ONE row at full width — fill row 1 only.
            perRow = count
            buttonWidth = WindowButton.preferredWidth
        } else if count <= fitPreferred * 2 {
            // Needs a second row, but still fits at full width — balance the two rows.
            perRow = Int(ceil(Double(count) / 2.0))
            buttonWidth = WindowButton.preferredWidth
        } else {
            // More than two full-width rows hold → shrink to fit (cap at fitMin*2).
            let shownCount = min(count, capacity)
            perRow = Int(ceil(Double(shownCount) / 2.0))
            let raw = (avail - CGFloat(perRow - 1) * spacing) / CGFloat(perRow)
            buttonWidth = max(WindowButton.minWidth, min(WindowButton.preferredWidth, raw))
        }

        let shown = Array(windows.prefix(count <= fitPreferred * 2 ? count : capacity))
        let topCount = min(perRow, shown.count)
        var newButtons: [WindowButton] = []
        for (i, w) in shown.enumerated() {
            let row = i < topCount ? switcherRow1 : switcherRow2
            let btn = WindowButton(info: w, panel: self, width: buttonWidth)
            btn.alphaValue = 0   // start hidden; fade in below
            row.addArrangedSubview(btn)
            newButtons.append(btn)
        }
        switcherRow2.isHidden = switcherRow2.arrangedSubviews.isEmpty
        reassembleZones()

        // Subtle fade-in so the strip appears smoothly instead of flashing.
        contentView?.layoutSubtreeIfNeeded()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.allowsImplicitAnimation = true
            for b in newButtons { b.animator().alphaValue = 1 }
        }

        if ProcessInfo.processInfo.environment["TBP_DEBUG"] != nil {
            NSLog("switcher: panelW=\(frame.width) perRow=\(perRow) w=\(Int(buttonWidth)) shown=\(shown.count)/\(windows.count)")
        }
    }

    /// Grouped mode: one bordered segment box per desktop, each holding that
    /// desktop's windows (in up to two internal rows).
    private func rebuildGrouped(_ windows: [WindowInfo]) {
        switcherRow1.isHidden = true
        switcherRow2.isHidden = true
        segmentRow.isHidden = false

        let nDesktops = max(desktopCount(), windows.map { $0.desktopIndex }.max() ?? 0)
        guard nDesktops > 0 else { return }

        // Split the total available width across the segments (never exceed it, so
        // the strip can't push the right zone off-screen).
        let totalAvail = switcherAvailableWidth()
        let segGap = segmentRow.spacing
        let rawSeg = (totalAvail - CGFloat(nDesktops - 1) * segGap) / CGFloat(nDesktops)
        let segWidth = max(WindowButton.minWidth + 12, rawSeg)
        // Boxes fill (almost) the full bar height.
        let segHeight = Self.barHeight - 10

        var newButtons: [WindowButton] = []
        for desk in 1...nDesktops {
            let deskWindows = windows.filter { $0.desktopIndex == desk }
            let seg = makeSegment(windows: deskWindows, width: segWidth, height: segHeight, into: &newButtons)
            segmentRow.addArrangedSubview(seg)
        }
        reassembleZones()

        contentView?.layoutSubtreeIfNeeded()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18; ctx.allowsImplicitAnimation = true
            for b in newButtons { b.animator().alphaValue = 1 }
        }
    }

    /// A bordered box for one desktop, containing its windows across two inner rows.
    private func makeSegment(windows: [WindowInfo], width: CGFloat, height: CGFloat,
                             into newButtons: inout [WindowButton]) -> NSView {
        let box = NSView()
        box.wantsLayer = true
        box.layer?.borderColor = NSColor.separatorColor.cgColor
        box.layer?.borderWidth = 1
        box.layer?.cornerRadius = 5
        box.translatesAutoresizingMaskIntoConstraints = false

        let inner = NSStackView()
        inner.orientation = .vertical
        inner.alignment = .leading
        inner.spacing = 3
        inner.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(inner)
        let widthC = box.widthAnchor.constraint(equalToConstant: width)
        widthC.priority = .defaultHigh   // yield rather than push the right zone off-screen
        NSLayoutConstraint.activate([
            widthC,
            box.heightAnchor.constraint(equalToConstant: height),   // full bar height
            inner.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 4),
            inner.trailingAnchor.constraint(lessThanOrEqualTo: box.trailingAnchor, constant: -4),
            inner.centerYAnchor.constraint(equalTo: box.centerYAnchor),
        ])

        // Button width to fit within the segment; balance windows over two rows.
        let innerAvail = width - 8
        let spacing: CGFloat = 4
        func fit(at w: CGFloat) -> Int { max(1, Int((innerAvail + spacing) / (w + spacing))) }
        let perRowPref = fit(at: WindowButton.preferredWidth)
        let perRowMin = fit(at: WindowButton.minWidth)
        let count = windows.count
        let perRow: Int, bw: CGFloat
        if count <= perRowPref { perRow = max(count, 1); bw = WindowButton.preferredWidth }
        else if count <= perRowPref * 2 { perRow = Int(ceil(Double(count)/2)); bw = WindowButton.preferredWidth }
        else {
            let shown = min(count, perRowMin * 2); perRow = Int(ceil(Double(shown)/2))
            bw = max(WindowButton.minWidth, min(WindowButton.preferredWidth, (innerAvail - CGFloat(perRow-1)*spacing)/CGFloat(perRow)))
        }

        let row1 = NSStackView(); row1.orientation = .horizontal; row1.spacing = spacing
        let row2 = NSStackView(); row2.orientation = .horizontal; row2.spacing = spacing
        inner.addArrangedSubview(row1); inner.addArrangedSubview(row2)

        let shown = Array(windows.prefix(perRowMin * 2))
        let topCount = min(perRow, shown.count)
        for (i, w) in shown.enumerated() {
            let btn = WindowButton(info: w, panel: self, width: bw)
            btn.alphaValue = 0
            (i < topCount ? row1 : row2).addArrangedSubview(btn)
            newButtons.append(btn)
        }
        row2.isHidden = row2.arrangedSubviews.isEmpty
        return box
    }

    /// Width available to ONE switcher row, given the switcher's zone and the space
    /// the Dock sections consume. Buttons are sized to fill this so the strip never
    /// overflows the screen, wherever the switcher is placed.
    private func switcherAvailableWidth() -> CGFloat {
        let screenW = frame.width > 0 ? frame.width : (NSScreen.screens.first?.frame.width ?? 1512)
        let pad = Self.horizontalPadding
        let gap: CGFloat = 16

        // Actual rendered width of a flanking zone (includes launcher + separators).
        // The switcher is excluded since it lives in its own zone, not these.
        contentView?.layoutSubtreeIfNeeded()
        func zoneWidth(_ z: Zone) -> CGFloat {
            let s = zoneStack(z)
            return s.arrangedSubviews.isEmpty ? 0 : s.fittingSize.width
        }

        let leftW = zoneWidth(.left)
        let rightW = zoneWidth(.right)
        // When expanding, the switcher is edge-anchored and uses the FULL gap between
        // the flanking zones (regardless of its nominal zone).
        if config.expand(for: .switcher) != nil {
            return max(WindowButton.minWidth, screenW - leftW - rightW - 2 * pad - 2 * gap)
        }
        switch config.zone(for: .switcher) {
        case .center:
            // Centered in centerZone: it grows symmetrically, so it must stay clear of
            // the WIDER neighbour on BOTH sides. Cap to the symmetric centered width so
            // it never pushes a zone off-screen (which made the right zone vanish).
            let half = screenW / 2 - max(leftW, rightW) - gap - pad
            return max(WindowButton.minWidth, half * 2)
        case .left, .right:
            // Edge-anchored (expand): use the full gap between the two flanking zones.
            return max(WindowButton.minWidth, screenW - leftW - rightW - 2 * pad - 2 * gap)
        }
    }

    private func dockStacks() -> [NSStackView] { [pinnedStack, runningStack, othersStack] }

    /// Returns true if the window is on a Space other than a currently-visible one.
    var onIsWindowOnOtherSpace: ((Int) -> Bool)?

    /// Raise a specific window (task-switcher click).
    func raiseWindow(_ info: WindowInfo) {
        let onOther = onIsWindowOnOtherSpace?(info.windowNumber) ?? false
        if onOther, info.desktopIndex >= 1 {
            // The private Space-switch APIs are dead on macOS 26, but synthesizing the
            // "switch to Desktop N" shortcut (Ctrl+N) still works. Switch to the
            // window's desktop, then raise it once it's on-screen (AX can only see
            // windows on the current Space).
            DesktopSwitcher.switchTo(desktop: info.desktopIndex)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                WindowControl.raise(windowNumber: info.windowNumber, pid: info.pid, title: info.title)
            }
        } else {
            WindowControl.raise(windowNumber: info.windowNumber, pid: info.pid, title: info.title)
        }
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
            // openApplication both activates a running app AND fires its "reopen"
            // handler — so an app with no open windows gets a fresh one, matching
            // the real Dock. For a not-running app it just launches. (Plain
            // activate() would bring the app forward but never make a window.)
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: cfg)
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
            WindowControl.close(windowNumber: w.windowNumber, pid: w.pid, title: w.title)
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

    // Custom tooltip (the non-key bar panel can't use AppKit's built-in .toolTip).
    private var overBadge = false

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways],
                                       owner: self, userInfo: nil))
    }

    /// Tooltip text depends on whether the cursor is over the Exposé badge.
    private func tooltipText(at p: NSPoint) -> String {
        if item.isRunning, badgeRect.insetBy(dx: -3, dy: -3).contains(p) {
            return "Show all windows of \(item.label)"
        }
        return item.label
    }

    override func mouseEntered(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        overBadge = item.isRunning && badgeRect.insetBy(dx: -3, dy: -3).contains(p)
        TooltipWindow.shared.show(tooltipText(at: p), below: self, anchorRect: iconRect)
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let nowOverBadge = item.isRunning && badgeRect.insetBy(dx: -3, dy: -3).contains(p)
        if nowOverBadge != overBadge {   // only re-show when the region changes
            overBadge = nowOverBadge
            TooltipWindow.shared.show(tooltipText(at: p), below: self, anchorRect: iconRect)
        }
    }

    override func mouseExited(with event: NSEvent) {
        TooltipWindow.shared.hide()
    }

    // The image view would otherwise swallow the click; route everything through here.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return bounds.contains(local) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        TooltipWindow.shared.hide()
        let p = convert(event.locationInWindow, from: nil)
        // Click on the Exposé badge (running apps only) → App Exposé; else regular.
        if item.isRunning, badgeRect.insetBy(dx: -3, dy: -3).contains(p) {
            panel?.expose(item)
        } else {
            panel?.activate(item)
        }
    }

    // Right-click opens the context menu via self.menu; hide the tooltip first.
    override func rightMouseDown(with event: NSEvent) {
        TooltipWindow.shared.hide()
        super.rightMouseDown(with: event)
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
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeAlways],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        TooltipWindow.shared.show(info.displayTitle, below: self)   // immediate, like the Dock
    }

    override func mouseExited(with event: NSEvent) {
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
        TooltipWindow.shared.hide()
        if inside { panel?.raiseWindow(info) }
    }

    // Right-click / control-click shows the context menu via `self.menu`; ensure the
    // pressed state never sticks if a right-click interrupts a left-press.
    override func rightMouseDown(with event: NSEvent) {
        setPressed(false)
        TooltipWindow.shared.hide()
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
    private let desktopButton = NSButton()

    /// Called when the desktop label is clicked, to toggle current-Space ↔ all-Spaces.
    var onToggleMode: (() -> Void)?

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

        // The desktop label is a flat, borderless button — click toggles the mode.
        desktopButton.isBordered = false
        desktopButton.bezelStyle = .inline
        desktopButton.font = .systemFont(ofSize: 9)
        desktopButton.contentTintColor = .secondaryLabelColor
        desktopButton.target = self
        desktopButton.action = #selector(toggleMode)
        desktopButton.toolTip = "Click to toggle current Desktop / All Desktops"
        desktopButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(desktopButton)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: TaskbarPanel.iconSize),
            // Apps button on top, desktop label centered beneath it.
            button.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.trailingAnchor.constraint(equalTo: trailingAnchor),
            button.heightAnchor.constraint(equalToConstant: 24),
            desktopButton.topAnchor.constraint(equalTo: button.bottomAnchor, constant: 0),
            desktopButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            desktopButton.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func toggleMode() { onToggleMode?() }

    /// Update the desktop-name label (e.g. "Desktop 2" or "All Desktops").
    func setDesktop(_ name: String) {
        desktopButton.title = name
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

        // Rounded "pill" like the macOS Dock tooltip.
        let bg = NSVisualEffectView()
        bg.material = .popover
        bg.blendingMode = .behindWindow
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = Self.height / 2   // full capsule
        bg.layer?.masksToBounds = true
        bg.layer?.borderWidth = 0.5
        bg.layer?.borderColor = NSColor.separatorColor.cgColor
        bg.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = bg

        label.font = .systemFont(ofSize: 13)
        label.textColor = .labelColor
        label.maximumNumberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -12),
            label.centerYAnchor.constraint(equalTo: bg.centerYAnchor),
        ])
    }

    private static let height: CGFloat = 26

    /// Show `text` centered above `view` (or above `anchorRect` within it, if given).
    func show(_ text: String, below view: NSView, anchorRect: NSRect? = nil) {
        guard let window = view.window else { return }
        label.stringValue = text
        panel.appearance = window.appearance

        let rect = anchorRect ?? view.bounds
        let onScreen = window.convertToScreen(view.convert(rect, to: nil))
        let width = label.intrinsicContentSize.width + 24
        let x = onScreen.midX - width / 2
        let y = onScreen.maxY + 6
        panel.setFrame(NSRect(x: x, y: y, width: width, height: Self.height), display: true)
        panel.orderFront(nil)
    }

    func hide() {
        panel.orderOut(nil)
    }
}
