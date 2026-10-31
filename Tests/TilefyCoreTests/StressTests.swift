import CoreGraphics
import XCTest
@testable import TilefyCore

/// Repeatable pseudo-random numbers, so that a failure can be replayed from its seed.
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Throws long random sequences of commands and events at the engine, and checks after every step
/// that it hasn't lost a window or produced an impossible layout.
final class StressTests: XCTestCase {
    private let monitors = [
        Monitor(
            id: 1,
            frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
            visibleFrame: CGRect(x: 0, y: 37, width: 1728, height: 1010)
        ),
        Monitor(
            id: 2,
            frame: CGRect(x: 1728, y: -200, width: 3008, height: 1692),
            visibleFrame: CGRect(x: 1728, y: -175, width: 3008, height: 1667)
        ),
    ]

    private let commands = [
        "focus-left", "focus-right", "focus-up", "focus-down",
        "swap-left", "swap-right", "swap-up", "swap-down",
        "focus-next", "focus-previous",
        "workspace-1", "workspace-2", "workspace-3", "workspace-next", "workspace-previous", "workspace-last",
        "move-to-workspace-1", "move-to-workspace-2", "move-to-workspace-3",
        "send-to-workspace-1", "send-to-workspace-4",
        "focus-monitor-next", "move-to-monitor-next", "move-workspace-to-monitor-next",
        "layout-dwindle", "layout-scrolling", "layout-master", "layout-centeredMaster",
        "layout-grid", "layout-monocle", "layout-toggle", "layout-next",
        "toggle-split", "toggle-float", "fullscreen", "full-width",
        "cycle-width", "center", "promote", "stack", "unstack",
        "grow-width", "shrink-width", "grow-height", "shrink-height", "balance",
        "toggle-scratchpad", "move-to-scratchpad",
    ]

    private func check(_ engine: TilingEngine, tracked: Set<WindowID>, step: String) {
        let context = "after \(step)"

        // Every window is in exactly one workspace.
        var seen: [WindowID: Int] = [:]
        for ws in engine.workspaces.values {
            for id in ws.allWindows {
                XCTAssertNil(seen[id], "\(id) is in two workspaces \(context)")
                seen[id] = ws.id
            }
            // Every layout's structure agrees with the workspace.
            XCTAssertEqual(Set(ws.dwindle.leaves), Set(ws.order), "dwindle out of sync \(context)")
            XCTAssertEqual(ws.dwindle.leaves.count, ws.order.count, "dwindle has duplicates \(context)")
            let stripped = ws.strip.columns.flatMap(\.windows)
            XCTAssertEqual(Set(stripped), Set(ws.order), "scrolling row out of sync \(context)")
            XCTAssertEqual(stripped.count, ws.order.count, "scrolling row has duplicates \(context)")
            XCTAssertFalse(ws.strip.columns.contains { $0.windows.isEmpty }, "empty column \(context)")
            XCTAssertTrue(ws.suspended.isSubset(of: Set(ws.allWindows)), "stale suspension \(context)")
            if let focused = ws.focused {
                XCTAssertTrue(ws.contains(focused), "focus on a window from elsewhere \(context)")
                XCTAssertFalse(ws.suspended.contains(focused), "focus on a suspended window \(context)")
            }
        }
        XCTAssertEqual(Set(seen.keys), tracked, "window lost or invented \(context)")

        // Every display shows a different workspace, and the scratchpad is never one of them.
        let shown = engine.monitors.compactMap { engine.activeWorkspaceID(on: $0.id) }
        XCTAssertEqual(Set(shown).count, engine.monitors.count, "one workspace on two displays \(context)")
        XCTAssertFalse(shown.contains(TilingEngine.scratchpadID), "scratchpad shown as a workspace \(context)")

        let plan = engine.plan()
        XCTAssertTrue(Set(plan.frames.keys).isSubset(of: tracked), "plan for an unknown window \(context)")
        XCTAssertTrue(Set(plan.hidden.keys).isSubset(of: tracked), "hiding an unknown window \(context)")

        // Every tiled window has a place, unless it's suspended, and none is both shown and hidden.
        for ws in engine.workspaces.values {
            for id in ws.visibleTiled {
                XCTAssertTrue(plan.frames[id] != nil || plan.hidden[id] != nil, "\(id) has no place \(context)")
            }
            for id in ws.suspended {
                XCTAssertNil(plan.frames[id], "moving suspended \(id) \(context)")
                XCTAssertNil(plan.hidden[id], "hiding suspended \(id) \(context)")
            }
        }

        // Tiled windows are on their display, with sensible sizes, and don't overlap.
        for monitor in engine.monitors {
            guard let workspaceID = engine.activeWorkspaceID(on: monitor.id),
                  let ws = engine.workspaces[workspaceID]
            else { continue }
            let frames = ws.visibleTiled.compactMap { id in plan.frames[id].map { (id, $0) } }
            for (id, frame) in frames {
                XCTAssertGreaterThan(frame.width, 0, "\(id) has no width \(context)")
                XCTAssertGreaterThan(frame.height, 0, "\(id) has no height \(context)")
                XCTAssertTrue(frame.minX.isFinite && frame.minY.isFinite, "\(id) has a bad frame \(context)")
                if ws.layout != .scrolling {
                    XCTAssertTrue(monitor.frame.contains(frame), "\(id) \(frame) off its display \(context)")
                }
            }
            guard ws.layout != .monocle, ws.fullscreen == nil else { continue }
            for (i, a) in frames.enumerated() {
                for b in frames[(i + 1)...] {
                    let overlap = a.1.intersection(b.1)
                    XCTAssertTrue(overlap.isNull || overlap.isEmpty, "\(a.0) overlaps \(b.0) in \(ws.layout) \(context)")
                }
            }
        }
    }

    func testRandomSequencesNeverBreakTheEngine() {
        for seed in UInt64(1)...200 {
            var random = SeededGenerator(state: seed)
            var frames: [WindowID: CGRect] = [:]
            let engine = TilingEngine(options: TilingOptions(innerGap: 8, outerGap: 8)) { frames[$0] }
            engine.setMonitors(monitors)

            var tracked: Set<WindowID> = []
            var suspended: Set<WindowID> = []
            var nextID: WindowID = 1

            for stepNumber in 0..<300 {
                var step: String
                switch Int.random(in: 0..<100, using: &random) {
                case 0..<15:
                    let id = nextID
                    nextID += 1
                    tracked.insert(id)
                    frames[id] = CGRect(x: 100, y: 100, width: 500, height: 400)
                    let floating = Bool.random(using: &random) && Int.random(in: 0..<4, using: &random) == 0
                    engine.addWindow(id, floating: floating, monitor: Bool.random(using: &random) ? 1 : 2, focus: Bool.random(using: &random))
                    step = "open \(id)"
                case 15..<25:
                    guard let id = tracked.sorted().randomElement(using: &random) else { continue }
                    tracked.remove(id)
                    suspended.remove(id)
                    engine.removeWindow(id)
                    step = "close \(id)"
                case 25..<30:
                    guard let id = tracked.sorted().randomElement(using: &random) else { continue }
                    if suspended.remove(id) != nil {
                        engine.resumeWindow(id)
                    } else {
                        suspended.insert(id)
                        engine.suspendWindow(id)
                    }
                    step = "toggle suspend \(id)"
                case 30..<40:
                    guard let id = tracked.sorted().randomElement(using: &random) else { continue }
                    engine.focusChanged(to: id)
                    step = "system focus \(id)"
                case 40..<43:
                    guard let id = tracked.sorted().randomElement(using: &random) else { continue }
                    let point = CGPoint(x: .random(in: 0...4000, using: &random), y: .random(in: 0...1000, using: &random))
                    engine.drop(id, at: point)
                    step = "drop \(id) at \(point)"
                case 43..<46:
                    guard let id = tracked.sorted().randomElement(using: &random) else { continue }
                    engine.grow(id, width: .random(in: -500...500, using: &random), height: .random(in: -500...500, using: &random))
                    step = "drag-resize \(id)"
                case 46..<48:
                    engine.setMonitors(Bool.random(using: &random) ? [monitors[0]] : monitors)
                    step = "displays changed"
                default:
                    let command = commands.randomElement(using: &random)!
                    engine.perform(Command(command)!)
                    step = command
                }
                check(engine, tracked: tracked, step: "\(step) (seed \(seed), step \(stepNumber))")
                if (testRun?.failureCount ?? 0) > 0 { return }
            }
        }
    }

    /// The same, but through the coordinator with the simulated Mac, including its timing.
    func testRandomEventsNeverBreakTheCoordinator() {
        for seed in UInt64(1000)...1060 {
            var random = SeededGenerator(state: seed)
            let mac = SimulatedMac()
            mac.monitors = monitors
            let coordinator = WindowCoordinator(config: Config(), system: mac)
            coordinator.start()
            var nextID: WindowID = 1

            for stepNumber in 0..<200 {
                var step = ""
                switch Int.random(in: 0..<100, using: &random) {
                case 0..<20:
                    mac.open(nextID, pid: Int32.random(in: 100...103, using: &random), focus: Bool.random(using: &random))
                    coordinator.scheduleReconcile(full: false)
                    step = "open \(nextID)"
                    nextID += 1
                case 20..<30:
                    guard let id = mac.windows.filter({ $0.value.exists }).keys.sorted().randomElement(using: &random) else { continue }
                    mac.close(window: id)
                    coordinator.windowDestroyed()
                    step = "close \(id)"
                case 30..<40:
                    guard let id = mac.windows.filter({ $0.value.exists }).keys.sorted().randomElement(using: &random) else { continue }
                    mac.windows[id]!.onScreen.toggle()
                    coordinator.scheduleReconcile(full: true)
                    step = "toggle on-screen \(id)"
                case 40..<50:
                    guard let id = mac.windows.filter({ $0.value.exists && $0.value.onScreen }).keys.sorted().randomElement(using: &random) else { continue }
                    mac.userFocuses(id)
                    coordinator.systemFocusChanged()
                    step = "focus \(id)"
                case 50..<55:
                    coordinator.setPaused(!coordinator.isPaused)
                    step = "toggle pause"
                default:
                    let command = commands.randomElement(using: &random)!
                    coordinator.run(command)
                    step = command
                }
                mac.advance(Double.random(in: 0...1, using: &random))

                let context = "after \(step) (seed \(seed), step \(stepNumber))"
                let alive = Set(mac.windows.filter { $0.value.exists }.keys)
                for ws in coordinator.engine.workspaces.values {
                    if !coordinator.isPaused {
                        // Heartbeats clear closed windows, so give any stragglers one first.
                        continue
                    }
                    XCTAssertTrue(Set(ws.allWindows).isSubset(of: Set(mac.windows.keys)), "unknown window \(context)")
                }
                if !coordinator.isPaused {
                    mac.advance(WindowCoordinator.heartbeatInterval + 0.01)
                    if coordinator.isPaused { continue }
                    let managed = Set(coordinator.engine.workspaces.values.flatMap(\.allWindows))
                    XCTAssertTrue(managed.isSubset(of: alive), "still managing a closed window \(context)")
                    let showing = Set(mac.windows.filter { $0.value.exists && $0.value.onScreen }.keys)
                    XCTAssertTrue(showing.isSubset(of: managed), "window not picked up \(context)")
                }
                if (testRun?.failureCount ?? 0) > 0 { return }
            }
        }
    }
}
