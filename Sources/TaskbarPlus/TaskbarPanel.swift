import AppKit
import CSkyLight

/// A borderless, non-activating panel that floats a Dock-style row of icons along
/// the bottom edge of the main screen and stays visible on every Space.
///
/// Layout mirrors the real Dock: [pinned] | [running-only] | [folders + Trash],
/// with separators only between non-empty sections and a running-dot under each
/// running app. Each icon hosts a right-click context menu.
/// Which portion of the screen width a panel occupies. `.full` is the normal
/// single bar; `.left`/`.right` are the two narrow split-mode panels with a clear
/// center gap between them for the real Dock.
enum SplitSide { case full, left, right }

final class TaskbarPanel: NSPanel {

    static let iconSize: CGFloat = 40
    private static let barHeight: CGFloat = 60
    private static let horizontalPadding: CGFloat = 14
    /// Fallback center gap (split mode) when the Dock width can't be estimated.
    private static let centerGapFraction: CGFloat = 0.40

    private let config: LayoutConfig
    private let side: SplitSide

    /// Split-mode resting level (Dock floats on top) and the raised level (above Dock).
    private static let belowDock = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) - 1)
    private static let aboveDock = NSWindow.Level.statusBar

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

    init(screen: NSScreen, config: LayoutConfig, side: SplitSide = .full) {
        self.targetFrameOrigin = screen.frame.origin
        self.config = config
        self.side = side
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        // Normal bar floats above everything (statusBar = 25 > dock = 20). Split mode
        // rests JUST BELOW the Dock (dock − 1) so the Dock floats on top in the center;
        // hovering the bar raises it above the Dock (see mouseEntered/Exited).
        level = config.splitMode ? Self.belowDock : .statusBar
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

        // Frosted blur background (the original look). `.sidebar` adapts to light/dark.
        let blur = NSVisualEffectView()
        blur.material = .sidebar
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.translatesAutoresizingMaskIntoConstraints = false
        contentView = blur
        // HARD-clamp the blur to a FIXED width/height (set per screen in reposition()).
        // A borderless panel whose contentView uses autolayout otherwise lets the
        // content's intrinsic width grow the window's content rect past the window frame
        // (observed: window 1512 but contentView 1681 → Trash + right chips rendered off
        // the visible edge and got clipped). A required constant width forces the layout
        // engine to compress the (breakable) switcher chips into the real on-screen width
        // instead of ballooning the canvas. Pinning to the superview/themeFrame did NOT
        // work — that lets the themeFrame grow with the content; a constant does not.
        let bw = blur.widthAnchor.constraint(equalToConstant: 100)
        let bh = blur.heightAnchor.constraint(equalToConstant: Self.barHeight)
        bw.priority = .required
        bh.priority = .required
        NSLayoutConstraint.activate([bw, bh])
        blurWidthConstraint = bw

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
        segmentRow.alignment = .top   // boxes share a top edge; the active underline hangs below
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
                z.layer?.backgroundColor = borderColors[i].withAlphaComponent(0.18).cgColor
            }
        }
        if debugBorders {
            switcherStack.wantsLayer = true
            switcherStack.layer?.borderColor = NSColor.systemYellow.cgColor
            switcherStack.layer?.borderWidth = 2
            switcherStack.layer?.backgroundColor = NSColor.systemYellow.withAlphaComponent(0.25).cgColor
        }

        if config.splitMode {
            // Split mode: launcher pinned LEFT, switcher (right zone) pinned RIGHT and
            // grows leftward. No center zone / no-overlap guards — those were pushing
            // the right zone off-screen. The launcher is tiny, so there's no overlap.
            leftZone.leadingAnchor.constraint(equalTo: blur.leadingAnchor, constant: Self.horizontalPadding).isActive = true
            let rightPin = rightZone.trailingAnchor.constraint(equalTo: blur.trailingAnchor, constant: -Self.horizontalPadding)
            rightPin.priority = .required
            // Hard floor: the right zone can't cross into the launcher (so its content
            // is forced to shrink/cap rather than overflow either edge).
            let floor = rightZone.leadingAnchor.constraint(greaterThanOrEqualTo: leftZone.trailingAnchor, constant: 16)
            floor.priority = .required
            NSLayoutConstraint.activate([rightPin, floor])
            reposition()
            NotificationCenter.default.addObserver(
                self, selector: #selector(reposition),
                name: NSApplication.didChangeScreenParametersNotification, object: nil)
            orderFront(nil)
            return
        }

        switch side {
        case .full:
            // Full bar: three zones (left edge / centered / right edge) with
            // no-overlap guards. Edge pins required; guards lower so they can't shove
            // a zone off-screen.
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
        case .left:
            // Split-left panel hosts only the launcher (left zone), pinned to the
            // left edge. Center/right zones are unused (no constraints → zero size).
            leftZone.leadingAnchor.constraint(equalTo: blur.leadingAnchor, constant: Self.horizontalPadding).isActive = true
        case .right:
            // Split-right panel hosts only the switcher (right zone), pinned to the
            // right edge so it can't run off-panel.
            rightZone.trailingAnchor.constraint(equalTo: blur.trailingAnchor, constant: -Self.horizontalPadding).isActive = true
        }

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
        let h = Self.barHeight
        // Normal mode: sit in the visible area (above the Dock). Split mode: sit at the
        // screen's true bottom edge, level with the Dock — the Dock floats on top in the
        // center (bar is below the Dock's window level), launcher/switcher show at edges.
        let area = config.splitMode ? screen.frame : screen.visibleFrame
        setFrame(NSRect(x: area.minX, y: area.minY, width: area.width, height: h), display: true)
        // Clamp the blur (contentView) to exactly the panel width so its content can't
        // balloon the content rect past the window and clip the right zone.
        blurWidthConstraint?.constant = area.width
        contentView?.layoutSubtreeIfNeeded()
        installHoverTracking()
    }

    private var hoverTracking: NSTrackingArea?

    /// In split mode, track the mouse over the bar so we can raise it above the Dock
    /// on hover. The Dock-covered center won't deliver enter events (the Dock gets
    /// them) — only the visible launcher/switcher edges trigger it, which is intended.
    private func installHoverTracking() {
        guard config.splitMode, let view = contentView else { return }
        if let t = hoverTracking { view.removeTrackingArea(t) }
        let t = NSTrackingArea(rect: view.bounds,
                               options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        view.addTrackingArea(t)
        hoverTracking = t
    }

    override func mouseEntered(with event: NSEvent) {
        if config.splitMode { level = Self.aboveDock }   // rise above the Dock
    }

    override func mouseExited(with event: NSEvent) {
        if config.splitMode { level = Self.belowDock }   // settle back under the Dock
    }

    // MARK: - Update

    private var lastWindows: [WindowInfo] = []
    private var dockSignature = ""
    private var grouped = false
    /// Number of desktops to segment into (grouped mode). Provided by the controller.
    var desktopCount: () -> Int = { 0 }
    /// 1-based index of the active desktop (grouped mode places it rightmost).
    var activeDesktop: () -> Int = { 0 }

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
            // This panel only mounts sections whose effective zone matches its side
            // (left panel → left zone, right panel → right zone, full → all zones).
            guard sideAllows(zoneKind) else { continue }
            let stack = zoneStack(zoneKind)
            let members = order.filter {
                config.sectionIsVisible($0) && config.effectiveZone(for: $0) == zoneKind && !isEmpty($0)
            }
            for (i, section) in members.enumerated() {
                if i > 0 { stack.addArrangedSubview(makeSeparator()) }
                stack.addArrangedSubview(container(for: section))
            }
        }
        applySwitcherExpand()
    }

    /// Whether this panel's side renders content for the given zone.
    private func sideAllows(_ zone: Zone) -> Bool {
        switch side {
        case .full:  return true
        case .left:  return zone == .left
        case .right: return zone == .right
        }
    }

    private var switcherExpandConstraints: [NSLayoutConstraint] = []
    /// Required constant width on the blur, kept equal to the panel's on-screen width
    /// so autolayout can't balloon the content rect past the window (see contentView setup).
    private var blurWidthConstraint: NSLayoutConstraint?

    /// If the switcher is configured to expand, pull it OUT of its zone stack and
    /// pin its edges directly to the blur so it spans exactly the gap toward the
    /// expand edge — its buttons then stretch (.fillEqually) to fill it. No feedback
    /// loop, no overshoot. If not expanding, it stays a normal zone member.
    private func applySwitcherExpand() {
        NSLayoutConstraint.deactivate(switcherExpandConstraints)
        switcherExpandConstraints = []

        let expand = config.expand(for: .switcher)
        // Split mode pins the switcher to the right, so its content right-aligns too.
        let align = config.splitMode ? .right : config.align(for: .switcher)

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
        // In split mode the switcher owns its whole panel and is pinned right by the
        // zone constraints, so the expand pull-out is unnecessary.
        let needsArea = (expand != nil) && !isEmpty(.switcher) && !config.splitMode
        guard needsArea, let blur = contentView else { return }

        (switcherStack.superview as? NSStackView)?.removeView(switcherStack)
        if switcherStack.superview == nil { blur.addSubview(switcherStack) }
        switcherStack.translatesAutoresizingMaskIntoConstraints = false

        let gap: CGFloat = 16
        // The switcher is the SINGLE variable-width element. Fixed content pins to its
        // edge — launcher + icons left, Trash right — and the switcher fills the gap
        // between them. Bound it required between the two zones so it can never overlap
        // them or run off-screen; its breakable (.defaultHigh) chip widths compress to
        // fit. A .defaultHigh bias positions it toward the configured align edge when
        // there's slack. (The flanking zones own their own edge pins; the switcher just
        // takes what's left. The earlier off-screen bug was the blur ballooning past the
        // window width, fixed at contentView setup — not this logic.)
        let leadingBound = switcherStack.leadingAnchor.constraint(
            greaterThanOrEqualTo: leftZone.trailingAnchor, constant: gap)
        leadingBound.priority = .required
        let trailingBound = switcherStack.trailingAnchor.constraint(
            lessThanOrEqualTo: rightZone.leadingAnchor, constant: -gap)
        trailingBound.priority = .required

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
        // Include the active desktop so grouped mode re-orders (active box rightmost)
        // when the Space changes even if the window set is identical.
        let activeKey = grouped ? "\(activeDesktop())|\(config.groupedOrder.rawValue)" : ""
        let signature = "\(grouped)|\(activeKey)|" + windows.map { "\($0.windowNumber):\($0.displayTitle):\($0.desktopIndex)" }.joined(separator: "|")
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
            NSLog("switcher: side=\(side) panelW=\(Int(frame.width)) perRow=\(perRow) w=\(Int(buttonWidth)) shown=\(shown.count)/\(windows.count)")
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

        // Only show a box for desktops that actually have windows (skip empty ones).
        var activeDesktops = (1...nDesktops).filter { desk in
            windows.contains { $0.desktopIndex == desk }
        }
        guard !activeDesktops.isEmpty else { reassembleZones(); return }

        // Box ordering. `.default` keeps the natural desktop sequence (1, 2, 3, …);
        // `.currentToRight` moves the current desktop's box to the rightmost position
        // (closest to the right edge, fully visible without hovering).
        let current = activeDesktop()
        if config.groupedOrder == .currentToRight, let i = activeDesktops.firstIndex(of: current) {
            activeDesktops.remove(at: i)
            activeDesktops.append(current)
        }

        // Split the available width across the (non-empty) segments. If they can't all
        // fit even at the minimum segment width, drop the LEFTMOST (oldest) desktops —
        // the active desktop (rightmost) and nearest neighbours stay.
        let totalAvail = switcherAvailableWidth()
        let segGap = segmentRow.spacing
        let minSeg = WindowButton.minWidth + 12
        let maxFit = max(1, Int((totalAvail + segGap) / (minSeg + segGap)))
        if activeDesktops.count > maxFit {
            activeDesktops = Array(activeDesktops.suffix(maxFit))   // keep rightmost (active) ones
        }
        let n = CGFloat(activeDesktops.count)
        let rawSeg = (totalAvail - (n - 1) * segGap) / n
        let segWidth = max(minSeg, rawSeg)
        // Boxes fill (almost) the full bar height; leave a little room below for the
        // active desktop's underline (which sits outside the box).
        let segHeight = Self.barHeight - 14

        var newButtons: [WindowButton] = []
        for desk in activeDesktops {
            let deskWindows = windows.filter { $0.desktopIndex == desk }
            let seg = makeSegment(windows: deskWindows, width: segWidth, height: segHeight,
                                  isActive: desk == current, into: &newButtons)
            segmentRow.addArrangedSubview(seg)
        }
        reassembleZones()

        contentView?.layoutSubtreeIfNeeded()
        if ProcessInfo.processInfo.environment["TBP_DEBUG"] != nil {
            NSLog("GROUPED active=\(current) order=\(activeDesktops) panel=\(frame.size) avail=\(Int(switcherAvailableWidth())) segW=\(Int(segWidth))")
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18; ctx.allowsImplicitAnimation = true
            for b in newButtons { b.animator().alphaValue = 1 }
        }
    }

    /// A bordered box for one desktop, containing its windows across two inner rows.
    /// The active desktop gets an underline BELOW the box so it's easy to spot at a glance.
    private func makeSegment(windows: [WindowInfo], width: CGFloat, height: CGFloat,
                             isActive: Bool, into newButtons: inout [WindowButton]) -> NSView {
        let boxIsDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let box = NSView()
        box.wantsLayer = true
        // Thin theme-aware hairline around each group. separatorColor.cgColor is both very
        // faint and static (won't adapt to light/dark), so resolve a foreground tint within
        // our effectiveAppearance instead.
        box.layer?.borderColor = (boxIsDark ? NSColor.white : NSColor.black)
            .withAlphaComponent(0.18).cgColor
        box.layer?.borderWidth = 1
        box.layer?.cornerRadius = 5
        box.translatesAutoresizingMaskIntoConstraints = false

        // The active desktop gets an underline sitting OUTSIDE and just under the box
        // (like a tab/segmented-control selection). Color follows the bar's theme —
        // resolve the foreground color within our effectiveAppearance, since a CALayer's
        // cgColor is static and won't otherwise adapt to light/dark.
        var underline: NSView? = nil
        if isActive {
            let line = NSView()
            line.wantsLayer = true
            let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            line.layer?.backgroundColor = (isDark ? NSColor.white : NSColor.black)
                .withAlphaComponent(0.85).cgColor
            line.layer?.cornerRadius = 1.5
            line.translatesAutoresizingMaskIntoConstraints = false
            underline = line
        }

        // Wrap [box] + [underline] in a vertical container so the underline is genuinely
        // BELOW the bordered box, not drawn inside it.
        let segment = NSView()
        segment.translatesAutoresizingMaskIntoConstraints = false
        segment.addSubview(box)
        NSLayoutConstraint.activate([
            box.topAnchor.constraint(equalTo: segment.topAnchor),
            box.leadingAnchor.constraint(equalTo: segment.leadingAnchor),
            box.trailingAnchor.constraint(equalTo: segment.trailingAnchor),
        ])
        if let line = underline {
            segment.addSubview(line)
            NSLayoutConstraint.activate([
                line.topAnchor.constraint(equalTo: box.bottomAnchor, constant: 2),
                line.centerXAnchor.constraint(equalTo: box.centerXAnchor),
                line.heightAnchor.constraint(equalToConstant: 3),
                line.widthAnchor.constraint(equalTo: box.widthAnchor, multiplier: 0.5),
                line.bottomAnchor.constraint(equalTo: segment.bottomAnchor),
            ])
        } else {
            box.bottomAnchor.constraint(equalTo: segment.bottomAnchor).isActive = true
        }

        // Align the windows within the box per the switcher's align (right in split
        // mode, so they sit flush toward the right edge of the group).
        let segAlign: NSLayoutConstraint.Attribute
        switch (config.splitMode ? .right : config.align(for: .switcher)) {
        case .left:   segAlign = .leading
        case .center: segAlign = .centerX
        case .right:  segAlign = .trailing
        }
        let inner = NSStackView()
        inner.orientation = .vertical
        inner.alignment = segAlign
        inner.spacing = 3
        inner.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(inner)
        let widthC = box.widthAnchor.constraint(equalToConstant: width)
        widthC.priority = .defaultHigh   // yield rather than push the right zone off-screen
        // Pin the inner stack to the box edge matching the alignment so the content
        // actually hugs that side (right edge in split mode); the opposite edge is a
        // loose bound.
        var cons: [NSLayoutConstraint] = [
            widthC,
            box.heightAnchor.constraint(equalToConstant: height),
            inner.centerYAnchor.constraint(equalTo: box.centerYAnchor),
        ]
        if segAlign == .trailing {
            cons.append(inner.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -4))
            cons.append(inner.leadingAnchor.constraint(greaterThanOrEqualTo: box.leadingAnchor, constant: 4))
        } else {
            cons.append(inner.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 4))
            cons.append(inner.trailingAnchor.constraint(lessThanOrEqualTo: box.trailingAnchor, constant: -4))
        }
        NSLayoutConstraint.activate(cons)

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
        return segment
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

        // Split mode: the switcher spans from the launcher to the right edge. It may
        // overlap the Dock region in the middle, but that's fine — the bar rests below
        // the Dock and rises above it on hover, so all windows are reachable. This lets
        // every window show instead of capping to a narrow strip.
        if config.splitMode {
            return max(WindowButton.minWidth, screenW - zoneWidth(.left) - 2 * pad - 2 * gap)
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
        // Width must be BREAKABLE (see CLAUDE.md "switcher off right edge"): a required
        // width would win over the switcher's .defaultHigh trailing bound and shove the
        // chips — and the Trash zone — off the right edge. Keep it high but yielding.
        let widthC = widthAnchor.constraint(equalToConstant: width)
        widthC.priority = .defaultHigh
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            widthC,
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
        // Mac-native look: a subtle translucent rounded-rect "chip" (like a toolbar
        // item), slightly stronger when pressed, with a faint hairline border.
        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let fill: NSColor
        if isDark {
            fill = pressed ? NSColor(white: 1.0, alpha: 0.22) : NSColor(white: 1.0, alpha: 0.10)
        } else {
            fill = pressed ? NSColor(white: 0.0, alpha: 0.14) : NSColor(white: 1.0, alpha: 0.55)
        }
        let r = bounds.insetBy(dx: 1, dy: 2)
        let path = NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6)
        fill.setFill()
        path.fill()
        NSColor.separatorColor.withAlphaComponent(0.6).setStroke()
        path.lineWidth = 0.5
        path.stroke()
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
        // Anchor Y to the BAR's top edge, not the hovered item's rect — so every
        // tooltip (app icon, switcher chip, etc.) sits at the SAME height above the bar,
        // a single consistent place to read, like the Dock. Using the item rect made
        // tooltips land at different heights as item rects varied within the bar.
        let y = window.frame.maxY + 6
        panel.setFrame(NSRect(x: x, y: y, width: width, height: Self.height), display: true)
        panel.orderFront(nil)
    }

    func hide() {
        panel.orderOut(nil)
    }
}
