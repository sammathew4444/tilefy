import CoreGraphics
import Foundation
@testable import TilefyCore

/// A pretend macOS for testing `WindowCoordinator`. Time is virtual, and windows respond the way
/// the real thing does, including reporting focus late when `focusDelay` is set.
final class SimulatedMac: WindowSystem {
    struct Window {
        var pid: Int32
        var frame: CGRect
        var onScreen = true
        var exists = true
        var fullScreen = false
        var cannotTile = false
        var bundleID: String?
        var title: String?
        var isReady = true
        /// Ignores every attempt to move or resize it.
        var isStubborn = false
    }

    var windows: [WindowID: Window] = [:]
    var monitors: [Monitor] = [
        Monitor(
            id: 1,
            frame: CGRect(x: 0, y: 0, width: 1600, height: 1000),
            visibleFrame: CGRect(x: 0, y: 25, width: 1600, height: 975)
        ),
    ]
    var frontPID: Int32?
    var focusedWindowByApp: [Int32: WindowID] = [:]
    var tilefyIsFrontmost = false

    // What Tilefy asked for.
    private(set) var focusRequests: [WindowID] = []
    private(set) var closed: [WindowID] = []
    private(set) var clearFocusCount = 0
    private(set) var moveCount = 0
    private(set) var hud: [String] = []
    private(set) var border: CGRect?

    var mouseDown = false
    var mouse = CGPoint.zero
    /// Tilefy's windows ignore focus requests while this is true, like an app that refuses.
    var refuseFocus = false
    /// Set by tests to make the focus change reach the "app" only some time after being requested.
    var focusDelay: TimeInterval = 0

    // MARK: - Virtual time

    private var clock = Date(timeIntervalSince1970: 1_000_000)
    private var timers: [(fire: Date, block: () -> Void)] = []

    func advance(_ seconds: TimeInterval) {
        let end = clock.addingTimeInterval(seconds)
        while let next = timers.enumerated().filter({ $0.element.fire <= end }).min(by: { $0.element.fire < $1.element.fire }) {
            timers.remove(at: next.offset)
            clock = max(clock, next.element.fire)
            next.element.block()
        }
        clock = end
    }

    var now: Date { clock }
    func after(_ delay: TimeInterval, _ block: @escaping () -> Void) {
        timers.append((clock.addingTimeInterval(delay), block))
    }

    // MARK: - Test helpers

    /// Opens a window at the default spot, and focuses it if `focus` is true.
    @discardableResult
    func open(_ id: WindowID, pid: Int32 = 100, focus: Bool = true, bundleID: String? = nil, cannotTile: Bool = false) -> WindowID {
        windows[id] = Window(
            pid: pid,
            frame: CGRect(x: 100 + CGFloat(id) * 10, y: 100, width: 500, height: 400),
            cannotTile: cannotTile,
            bundleID: bundleID
        )
        if focus { userFocuses(id) }
        return id
    }

    func userFocuses(_ id: WindowID) {
        guard let window = windows[id] else { return }
        tilefyIsFrontmost = false
        frontPID = window.pid
        focusedWindowByApp[window.pid] = id
    }

    func close(window id: WindowID) {
        windows[id]?.exists = false
        windows[id]?.onScreen = false
        if let pid = windows[id]?.pid, focusedWindowByApp[pid] == id { focusedWindowByApp[pid] = nil }
    }

    func isParked(_ id: WindowID) -> Bool {
        guard let frame = windows[id]?.frame else { return false }
        return monitors.allSatisfy { $0.frame.intersection(frame).width <= 1 || $0.frame.intersection(frame).height <= 1 }
    }

    // MARK: - WindowSystem

    func currentMonitors() -> [Monitor] { monitors }

    func onScreenWindows() -> [WindowID: Int32] {
        var result: [WindowID: Int32] = [:]
        for (id, window) in windows where window.onScreen { result[id] = window.pid }
        return result
    }

    func attachToRunningApps() {}

    func inspectWindows(pid: Int32, among ids: Set<WindowID>) -> [WindowInspection] {
        ids.compactMap { id in
            guard let window = windows[id], window.pid == pid else { return nil }
            guard window.isReady else { return .reject(id: id) }
            return .manage(id: id, pid: pid, frame: window.frame, cannotTile: window.cannotTile, bundleID: window.bundleID, title: window.title)
        }
    }

    func isGone(_ id: WindowID) -> Bool { !(windows[id]?.exists ?? false) }
    func isFullScreen(_ id: WindowID) -> Bool { windows[id]?.fullScreen ?? false }
    func frame(of id: WindowID) -> CGRect? { windows[id]?.frame }

    func frontmost() -> Frontmost {
        if tilefyIsFrontmost { return .tilefy }
        guard let frontPID else { return .unknown }
        return .app(pid: frontPID, focusedWindow: focusedWindowByApp[frontPID])
    }

    func forget(_ id: WindowID) {}

    private(set) var applyCount = 0

    private(set) var lastAnimationDuration: Double = -1
    var savedState: Data?
    var session = "boot-1"
    var sessionID: String { session }
    func loadState() -> Data? { savedState }
    func saveState(_ data: Data) { savedState = data }

    func carryOut(
        plan: LayoutPlan,
        skipping: WindowID?,
        focus: WindowID?,
        monitors: [Monitor],
        animationDuration: Double,
        completion: @escaping () -> Void
    ) {
        applyCount += 1
        lastAnimationDuration = animationDuration
        for (id, frame) in plan.frames where id != skipping && windows[id]?.isStubborn != true {
            if windows[id]?.frame != frame { moveCount += 1 }
            windows[id]?.frame = frame
        }
        for (id, monitorID) in plan.hidden {
            guard let size = windows[id]?.frame.size, let monitor = monitors.first(where: { $0.id == monitorID }) else { continue }
            let origin = hiddenOrigin(for: size, on: monitor, among: monitors)
            if windows[id]?.frame.origin != origin { moveCount += 1 }
            windows[id]?.frame.origin = origin
        }
        if let focus {
            focusRequests.append(focus)
            if !refuseFocus {
                if focusDelay > 0 {
                    after(focusDelay) { [weak self] in self?.userFocuses(focus) }
                } else {
                    userFocuses(focus)
                }
            }
        }
        completion()
    }

    func setPosition(of id: WindowID, to origin: CGPoint) {
        windows[id]?.frame.origin = origin
    }

    func close(_ id: WindowID) {
        closed.append(id)
    }

    func clearFocus() {
        clearFocusCount += 1
        tilefyIsFrontmost = true
    }

    private(set) var borderStyle: BorderStyle = .normal
    func showBorder(around frame: CGRect?, width: Double, style: BorderStyle) {
        border = frame
        borderStyle = style
    }
    func showHUD(_ text: String, on monitor: Monitor) { hud.append(text) }

    var isMouseDown: Bool { mouseDown }
    var mouseLocation: CGPoint { mouse }
}
