import AppKit
import QuartzCore
import TilefyCore

/// A thin click-through outline around the focused window.
final class FocusBorder {
    private lazy var panel: NSPanel = {
        let panel = makeOverlayPanel()
        let view = NSView()
        view.wantsLayer = true
        view.layer?.cornerRadius = 12
        panel.contentView = view
        return panel
    }()

    func show(around frame: CGRect, width: Double, style: BorderStyle) {
        let inset = CGFloat(width)
        let rect = Displays.appKitRect(frame).insetBy(dx: -inset, dy: -inset)
        // Windows in a group are stacked, and a sticky one stays put, so both look a little different.
        let color: NSColor
        switch style {
        case .normal: color = .controlAccentColor
        case .grouped: color = .systemPurple
        case .sticky: color = .systemOrange
        }
        panel.contentView?.layer?.borderColor = color.cgColor
        panel.contentView?.layer?.borderWidth = inset
        panel.setFrame(rect, display: true)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }
}

/// A small label shown for a moment when the workspace or layout changes. Parked windows leave
/// nothing on screen to say where you are, so without it a switch to an empty workspace looks like
/// everything vanished.
final class HUD {
    private lazy var label: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 20, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        return label
    }()

    private lazy var panel: NSPanel = {
        let panel = makeOverlayPanel()
        panel.level = .statusBar
        let view = NSView()
        view.wantsLayer = true
        view.layer?.cornerRadius = 14
        view.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
        view.addSubview(label)
        panel.contentView = view
        return panel
    }()

    private var hideWork: DispatchWorkItem?

    func show(_ text: String, on monitor: Monitor) {
        _ = panel
        label.stringValue = text
        label.sizeToFit()
        let size = CGSize(width: label.frame.width + 44, height: label.frame.height + 24)
        let area = Displays.appKitRect(monitor.visibleFrame)
        panel.setFrame(
            CGRect(x: area.midX - size.width / 2, y: area.minY + 80, width: size.width, height: size.height),
            display: false
        )
        label.frame.origin = CGPoint(x: 22, y: 12)
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.2
                self?.panel.animator().alphaValue = 0
            }, completionHandler: {
                if self?.panel.alphaValue == 0 { self?.panel.orderOut(nil) }
            })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }
}

private func makeOverlayPanel() -> NSPanel {
    let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.ignoresMouseEvents = true
    panel.level = .floating
    panel.isReleasedWhenClosed = false
    panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
    return panel
}

/// Catches scrolling while the shortcut modifier is held, so it doesn't also scroll or zoom the
/// window under the cursor. Everything else passes through untouched.
final class ModifierScrollTap {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private let flags: CGEventFlags
    private let onScroll: (CGFloat, CGFloat) -> Void

    init?(modifier: String, onScroll: @escaping (CGFloat, CGFloat) -> Void) {
        var flags: CGEventFlags = []
        for part in modifier.split(separator: "+") {
            switch part {
            case "ctrl": flags.insert(.maskControl)
            case "alt": flags.insert(.maskAlternate)
            case "cmd": flags.insert(.maskCommand)
            case "shift": flags.insert(.maskShift)
            default: return nil
            }
        }
        guard !flags.isEmpty else { return nil }
        self.flags = flags
        self.onScroll = onScroll

        let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(1 << CGEventType.scrollWheel.rawValue),
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let owner = Unmanaged<ModifierScrollTap>.fromOpaque(refcon).takeUnretainedValue()
                return owner.handle(type, event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )
        guard let tap else { return nil }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }

    func invalidate() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        source = nil
        tap = nil
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        // macOS turns off a tap it considers slow or after secure input. Turn it back on.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type == .scrollWheel, event.flags.isSuperset(of: flags) else {
            return Unmanaged.passUnretained(event)
        }
        let dy = CGFloat(event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1))
        let dx = CGFloat(event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2))
        // This callback must return quickly, or macOS disables the tap and scrolling stutters.
        DispatchQueue.main.async { [onScroll] in onScroll(dx, dy) }
        return nil
    }
}

/// Watches the trackpad for swipes. It only listens: every event carries on as normal, so it can't
/// slow down or swallow anything. macOS has no way to take a gesture away from Mission Control, which
/// is why Settings points out when the two overlap.
final class TrackpadSwipeTap {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private let onTouches: ([CGPoint]) -> Void

    init?(onTouches: @escaping ([CGPoint]) -> Void) {
        self.onTouches = onTouches
        let gestureEvents = CGEventMask(1) << CGEventMask(NSEvent.EventType.gesture.rawValue)
        let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: gestureEvents,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                Unmanaged<TrackpadSwipeTap>.fromOpaque(refcon).takeUnretainedValue().handle(type, event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )
        guard let tap else { return nil }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }

    func invalidate() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        source = nil
        tap = nil
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        guard let gesture = NSEvent(cgEvent: event), gesture.type == .gesture else { return }
        onTouches(gesture.touches(matching: .touching, in: nil).map(\.normalizedPosition))
    }
}
