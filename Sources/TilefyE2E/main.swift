import AppKit
import CTilefyE2E
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
        case "fullscreen":
            window?.toggleFullScreen(nil)
        case "refuse-resizes":
            // An app that won't go below its current size, like a busy or size-limited one.
            if let window { window.minSize = window.frame.size }
        case "allow-resizes":
            window?.minSize = NSSize(width: 100, height: 100)
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
// These change the machine (displays, login items), so only CI asks for them.
let testSecondDisplay = CommandLine.arguments.contains("--second-display")
let testLoginItem = CommandLine.arguments.contains("--login-item")

// Keeps NSScreen up to date as displays come and go, with no Dock icon or menu bar.
_ = NSApplication.shared
NSApp.setActivationPolicy(.prohibited)

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

let statePath = NSTemporaryDirectory() + "tilefy-e2e-state-\(getpid()).json"

func launchTilefy() {
    if launchWithOpen {
        // Through Launch Services, so macOS checks Tilefy's own Accessibility permission.
        capture("/usr/bin/open", [
            "-n", appArgument,
            "--env", "TILEFY_CONFIG=\(configPath)", "--env", "TILEFY_STATE=\(statePath)",
            "--args", "--only-app=TilefyE2E",
        ])
    } else {
        // As a child process, so macOS checks the permission of whatever is running this program (CI).
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tilefyBinary)
        process.arguments = ["--only-app=TilefyE2E"]
        process.environment = ProcessInfo.processInfo.environment.merging([
            "TILEFY_CONFIG": configPath, "TILEFY_STATE": statePath,
        ]) { _, new in new }
        try? process.run()
    }
}
launchTilefy()

func cleanUp() {
    capture("/usr/bin/pkill", ["-x", "Tilefy"])
    control("quit")
    pump(0.3)
    if fixture.isRunning { fixture.terminate() }
    try? FileManager.default.removeItem(atPath: configPath)
    try? FileManager.default.removeItem(atPath: statePath)
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

/// This process can see the visible area a few points differently from the app (it depends on how
/// AppKit was set up in each, and a Dock moving), so "fits on screen" allows for that much.
let areaTolerance: CGFloat = 6

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
    return used > area.width * area.height * 0.9 && rects.allSatisfy { area.insetBy(dx: -areaTolerance, dy: -areaTolerance).contains($0) }
}

func isTiled(count: Int) -> Bool {
    let rects = Array(frames().values)
    return rects.count == count && noneOverlap(rects) && coversScreen(rects, gaps: count)
}

/// Grouped windows share a frame, so this counts tiles, not windows.
func uniqueFrames() -> [CGRect] {
    var seen: [CGRect] = []
    for frame in frames().values where !seen.contains(frame) { seen.append(frame) }
    return seen
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
    return rects.count == 3 && rects.allSatisfy { abs($0.width - screenArea().width) < areaTolerance && abs($0.height - screenArea().height) < areaTolerance }
}, describe())

section("Animations")
func dispatchWithoutWaiting(_ command: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tilefyBinary)
    process.arguments = ["dispatch", command]
    try? process.run()
}

func writeConfig(_ json: String) {
    try? Data(json.utf8).write(to: URL(fileURLWithPath: configPath))
    dispatch("reload-config")
    pump(0.5)
}

/// Every different frame the windows pass through in the next moment, read from the window server.
func distinctFramesDuring(_ seconds: TimeInterval, after action: () -> Void) -> Int {
    var seen: Set<String> = []
    action()
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        for (id, frame) in frames() { seen.insert("\(id) \(frame)") }
        usleep(4000)
    }
    return seen.count
}

// Slower than normal, to be sure of catching it from another process.
writeConfig(#"{"innerGap": 8, "outerGap": 8, "defaultLayout": "dwindle", "animationDuration": 0.5}"#)
dispatch("layout-master")
_ = waitUntil { isTiled(count: 3) }
pump(1)
let animatedFrames = distinctFramesDuring(1) { dispatchWithoutWaiting("layout-dwindle") }
check("windows pass through in-between positions", animatedFrames > 8, "only \(animatedFrames) distinct frames")
check("and end up exactly tiled", waitUntil { isTiled(count: 3) }, describe())
writeConfig(#"{"innerGap": 8, "outerGap": 8, "defaultLayout": "dwindle", "animations": false}"#)
dispatch("layout-master")
_ = waitUntil { isTiled(count: 3) }
pump(0.5)
let instantFrames = distinctFramesDuring(1) { dispatchWithoutWaiting("layout-dwindle") }
check("turning animations off makes moves instant", instantFrames < animatedFrames && instantFrames <= 9, "\(instantFrames) distinct frames, \(animatedFrames) when animated")
writeConfig(#"{"innerGap": 8, "outerGap": 8, "defaultLayout": "dwindle"}"#)
_ = waitUntil { isTiled(count: 3) }

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
        return abs(frame.midX - screenArea().midX) < areaTolerance && abs(frame.midY - screenArea().midY) < areaTolerance
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

section("Window groups")
if let first = status()?.focusedWindow {
    dispatch("toggle-group")
    pump(0.3)
    control("open")
    check("a new window joins the group, sharing its tile", waitUntil {
        guard let newest = status()?.focusedWindow, newest != first,
              let a = frames()[Int(first)], let b = frames()[Int(newest)]
        else { return false }
        return frames().count == 4 && a == b
    }, describe())
    check("the layout still has three tiles", uniqueFrames().count == 3 && noneOverlap(uniqueFrames()), describe())
    screenshot("window-group")
    let newest = status()?.focusedWindow
    check("the newest member is in front", waitUntil { fixtureWindows().first?.id == newest.map(Int.init) })
    dispatch("group-next")
    check("cycling brings the other member forward", waitUntil { fixtureWindows().first?.id == Int(first) && status()?.focusedWindow == first }, "front is \(String(describing: fixtureWindows().first?.id))")
    dispatch("toggle-group")
    check("breaking up the group gives each its own tile", waitUntil { isTiled(count: 4) }, describe())
    if let newest {
        control("close:\(newest)")
        check("back to three", waitUntil { isTiled(count: 3) }, describe())
    }

    // Moving into a group in a direction, and back out.
    dispatch("layout-grid")
    _ = waitUntil { isTiled(count: 3) }
    pump(0.4)
    if let focused = status()?.focusedWindow {
        // In this grid there's something either above or below it, depending on which row it's in.
        let isTopRow = (frames()[Int(focused)]?.minY ?? 0) < screenArea().midY
        dispatch(isTopRow ? "move-into-group-down" : "move-into-group-up")
        check("a window can move into a group next to it", waitUntil { uniqueFrames().count == 2 }, describe())
        dispatch("remove-from-group")
        check("and come back out", waitUntil { status()?.focusedWindow == focused && isTiled(count: 3) }, describe())
    }
    dispatch("layout-dwindle")
    _ = waitUntil { isTiled(count: 3) }
}

section("Sticky windows")
if let window = status()?.focusedWindow {
    dispatch("toggle-sticky")
    check("a sticky window floats", waitUntil {
        guard let frame = frames()[Int(window)] else { return false }
        return abs(frame.midX - screenArea().midX) < areaTolerance
    }, describe())
    pump(0.3)
    let stuck = frames()[Int(window)]
    dispatch("workspace-5")
    check("it stays on screen across workspaces", waitUntil {
        status()?.workspace == 5 && frames().filter { $0.key != Int(window) }.values.allSatisfy(isParked)
    }, describe())
    check("exactly where it was", frames()[Int(window)] == stuck, describe())
    screenshot("sticky")
    pump(2)
    check("it's the focus on the new workspace", status()?.focusedWindow == window && status()?.workspace == 5)
    dispatch("toggle-float")
    pump(0.5)
    dispatch("workspace-1")
    check("tiling it ends being sticky, so it stays behind", waitUntil { frames()[Int(window)].map(isParked) ?? false }, describe())
    dispatch("workspace-5")
    _ = waitUntil { status()?.workspace == 5 }
    dispatch("move-to-workspace-1")
    check("and it can rejoin the others", waitUntil { status()?.workspace == 1 && isTiled(count: 3) }, describe())
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
        return screenArea().insetBy(dx: -areaTolerance, dy: -areaTolerance).contains(frame)
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

section("Apps that refuse a resize")
if let target = frames().keys.sorted().first {
    control("refuse-resizes:\(target)")
    pump(0.2)
    dispatch("layout-master")
    pump(1)
    let refused = frames()[target]
    print("  note  while refusing, the window is \(String(describing: refused))")
    check("Tilefy doesn't crash or hang on it", status() != nil)
    control("allow-resizes:\(target)")
    check("it's put right once the app allows it", waitUntil(timeout: 8) { isTiled(count: 6) }, describe())
    dispatch("layout-grid")
    _ = waitUntil { isTiled(count: 6) }
}

section("Native fullscreen, which is a real Space switch")
if let target = status()?.focusedWindow {
    let before = frames()
    control("fullscreen:\(target)")
    let screenFrame = NSScreen.screens[0].frame
    check("the window goes fullscreen", waitUntil(timeout: 10) {
        frames()[Int(target)].map { abs($0.width - screenFrame.width) < 2 && abs($0.height - screenFrame.height) < 2 } ?? false
    }, describe())
    check("the other windows leave the screen with their Space", waitUntil(timeout: 10) { frames().values.filter { $0.height > 50 }.count == 1 }, describe())
    pump(3.5)
    check("Tilefy leaves the fullscreen window alone", frames()[Int(target)].map { abs($0.width - screenFrame.width) < 2 } ?? false, describe())
    check("no focus or workspace changes while away", status()?.workspace == 1)
    screenshot("native-fullscreen")
    control("fullscreen:\(target)")
    check("leaving fullscreen brings everything back to its slot", waitUntil(timeout: 12) { same(frames(), before) }, describe())
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

func mousePost(_ type: CGEventType, _ point: CGPoint) {
    let source = CGEventSource(stateID: .hidSystemState)
    let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
    event?.setIntegerValueField(.mouseEventClickState, value: 1)
    event?.flags = []
    event?.post(tap: .cghidEventTap)
    pump(0.03)
}

func tilefySettingsWindow() -> CGRect? {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[CFString: Any]] ?? []
    for info in list where info[kCGWindowOwnerName] as? String == "Tilefy" && info[kCGWindowLayer] as? Int == 0 {
        if let bounds = info[kCGWindowBounds] as? NSDictionary, let frame = CGRect(dictionaryRepresentation: bounds) { return frame }
    }
    return nil
}

if testLoginItem {
    section("Launch at login")
    func loginItemRegistered() -> Bool {
        // The list keeps entries that were turned off, so look at this one's state.
        let dump = capture("/usr/bin/sudo", ["-n", "/usr/bin/sfltool", "dumpbtm"]).output.lowercased()
        return dump.components(separatedBy: "uuid:").contains { $0.contains("app.tilefy") && $0.contains("[enabled") }
    }
    dispatch("open-settings-general")
    pump(1.2)

    var seenControls: [String] = []
    func findCheckbox(_ element: AXUIElement, depth: Int = 0) -> AXUIElement? {
        var role: CFTypeRef?
        var title: CFTypeRef?
        var label: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &title)
        AXUIElementCopyAttributeValue(element, kAXDescriptionAttribute as CFString, &label)
        let name = "\(title as? String ?? "") \(label as? String ?? "")"
        if seenControls.count < 40 { seenControls.append("\(role as? String ?? "?"): \(name)") }
        if role as? String == kAXCheckBoxRole, name.contains("login") { return element }
        var children: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
        guard depth < 24, let list = children as? [AXUIElement] else { return nil }
        for child in list {
            if let found = findCheckbox(child, depth: depth + 1) { return found }
        }
        return nil
    }

    if let pid = capture("/usr/bin/pgrep", ["-x", "Tilefy"]).output.split(separator: "\n").first.flatMap({ Int32($0) }),
       let checkbox = findCheckbox(AXUIElementCreateApplication(pid)) {
        check("not registered at first", !loginItemRegistered())
        AXUIElementPerformAction(checkbox, kAXPressAction as CFString)
        pump(1.5)
        screenshot("login-item-on")
        check("turning it on registers a login item", waitUntil { loginItemRegistered() })
        AXUIElementPerformAction(checkbox, kAXPressAction as CFString)
        pump(1.5)
        screenshot("login-item-off")
        check("turning it off removes it", waitUntil { !loginItemRegistered() })
    } else {
        check("found the Launch at login checkbox", false, "\(seenControls)")
    }
}

if testSecondDisplay {
    section("Two displays (a virtual second display)")
    func displays() -> [CGRect] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 8)
        var count: UInt32 = 0
        CGGetActiveDisplayList(8, &ids, &count)
        return ids.prefix(Int(count)).map(CGDisplayBounds)
    }
    dispatch("workspace-1")
    dispatch("layout-grid")
    _ = waitUntil { status()?.workspace == 1 && isTiled(count: 6) }
    let virtualDisplay = TilefyCreateVirtualDisplay(1280, 800)
    pump(0.5)
    if virtualDisplay != nil, waitUntil(timeout: 10, { displays().count == 2 }) {
        let main = displays()[0]
        let second = displays()[1]
        print("  note  displays: \(main) and \(second)")
        pump(2)
        func isOn(_ display: CGRect, _ frame: CGRect) -> Bool {
            display.insetBy(dx: -2, dy: -2).contains(frame)
        }
        check("the windows stay tiled on the first display", waitUntil { frames().values.allSatisfy { isOn(main, $0) } }, describe())

        guard let moving = status()?.focusedWindow else { fatalError("no focused window") }
        dispatch("move-to-monitor-next")
        check("move-to-monitor-next carries the window across", waitUntil { frames()[Int(moving)].map { isOn(second, $0) } ?? false }, describe())
        check("it fills the second display", waitUntil {
            frames()[Int(moving)].map { $0.width > second.width - 20 && $0.height > second.height * 0.8 } ?? false
        }, describe())
        check("focus followed it", status()?.focusedWindow == moving)
        pump(0.3)
        screenshot("two-displays")
        let firstWorkspace = status()?.windows.first { $0.key != String(moving) }?.value
        let secondWorkspace = status()?.workspace
        check("each display has its own workspace", firstWorkspace != nil && firstWorkspace != secondWorkspace, "\(String(describing: firstWorkspace)) and \(String(describing: secondWorkspace))")
        check("the first display fills the gap", waitUntil {
            let rest = frames().filter { $0.key != Int(moving) }.values
            return rest.count == 5 && noneOverlap(Array(rest)) && rest.allSatisfy { isOn(main, $0) }
        }, describe())

        // Parking must not put windows on the neighbouring display.
        dispatch("workspace-7")
        check("a parked window doesn't land on the other display", waitUntil {
            guard let frame = frames()[Int(moving)] else { return false }
            return isParked(frame)
        }, describe())
        if let firstWorkspace { dispatch("workspace-\(firstWorkspace)") }
        if let secondWorkspace { dispatch("workspace-\(secondWorkspace)") }
        check("switching back brings it to the second display", waitUntil { frames()[Int(moving)].map { isOn(second, $0) } ?? false }, describe())

        // The scrolling layout next to another display.
        if let firstWorkspace { dispatch("workspace-\(firstWorkspace)") }
        dispatch("layout-scrolling")
        _ = waitUntil { status()?.layout == "scrolling" }
        pump(1)
        check("scrolled columns don't spill onto the other display", waitUntil {
            frames().filter { $0.key != Int(moving) }.values.allSatisfy { !$0.intersects(second) || isParked($0) }
        }, describe())
        screenshot("two-displays-scrolling")
        dispatch("layout-grid")
        _ = waitUntil { status()?.layout == "grid" }

        // Dragging across displays.
        if let window = frames().first(where: { $0.key != Int(moving) && isOn(main, $0.value) }) {
            pump(0.5)
            let start = CGPoint(x: window.value.midX, y: window.value.minY + 14)
            let end = CGPoint(x: second.midX, y: second.midY)
            mousePost(.mouseMoved, start)
            pump(0.3)
            mousePost(.leftMouseDown, start)
            pump(0.3)
            for step in 1...30 {
                let t = CGFloat(step) / 30
                mousePost(.leftMouseDragged, CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t))
            }
            pump(0.3)
            mousePost(.leftMouseUp, end)
            check("dragging a window to the other display moves it there", waitUntil { frames()[window.key].map { isOn(second, $0) } ?? false }, describe())
            check("and the two share the display", waitUntil {
                guard let a = frames()[window.key], let b = frames()[Int(moving)] else { return false }
                return isOn(second, a) && isOn(second, b) && noneOverlap([a, b])
            }, describe())
        }

        // Unplugging.
        TilefyDestroyVirtualDisplay(virtualDisplay)
        check("the display is gone", waitUntil(timeout: 10) { displays().count == 1 })
        pump(2)
        check("Tilefy survives the unplug", status() != nil)
        if let secondWorkspace {
            dispatch("workspace-\(secondWorkspace)")
            check("its windows are reachable on the remaining display", waitUntil {
                frames()[Int(moving)].map { isOn(main, $0) } ?? false
            }, describe())
        }
        dispatch("workspace-1")
        _ = waitUntil { status()?.workspace == 1 }
    } else {
        print("  skip  this machine won't create a virtual display")
    }
}

section("Restarting Tilefy")
func tilefyPID() -> Int32? {
    capture("/usr/bin/pgrep", ["-x", "Tilefy"]).output.split(separator: "\n").first.flatMap { Int32($0) }
}

func restartAndCheck(signal: Int32, name: String) {
    let beforeFrames = frames()
    let beforeStatus = status()
    pump(1.5)  // Long enough for the state to be saved.
    if let pid = tilefyPID() { kill(pid, signal) }
    _ = waitUntil { tilefyPID() == nil }
    pump(0.5)
    launchTilefy()
    check("\(name): it comes back", waitUntil(timeout: 10) { status()?.started == true })
    check("\(name): every window is back where it was", waitUntil { same(frames(), beforeFrames) }, describe())
    let afterStatus = status()
    check("\(name): the same workspaces and layout", afterStatus?.windows == beforeStatus?.windows && afterStatus?.layout == beforeStatus?.layout && afterStatus?.workspace == beforeStatus?.workspace, "\(String(describing: afterStatus)) vs \(String(describing: beforeStatus))")
}

dispatch("workspace-1")
dispatch("layout-master")
_ = waitUntil { status()?.layout == "master" }
if let window = status()?.focusedWindow {
    dispatch("send-to-workspace-4")
    _ = waitUntil { frames()[Int(window)].map(isParked) ?? false }
    pump(0.5)
    restartAndCheck(signal: SIGTERM, name: "after quitting")
    check("a parked window stays parked", frames()[Int(window)].map(isParked) ?? false, describe())
    restartAndCheck(signal: SIGKILL, name: "after a crash")
    dispatch("workspace-4")
    check("its workspace still works", waitUntil { frames()[Int(window)].map { !isParked($0) } ?? false }, describe())
    dispatch("workspace-1")
    _ = waitUntil { status()?.workspace == 1 }
}

section("Pause and quit")
dispatch("workspace-8")
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
