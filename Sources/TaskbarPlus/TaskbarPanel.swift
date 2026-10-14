import AppKit
import CSkyLight

/// A borderless, non-activating panel along the bottom edge of one screen, visible
/// on every Space: [Apps launcher + pinned + running icons] … [window switcher] …
/// [folders + Trash], with separators only between non-empty sections and a
/// running-dot under each running app. In taskbar-only mode only the launcher and
/// the switcher show. Each icon / window button hosts a right-click context menu.
final class TaskbarPanel: NSPanel {

    /// Standard: 60pt bar, 40pt icons, two rows of window buttons. Compact: one row.
    var iconSize: CGFloat { config.compact ? 26 : 40 }
    private var barHeight: CGFloat { config.compact ? 36 : 60 }
    /// Rows of window buttons the switcher (and each grouped box) may use.
    private var maxRows: Int { config.compact ? 1 : 2 }
    private static let horizontalPadding: CGFloat = 14

    private let config: LayoutConfig

    /// taskbar-only resting level (Dock floats on top) and the raised level (above Dock).
    private static let belowDock = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) - 1)
    private static let aboveDock = NSWindow.Level.statusBar

    // Three horizontal zones the sections are distributed into.
    private let leftZone = NSStackView()
    private let centerZone = NSStackView()
    private let rightZone = NSStackView()

    // Per-section content containers (filled by update*, then placed into a zone).
    private let launcherStack = NSStackView()
    private let launcherButton: LauncherButton
    private let pinnedStack = NSStackView()
    private let runningStack = NSStackView()
    private let othersStack = NSStackView()

    /// Win95-style task switcher: one button per window, across two rows.
    private let switcherStack = NSStackView()
    private let switcherRow1 = NSStackView()
    private let switcherRow2 = NSStackView()
    /// Grouped mode: a horizontal row of bordered per-desktop segment boxes.
    private let segmentRow = NSStackView()
    /// Grouped mode: a single persistent underline that slides to the active group's
    /// box (a tab-style selection indicator). Lives in the contentView, above the
    /// segment row, so it can animate its frame across box positions.
    private let activeIndicator = NSView()
    /// The boxes of the last grouped layout, by desktop index, so we can position the
    /// indicator and decide whether a Space switch is a pure slide (same boxes) or a
    /// structural change (snap, no animation).
    private var groupedBoxes: [Int: NSView] = [:]
    private var lastIndicatorDesktops: [Int] = []
    /// Width pin on the segment row so .fillEqually has the full switcher area to divide
    /// equally among the group boxes (otherwise the row hugs content and boxes shrink-wrap).
    private var segmentRowWidth: NSLayoutConstraint?

    /// The screen this bar lives on. Resolved fresh by frame on each reposition so
    /// it survives display reconfiguration.
    private let targetFrameOrigin: CGPoint

    init(screen: NSScreen, config: LayoutConfig) {
        self.targetFrameOrigin = screen.frame.origin
        self.config = config
        self.launcherButton = LauncherButton(compact: config.compact)
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        // Normal bar floats above everything (statusBar = 25 > dock = 20). Taskbar-only mode
        // rests JUST BELOW the Dock (dock − 1) so the Dock floats on top in the center;
        // hovering the bar raises it above the Dock (see mouseEntered/Exited).
        level = config.taskbarOnly ? Self.belowDock : .statusBar
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
        // Auto theme: grouped-box borders / the active underline bake a light- or
        // dark-specific CGColor, so rebuild the switcher when the system appearance flips.
        if config.theme == .auto {
            appearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.rebuildSwitcher(self.lastWindows, force: true)
                }
            }
        }

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
        let bh = blur.heightAnchor.constraint(equalToConstant: barHeight)
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
        segmentRow.distribution = .fill   // each box carries its own (window-count-weighted) width
        segmentRow.spacing = 8
        segmentRow.isHidden = true
        switcherStack.addArrangedSubview(segmentRow)

        // The sliding active-group indicator (manually framed, not in any stack).
        activeIndicator.wantsLayer = true
        activeIndicator.layer?.cornerRadius = 1.5
        activeIndicator.isHidden = true

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

        if config.taskbarOnly {
            // Taskbar-only mode: launcher pinned LEFT. With a bottom Dock the switcher
            // (right zone) is pinned RIGHT and grows leftward (it may run under the Dock,
            // which floats on top); otherwise it's centered (center zone, below). No zone-to-zone
            // no-overlap guards — those were pushing the right zone off-screen.
            leftZone.leadingAnchor.constraint(equalTo: blur.leadingAnchor, constant: Self.horizontalPadding).isActive = true
            let rightPin = rightZone.trailingAnchor.constraint(equalTo: blur.trailingAnchor, constant: -Self.horizontalPadding)
            rightPin.priority = .required
            // Hard floor: the right zone can't cross into the launcher (so its content
            // is forced to shrink/cap rather than overflow either edge).
            let floor = rightZone.leadingAnchor.constraint(greaterThanOrEqualTo: leftZone.trailingAnchor, constant: 16)
            floor.priority = .required
            // When the Dock isn't at the bottom, the switcher moves to the center zone,
            // centered on the SCREEN's midpoint (the bar itself may stop short of a side
            // Dock, so its own center is off by the Dock's width). Bounded required
            // between the launcher and the right edge; the centering is the bias.
            let centerX = centerZone.centerXAnchor.constraint(equalTo: blur.centerXAnchor)
            centerX.priority = .defaultHigh
            let centerFloor = centerZone.leadingAnchor.constraint(greaterThanOrEqualTo: leftZone.trailingAnchor, constant: 16)
            let centerCeil = centerZone.trailingAnchor.constraint(lessThanOrEqualTo: blur.trailingAnchor, constant: -Self.horizontalPadding)
            NSLayoutConstraint.activate([rightPin, floor, centerX, centerFloor, centerCeil])
            centerXConstraint = centerX
            reposition()
            NotificationCenter.default.addObserver(
                self, selector: #selector(reposition),
                name: NSApplication.didChangeScreenParametersNotification, object: nil)
            orderFront(nil)
            return
        }

        // Full bar: three zones (left edge / centered / right edge) with no-overlap
        // guards. Edge pins required; guards lower so they can't shove a zone
        // off-screen.
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
        let h = barHeight
        // Normal mode: sit in the visible area (above the Dock). Taskbar-only mode: sit at the
        // screen's true bottom edge, level with the Dock — the Dock floats on top in the
        // center (bar is below the Dock's window level), launcher/switcher show at edges.
        // Horizontally, taskbar-only mode still takes visibleFrame's span: with the Dock on the
        // left/right, visibleFrame excludes the Dock's strip, so the bar ends beside the
        // Dock instead of running under it (and covering it when raised on hover).
        // With a bottom Dock, visibleFrame spans the full width, so nothing changes.
        let vf = screen.visibleFrame
        let area = config.taskbarOnly
            ? NSRect(x: vf.minX, y: screen.frame.minY, width: vf.width, height: h)
            : vf
        setFrame(NSRect(x: area.minX, y: area.minY, width: area.width, height: h), display: true)
        // Clamp the blur (contentView) to exactly the panel width so its content can't
        // balloon the content rect past the window and clip the right zone.
        blurWidthConstraint?.constant = area.width
        // Screen midpoint relative to the bar's midpoint (non-zero with a side Dock).
        centerXConstraint?.constant = screen.frame.midX - area.midX
        // Taskbar-only layout depends on where the Dock is: re-mount the switcher if
        // the Dock moved to/from the bottom (bottom Dock → visibleFrame starts above
        // the screen's bottom edge).
        // Also re-fit the chips when the geometry they were sized for changed (bar
        // width, screen-center offset) — e.g. resolution change, side Dock resized.
        let atBottom = vf.minY > screen.frame.minY
        let geometry = "\(area.width)|\(centerXConstraint?.constant ?? 0)|\(atBottom)"
        if geometry != lastGeometry {
            let first = lastGeometry.isEmpty
            lastGeometry = geometry
            dockAtBottom = atBottom
            if !first { rebuildSwitcher(lastWindows, force: true) }   // recomputes width + reassembles zones
        }
        contentView?.layoutSubtreeIfNeeded()
        installHoverTracking()
    }

    private var hoverTracking: NSTrackingArea?

    /// Track the mouse over the whole bar:
    /// - Cursor: the bar is a non-key panel, so AppKit's cursor rects never reset the
    ///   cursor here. Crossing a maximised window's bottom edge (which sits right on
    ///   the bar) leaves its resize cursor showing over the bar; we force the arrow.
    /// - Taskbar-only mode: raise the bar above the Dock on hover. The Dock-covered
    ///   center won't deliver enter events (the Dock gets them) — only the visible
    ///   launcher/switcher edges trigger it, which is intended.
    private func installHoverTracking() {
        guard let view = contentView else { return }
        if let t = hoverTracking { view.removeTrackingArea(t) }
        let t = NSTrackingArea(rect: view.bounds,
                               options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        view.addTrackingArea(t)
        hoverTracking = t
    }

    override func mouseEntered(with event: NSEvent) {
        NSCursor.arrow.set()
        if config.taskbarOnly { level = Self.aboveDock }   // rise above the Dock
    }

    override func mouseMoved(with event: NSEvent) {
        NSCursor.arrow.set()
    }

    override func mouseExited(with event: NSEvent) {
        if config.taskbarOnly { level = Self.belowDock }   // settle back under the Dock
    }

    /// Drop back under the Dock if the hover raise is stale — e.g. the bar was hidden
    /// (fullscreen) while hovered: a window ignoring mouse events gets no mouseExited.
    func settleHoverLevel() {
        guard config.taskbarOnly else { return }
        if !frame.contains(NSEvent.mouseLocation) { level = Self.belowDock }
    }

    override func close() {
        TooltipWindow.shared.hide()
        super.close()
    }

    // MARK: - Update

    private var lastWindows: [WindowInfo] = []
    private var dockSignature = ""
    private var grouped = false
    /// Number of desktops to segment into (grouped mode). Provided by the controller.
    /// 1-based index of the active desktop (grouped mode underlines its box).
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
        // label, section, running-dot state, and the icon instance (icons are cached, so
        // a new instance means a real change: Trash empty↔full, or a refreshed app icon).
        let signature = items.map {
            let id: String
            switch $0.kind {
            case .app(_, let url): id = url.path
            case .folder(let url): id = url.path
            case .trash: id = "trash"
            }
            return "\($0.section):\(id):\($0.label):\($0.isRunning):\(ObjectIdentifier($0.icon).hashValue)"
        }.joined(separator: "|")
        guard signature != dockSignature else { return }
        dockSignature = signature
        // The hovered icon may be about to be removed; removed views get no mouseExited.
        TooltipWindow.shared.hide()

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

    /// Whether the real Dock sits along the bottom of this panel's screen (set in
    /// reposition()). Taskbar-only mode pins the switcher right only then; with a
    /// side Dock (or none on this screen) the switcher is centered instead.
    private var dockAtBottom = true
    /// Taskbar-only mode: offsets the center zone to the screen's midpoint.
    private var centerXConstraint: NSLayoutConstraint?
    private var appearanceObservation: NSKeyValueObservation?
    /// Geometry the switcher chips were last sized for (see reposition()).
    private var lastGeometry = ""

    /// Zone a section renders in on this panel. Like `config.effectiveZone`, except
    /// that taskbar-only mode centers the switcher when the Dock isn't at the bottom.
    private func effectiveZone(for section: Section) -> Zone {
        if config.taskbarOnly && section == .switcher && !dockAtBottom { return .center }
        return config.effectiveZone(for: section)
    }

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
            let members = order.filter {
                config.sectionIsVisible($0) && effectiveZone(for: $0) == zoneKind && !isEmpty($0)
            }
            for (i, section) in members.enumerated() {
                if i > 0 { stack.addArrangedSubview(makeSeparator()) }
                stack.addArrangedSubview(container(for: section))
            }
        }
        applySwitcherExpand()
    }

    private var switcherExpandConstraints: [NSLayoutConstraint] = []
    /// Required constant width on the blur, kept equal to the panel's on-screen width
    /// so autolayout can't balloon the content rect past the window (see contentView setup).
    private var blurWidthConstraint: NSLayoutConstraint?

    /// Replace-Dock mode: pull the switcher OUT of its zone stack and pin it directly
    /// to the blur so it spans exactly the gap between the left icons and the right
    /// zone. No feedback loop, no overshoot. In taskbar-only mode it stays a normal
    /// zone member.
    private func applySwitcherExpand() {
        NSLayoutConstraint.deactivate(switcherExpandConstraints)
        switcherExpandConstraints = []

        switcherRow1.distribution = .fill
        switcherRow2.distribution = .fill
        // Button rows start at the switcher area's left edge.
        switcherStack.alignment = .leading

        // The switcher always expands to fill the gap between the left icons and the
        // right zone (Replace-Dock mode). In taskbar-only mode it stays a member of its
        // zone instead: the zone constraints pin it right or center it.
        let needsArea = !isEmpty(.switcher) && !config.taskbarOnly
        guard needsArea, let blur = contentView else { return }

        (switcherStack.superview as? NSStackView)?.removeView(switcherStack)
        if switcherStack.superview == nil { blur.addSubview(switcherStack) }
        switcherStack.translatesAutoresizingMaskIntoConstraints = false

        let gap: CGFloat = 16
        // The switcher is the SINGLE variable-width element. Fixed content pins to its
        // edge — launcher + icons left, Trash right — and the switcher fills the gap
        // between them. Bound it required between the two zones so it can never overlap
        // them or run off-screen; its breakable (.defaultHigh) chip widths compress to
        // fit. A .defaultHigh bias keeps it at the left end of that gap when there's
        // slack. (The flanking zones own their own edge pins; the switcher just
        // takes what's left. The earlier off-screen bug was the blur ballooning past the
        // window width, fixed at contentView setup — not this logic.)
        let leadingBound = switcherStack.leadingAnchor.constraint(
            greaterThanOrEqualTo: leftZone.trailingAnchor, constant: gap)
        leadingBound.priority = .required
        let trailingBound = switcherStack.trailingAnchor.constraint(
            lessThanOrEqualTo: rightZone.leadingAnchor, constant: -gap)
        trailingBound.priority = .required

        let bias = switcherStack.leadingAnchor.constraint(equalTo: leftZone.trailingAnchor, constant: gap)
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
        // Include the active desktop so grouped mode re-renders (active-desktop
        // indicator) when the Space changes even if the window set is identical.
        let activeKey = grouped ? "\(activeDesktop())" : ""
        let signature = "\(grouped)|\(activeKey)|" + windows.map { "\($0.windowNumber):\($0.displayTitle):\($0.desktopIndex)" }.joined(separator: "|")
        if !force, signature == switcherSignature { return }
        switcherSignature = signature
        // The hovered chip may be about to be removed; removed views get no mouseExited.
        TooltipWindow.shared.hide()

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
        activeIndicator.isHidden = true   // only shown in grouped mode
        lastIndicatorDesktops = []

        let layout = fillRows([switcherRow1, switcherRow2], with: windows, avail: switcherAvailableWidth())
        let newButtons = layout.buttons
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
            NSLog("switcher: panelW=\(Int(frame.width)) perRow=\(layout.perRow) w=\(Int(layout.width)) shown=\(newButtons.count)/\(windows.count)")
        }
    }

    /// Lay `windows` out as buttons over up to `maxRows` of `rows` within `avail`
    /// width: full width when they fit, else shrunk (down to `WindowButton.minWidth`);
    /// any that still don't fit go into a trailing "» N" overflow button (so the
    /// newest windows never silently disappear). Returns the new window buttons.
    private func fillRows(_ rows: [NSStackView], with windows: [WindowInfo],
                          avail: CGFloat) -> (buttons: [WindowButton], perRow: Int, width: CGFloat) {
        let spacing = rows[0].spacing
        let nRows = min(maxRows, rows.count)
        func fit(at width: CGFloat) -> Int { max(1, Int((avail + spacing) / (width + spacing))) }
        let fitPreferred = fit(at: WindowButton.preferredWidth)   // per row at full width
        let capacity = fit(at: WindowButton.minWidth) * nRows    // absolute max, all rows

        let overflow = windows.count > capacity
        let slots = overflow ? capacity : windows.count            // incl. the overflow button
        let perRow: Int            // slots in the (fuller) top row
        let width: CGFloat
        if slots <= fitPreferred {
            // Everything fits on ONE row at full width — fill row 1 only.
            perRow = slots
            width = WindowButton.preferredWidth
        } else if slots <= fitPreferred * nRows {
            // Needs a second row, but still fits at full width — balance the rows.
            perRow = Int(ceil(Double(slots) / Double(nRows)))
            width = WindowButton.preferredWidth
        } else {
            // More than the rows hold at full width → shrink to fit.
            perRow = Int(ceil(Double(slots) / Double(nRows)))
            let raw = (avail - CGFloat(perRow - 1) * spacing) / CGFloat(perRow)
            width = max(WindowButton.minWidth, min(WindowButton.preferredWidth, raw))
        }
        func row(forSlot i: Int) -> NSStackView { rows[i < perRow ? 0 : nRows - 1] }

        let shown = overflow ? Array(windows.prefix(capacity - 1)) : windows
        var buttons: [WindowButton] = []
        for (i, w) in shown.enumerated() {
            let btn = WindowButton(info: w, panel: self, width: width)
            btn.alphaValue = 0   // start hidden; faded in by the caller
            row(forSlot: i).addArrangedSubview(btn)
            buttons.append(btn)
        }
        if overflow {
            let rest = Array(windows.dropFirst(shown.count))
            row(forSlot: shown.count).addArrangedSubview(OverflowButton(windows: rest, panel: self))
        }
        for r in rows.dropFirst() { r.isHidden = r.arrangedSubviews.isEmpty }
        return (buttons, perRow, width)
    }

    /// No boxes to show: hide the active-desktop underline (it would otherwise stay
    /// where the last box was) and forget the old boxes.
    private func clearGroupedIndicator() {
        activeIndicator.isHidden = true
        groupedBoxes = [:]
        lastIndicatorDesktops = []
    }

    /// Key of the grouped box for windows on no numbered desktop (fullscreen-app
    /// Spaces, or Space unknown). Shown last; never the "active" box.
    private static let otherDesktop = 0

    /// Grouped mode: one bordered box per desktop that has windows (in desktop order,
    /// plus a last box for windows on fullscreen-app Spaces), each holding that
    /// desktop's windows in up to `maxRows` internal rows.
    private func rebuildGrouped(_ windows: [WindowInfo]) {
        switcherRow1.isHidden = true
        switcherRow2.isHidden = true
        segmentRow.isHidden = false

        let current = activeDesktop()
        var desks = Set(windows.map { $0.desktopIndex }).sorted {
            // Numbered desktops ascending; the "other" box last.
            ($0 == Self.otherDesktop ? Int.max : $0) < ($1 == Self.otherDesktop ? Int.max : $1)
        }
        guard !desks.isEmpty else { clearGroupedIndicator(); reassembleZones(); return }

        // If the boxes can't all fit even at the minimum width, keep the ACTIVE desktop
        // and its nearest neighbours (the "other" box counts as farthest).
        let totalAvail = switcherAvailableWidth()
        let segGap = segmentRow.spacing
        let minSeg = WindowButton.minWidth + 12
        let maxFit = max(1, Int((totalAvail + segGap) / (minSeg + segGap)))
        if desks.count > maxFit {
            func distance(_ d: Int) -> Int { d == Self.otherDesktop ? Int.max : abs(d - current) }
            let keep = Set(desks.sorted { (distance($0), $0) < (distance($1), $1) }.prefix(maxFit))
            desks = desks.filter { keep.contains($0) }
        }
        // Box widths: each gets the minimum, and the rest is shared in proportion to
        // its window count — a busy desktop gets room, a 1-window desktop doesn't
        // hog an equal share.
        let counts = desks.map { d in windows.filter { $0.desktopIndex == d }.count }
        let n = CGFloat(desks.count)
        let free = max(0, totalAvail - (n - 1) * segGap - n * minSeg)
        let totalCount = CGFloat(max(1, counts.reduce(0, +)))
        let widths = counts.map { minSeg + free * CGFloat($0) / totalCount }
        // Boxes fill (almost) the full bar height; leave a little room below for the
        // active desktop's underline (which sits outside the box).
        let segHeight = barHeight - (config.compact ? 8 : 14)

        var newButtons: [WindowButton] = []
        groupedBoxes = [:]
        for (desk, width) in zip(desks, widths) {
            let deskWindows = windows.filter { $0.desktopIndex == desk }
            let (seg, box) = makeSegment(windows: deskWindows, width: width, height: segHeight,
                                         into: &newButtons)
            segmentRow.addArrangedSubview(seg)
            groupedBoxes[desk] = box
        }
        // Pin the segment row to the boxes' total width.
        let rowWidth = (n - 1) * segGap + widths.reduce(0, +)
        if let c = segmentRowWidth { c.constant = rowWidth }
        else {
            let c = segmentRow.widthAnchor.constraint(equalToConstant: rowWidth)
            c.priority = .defaultHigh
            c.isActive = true
            segmentRowWidth = c
        }
        reassembleZones()

        contentView?.layoutSubtreeIfNeeded()
        // Slide the active-group indicator to the current desktop's box. Animate only
        // when the set of boxes is unchanged (a pure desktop switch); snap otherwise
        // (boxes were added/removed/reordered, so a slide would look wrong).
        let animate = desks == lastIndicatorDesktops
        lastIndicatorDesktops = desks
        updateActiveIndicator(activeDesktop: current, animate: animate)

        if ProcessInfo.processInfo.environment["TBP_DEBUG"] != nil {
            NSLog("GROUPED active=\(current) order=\(desks) avail=\(Int(totalAvail)) widths=\(widths.map { Int($0) })")
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18; ctx.allowsImplicitAnimation = true
            for b in newButtons { b.animator().alphaValue = 1 }
        }
    }

    /// Position (and optionally slide) the persistent active-group indicator under the
    /// active desktop's box. The indicator lives in the contentView so it can animate
    /// its frame across box positions independently of the stack-laid segment row.
    private func updateActiveIndicator(activeDesktop: Int, animate: Bool) {
        guard grouped, let blur = contentView, let box = groupedBoxes[activeDesktop] else {
            activeIndicator.isHidden = true
            return
        }
        if activeIndicator.superview !== blur {
            activeIndicator.removeFromSuperview()
            blur.addSubview(activeIndicator)
        }
        // Theme-aware color (CALayer cgColor is static, so set it each time).
        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        activeIndicator.layer?.backgroundColor = (isDark ? NSColor.white : NSColor.black)
            .withAlphaComponent(0.85).cgColor

        // Target frame: centered under the box, half its width, 3pt tall, just below it.
        let boxFrame = box.convert(box.bounds, to: blur)
        let w = boxFrame.width * 0.5
        let target = NSRect(x: boxFrame.midX - w / 2, y: boxFrame.minY - 5, width: w, height: 3)

        activeIndicator.isHidden = false
        if animate && activeIndicator.frame != .zero {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.22
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                ctx.allowsImplicitAnimation = true
                activeIndicator.animator().frame = target
            }
        } else {
            activeIndicator.frame = target   // snap (first show / structural change)
        }
    }

    /// A bordered box for one desktop, containing its windows across two inner rows.
    /// Returns the wrapper segment and its inner box (the box is what the sliding active
    /// indicator aligns to). The active indicator itself is positioned separately.
    private func makeSegment(windows: [WindowInfo], width: CGFloat, height: CGFloat,
                             into newButtons: inout [WindowButton]) -> (segment: NSView, box: NSView) {
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

        // The active desktop's underline is NOT drawn here anymore — a single persistent
        // `activeIndicator` view slides to the active box (see updateActiveIndicator), so
        // it can animate across box positions on a desktop switch. We just leave room
        // below the box for it via the segment wrapper.

        // Wrap the box in a container that reserves the underline strip below it, so all
        // boxes (active or not) share the same top edge and height.
        let segment = NSView()
        segment.translatesAutoresizingMaskIntoConstraints = false
        segment.addSubview(box)
        NSLayoutConstraint.activate([
            box.topAnchor.constraint(equalTo: segment.topAnchor),
            box.leadingAnchor.constraint(equalTo: segment.leadingAnchor),
            box.trailingAnchor.constraint(equalTo: segment.trailingAnchor),
            box.bottomAnchor.constraint(equalTo: segment.bottomAnchor, constant: -5),
        ])

        let inner = NSStackView()
        inner.orientation = .vertical
        inner.alignment = .leading
        inner.spacing = 3
        inner.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(inner)
        // This box's width (weighted by window count in rebuildGrouped). Breakable,
        // like every switcher width (see CLAUDE.md "switcher off right edge").
        let widthC = segment.widthAnchor.constraint(equalToConstant: width)
        widthC.priority = .defaultHigh
        NSLayoutConstraint.activate([
            widthC,
            box.heightAnchor.constraint(equalToConstant: height),
            inner.centerYAnchor.constraint(equalTo: box.centerYAnchor),
            inner.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 4),
            inner.trailingAnchor.constraint(lessThanOrEqualTo: box.trailingAnchor, constant: -4),
        ])

        let row1 = NSStackView(); row1.orientation = .horizontal; row1.spacing = 4
        let row2 = NSStackView(); row2.orientation = .horizontal; row2.spacing = 4
        inner.addArrangedSubview(row1); inner.addArrangedSubview(row2)
        newButtons += fillRows([row1, row2], with: windows, avail: width - 8).buttons
        return (segment, box)
    }

    /// Width available to ONE switcher row, given the space the other sections
    /// consume. Buttons are sized to fill this so the strip never overflows the screen.
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

        // Taskbar-only mode: the switcher spans from the launcher to the right edge. It may
        // overlap the Dock region in the middle, but that's fine — the bar rests below
        // the Dock and rises above it on hover, so all windows are reachable. This lets
        // every window show instead of capping to a narrow strip.
        if config.taskbarOnly {
            if !dockAtBottom {
                // Centered on the screen's midpoint: the width is twice the room on
                // the tighter side (launcher on the left, bar edge on the right).
                let mid = frame.width / 2 + (centerXConstraint?.constant ?? 0)
                let half = min(mid - (pad + zoneWidth(.left) + gap), screenW - pad - mid)
                return max(WindowButton.minWidth, 2 * half)
            }
            return max(WindowButton.minWidth, screenW - zoneWidth(.left) - 2 * pad - 2 * gap)
        }

        // Replace-Dock mode: the switcher expands over the full gap between the left
        // icons and the right zone (folders + Trash).
        return max(WindowButton.minWidth, screenW - zoneWidth(.left) - zoneWidth(.right) - 2 * pad - 2 * gap)
    }

    private func dockStacks() -> [NSStackView] { [pinnedStack, runningStack, othersStack] }

    /// Returns true if the window is on a Space other than a currently-visible one.
    var onIsWindowOnOtherSpace: ((Int) -> Bool)?

    /// Raise a specific window (task-switcher click).
    func raiseWindow(_ info: WindowInfo) {
        let onOther = onIsWindowOnOtherSpace?(info.windowNumber) ?? false
        // The private Space-switch APIs are dead on macOS 26, but synthesizing the
        // "switch to Desktop N" shortcut (Ctrl+N) still works. Switch to the window's
        // desktop, then raise it once it's on-screen (AX can only see windows on the
        // current Space). If that shortcut is off/missing, just raise (activates the app).
        if onOther, info.desktopIndex >= 1, DesktopSwitcher.switchTo(desktop: info.desktopIndex) {
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
    private let size: CGFloat
    private var iconRect: NSRect {
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
        self.size = panel.iconSize
        super.init(frame: .zero)

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
    private var hovered = false

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
        hovered = true; needsDisplay = true   // event-driven; no cost when idle
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
        hovered = false; needsDisplay = true
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

        // Hover highlight: a rounded backing behind the icon, like the Dock's hover
        // state. App icons are usually full-bleed, so a backing exactly the icon size
        // is hidden — extend it slightly PAST the icon so a visible rounded halo/rim
        // shows around it. Drawn before the imageView subview composites on top.
        // Purely event-driven — only redraws on enter/exit.
        if hovered {
            let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            (isDark ? NSColor(white: 1.0, alpha: 0.20) : NSColor(white: 0.0, alpha: 0.14)).setFill()
            let halo = iconRect.insetBy(dx: -3, dy: -3)
            NSBezierPath(roundedRect: halo, xRadius: 9, yRadius: 9).fill()
        }

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
    private var hovered = false

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
        hovered = true; needsDisplay = true   // event-driven; no cost when idle
    }

    override func mouseExited(with event: NSEvent) {
        TooltipWindow.shared.hide()
        hovered = false; needsDisplay = true
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
        // Three intensities: idle → hovered → pressed. Hover is a clear, noticeable
        // bump so the button under the cursor reads as "live" (like the Dock / a
        // toolbar item). In light mode hover tints toward the accent for visibility.
        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let fill: NSColor
        if isDark {
            fill = pressed ? NSColor(white: 1.0, alpha: 0.30)
                 : hovered ? NSColor(white: 1.0, alpha: 0.24)
                           : NSColor(white: 1.0, alpha: 0.10)
        } else {
            fill = pressed ? NSColor(white: 0.0, alpha: 0.18)
                 : hovered ? NSColor(white: 0.0, alpha: 0.10)
                           : NSColor(white: 1.0, alpha: 0.55)
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

/// Win95 Start-style launcher: a button that pops up the application menu
/// (Pre-Installed / Installed / Dock groups — see AppMenuBuilder). The menu is cached and
/// rebuilt only when the app folders or Dock pins change.
final class LauncherButton: NSView {

    private let builder = AppMenuBuilder()
    private let button = NSButton()
    private let desktopButton = NSButton()
    /// Small magnifier that opens Spotlight, beside the desktop label.
    private let spotlightButton = NSButton()

    /// Called when the desktop label is clicked, to cycle this desktop → all → grouped.
    var onToggleMode: (() -> Void)?

    /// Compact (1-row bar): the desktop label sits right of the Apps button instead
    /// of beneath it.
    init(compact: Bool) {
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
        // Never let the "Apps" title get squeezed to "…": resist compression and don't
        // stretch. The launcher hugs this natural width.
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.setContentHuggingPriority(.required, for: .horizontal)
        addSubview(button)

        // The desktop label is a flat, borderless button — click toggles the mode.
        desktopButton.isBordered = false
        desktopButton.bezelStyle = .inline
        desktopButton.font = .systemFont(ofSize: 9)
        desktopButton.contentTintColor = .secondaryLabelColor
        desktopButton.target = self
        desktopButton.action = #selector(toggleMode)
        desktopButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(desktopButton)

        // Flat magnifier, same muted style as the desktop label.
        let glass = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Spotlight")
        spotlightButton.image = glass?.withSymbolConfiguration(
            .init(pointSize: compact ? 11 : 9, weight: .semibold))
        spotlightButton.isBordered = false
        spotlightButton.bezelStyle = .inline
        spotlightButton.imagePosition = .imageOnly
        spotlightButton.contentTintColor = .secondaryLabelColor
        spotlightButton.target = self
        spotlightButton.action = #selector(openSpotlight)
        spotlightButton.translatesAutoresizingMaskIntoConstraints = false
        spotlightButton.setContentHuggingPriority(.required, for: .horizontal)
        addSubview(spotlightButton)

        if compact {
            desktopButton.font = .systemFont(ofSize: 10)
            NSLayoutConstraint.activate([
                heightAnchor.constraint(equalToConstant: 26),
                // [Apps] 🔍 Desk 1 — all on one line.
                button.centerYAnchor.constraint(equalTo: centerYAnchor),
                button.leadingAnchor.constraint(equalTo: leadingAnchor),
                button.heightAnchor.constraint(equalToConstant: 24),
                spotlightButton.centerYAnchor.constraint(equalTo: centerYAnchor),
                spotlightButton.leadingAnchor.constraint(equalTo: button.trailingAnchor, constant: 4),
                desktopButton.centerYAnchor.constraint(equalTo: centerYAnchor),
                desktopButton.leadingAnchor.constraint(equalTo: spotlightButton.trailingAnchor, constant: 2),
                desktopButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            ])
            return
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 40),
            // Apps button on top; beneath it, 🔍 then the desktop label.
            button.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.trailingAnchor.constraint(equalTo: trailingAnchor),
            button.heightAnchor.constraint(equalToConstant: 24),
            spotlightButton.centerYAnchor.constraint(equalTo: desktopButton.centerYAnchor),
            spotlightButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            desktopButton.topAnchor.constraint(equalTo: button.bottomAnchor, constant: 0),
            desktopButton.leadingAnchor.constraint(equalTo: spotlightButton.trailingAnchor, constant: 2),
            desktopButton.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    @objc private func openSpotlight() { SystemShortcut.openSpotlight() }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func toggleMode() { onToggleMode?() }

    /// Update the desktop-name label (e.g. "Desk 2" or "All Desks").
    func setDesktop(_ name: String) {
        desktopButton.title = name
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { builder.prewarm() }   // build the menu before first click
    }

    // Tooltips for the desktop label and the Spotlight button. The bar is a non-key
    // panel, so AppKit's `.toolTip` never fires — use the shared custom TooltipWindow
    // (see CLAUDE.md).
    private var tooltipTracking: [NSTrackingArea] = []
    private lazy var tooltips: [(view: NSView, text: String)] = [
        (desktopButton, "Click to cycle: this desktop / all desktops / grouped"),
        (spotlightButton, "Spotlight search"),
    ]

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        tooltipTracking.forEach { removeTrackingArea($0) }
        tooltipTracking = tooltips.indices.map { i in
            let t = NSTrackingArea(rect: tooltips[i].view.frame, options: [.mouseEnteredAndExited, .activeAlways],
                                   owner: self, userInfo: ["tip": i])
            addTrackingArea(t)
            return t
        }
    }

    override func mouseEntered(with event: NSEvent) {
        guard let i = event.trackingArea?.userInfo?["tip"] as? Int, tooltips.indices.contains(i) else { return }
        TooltipWindow.shared.show(tooltips[i].text, below: tooltips[i].view)
    }

    override func mouseExited(with event: NSEvent) {
        TooltipWindow.shared.hide()
    }

    @objc private func showMenu() {
        // Cached: only rebuilds when /Applications actually changed.
        let menu = builder.menu()
        // Pop up just above the button (the bar sits at the screen's bottom edge).
        let origin = NSPoint(x: 0, y: bounds.height + 4)
        menu.popUp(positioning: nil, at: origin, in: self)
    }
}

/// "» N" button at the end of a switcher row (or grouped box) holding the windows
/// that didn't fit; click lists them in a menu, choosing one raises it.
final class OverflowButton: NSButton {
    private let windows: [WindowInfo]
    private weak var panel: TaskbarPanel?

    init(windows: [WindowInfo], panel: TaskbarPanel) {
        self.windows = windows
        self.panel = panel
        super.init(frame: .zero)
        title = "» \(windows.count)"
        font = .boldSystemFont(ofSize: 11)
        bezelStyle = .rounded
        controlSize = .small
        target = self
        action = #selector(showList)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 24),
            widthAnchor.constraint(greaterThanOrEqualToConstant: WindowButton.minWidth),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func showList() {
        let menu = NSMenu()
        for (i, w) in windows.enumerated() {
            let item = NSMenuItem(title: w.displayTitle, action: #selector(pick(_:)), keyEquivalent: "")
            item.target = self
            item.tag = i
            let icon = w.icon.copy() as? NSImage
            icon?.size = NSSize(width: 16, height: 16)
            item.image = icon
            menu.addItem(item)
        }
        // Pop up just above the button (the bar sits at the screen's bottom edge).
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + 4), in: self)
    }

    @objc private func pick(_ sender: NSMenuItem) {
        guard windows.indices.contains(sender.tag) else { return }
        panel?.raiseWindow(windows[sender.tag])
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
        // Keep it on the bar's screen (long titles at the far edges would otherwise
        // run off-screen or onto the next display).
        let bounds = window.screen?.frame ?? onScreen
        let x = min(max(onScreen.midX - width / 2, bounds.minX + 4), bounds.maxX - width - 4)
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
