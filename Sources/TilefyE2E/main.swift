import AppKit
import TilefyCore

// Real-window tests: drives an actual Tilefy against actual windows and checks where they end up.
//
// Tilefy runs with --only-app so it manages nothing but the windows this program opens. Positions
// are read from the window server, not from Tilefy, so a wrong answer can't hide behind its own
// bookkeeping.

let controlName = Notification.Name("app.tilefy.e2e-control")

// MARK: - The fixture app: a process whose windows are the test subjects

func runFixture(count: Int) -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    var windows: [NSWindow] = []
    let colors: [NSColor] = [.systemBlue, .systemPurple, .systemTeal, .systemOrange, .systemPink, .systemGreen, .systemIndigo]

    func open() {
        let window = NSWindow(
            contentRect: NSRect(x: 200 + windows.count * 30, y: 200 + windows.count * 30, width: 420, height: 300),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenPrimary]
        window.title = "Window \(windows.count + 1)"
        window.backgroundColor = colors[windows.count % colors.count].withAlphaComponent(0.85)
        window.makeKeyAndOrderFront(nil)
        windows.append(window)
    }

    DistributedNotificationCenter.default().addObserver(forName: controlName, object: nil, queue: .main) { note in
        guard let parts = (note.object as? String)?.split(separator: ":"), let action = parts.first else { return }
        let target = parts.count > 1 ? Int(parts[1]) : nil
        let window = windows.first { $0.windowNumber == target }
        switch action {
        case "open": open()
        case "close": window?.close()
        case "minimize": window?.miniaturize(nil)
        case "restore": window?.deminiaturize(nil)
        case "resize-self":
            if let window { window.setFrame(window.frame.insetBy(dx: 40, dy: 40), display: true) }
        case "quit": exit(0)
        default: break
        }
    }
    for _ in 0..<count { open() }
    app.activate(ignoringOtherApps: true)
    app.run()
    exit(0)
}

if CommandLine.arguments.dropFirst().first == "fixture" {
    runFixture(count: Int(CommandLine.arguments.dropFirst(2).first ?? "") ?? 3)
}

// MARK: - The driver

guard let appArgument = CommandLine.arguments.dropFirst().first else {
    print("usage: TilefyE2E <path to Tilefy.app> [screenshot directory] [--open]")
    exit(64)
}
let tilefyBinary = URL(fileURLWithPath: appArgument).appendingPathComponent("Contents/MacOS/Tilefy").path
let screenshots: String? = CommandLine.arguments.dropFirst(2).first { !$0.hasPrefix("--") }
let launchWithOpen = CommandLine.arguments.contains("--open")

var failures: [String] = []
var passes = 0

@discardableResult
func capture(_ path: String, _ arguments: [String]) -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do { try process.run() } catch { return (-1, "\(error)") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}

func pump(_ seconds: TimeInterval) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
}

func waitUntil(timeout: TimeInterval = 6, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        pump(0.1)
    }
    return condition()
}

func screenshot(_ name: String) {
    guard let screenshots else { return }
    try? FileManager.default.createDirectory(atPath: screenshots, withIntermediateDirectories: true)
    capture("/usr/sbin/screencapture", ["-x", "\(screenshots)/\(name).png"])
}

func check(_ name: String, _ condition: @autoclosure () -> Bool, _ detail: @autoclosure () -> String = "") {
    if condition() {
        passes += 1
        print("  ok    \(name)")
    } else {
        let message = "\(name) \(detail())"
        failures.append(message)
        print("  FAIL  \(message)")
        screenshot("failure-\(failures.count)")
    }
}

func section(_ name: String) {
    print("\n\(name)")
}

// MARK: Launching

let fixture = Process()
fixture.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
fixture.arguments = ["fixture", "3"]
try fixture.run()
let fixturePID = fixture.processIdentifier

func control(_ message: String) {
    DistributedNotificationCenter.default().postNotificationName(controlName, object: message, userInfo: nil, deliverImmediately: true)
}

/// Fixture windows the window server has on screen, front to back, in top-left coordinates.
func fixtureWindows() -> [(id: Int, frame: CGRect)] {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[CFString: Any]] ?? []
    return list.compactMap { info in
        guard info[kCGWindowOwnerPID] as? Int32 == fixturePID, info[kCGWindowLayer] as? Int == 0,
              let id = info[kCGWindowNumber] as? Int,
              let bounds = info[kCGWindowBounds] as? NSDictionary,
              let frame = CGRect(dictionaryRepresentation: bounds)
        else { return nil }
        return (id, frame)
    }
}

func frames() -> [Int: CGRect] {
    Dictionary(uniqueKeysWithValues: fixtureWindows().map { ($0.id, $0.frame) })
}

guard waitUntil({ fixtureWindows().count == 3 }) else {
    print("The fixture's windows never appeared. Is there a display?")
    fixture.terminate()
    exit(2)
}

let configPath = NSTemporaryDirectory() + "tilefy-e2e-\(getpid()).json"
try Data(#"{"innerGap": 8, "outerGap": 8, "defaultLayout": "dwindle"}"#.utf8).write(to: URL(fileURLWithPath: configPath))

capture("/usr/bin/pkill", ["-x", "Tilefy"])
pump(0.5)

var tilefy: Process?
if launchWithOpen {
    // Through Launch Services, so macOS checks Tilefy's own Accessibility permission.
    capture("/usr/bin/open", ["-n", appArgument, "--env", "TILEFY_CONFIG=\(configPath)", "--args", "--only-app=TilefyE2E"])
} else {
    // As a child process, so macOS checks the permission of whatever is running this program (CI).
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tilefyBinary)
    process.arguments = ["--only-app=TilefyE2E"]
    process.environment = ProcessInfo.processInfo.environment.merging(["TILEFY_CONFIG": configPath]) { _, new in new }
    try process.run()
    tilefy = process
}

func cleanUp() {
    capture("/usr/bin/pkill", ["-x", "Tilefy"])
    control("quit")
    pump(0.3)
    if fixture.isRunning { fixture.terminate() }
    try? FileManager.default.removeItem(atPath: configPath)
}

func dispatch(_ command: String) {
    let result = capture(tilefyBinary, ["dispatch", command])
    if result.status != 0 { print("  dispatch \(command) failed: \(result.output)") }
}

func status() -> TilefyStatus? {
    let result = capture(tilefyBinary, ["status"])
    guard result.status == 0 else { return nil }
    return try? JSONDecoder().decode(TilefyStatus.self, from: Data(result.output.utf8))
}

section("Startup")
var firstStatus: TilefyStatus?
_ = waitUntil(timeout: 10) {
    firstStatus = status()
    return firstStatus != nil
}
check("the app is running and answers status", firstStatus != nil)
guard waitUntil(timeout: 5, { status()?.started == true }) else {
    print("""

    Tilefy is running but doesn't have Accessibility permission, so it can't move windows.
    Turn it on in System Settings > Privacy & Security > Accessibility, then run this again.
    """)
    cleanUp()
    exit(3)
}
check("has Accessibility permission", true)

// MARK: Geometry helpers

func screenArea() -> CGRect {
    let primaryHeight = NSScreen.screens[0].frame.height
    let front = fixtureWindows().first?.frame ?? .zero
    let screen = NSScreen.screens.first {
        let flipped = CGRect(x: $0.frame.minX, y: primaryHeight - $0.frame.maxY, width: $0.frame.width, height: $0.frame.height)
        return flipped.contains(CGPoint(x: front.midX, y: front.midY))
    } ?? NSScreen.screens[0]
    let visible = screen.visibleFrame
    return CGRect(x: visible.minX, y: primaryHeight - visible.maxY, width: visible.width, height: visible.height).insetBy(dx: 8, dy: 8)
}

func noneOverlap(_ rects: [CGRect]) -> Bool {
    for (i, a) in rects.enumerated() {
        for b in rects[(i + 1)...] where a.insetBy(dx: 1, dy: 1).intersects(b.insetBy(dx: 1, dy: 1)) { return false }
    }
    return true
}

func coversScreen(_ rects: [CGRect], gaps: Int) -> Bool {
    let area = screenArea()
    let used = rects.reduce(CGFloat(0)) { $0 + $1.width * $1.height }
    return used > area.width * area.height * 0.9 && rects.allSatisfy { area.insetBy(dx: -2, dy: -2).contains($0) }
}

func isTiled(count: Int) -> Bool {
    let rects = Array(frames().values)
    return rects.count == count && noneOverlap(rects) && coversScreen(rects, gaps: count)
}

func describe() -> String {
    "\(frames().sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }) screen \(screenArea())"
}

func isParked(_ frame: CGRect) -> Bool {
    let primaryHeight = NSScreen.screens[0].frame.height
    return NSScreen.screens.allSatisfy {
        let flipped = CGRect(x: $0.frame.minX, y: primaryHeight - $0.frame.maxY, width: $0.frame.width, height: $0.frame.height)
        let overlap = flipped.intersection(frame)
        return overlap.isNull || overlap.width <= 40 || overlap.height <= 40
    }
}

func same(_ a: [Int: CGRect], _ b: [Int: CGRect]) -> Bool {
    guard a.keys == b.keys else { return false }
    return a.allSatisfy { key, frame in
        guard let other = b[key] else { return false }
        return abs(frame.minX - other.minX) < 2 && abs(frame.minY - other.minY) < 2
            && abs(frame.width - other.width) < 2 && abs(frame.height - other.height) < 2
    }
}

// MARK: - Scenarios

section("Layouts")
check("dwindle tiles the existing windows", waitUntil { isTiled(count: 3) }, describe())
pump(0.5)
screenshot("layout-dwindle")

for (command, name) in [("layout-grid", "grid"), ("layout-master", "master"), ("layout-centeredMaster", "centered-master")] {
    dispatch(command)
    check("\(name) tiles the windows", waitUntil { isTiled(count: 3) }, describe())
    pump(0.5)
    screenshot("layout-\(name)")
}

dispatch("layout-grid")
_ = waitUntil { isTiled(count: 3) }
for _ in 0..<3 { control("open") }
check("grid columns are equal in width", waitUntil {
    let widths = frames().values.map(\.width)
    return widths.count == 6 && widths.max()! - widths.min()! <= 1
}, describe())
for id in frames().keys.sorted().suffix(3) { control("close:\(id)") }
_ = waitUntil { isTiled(count: 3) }

dispatch("layout-master")
check("master makes one window larger", waitUntil {
    let widths = frames().values.map(\.width).sorted()
    return widths.count == 3 && widths[2] > widths[0] * 1.1
}, describe())

dispatch("layout-monocle")
check("monocle makes every window fill the screen", waitUntil {
    let rects = Array(frames().values)
    return rects.count == 3 && rects.allSatisfy { abs($0.width - screenArea().width) < 2 && abs($0.height - screenArea().height) < 2 }
}, describe())

section("Focus")
dispatch("focus-next")
pump(0.5)
if let focused = status()?.focusedWindow {
    check("focus moves to and raises the requested window", waitUntil { fixtureWindows().first?.id == Int(focused) }, "front is \(String(describing: fixtureWindows().first?.id)), wanted \(focused)")
    let before = focused
    dispatch("focus-next")
    let moved = waitUntil { status()?.focusedWindow != before }
    check("focus-next changes the focused window", moved)
    if let next = status()?.focusedWindow {
        check("the new window comes to the front", waitUntil { fixtureWindows().first?.id == Int(next) })
    }
    pump(1.8)
    check("focus stays put through a heartbeat", status()?.focusedWindow == status()?.focusedWindow && status()?.workspace == 1)
} else {
    check("status reports a focused window", false)
}

dispatch("layout-dwindle")
check("back to dwindle", waitUntil { isTiled(count: 3) }, describe())

section("Workspaces")
let home = frames()
dispatch("workspace-2")
check("switching parks the windows", waitUntil { frames().values.allSatisfy(isParked) }, describe())
check("parked windows still count as on-screen", frames().count == 3, describe())
pump(0.3)
screenshot("hud-empty-workspace")
pump(2)
check("an empty workspace doesn't bounce back", status()?.workspace == 2, "workspace \(String(describing: status()?.workspace))")
dispatch("workspace-1")
check("switching back restores exact positions", waitUntil { same(frames(), home) }, describe())

if let window = status()?.focusedWindow {
    dispatch("move-to-workspace-3")
    check("move-to-workspace follows the window", waitUntil { status()?.workspace == 3 })
    check("the moved window fills its new workspace", waitUntil {
        guard let frame = frames()[Int(window)] else { return false }
        return abs(frame.width - screenArea().width) < 2
    }, describe())
    check("the windows left behind are parked", waitUntil { frames().filter { $0.key != Int(window) }.values.allSatisfy(isParked) }, describe())
    dispatch("move-to-workspace-1")
    check("and it can come back", waitUntil { status()?.workspace == 1 && isTiled(count: 3) }, describe())
}

section("Windows opening and closing")
control("open")
check("a new window is tiled", waitUntil { isTiled(count: 4) }, describe())
screenshot("four-windows")
if let newest = status()?.focusedWindow {
    check("and takes focus", waitUntil { fixtureWindows().first?.id == Int(newest) })
    control("close:\(newest)")
    check("closing a window closes the hole", waitUntil { isTiled(count: 3) }, describe())
    check("and focus moves to a remaining window", waitUntil {
        guard let focused = status()?.focusedWindow else { return false }
        return frames()[Int(focused)] != nil
    })
}

section("Minimizing")
if let target = frames().keys.sorted().first {
    let before = frames()
    control("minimize:\(target)")
    check("minimizing closes the hole", waitUntil(timeout: 8) { isTiled(count: 2) }, describe())
    control("restore:\(target)")
    check("restoring puts it back in its slot", waitUntil(timeout: 8) { same(frames(), before) }, describe())
}

section("Floating")
if let window = status()?.focusedWindow {
    dispatch("toggle-float")
    check("a floated window lifts out of its tile", waitUntil {
        guard let frame = frames()[Int(window)] else { return false }
        return abs(frame.midX - screenArea().midX) < 3 && abs(frame.midY - screenArea().midY) < 3
    }, describe())
    check("the others take the space", waitUntil {
        let others = frames().filter { $0.key != Int(window) }.values
        return noneOverlap(Array(others)) && coversScreen(Array(others), gaps: 2)
    }, describe())
    screenshot("floating")
    dispatch("toggle-float")
    check("tiling it again restores the layout", waitUntil { isTiled(count: 3) }, describe())
}

section("Scratchpad")
if let window = status()?.focusedWindow {
    dispatch("move-to-scratchpad")
    check("moving to the scratchpad parks the window", waitUntil { frames()[Int(window)].map(isParked) ?? false }, describe())
    dispatch("toggle-scratchpad")
    check("toggling shows it", waitUntil { frames()[Int(window)].map { !isParked($0) } ?? false }, describe())
    dispatch("toggle-scratchpad")
    check("toggling again hides it", waitUntil { frames()[Int(window)].map(isParked) ?? false }, describe())
    dispatch("toggle-scratchpad")
    _ = waitUntil { frames()[Int(window)].map { !isParked($0) } ?? false }
    dispatch("toggle-float")
    check("floating it back into the layout", waitUntil { isTiled(count: 3) }, describe())
}

section("Scrolling layout")
dispatch("layout-scrolling")
for _ in 0..<3 { control("open") }
check("windows open at half width in a row", waitUntil {
    frames().count == 6 && frames().values.filter { !isParked($0) }.allSatisfy { abs($0.width - (screenArea().width - 8) / 2) < 3 }
}, describe())
check("columns that don't fit are out of sight", waitUntil { frames().values.contains(where: isParked) }, describe())
pump(0.3)
screenshot("layout-scrolling")
if let focused = status()?.focusedWindow {
    for _ in 0..<5 { dispatch("focus-left"); pump(0.2) }
    let leftmost = status()?.focusedWindow
    check("focus travels along the row", leftmost != focused)
    check("the viewport follows it", waitUntil {
        guard let leftmost, let frame = frames()[Int(leftmost)] else { return false }
        return screenArea().insetBy(dx: -2, dy: -2).contains(frame)
    }, describe())
    dispatch("cycle-width")
    check("cycle-width makes the column two thirds wide", waitUntil {
        guard let leftmost, let frame = frames()[Int(leftmost)] else { return false }
        return abs(frame.width - ((screenArea().width + 8) * 2 / 3 - 8)) < 3
    }, describe())
}
dispatch("layout-grid")
check("switching layout brings every window back", waitUntil { isTiled(count: 6) }, describe())

section("Apps that resize themselves")
if let target = frames().keys.sorted().first {
    let slot = frames()[target]
    control("resize-self:\(target)")
    _ = waitUntil(timeout: 1) { frames()[target] != slot }
    dispatch("retile")
    check("snap-back corrects it", waitUntil { frames()[target] == slot }, describe())
}

section("Real input (synthesized keyboard and mouse)")
func postKey(_ keyCode: CGKeyCode, flags: CGEventFlags) {
    let source = CGEventSource(stateID: .hidSystemState)
    let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
    let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
    down?.flags = flags
    up?.flags = flags
    down?.post(tap: .cghidEventTap)
    up?.post(tap: .cghidEventTap)
}
if AXIsProcessTrusted() {
    dispatch("layout-dwindle")
    _ = waitUntil { status()?.layout == "dwindle" }
    postKey(CGKeyCode(Hotkey("g")!.keyCode), flags: [.maskControl, .maskAlternate])
    check("the ⌃⌥G shortcut switches to grid", waitUntil { status()?.layout == "grid" }, "layout is \(String(describing: status()?.layout))")
    postKey(CGKeyCode(Hotkey("2")!.keyCode), flags: [.maskControl, .maskAlternate])
    check("the ⌃⌥2 shortcut switches workspace", waitUntil { status()?.workspace == 2 }, "workspace \(String(describing: status()?.workspace))")
    postKey(CGKeyCode(Hotkey("1")!.keyCode), flags: [.maskControl, .maskAlternate])
    _ = waitUntil { status()?.workspace == 1 }

    dispatch("layout-grid")
    _ = waitUntil { isTiled(count: 6) }
    pump(0.5)
    let before = frames()
    let ids = before.keys.sorted()
    if ids.count >= 2, let a = before[ids[0]], let b = before[ids[1]] {
        func mouse(_ type: CGEventType, _ point: CGPoint) {
            let source = CGEventSource(stateID: .hidSystemState)
            let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
            event?.setIntegerValueField(.mouseEventClickState, value: 1)
            event?.flags = []  // Otherwise ⌃ from the shortcuts above lingers, making this a right-click.
            event?.post(tap: .cghidEventTap)
            pump(0.03)
        }
        let start = CGPoint(x: a.midX, y: a.minY + 14)
        let end = CGPoint(x: b.midX, y: b.midY)
        mouse(.mouseMoved, start)
        pump(0.3)
        mouse(.leftMouseDown, start)
        pump(0.3)
        for step in 1...30 {
            let t = CGFloat(step) / 30
            mouse(.leftMouseDragged, CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t))
        }
        pump(0.3)
        let midDrag = frames()[ids[0]] ?? .zero
        print("  note  mid-drag the window is at \(midDrag), it started at \(a)")
        screenshot("mid-drag")
        check("the window follows the mouse", abs(midDrag.minX - a.minX) > 20, "\(midDrag)")
        mouse(.leftMouseUp, end)
        check("dragging a window onto another swaps them", waitUntil {
            let now = frames()
            guard let newA = now[ids[0]], let newB = now[ids[1]] else { return false }
            return abs(newA.minX - b.minX) < 2 && abs(newA.minY - b.minY) < 2 && abs(newB.minX - a.minX) < 2 && abs(newB.minY - a.minY) < 2
        }, describe())
    }

    // Scrolling with the modifier held.
    let startWorkspace = status()?.workspace
    dispatch("workspace-2")
    _ = waitUntil { status()?.workspace == 2 }
    for _ in 0..<8 {
        let scroll = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 10, wheel2: 0, wheel3: 0)
        scroll?.flags = [.maskControl, .maskAlternate]
        scroll?.post(tap: .cghidEventTap)
        pump(0.03)
    }
    check("scrolling with ⌃⌥ held switches workspace", waitUntil { status()?.workspace != 2 }, "workspace \(String(describing: status()?.workspace))")
    if let startWorkspace { dispatch("workspace-\(startWorkspace)") }
    _ = waitUntil { status()?.workspace == startWorkspace }

    // The shortcut recorder in Settings: click a shortcut, press new keys, check it took effect.
    dispatch("open-settings-shortcuts")
    pump(1.2)
    func tilefyWindow() -> CGRect? {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[CFString: Any]] ?? []
        for info in list where info[kCGWindowOwnerName] as? String == "Tilefy" && info[kCGWindowLayer] as? Int == 0 {
            if let bounds = info[kCGWindowBounds] as? NSDictionary, let frame = CGRect(dictionaryRepresentation: bounds) { return frame }
        }
        return nil
    }
    let settings = tilefyWindow()
    let screenFrame = NSScreen.screens[0].frame
    check("the Settings window is centered and fits on screen", settings.map {
        screenFrame.contains($0) && abs($0.midX - screenFrame.midX) < 2
    } ?? false, "\(String(describing: settings)) on \(screenFrame)")
    if let settings {
        // The first row's button, "Focus left", at the right of the list.
        let button = CGPoint(x: settings.maxX - 70, y: settings.minY + 130)
        for type: CGEventType in [.leftMouseDown, .leftMouseUp] {
            let event = CGEvent(mouseEventSource: CGEventSource(stateID: .hidSystemState), mouseType: type, mouseCursorPosition: button, mouseButton: .left)
            event?.setIntegerValueField(.mouseEventClickState, value: 1)
            event?.flags = []
            event?.post(tap: .cghidEventTap)
            pump(0.1)
        }
        pump(0.5)
        screenshot("recorder-waiting")
        postKey(CGKeyCode(Hotkey("y")!.keyCode), flags: [.maskControl, .maskAlternate])
        pump(0.5)
        screenshot("recorder-done")
        let saved = (try? Data(contentsOf: URL(fileURLWithPath: configPath))).flatMap { try? JSONDecoder().decode(Config.self, from: $0) }
        check("the recorder saves the new shortcut", saved?.combo(for: "focus-left") == "ctrl+alt+y", "focus-left is \(String(describing: saved?.combo(for: "focus-left")))")
        check("and frees the old one", saved?.command(boundTo: "ctrl+alt+left") == nil)

        dispatch("layout-monocle")
        _ = waitUntil { status()?.layout == "monocle" }
        dispatch("focus-next")
        pump(0.5)
        let before = status()?.focusedWindow
        postKey(CGKeyCode(Hotkey("y")!.keyCode), flags: [.maskControl, .maskAlternate])
        check("the new shortcut works straight away", waitUntil { status()?.focusedWindow != before }, "focus stayed on \(String(describing: before))")
        dispatch("layout-grid")
        _ = waitUntil { status()?.layout == "grid" }
    }
} else {
    print("  skip  this process can't post input events without Accessibility permission")
}

section("Settings window")
for tab in ["general", "layouts", "shortcuts", "apps"] {
    dispatch("open-settings-\(tab)")
    pump(1)
    screenshot("settings-\(tab)")
}
check("still alive after opening every Settings tab", status() != nil)

section("Pause and quit")
dispatch("workspace-2")
_ = waitUntil { frames().values.allSatisfy(isParked) }
dispatch("toggle-pause")
check("pausing brings parked windows back on-screen", waitUntil { frames().values.allSatisfy { !isParked($0) } }, describe())
dispatch("toggle-pause")
check("resuming parks them again", waitUntil { frames().values.allSatisfy(isParked) }, describe())

let pid = capture("/usr/bin/pgrep", ["-x", "Tilefy"]).output.split(separator: "\n").first.flatMap { Int32($0) }
if let pid { kill(pid, SIGTERM) }
check("quitting brings parked windows back on-screen", waitUntil { frames().values.allSatisfy { !isParked($0) } }, describe())
check("the app exits", waitUntil { capture("/usr/bin/pgrep", ["-x", "Tilefy"]).status != 0 })

cleanUp()
print("\n\(passes) passed, \(failures.count) failed")
for failure in failures { print("  FAIL \(failure)") }
exit(failures.isEmpty ? 0 : 1)
