import CoreGraphics

public struct TilingOptions: Equatable, Sendable {
    public var innerGap: CGFloat
    public var outerGap: CGFloat
    public var reserved: Insets
    public var defaultLayout: LayoutKind
    public var scrollingDefaultWidth: CGFloat

    public init(
        innerGap: CGFloat = 8,
        outerGap: CGFloat = 8,
        reserved: Insets = Insets(),
        defaultLayout: LayoutKind = .dwindle,
        scrollingDefaultWidth: CGFloat = 0.5
    ) {
        self.innerGap = innerGap
        self.outerGap = outerGap
        self.reserved = reserved
        self.defaultLayout = defaultLayout
        self.scrollingDefaultWidth = scrollingDefaultWidth
    }
}

/// What the windows should look like right now. A full snapshot, not a diff.
public struct LayoutPlan: Equatable {
    /// Windows that should be visible, and where.
    public var frames: [WindowID: CGRect] = [:]
    /// Windows to park out of sight, and the monitor to park them on.
    public var hidden: [WindowID: MonitorID] = [:]
    public var focused: WindowID?

    public init() {}
}

/// The window manager's brain: which windows exist, which workspace they are on and where they
/// go. It never talks to macOS, so all of its behaviour can be tested without moving a real window.
public final class TilingEngine {
    public private(set) var monitors: [Monitor] = []
    public private(set) var workspaces: [Int: Workspace] = [:]
    public private(set) var focusedMonitor: MonitorID?
    public var options: TilingOptions

    /// Workspace showing on each monitor.
    private var active: [MonitorID: Int] = [:]
    private var previousWorkspace: Int?
    /// Where floating windows belong while their workspace is hidden.
    private var floatFrames: [WindowID: CGRect] = [:]
    private var parkedFloats: Set<WindowID> = []
    /// Looks up a window's real frame, needed to remember floats before hiding them.
    private let currentFrame: (WindowID) -> CGRect?
    private(set) var lastFrames: [WindowID: CGRect] = [:]
    /// Windows that belong to the scratchpad, whether currently shown or tucked away.
    private var scratchpadMembers: Set<WindowID> = []
    /// Never shown as a workspace. Its windows visit the active workspace as floats.
    static let scratchpadID = 0

    public init(options: TilingOptions = TilingOptions(), currentFrame: @escaping (WindowID) -> CGRect? = { _ in nil }) {
        self.options = options
        self.currentFrame = currentFrame
    }

    // MARK: - Lookups

    public var activeWorkspace: Workspace? {
        guard let focusedMonitor, let id = active[focusedMonitor] else { return nil }
        return workspaces[id]
    }

    public var focusedWindow: WindowID? { activeWorkspace?.focused }

    public func workspace(containing id: WindowID) -> Workspace? {
        workspaces.values.first { $0.contains(id) }
    }

    public func isTracked(_ id: WindowID) -> Bool { workspace(containing: id) != nil }

    public func isVisible(_ workspace: Workspace) -> Bool { active.values.contains(workspace.id) }

    public var occupiedWorkspaces: [Int] {
        workspaces.values.filter { !$0.isEmpty && $0.id != Self.scratchpadID }.map(\.id).sorted()
    }

    public func activeWorkspaceID(on monitor: MonitorID) -> Int? { active[monitor] }

    private func workspace(_ id: Int) -> Workspace {
        if let existing = workspaces[id] { return existing }
        let created = Workspace(id: id, layout: options.defaultLayout)
        created.strip.defaultWidth = options.scrollingDefaultWidth
        workspaces[id] = created
        return created
    }

    private func monitor(_ id: MonitorID?) -> Monitor? {
        monitors.first { $0.id == id }
    }

    private func monitorID(showing workspace: Int) -> MonitorID? {
        active.first { $0.value == workspace }?.key
    }

    private func bounds(of monitor: Monitor) -> CGRect {
        let gap = options.outerGap
        return monitor.visibleFrame
            .inset(by: options.reserved)
            .inset(by: Insets(top: gap, left: gap, bottom: gap, right: gap))
    }

    private func monitor(at point: CGPoint) -> Monitor? {
        monitors.first { $0.frame.contains(point) }
    }

    /// The monitor a rectangle mostly sits on. Parked windows have their center off every
    /// display, so fall back to the closest one.
    public func monitorID(nearest rect: CGRect) -> MonitorID? {
        if let containing = monitor(at: rect.center) { return containing.id }
        func distance(_ monitor: Monitor) -> CGFloat {
            let dx = max(monitor.frame.minX - rect.midX, 0, rect.midX - monitor.frame.maxX)
            let dy = max(monitor.frame.minY - rect.midY, 0, rect.midY - monitor.frame.maxY)
            return dx * dx + dy * dy
        }
        return monitors.min { distance($0) < distance($1) }?.id
    }

    // MARK: - Displays

    /// Updates the display list. Workspaces stay attached to a display that reappears, and every
    /// connected display always shows some workspace.
    public func setMonitors(_ newMonitors: [Monitor]) {
        monitors = newMonitors.sorted { ($0.frame.minX, $0.frame.minY) < ($1.frame.minX, $1.frame.minY) }
        let ids = Set(monitors.map(\.id))
        active = active.filter { ids.contains($0.key) }

        for monitor in monitors where active[monitor.id] == nil {
            let shown = Set(active.values)
            let returning = workspaces.values
                .filter { $0.monitor == monitor.id && !shown.contains($0.id) && !$0.isEmpty }
                .map(\.id)
                .min()
            let next = returning ?? firstAvailableWorkspace(excluding: shown)
            active[monitor.id] = next
            workspace(next).monitor = monitor.id
        }
        if focusedMonitor == nil || !ids.contains(focusedMonitor!) {
            focusedMonitor = monitors.first?.id
        }
    }

    private func firstAvailableWorkspace(excluding shown: Set<Int>) -> Int {
        // Prefer an empty workspace, so a new display doesn't pull windows away from another one.
        for id in 1...9 where !shown.contains(id) && (workspaces[id]?.isEmpty ?? true) {
            return id
        }
        return (1...9).first { !shown.contains($0) } ?? 1
    }

    // MARK: - Window lifecycle

    /// Starts managing a window. It joins the workspace showing on `monitor`, or the focused monitor.
    /// A `workspace` from an app rule takes priority over the monitor.
    public func addWindow(
        _ id: WindowID,
        floating: Bool = false,
        monitor: MonitorID? = nil,
        workspace requested: Int? = nil,
        focus: Bool = true
    ) {
        guard !isTracked(id),
              let target = requested ?? monitor.flatMap({ active[$0] }) ?? focusedMonitor.flatMap({ active[$0] })
        else { return }
        let ws = workspace(target)
        if floating {
            ws.insertFloating(id)
        } else {
            ws.insertTiled(id)
        }
        if focus { ws.setFocused(id) }
    }

    public func removeWindow(_ id: WindowID) {
        workspace(containing: id)?.remove(id)
        floatFrames[id] = nil
        parkedFloats.remove(id)
        scratchpadMembers.remove(id)
        tightenScrolling()
    }

    /// The window is on another native Space, minimized or hidden. It keeps its slot.
    public func suspendWindow(_ id: WindowID) {
        workspace(containing: id)?.suspend(id)
        tightenScrolling()
    }

    public func resumeWindow(_ id: WindowID) {
        workspace(containing: id)?.resume(id)
    }

    public func isSuspended(_ id: WindowID) -> Bool {
        workspace(containing: id)?.suspended.contains(id) ?? false
    }

    /// macOS moved focus, by a click, Cmd-Tab or the Dock. The engine follows, switching to the
    /// window's workspace if it was hidden.
    public func focusChanged(to id: WindowID) {
        if workspaces[Self.scratchpadID]?.contains(id) == true { showScratchpad() }
        guard let ws = workspace(containing: id), !ws.suspended.contains(id) else { return }
        if !isVisible(ws) { show(ws.id) }
        ws.setFocused(id)
        if ws.fullscreen != id, !ws.isFloating(id) { ws.fullscreen = nil }
        focusedMonitor = monitorID(showing: ws.id) ?? focusedMonitor
    }

    private func tightenScrolling() {
        for (monitorID, workspaceID) in active {
            guard let monitor = monitor(monitorID), let ws = workspaces[workspaceID] else { continue }
            ws.strip.tighten(viewport: bounds(of: monitor).width, gap: options.innerGap, suspended: ws.suspended)
        }
    }

    // MARK: - Workspaces

    private func show(_ id: Int) {
        let target = workspace(id)
        let destination = target.monitor.flatMap { monitor($0) }?.id ?? focusedMonitor
        guard let destination else { return }

        // Remember floats on the outgoing workspace before they are parked.
        if let outgoing = active[destination], let ws = workspaces[outgoing], outgoing != id {
            for window in ws.floating {
                if !parkedFloats.contains(window), let frame = currentFrame(window) {
                    floatFrames[window] = frame
                }
            }
        }
        active[destination] = id
        target.monitor = destination
    }

    public func switchToWorkspace(_ id: Int) {
        if let current = activeWorkspace?.id, current != id { previousWorkspace = current }
        if let monitor = monitorID(showing: id) {
            focusedMonitor = monitor
        } else {
            let destination = workspaces[id]?.monitor.flatMap { monitor($0) }?.id ?? focusedMonitor
            if let destination { focusedMonitor = destination }
            show(id)
        }
    }

    private func step(workspaceBy delta: Int) {
        guard let current = activeWorkspace?.id else { return }
        // Stepping visits occupied workspaces, plus the current one if it is empty.
        let stops = Set(occupiedWorkspaces + [current]).sorted()
        guard let index = stops.firstIndex(of: current), stops.count > 1 else { return }
        switchToWorkspace(stops[(index + delta + stops.count) % stops.count])
    }

    private func move(_ id: WindowID, toWorkspace target: Int, follow: Bool) {
        guard let source = workspace(containing: id), source.id != target else { return }
        let wasFloating = source.isFloating(id)
        let frame = wasFloating ? currentFrame(id) : nil
        let sourceMonitor = monitorID(showing: source.id)
        source.remove(id)
        scratchpadMembers.remove(id)
        let destination = workspace(target)
        if wasFloating {
            destination.insertFloating(id)
            floatFrames[id] = frame
            // A float doesn't get a tile to tell it where to go, so carry it to the new display.
            if let frame, let to = monitor(monitorID(showing: target)), monitorID(showing: target) != sourceMonitor {
                floatFrames[id] = centered(frame.size, on: to)
                parkedFloats.insert(id)
            }
        } else {
            destination.insertTiled(id)
        }
        destination.setFocused(id)
        if follow {
            switchToWorkspace(target)
        } else {
            tightenScrolling()
        }
    }

    private func centered(_ size: CGSize, on monitor: Monitor, cascade: Int = 0) -> CGRect {
        let area = bounds(of: monitor)
        let offset = CGFloat(cascade) * 28
        return CGRect(
            x: area.midX - size.width / 2 + offset,
            y: area.midY - size.height / 2 + offset,
            width: size.width,
            height: size.height
        )
    }

    /// Trades the workspace on the focused display with the one on the next display.
    private func moveWorkspaceToNextMonitor() {
        guard let from = focusedMonitor, let next = nextMonitor(),
              let moving = active[from], let other = active[next.id],
              let fromMonitor = monitor(from)
        else { return }
        active[next.id] = moving
        active[from] = other
        workspaces[moving]?.monitor = next.id
        workspaces[other]?.monitor = from
        focusedMonitor = next.id

        for (workspaceID, destination) in [(moving, next), (other, fromMonitor)] {
            for id in workspaces[workspaceID]?.floating ?? [] {
                guard let frame = currentFrame(id) else { continue }
                floatFrames[id] = centered(frame.size, on: destination)
                parkedFloats.insert(id)
            }
        }
    }

    // MARK: - Scratchpad

    private var scratchpadIsShown: Bool {
        scratchpadMembers.contains { workspace(containing: $0)?.id != Self.scratchpadID }
    }

    private func moveToScratchpad(_ id: WindowID) {
        guard let source = workspace(containing: id), source.id != Self.scratchpadID else { return }
        let wasFloating = source.isFloating(id)
        let frame = currentFrame(id)
        source.remove(id)
        workspace(Self.scratchpadID).insertFloating(id)
        scratchpadMembers.insert(id)
        if wasFloating { floatFrames[id] = frame }
        tightenScrolling()
    }

    private func hideScratchpad() {
        let tray = workspace(Self.scratchpadID)
        for id in scratchpadMembers.sorted() {
            guard let ws = workspace(containing: id), ws.id != tray.id else { continue }
            if let frame = currentFrame(id) { floatFrames[id] = frame }
            ws.remove(id)
            tray.insertFloating(id)
        }
    }

    private func showScratchpad() {
        guard let ws = activeWorkspace, let monitor = monitor(focusedMonitor),
              let tray = workspaces[Self.scratchpadID]
        else { return }
        let area = bounds(of: monitor)
        let fallback = CGSize(width: area.width * 0.6, height: area.height * 0.7)
        for (index, id) in tray.floating.enumerated() {
            tray.remove(id)
            ws.insertFloating(id)
            floatFrames[id] = centered(floatFrames[id]?.size ?? fallback, on: monitor, cascade: index)
            parkedFloats.insert(id)
            ws.setFocused(id)
        }
    }

    // MARK: - Commands

    /// Runs a keybinding. Call `plan()` afterwards to get the resulting window positions.
    public func perform(_ command: Command) {
        let ws = activeWorkspace
        let focused = ws?.focused

        switch command {
        case let .focus(direction):
            moveFocus(direction)
        case let .swap(direction):
            swapFocused(direction)
        case .focusNextInWorkspace:
            cycleFocus(by: 1)
        case .focusPreviousInWorkspace:
            cycleFocus(by: -1)
        case let .workspace(id):
            switchToWorkspace(id)
        case .workspaceNext:
            step(workspaceBy: 1)
        case .workspacePrevious:
            step(workspaceBy: -1)
        case .workspaceLast:
            if let previousWorkspace { switchToWorkspace(previousWorkspace) }
        case let .moveToWorkspace(target, follow):
            if let focused { move(focused, toWorkspace: target, follow: follow) }
        case .focusMonitorNext:
            if let next = nextMonitor() {
                focusedMonitor = next.id
            }
        case .moveToMonitorNext:
            if let focused, let next = nextMonitor(), let target = active[next.id] {
                move(focused, toWorkspace: target, follow: true)
            }
        case .moveWorkspaceToMonitorNext:
            moveWorkspaceToNextMonitor()
        case .moveToScratchpad:
            if let focused { moveToScratchpad(focused) }
        case .toggleScratchpad:
            if scratchpadIsShown {
                hideScratchpad()
            } else {
                showScratchpad()
            }
        case let .layout(kind):
            ws?.layout = kind
        case .toggleDwindleScrolling:
            if let ws { ws.layout = ws.layout == .scrolling ? .dwindle : .scrolling }
        case .layoutNext:
            if let ws {
                let all = LayoutKind.allCases
                ws.layout = all[(all.firstIndex(of: ws.layout)! + 1) % all.count]
            }
        case .toggleSplit:
            if let ws, let focused { ws.toggleSplit(of: focused) }
        case .toggleFloat:
            if let ws, let focused {
                ws.toggleFloating(focused)
                if !ws.isFloating(focused) { scratchpadMembers.remove(focused) }
                // A newly floated window lifts out of its tile, centered, so what's behind shows.
                if ws.isFloating(focused), let monitor = monitor(focusedMonitor) {
                    let area = bounds(of: monitor)
                    floatFrames[focused] = area.insetBy(dx: area.width * 0.2, dy: area.height * 0.15)
                    parkedFloats.insert(focused)
                }
            }
        case .fullscreen:
            if let ws, let focused, !ws.isFloating(focused) {
                ws.fullscreen = ws.fullscreen == focused ? nil : focused
            }
        case .fullWidth:
            if let ws, let focused {
                if ws.layout == .scrolling {
                    ws.strip.setFullWidth(of: focused)
                } else if !ws.isFloating(focused) {
                    ws.fullscreen = ws.fullscreen == focused ? nil : focused
                }
            }
        case .cycleWidth:
            if let ws, let focused, ws.layout == .scrolling { ws.strip.cycleWidth(of: focused) }
        case .center:
            if let ws, let focused, ws.layout == .scrolling, let monitor = monitor(focusedMonitor) {
                ws.strip.center(
                    focused,
                    viewport: bounds(of: monitor).width,
                    gap: options.innerGap,
                    suspended: ws.suspended
                )
            }
        case .promote:
            if let ws, let focused, !ws.isFloating(focused) { ws.promote(focused) }
        case .stack:
            if let ws, let focused, ws.layout == .scrolling { ws.strip.stackIntoPrevious(focused) }
        case .unstack:
            if let ws, let focused, ws.layout == .scrolling { ws.strip.unstack(focused) }
        case let .grow(width, height):
            if let focused { grow(focused, width: CGFloat(width), height: CGFloat(height)) }
        case .balance:
            ws?.balance()
        case .retile, .close:
            break
        }
    }

    /// Grows a tiled window, also used when the user drags a window's edge.
    public func grow(_ id: WindowID, width: CGFloat, height: CGFloat) {
        guard let ws = workspace(containing: id), !ws.isFloating(id),
              let monitorID = monitorID(showing: ws.id), let monitor = monitor(monitorID)
        else { return }
        ws.grow(id, width: width, height: height, bounds: bounds(of: monitor), gap: options.innerGap)
    }

    /// The user dragged a window and let go. Dropping it on another tile swaps the two. Dropping
    /// it on another display moves it there. Anywhere else, it snaps back to its slot.
    public func drop(_ id: WindowID, at point: CGPoint) {
        guard let source = workspace(containing: id), !source.isFloating(id) else { return }
        if let target = monitor(at: point), let targetWorkspace = active[target.id], targetWorkspace != source.id {
            move(id, toWorkspace: targetWorkspace, follow: true)
            return
        }
        let target = lastFrames.first { key, frame in
            key != id && frame.contains(point) && source.order.contains(key) && !source.isFloating(key)
        }
        if let target { source.swap(id, target.key) }
    }

    private func nextMonitor() -> Monitor? {
        guard monitors.count > 1, let index = monitors.firstIndex(where: { $0.id == focusedMonitor }) else {
            return nil
        }
        return monitors[(index + 1) % monitors.count]
    }

    private func adjacentMonitor(_ direction: Direction) -> Monitor? {
        guard let current = monitor(focusedMonitor) else { return nil }
        let candidates = monitors.filter { $0.id != current.id }
        let origin = current.frame.center
        return candidates
            .filter { monitor in
                switch direction {
                case .left: return monitor.frame.midX < origin.x
                case .right: return monitor.frame.midX > origin.x
                case .up: return monitor.frame.midY < origin.y
                case .down: return monitor.frame.midY > origin.y
                }
            }
            .min { a, b in
                func distance(_ m: Monitor) -> CGFloat {
                    hypot(m.frame.midX - origin.x, m.frame.midY - origin.y)
                }
                return distance(a) < distance(b)
            }
    }

    private func cycleFocus(by delta: Int) {
        guard let ws = activeWorkspace else { return }
        let windows = ws.visibleTiled
        guard !windows.isEmpty else { return }
        guard let focused = ws.lastTiledFocus, let index = windows.firstIndex(of: focused) else {
            ws.setFocused(windows[0])
            return
        }
        ws.setFocused(windows[(index + delta + windows.count) % windows.count])
        ws.fullscreen = nil
    }

    private func moveFocus(_ direction: Direction) {
        guard let ws = activeWorkspace, let monitor = monitor(focusedMonitor) else { return }

        // A floating window has no spot in the layout. Return to the tile it floats above.
        if let focused = ws.focused, ws.isFloating(focused), let tile = ws.lastTiledFocus {
            ws.setFocused(tile)
            return
        }
        if ws.layout == .monocle || ws.fullscreen != nil {
            if ws.visibleTiled.count > 1 {
                cycleFocus(by: direction == .left || direction == .up ? -1 : 1)
                return
            }
        } else if let focused = ws.focused {
            let frames = ws.frames(in: bounds(of: monitor), gap: options.innerGap)
            if let target = neighbor(of: focused, direction: direction, in: frames) {
                ws.setFocused(target)
                return
            }
        }
        // Nothing further on this display: cross to the next one.
        if let next = adjacentMonitor(direction) {
            focusedMonitor = next.id
        }
    }

    private func swapFocused(_ direction: Direction) {
        guard let ws = activeWorkspace, let focused = ws.focused, !ws.isFloating(focused),
              let monitor = monitor(focusedMonitor)
        else { return }
        let frames = ws.frames(in: bounds(of: monitor), gap: options.innerGap)
        if let target = neighbor(of: focused, direction: direction, in: frames), ws.layout != .monocle {
            ws.swap(focused, target)
        } else if let next = adjacentMonitor(direction), let target = active[next.id] {
            move(focused, toWorkspace: target, follow: true)
        }
    }

    // MARK: - Planning

    public func plan() -> LayoutPlan {
        var plan = LayoutPlan()
        var hiddenMonitor: [Int: MonitorID] = [:]
        var layoutFrames: [WindowID: CGRect] = [:]

        for monitor in monitors {
            guard let workspaceID = active[monitor.id], let ws = workspaces[workspaceID] else { continue }
            let area = bounds(of: monitor)
            let others = monitors.filter { $0.id != monitor.id }

            for (id, frame) in ws.frames(in: area, gap: options.innerGap) {
                layoutFrames[id] = frame
                if shouldHide(frame, in: area, monitor: monitor, others: others) {
                    plan.hidden[id] = monitor.id
                } else {
                    plan.frames[id] = frame
                }
            }
            for id in ws.floating where !ws.suspended.contains(id) && parkedFloats.remove(id) != nil {
                if let frame = floatFrames[id] { plan.frames[id] = frame }
            }
            hiddenMonitor[workspaceID] = monitor.id
        }

        for ws in workspaces.values where !isVisible(ws) {
            let parkOn = ws.monitor.flatMap { monitor($0) }?.id ?? focusedMonitor
            guard let parkOn else { continue }
            for id in ws.allWindows where !ws.suspended.contains(id) {
                plan.hidden[id] = parkOn
                if ws.isFloating(id) { parkedFloats.insert(id) }
            }
        }

        lastFrames = layoutFrames
        plan.focused = focusedWindow
        return plan
    }

    /// A scrolled column is hidden once it is fully off-screen, or as soon as it would spill onto
    /// a neighbouring display. Otherwise a partly visible column stays, as a peek at what's next.
    private func shouldHide(_ frame: CGRect, in area: CGRect, monitor: Monitor, others: [Monitor]) -> Bool {
        if area.contains(frame) { return false }
        if !frame.intersects(monitor.frame) || frame.intersection(area).width < 1 { return true }
        return others.contains { frame.intersects($0.frame) }
    }
}
