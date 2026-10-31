import AppKit
import ApplicationServices
import TilefyCore

/// The real `WindowSystem`: Accessibility for windows, NSWorkspace for apps.
final class AccessibilitySystem: WindowSystem {
    weak var coordinator: WindowCoordinator?

    private struct AppObserver {
        let observer: AXObserver
        let app: AXUIElement
    }

    private var observers: [pid_t: AppObserver] = [:]
    private var elements: [WindowID: (element: AXUIElement, pid: pid_t)] = [:]
    private let writer = FrameWriter()
    private let border = FocusBorder()
    private let hud = HUD()
    private var lastBorderFrame: CGRect?
    private var workspaceObservers: [NSObjectProtocol] = []
    /// When set, only this app's windows are managed. See `--only-app` in the README.
    private let onlyApp: String?
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    init(onlyApp: String?) {
        self.onlyApp = onlyApp
        // A frozen app should cost at most a short stall, not the default six seconds.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.25)
        observeWorkspace()
    }

    private func isEligible(_ app: NSRunningApplication) -> Bool {
        guard app.activationPolicy == .regular, app.processIdentifier != ownPID else { return false }
        guard let onlyApp else { return true }
        return app.bundleIdentifier == onlyApp || app.localizedName == onlyApp
    }

    private func observeWorkspace() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didHideApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification,
            NSWorkspace.activeSpaceDidChangeNotification,
        ] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.coordinator?.scheduleReconcile(full: true)
            })
        }
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                self?.detach(from: app.processIdentifier)
            }
            self?.coordinator?.scheduleReconcile(full: false)
        })
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.coordinator?.systemFocusChanged()
        })
        workspaceObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.coordinator?.displaysChanged()
        })
    }

    // MARK: - Observing apps and windows

    func attachToRunningApps() {
        for app in NSWorkspace.shared.runningApplications where isEligible(app) {
            attach(to: app.processIdentifier)
        }
    }

    private func attach(to pid: pid_t) {
        guard observers[pid] == nil else { return }
        var created: AXObserver?
        guard AXObserverCreate(pid, axCallback, &created) == .success, let observer = created else { return }

        let app = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        // An app that is still launching refuses this. The heartbeat retries it.
        guard AXObserverAddNotification(observer, app, kAXWindowCreatedNotification as CFString, refcon) == .success else {
            return
        }
        AXObserverAddNotification(observer, app, kAXFocusedWindowChangedNotification as CFString, refcon)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        observers[pid] = AppObserver(observer: observer, app: app)
    }

    private func detach(from pid: pid_t) {
        if let entry = observers.removeValue(forKey: pid) {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(entry.observer), .defaultMode)
        }
        writer.forget(pid: pid)
    }

    private func observe(_ element: AXUIElement, pid: pid_t) {
        guard let entry = observers[pid] else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in [
            kAXUIElementDestroyedNotification,
            kAXWindowMiniaturizedNotification,
            kAXWindowDeminiaturizedNotification,
            kAXWindowMovedNotification,
            kAXWindowResizedNotification,
        ] {
            AXObserverAddNotification(entry.observer, element, name as CFString, refcon)
        }
    }

    fileprivate func handle(notification: String, element: AXUIElement) {
        guard let coordinator else { return }
        switch notification {
        case kAXWindowMovedNotification, kAXWindowResizedNotification:
            if let id = AX.windowID(of: element) { coordinator.windowGeometryChanged(id) }
        case kAXFocusedWindowChangedNotification:
            coordinator.systemFocusChanged()
        case kAXUIElementDestroyedNotification:
            coordinator.windowDestroyed()
        default:
            coordinator.scheduleReconcile(full: false)
        }
    }

    // MARK: - WindowSystem: reading

    func currentMonitors() -> [Monitor] {
        Displays.current()
    }

    func onScreenWindows() -> [WindowID: Int32] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[CFString: Any]] else { return [:] }
        var result: [WindowID: Int32] = [:]
        for info in list {
            guard info[kCGWindowLayer] as? Int == 0,
                  (info[kCGWindowAlpha] as? Double ?? 1) > 0,
                  let id = info[kCGWindowNumber] as? WindowID,
                  let pid = info[kCGWindowOwnerPID] as? pid_t,
                  pid != ownPID
            else { continue }
            result[id] = pid
        }
        return result
    }

    func inspectWindows(pid: Int32, among ids: Set<WindowID>) -> [WindowInspection] {
        guard let app = NSRunningApplication(processIdentifier: pid), isEligible(app) else { return [] }
        attach(to: pid)

        var results: [WindowInspection] = []
        for element in AX.windows(of: AXUIElementCreateApplication(pid)) {
            guard let id = AX.windowID(of: element), ids.contains(id) else { continue }
            guard let frame = AX.frame(of: element), Self.isManageable(element) else {
                results.append(.reject(id: id))
                continue
            }
            elements[id] = (element, pid)
            observe(element, pid: pid)
            results.append(.manage(
                id: id,
                pid: pid,
                frame: frame,
                cannotTile: Self.cannotTile(element),
                bundleID: app.bundleIdentifier ?? app.localizedName,
                title: AX.attribute(element, kAXTitleAttribute, as: String.self)
            ))
        }
        return results
    }

    private static func isManageable(_ element: AXUIElement) -> Bool {
        AX.attribute(element, kAXRoleAttribute, as: String.self) == kAXWindowRole
            && AX.attribute(element, kAXSubroleAttribute, as: String.self) == kAXStandardWindowSubrole
            && AX.isSettable(element, kAXPositionAttribute)
            && !AX.isFullScreen(element)
    }

    /// Fixed-size windows, and those without a fullscreen button (usually utility windows and
    /// panels that appear as standard windows), can't fill an arbitrary tile.
    private static func cannotTile(_ element: AXUIElement) -> Bool {
        if !AX.isSettable(element, kAXSizeAttribute) { return true }
        let fullScreenButton: CFTypeRef? = AX.attribute(element, kAXFullScreenButtonAttribute)
        return fullScreenButton == nil
    }

    func isGone(_ id: WindowID) -> Bool {
        guard let entry = elements[id] else { return true }
        return NSRunningApplication(processIdentifier: entry.pid) == nil || AX.isDestroyed(entry.element)
    }

    func isFullScreen(_ id: WindowID) -> Bool {
        elements[id].map { AX.isFullScreen($0.element) } ?? false
    }

    func frame(of id: WindowID) -> CGRect? {
        elements[id].flatMap { AX.frame(of: $0.element) }
    }

    func frontmost() -> Frontmost {
        guard let front = NSWorkspace.shared.frontmostApplication else { return .unknown }
        if front.processIdentifier == ownPID { return .tilefy }
        let app = AXUIElementCreateApplication(front.processIdentifier)
        return .app(
            pid: front.processIdentifier,
            focusedWindow: AX.focusedWindow(of: app).flatMap { AX.windowID(of: $0) }
        )
    }

    func forget(_ id: WindowID) {
        elements[id] = nil
    }

    // MARK: - WindowSystem: acting

    func carryOut(
        plan: LayoutPlan,
        skipping: WindowID?,
        focus: WindowID?,
        monitors: [Monitor],
        animationDuration: Double,
        completion: @escaping () -> Void
    ) {
        // The override is for the real-window tests, as GitHub's Mac runners have Reduce Motion on.
        let ignoreReduceMotion = ProcessInfo.processInfo.environment["TILEFY_IGNORE_REDUCE_MOTION"] != nil
        let duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion && !ignoreReduceMotion ? 0 : animationDuration
        // The outline would lag behind a sliding window, so it comes back once the window has arrived.
        if duration > 0, let focused = plan.focused, let target = plan.frames[focused], target != lastBorderFrame {
            border.hide()
        }

        struct Batch {
            var frames: [(WindowID, AXUIElement, CGRect)] = []
            var hides: [(WindowID, AXUIElement, MonitorID)] = []
        }
        var batches: [pid_t: Batch] = [:]
        for (id, frame) in plan.frames where id != skipping {
            guard let entry = elements[id] else { continue }
            batches[entry.pid, default: Batch()].frames.append((id, entry.element, frame))
        }
        for (id, monitor) in plan.hidden {
            guard let entry = elements[id] else { continue }
            batches[entry.pid, default: Batch()].hides.append((id, entry.element, monitor))
        }

        let focusEntry = focus.flatMap { elements[$0] }
        if let focusEntry {
            NSRunningApplication(processIdentifier: focusEntry.pid)?.activate(options: [])
            if batches[focusEntry.pid] == nil { batches[focusEntry.pid] = Batch() }
        }
        // The border follows the focused window, which means waiting for its app specifically.
        let waitFor = focusEntry?.pid ?? plan.focused.flatMap { elements[$0]?.pid }

        for (pid, batch) in batches {
            writer.enqueue(
                pid: pid,
                frames: batch.frames,
                hides: batch.hides,
                focus: pid == focusEntry?.pid ? focusEntry?.element : nil,
                monitors: monitors,
                animationDuration: duration,
                completion: pid == waitFor ? completion : nil
            )
        }
        if waitFor == nil || batches[waitFor!] == nil { completion() }
    }

    func setPosition(of id: WindowID, to origin: CGPoint) {
        if let entry = elements[id] { AX.setPosition(entry.element, origin) }
    }

    func close(_ id: WindowID) {
        if let entry = elements[id] { AX.close(window: entry.element) }
    }

    func clearFocus() {
        NSApp.activate(ignoringOtherApps: true)
    }

    func showBorder(around frame: CGRect, of window: WindowID, width: Double, cornerRadius: Double?, style: BorderStyle) {
        lastBorderFrame = frame
        let radius = cornerRadius.map { CGFloat($0) } ?? WindowCorners.radius(of: window)
        border.show(around: frame, cornerRadius: radius, width: width, style: style)
    }

    func hideBorder() {
        lastBorderFrame = nil
        border.hide()
    }

    // MARK: - Saved state

    private static let stateURL: URL = {
        if let path = ProcessInfo.processInfo.environment["TILEFY_STATE"] {
            return URL(fileURLWithPath: path)
        }
        return Config.fileURL.deletingLastPathComponent().appendingPathComponent("state.json")
    }()

    func loadState() -> Data? {
        try? Data(contentsOf: Self.stateURL)
    }

    func saveState(_ data: Data) {
        let url = Self.stateURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    lazy var sessionID: String = {
        var bootTime = timeval()
        var size = MemoryLayout<timeval>.size
        sysctlbyname("kern.boottime", &bootTime, &size, nil, 0)
        return String(bootTime.tv_sec)
    }()

    func showHUD(_ text: String, on monitor: Monitor) {
        hud.show(text, on: monitor)
    }

    var isMouseDown: Bool { NSEvent.pressedMouseButtons & 1 != 0 }
    var mouseLocation: CGPoint { Displays.accessibilityPoint(NSEvent.mouseLocation) }
    var now: Date { Date() }

    func after(_ delay: TimeInterval, _ block: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: block)
    }
}

private let axCallback: AXObserverCallback = { _, element, notification, refcon in
    guard let refcon else { return }
    Unmanaged<AccessibilitySystem>.fromOpaque(refcon)
        .takeUnretainedValue()
        .handle(notification: notification as String, element: element)
}
