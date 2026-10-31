import CoreGraphics
import Foundation

/// A snapshot of the current state, for `Tilefy status` and scripts.
public struct TilefyStatus: Codable, Equatable {
    /// False until Accessibility permission has been granted.
    public var started: Bool
    public var paused: Bool
    public var workspace: Int?
    public var layout: String?
    public var focusedWindow: WindowID?
    public var occupiedWorkspaces: [Int]
    /// Window ID (as a string, since JSON keys must be) to workspace number.
    public var windows: [String: Int]
}

/// Connects the engine to the system: it notices what windows exist, feeds that to the engine, and
/// carries out the engine's plans.
///
/// All window events funnel into `reconcile`, which compares what's on screen with what the engine
/// believes, instead of each event working out its own effect. A missed or out-of-order event
/// therefore costs at most one heartbeat. Everything here runs on the main thread.
public final class WindowCoordinator {
    public private(set) var config: Config
    public let engine: TilingEngine
    public private(set) var isPaused = false
    public private(set) var isStarted = false
    public var onStateChange: (() -> Void)?

    private let system: WindowSystem
    private var owners: [WindowID: Int32] = [:]
    /// Windows looked at and rejected, with when they were first seen. Some apps only fill in a
    /// window's details shortly after creating it, so recent ones are rechecked.
    private var rejected: [WindowID: Date] = [:]
    /// In native fullscreen, on a Space of their own. They must not be moved.
    private var fullscreenWindows: Set<WindowID> = []
    private var lastPlan = LayoutPlan()
    private var reconcileGeneration = 0
    private var scroll = ScrollAccumulator()

    // A focus change Tilefy just requested. macOS reports focus asynchronously, so for a moment it
    // can report the previous window, which must not be mistaken for the user switching back.
    private var requestedFocus: (window: WindowID?, until: Date)?
    // Windows that had focus just before a request. Only reports of these are suspect: a report of
    // anything else, like a window that just opened, is real news even moments after a request.
    private var staleFocus: Set<WindowID> = []
    // The window macOS last reported as focused. Tilefy only follows changes to it. After switching
    // to an empty workspace, macOS can still call a hidden window focused, and following that would
    // bounce straight back.
    private var lastSystemFocus: WindowID?

    private var draggedWindow: WindowID?

    static let heartbeatInterval: TimeInterval = 1.5
    static let focusGuard: TimeInterval = 0.4

    public init(config: Config, system: WindowSystem) {
        self.config = config
        self.system = system
        self.engine = TilingEngine(options: config.tilingOptions) { [weak system] id in system?.frame(of: id) }
    }

    // MARK: - Lifecycle

    public func start() {
        guard !isStarted else { return }
        isStarted = true
        engine.setMonitors(system.currentMonitors())
        system.attachToRunningApps()
        reconcile(full: true, isInitialScan: true)
        scheduleHeartbeat()
    }

    private func scheduleHeartbeat() {
        system.after(Self.heartbeatInterval) { [weak self] in
            guard let self, self.isStarted else { return }
            self.reconcile(full: true)
            self.scheduleHeartbeat()
        }
    }

    /// Leaves every window reachable. The ones parked out of sight come back on-screen.
    public func stop() {
        guard isStarted else { return }
        restoreParkedWindows()
        system.showBorder(around: nil, width: 0)
        isStarted = false
    }

    public func setPaused(_ paused: Bool) {
        guard paused != isPaused else { return }
        isPaused = paused
        if paused {
            restoreParkedWindows()
            system.showBorder(around: nil, width: 0)
        } else {
            engine.setMonitors(system.currentMonitors())
            reconcile(full: true)
            apply(focus: false)
        }
        onStateChange?()
    }

    public func update(config: Config) {
        self.config = config
        engine.options = config.tilingOptions
        apply(focus: false)
    }

    // MARK: - Events from the system

    public func displaysChanged() {
        guard !isPaused, isStarted else { return }
        engine.setMonitors(system.currentMonitors())
        apply(focus: false)
        onStateChange?()
    }

    /// Something happened that may have changed which windows exist or are showing.
    public func scheduleReconcile(full: Bool) {
        guard isStarted else { return }
        reconcileGeneration += 1
        let generation = reconcileGeneration
        system.after(0.04) { [weak self] in
            guard let self, generation == self.reconcileGeneration else { return }
            self.reconcile(full: full)
        }
    }

    public func windowDestroyed() {
        scheduleReconcile(full: false)
        // The window can outlive this notification by a moment in the window list. Look again
        // shortly, rather than leaving a hole until the next heartbeat.
        system.after(0.2) { [weak self] in self?.reconcile(full: false) }
    }

    public func reconcile(full: Bool, isInitialScan: Bool = false) {
        guard !isPaused, isStarted else { return }
        if full { system.attachToRunningApps() }

        let onScreen = system.onScreenWindows()
        let focusedBefore = engine.focusedWindow
        var changed = false
        var focusedWindowClosed = false

        for id in Array(owners.keys) {
            let isOnScreen = onScreen[id] != nil
            if !isOnScreen, system.isGone(id) {
                if id == focusedBefore { focusedWindowClosed = true }
                owners[id] = nil
                fullscreenWindows.remove(id)
                engine.removeWindow(id)
                system.forget(id)
                changed = true
                continue
            }
            if full, isOnScreen {
                if system.isFullScreen(id) {
                    fullscreenWindows.insert(id)
                } else {
                    fullscreenWindows.remove(id)
                }
            }
            let shouldShow = isOnScreen && !fullscreenWindows.contains(id)
            if shouldShow == engine.isSuspended(id) {
                if shouldShow {
                    engine.resumeWindow(id)
                } else {
                    engine.suspendWindow(id)
                }
                changed = true
            }
        }

        let addedAny = discoverWindows(onScreen: onScreen, isInitialScan: isInitialScan)
        if addedAny { changed = true }
        rejected = rejected.filter { onScreen[$0.key] != nil }

        let focusChanged = syncFocus(applyChanges: false)
        if changed || focusChanged || isInitialScan {
            apply(focus: focusedWindowClosed)
            onStateChange?()
        }

        if addedAny {
            // Many apps adjust a new window's size just after showing it, so check it again.
            system.after(0.35) { [weak self] in self?.apply(focus: false) }
        }
    }

    private func discoverWindows(onScreen: [WindowID: Int32], isInitialScan: Bool) -> Bool {
        let now = system.now
        let unknown = onScreen.filter { id, _ in
            guard owners[id] == nil else { return false }
            guard let firstSeen = rejected[id] else { return true }
            return now.timeIntervalSince(firstSeen) < 3
        }
        guard !unknown.isEmpty else { return false }

        var found: [(id: WindowID, pid: Int32, frame: CGRect, cannotTile: Bool, bundleID: String?)] = []
        for pid in Set(unknown.values).sorted() {
            let ids = Set(unknown.filter { $0.value == pid }.keys)
            for inspection in system.inspectWindows(pid: pid, among: ids) {
                switch inspection {
                case let .manage(id, pid, frame, cannotTile, bundleID):
                    rejected[id] = nil
                    found.append((id, pid, frame, cannotTile, bundleID))
                case let .reject(id):
                    if rejected[id] == nil { rejected[id] = now }
                }
            }
        }

        // On first launch, keep the left-to-right order the windows are already in.
        if isInitialScan { found.sort { ($0.frame.minX, $0.id) < ($1.frame.minX, $1.id) } }

        for window in found {
            owners[window.id] = window.pid
            let bundleID = window.bundleID ?? ""
            let floats = window.cannotTile || config.floatApps.contains(bundleID)
            // A window stays on the display macOS opened it on, unless an app rule says otherwise.
            engine.addWindow(
                window.id,
                floating: floats,
                monitor: engine.monitorID(nearest: window.frame),
                workspace: config.appWorkspaces[bundleID].flatMap { (1...9).contains($0) ? $0 : nil },
                focus: isInitialScan
            )
        }
        return !found.isEmpty
    }

    // MARK: - Focus

    /// Call when macOS reports that focus may have moved.
    public func systemFocusChanged() {
        syncFocus(applyChanges: true)
    }

    @discardableResult
    private func syncFocus(applyChanges: Bool) -> Bool {
        guard !isPaused, isStarted else { return false }

        let id: WindowID
        switch system.frontmost() {
        case .tilefy:
            // Whatever gets focus next counts as a change, even the window that had it before.
            lastSystemFocus = nil
            system.showBorder(around: nil, width: 0)
            return false
        case let .app(_, focused?) where engine.isTracked(focused):
            id = focused
        case .app, .unknown:
            system.showBorder(around: nil, width: 0)
            return false
        }

        if let requestedFocus, system.now < requestedFocus.until, requestedFocus.window != id, staleFocus.contains(id) {
            return false
        }
        guard id != lastSystemFocus else {
            // Same window as before, so it isn't news. But if its workspace is showing and has lost
            // track of it (the window list can come back briefly empty during Space transitions, and
            // that clears focus), put it right. Otherwise shortcuts have nothing to act on.
            if let ws = engine.workspace(containing: id), engine.isVisible(ws), ws.focused != id {
                engine.focusChanged(to: id)
                if applyChanges {
                    apply(focus: false)
                    onStateChange?()
                }
                return true
            }
            if applyChanges { refreshBorder() }
            return false
        }
        lastSystemFocus = id

        let before = (engine.focusedWindow, engine.activeWorkspace?.id, engine.focusedMonitor)
        engine.focusChanged(to: id)
        let after = (engine.focusedWindow, engine.activeWorkspace?.id, engine.focusedMonitor)
        let changed = before != after

        if changed, applyChanges {
            apply(focus: false)
            onStateChange?()
        } else if applyChanges {
            refreshBorder()
        }
        return changed
    }

    private func refreshBorder() {
        guard config.focusBorder, draggedWindow == nil,
              let focused = engine.focusedWindow, lastPlan.hidden[focused] == nil,
              let pid = owners[focused], let frame = system.frame(of: focused)
        else {
            system.showBorder(around: nil, width: 0)
            return
        }
        // Another app may be frontmost with no tracked window, like a panel. Don't draw over it.
        var isFront = false
        if case let .app(frontPID, _) = system.frontmost(), frontPID == pid { isFront = true }
        let isExpected = requestedFocus.map { $0.window == focused && system.now < $0.until } ?? false
        guard isFront || isExpected else {
            system.showBorder(around: nil, width: 0)
            return
        }
        system.showBorder(around: frame, width: config.focusBorderWidth)
    }

    // MARK: - Applying plans

    private func apply(focus: Bool) {
        guard !isPaused, isStarted else { return }
        let plan = engine.plan()
        lastPlan = plan

        var focusTarget: WindowID?
        if focus {
            if let previous = requestedFocus, system.now >= previous.until { staleFocus.removeAll() }
            if let previous = lastSystemFocus { staleFocus.insert(previous) }
            if let target = plan.focused { staleFocus.remove(target) }
            requestedFocus = (plan.focused, system.now.addingTimeInterval(Self.focusGuard))
            focusTarget = plan.focused
            if let target = plan.focused {
                lastSystemFocus = target
            } else if case let .app(_, front?) = system.frontmost(), plan.hidden[front] != nil {
                // Nothing to focus here, and keystrokes would otherwise go to a window out of sight.
                system.clearFocus()
            }
        }
        system.carryOut(plan: plan, skipping: draggedWindow, focus: focusTarget, monitors: engine.monitors) { [weak self] in
            self?.refreshBorder()
        }
    }

    public func run(_ commandName: String) {
        guard !isPaused, isStarted, let command = Command(commandName) else { return }
        if case .close = command {
            if let focused = engine.focusedWindow { system.close(focused) }
            return
        }
        let before = (engine.activeWorkspace?.id, engine.activeWorkspace?.layout)
        engine.perform(command)
        apply(focus: true)
        onStateChange?()

        let after = (engine.activeWorkspace?.id, engine.activeWorkspace?.layout)
        if config.showHUD, before != after, let ws = engine.activeWorkspace,
           let monitor = engine.monitors.first(where: { $0.id == engine.focusedMonitor }) {
            system.showHUD("\(ws.id)  ·  \(ws.layout.title)", on: monitor)
        }
    }

    /// Scrolling with the shortcut modifier held. Up and down change workspace, like Omarchy.
    /// Left and right move focus, which slides the row in the scrolling layout.
    public func scrolled(dx: CGFloat, dy: CGFloat) {
        switch scroll.add(dx: dx, dy: dy) {
        case .up: run("workspace-previous")
        case .down: run("workspace-next")
        case .left: run("focus-left")
        case .right: run("focus-right")
        case nil: break
        }
    }

    public func status() -> TilefyStatus {
        var windows: [String: Int] = [:]
        for id in owners.keys {
            if let ws = engine.workspace(containing: id) { windows[String(id)] = ws.id }
        }
        return TilefyStatus(
            started: isStarted,
            paused: isPaused,
            workspace: engine.activeWorkspace?.id,
            layout: engine.activeWorkspace?.layout.rawValue,
            focusedWindow: engine.focusedWindow,
            occupiedWorkspaces: engine.occupiedWorkspaces,
            windows: windows
        )
    }

    private func restoreParkedWindows() {
        // Cascade from the top left, so that everything brought back is visible and can be clicked.
        var offsets: [MonitorID: CGFloat] = [:]
        for (id, monitorID) in lastPlan.hidden.sorted(by: { $0.key < $1.key }) {
            guard let monitor = engine.monitors.first(where: { $0.id == monitorID }) else { continue }
            let offset = offsets[monitorID, default: 40]
            offsets[monitorID] = offset + 30
            system.setPosition(of: id, to: CGPoint(x: monitor.visibleFrame.minX + offset, y: monitor.visibleFrame.minY + offset))
        }
        lastPlan.hidden = [:]
    }

    // MARK: - Dragging with the mouse

    /// A window moved or resized, by the user, its app, or Tilefy itself.
    public func windowGeometryChanged(_ id: WindowID) {
        guard !isPaused, isStarted, engine.isTracked(id) else { return }
        guard system.isMouseDown else {
            // Floating windows can be moved by their app or by the keyboard, so keep the border on them.
            if id == engine.focusedWindow, engine.workspace(containing: id)?.isFloating(id) == true {
                refreshBorder()
            }
            return
        }
        guard draggedWindow == nil else { return }
        draggedWindow = id
        system.showBorder(around: nil, width: 0)
        pollForMouseUp()
    }

    private func pollForMouseUp() {
        system.after(0.05) { [weak self] in
            guard let self else { return }
            if self.system.isMouseDown {
                self.pollForMouseUp()
            } else {
                self.finishDrag()
            }
        }
    }

    private func finishDrag() {
        guard let id = draggedWindow else { return }
        draggedWindow = nil
        guard isStarted, !isPaused else { return }

        // Floats simply stay where they were dropped. Only tiles have a slot to reconcile with.
        guard engine.workspace(containing: id)?.isFloating(id) == false,
              let slot = lastPlan.frames[id],
              let actual = system.frame(of: id)
        else {
            refreshBorder()
            return
        }
        let widthChange = actual.width - slot.width
        let heightChange = actual.height - slot.height
        if abs(widthChange) > 2 || abs(heightChange) > 2 {
            engine.grow(id, width: widthChange, height: heightChange)
        } else if abs(actual.minX - slot.minX) > 2 || abs(actual.minY - slot.minY) > 2 {
            engine.drop(id, at: system.mouseLocation)
        }
        apply(focus: false)
        onStateChange?()
    }
}
