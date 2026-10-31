import AppKit
import ApplicationServices
import TilefyCore

/// Private but long-stable, and used by essentially every Mac window manager: there is no public
/// way to match an Accessibility window to its CGWindowID.
@_silgen_name("_AXUIElementGetWindow")
@discardableResult
private func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

enum AX {
    static func attribute<T>(_ element: AXUIElement, _ name: String, as: T.Type = T.self) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    static func windowID(of element: AXUIElement) -> WindowID? {
        var id: CGWindowID = 0
        return _AXUIElementGetWindow(element, &id) == .success && id != 0 ? id : nil
    }

    static func windows(of app: AXUIElement) -> [AXUIElement] {
        attribute(app, kAXWindowsAttribute) ?? []
    }

    static func focusedWindow(of app: AXUIElement) -> AXUIElement? {
        guard let value: CFTypeRef = attribute(app, kAXFocusedWindowAttribute),
              CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    static func frame(of element: AXUIElement) -> CGRect? {
        guard let position: AXValue = attribute(element, kAXPositionAttribute),
              let size: AXValue = attribute(element, kAXSizeAttribute)
        else { return nil }
        var origin = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(position, .cgPoint, &origin), AXValueGetValue(size, .cgSize, &extent) else { return nil }
        return CGRect(origin: origin, size: extent)
    }

    static func setPosition(_ element: AXUIElement, _ point: CGPoint) {
        var point = point
        guard let value = AXValueCreate(.cgPoint, &point) else { return }
        AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value)
    }

    static func setSize(_ element: AXUIElement, _ size: CGSize) {
        var size = size
        guard let value = AXValueCreate(.cgSize, &size) else { return }
        AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value)
    }

    /// Size, position, size: some apps clamp a resize to the display they're currently on, so a
    /// window crossing to another display needs its size set again once it has arrived.
    static func setFrame(_ element: AXUIElement, _ frame: CGRect) {
        setSize(element, frame.size)
        setPosition(element, frame.origin)
        setSize(element, frame.size)
    }

    static func isSettable(_ element: AXUIElement, _ name: String) -> Bool {
        var settable = DarwinBoolean(false)
        let status = AXUIElementIsAttributeSettable(element, name as CFString, &settable)
        return status == .success && settable.boolValue
    }

    static func isFullScreen(_ element: AXUIElement) -> Bool {
        attribute(element, "AXFullScreen", as: Bool.self) ?? false
    }

    /// True once the window no longer exists, as opposed to the app merely being slow to answer.
    static func isDestroyed(_ element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value) == .invalidUIElement
    }

    static func focus(window: AXUIElement, app: AXUIElement) {
        AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    }

    static func close(window: AXUIElement) {
        guard let value: CFTypeRef = attribute(window, kAXCloseButtonAttribute),
              CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return }
        AXUIElementPerformAction(unsafeBitCast(value, to: AXUIElement.self), kAXPressAction as CFString)
    }
}

/// Moves windows off the main thread, with one serial queue per app, so one frozen app can't hold
/// up the others or the hotkeys. If an app falls behind, its pending moves merge and it only
/// performs the newest position for each window.
final class FrameWriter {
    private struct Pending {
        var frames: [WindowID: (AXUIElement, CGRect)] = [:]
        var hides: [WindowID: (AXUIElement, MonitorID)] = [:]
        var focus: AXUIElement?
        var monitors: [Monitor] = []
        var completions: [() -> Void] = []
        var isDraining = false
    }

    private let lock = NSLock()
    private var pending: [pid_t: Pending] = [:]
    private var queues: [pid_t: DispatchQueue] = [:]

    func enqueue(
        pid: pid_t,
        frames: [(WindowID, AXUIElement, CGRect)],
        hides: [(WindowID, AXUIElement, MonitorID)],
        focus: AXUIElement?,
        monitors: [Monitor],
        completion: (() -> Void)?
    ) {
        lock.lock()
        defer { lock.unlock() }
        var entry = pending[pid] ?? Pending()
        for (id, element, frame) in frames {
            entry.frames[id] = (element, frame)
            entry.hides[id] = nil
        }
        for (id, element, monitor) in hides {
            entry.hides[id] = (element, monitor)
            entry.frames[id] = nil
        }
        if let focus { entry.focus = focus }
        if let completion { entry.completions.append(completion) }
        entry.monitors = monitors

        let shouldStart = !entry.isDraining
        entry.isDraining = true
        pending[pid] = entry

        if shouldStart {
            let queue = queues[pid] ?? DispatchQueue(label: "app.tilefy.writer.\(pid)")
            queues[pid] = queue
            queue.async { [weak self] in self?.drain(pid) }
        }
    }

    func forget(pid: pid_t) {
        lock.lock()
        defer { lock.unlock() }
        pending[pid] = nil
        queues[pid] = nil
    }

    private func drain(_ pid: pid_t) {
        while true {
            lock.lock()
            guard var entry = pending[pid] else {
                lock.unlock()
                return
            }
            if entry.frames.isEmpty, entry.hides.isEmpty, entry.focus == nil, entry.completions.isEmpty {
                entry.isDraining = false
                pending[pid] = entry
                lock.unlock()
                return
            }
            let work = entry
            entry.frames = [:]
            entry.hides = [:]
            entry.focus = nil
            entry.completions = []
            pending[pid] = entry
            lock.unlock()
            perform(work, pid: pid)
        }
    }

    private func perform(_ work: Pending, pid: pid_t) {
        let app = AXUIElementCreateApplication(pid)

        // With this flag on (set by screen readers, and by some apps on their own) moves animate and can land in the wrong place.
        let enhanced = "AXEnhancedUserInterface" as CFString
        let wasEnhanced = AX.attribute(app, enhanced as String, as: Bool.self) ?? false
        if wasEnhanced { AXUIElementSetAttributeValue(app, enhanced, kCFBooleanFalse) }

        for (element, frame) in work.frames.values {
            let current = AX.frame(of: element)
            if let current, Self.isClose(current, frame) { continue }
            AX.setFrame(element, frame)
        }

        for (element, monitorID) in work.hides.values {
            guard let current = AX.frame(of: element),
                  let monitor = work.monitors.first(where: { $0.id == monitorID })
            else { continue }
            let origin = hiddenOrigin(for: current.size, on: monitor, among: work.monitors)
            if abs(current.minX - origin.x) > 1 || abs(current.minY - origin.y) > 1 {
                AX.setPosition(element, origin)
            }
        }

        if wasEnhanced { AXUIElementSetAttributeValue(app, enhanced, kCFBooleanTrue) }

        if let focus = work.focus {
            AX.focus(window: focus, app: app)
        }

        if !work.completions.isEmpty {
            DispatchQueue.main.async { work.completions.forEach { $0() } }
        }
    }

    private static func isClose(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 1 && abs(a.minY - b.minY) < 1 && abs(a.width - b.width) < 1 && abs(a.height - b.height) < 1
    }
}

/// Reads the display layout, converted into Accessibility coordinates.
enum Displays {
    static func current() -> [Monitor] {
        guard let primaryHeight = NSScreen.screens.first?.frame.height else { return [] }

        func flipped(_ rect: CGRect) -> CGRect {
            CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
        }

        return NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            return Monitor(id: number.uint32Value, frame: flipped(screen.frame), visibleFrame: flipped(screen.visibleFrame))
        }
    }

    /// An Accessibility rectangle as an AppKit screen rectangle.
    static func appKitRect(_ rect: CGRect) -> CGRect {
        guard let primaryHeight = NSScreen.screens.first?.frame.height else { return rect }
        return CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// An AppKit screen point as an Accessibility point.
    static func accessibilityPoint(_ point: CGPoint) -> CGPoint {
        guard let primaryHeight = NSScreen.screens.first?.frame.height else { return point }
        return CGPoint(x: point.x, y: primaryHeight - point.y)
    }
}
