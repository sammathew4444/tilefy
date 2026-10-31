import CoreGraphics
import XCTest
@testable import TilefyCore

final class CoordinatorTests: XCTestCase {
    private var mac: SimulatedMac!
    private var coordinator: WindowCoordinator!

    private func start(windows: Int = 0, config: Config = Config()) {
        mac = SimulatedMac()
        for i in 0..<windows { mac.open(WindowID(i + 1)) }
        coordinator = WindowCoordinator(config: config, system: mac)
        coordinator.start()
    }

    /// Lets a window event reach the coordinator the way the real notifications do.
    private func settle() {
        coordinator.scheduleReconcile(full: false)
        mac.advance(0.5)
    }

    private func heartbeat() {
        mac.advance(WindowCoordinator.heartbeatInterval + 0.01)
    }

    private var tiled: Int { coordinator.engine.activeWorkspace?.visibleTiled.count ?? 0 }

    // MARK: - Finding windows

    func testFirstLaunchTilesWhatsAlreadyOpen() {
        start(windows: 3)
        XCTAssertEqual(tiled, 3)
        XCTAssertFalse(mac.windows[1]!.frame.intersects(mac.windows[2]!.frame))
        XCTAssertEqual(coordinator.engine.focusedWindow, 3, "matches what macOS says is focused")
    }

    func testWindowsStayOnTheDisplayTheyreOn() {
        mac = SimulatedMac()
        mac.monitors.append(Monitor(
            id: 2,
            frame: CGRect(x: 1600, y: 0, width: 1000, height: 800),
            visibleFrame: CGRect(x: 1600, y: 0, width: 1000, height: 800)
        ))
        mac.open(1)
        mac.open(2)
        mac.windows[2]!.frame.origin.x = 1800
        coordinator = WindowCoordinator(config: Config(), system: mac)
        coordinator.start()
        XCTAssertLessThan(mac.windows[1]!.frame.maxX, 1600)
        XCTAssertGreaterThanOrEqual(mac.windows[2]!.frame.minX, 1600)
    }

    func testNewWindowIsTiledAndFocused() {
        start(windows: 1)
        mac.open(2)
        settle()
        XCTAssertEqual(tiled, 2)
        XCTAssertEqual(coordinator.engine.focusedWindow, 2)
        XCTAssertEqual(mac.windows[1]!.frame.width, mac.windows[2]!.frame.width, accuracy: 1)
    }

    func testBackgroundWindowDoesntStealFocus() {
        start(windows: 1)
        mac.open(2, focus: false)
        settle()
        XCTAssertEqual(tiled, 2)
        XCTAssertEqual(coordinator.engine.focusedWindow, 1)
    }

    func testAppResizingItsNewWindowGetsCorrected() {
        start(windows: 1)
        mac.open(2)
        settle()
        let slot = mac.windows[2]!.frame
        mac.open(3, focus: false)
        coordinator.scheduleReconcile(full: false)
        mac.advance(0.1)
        let adjusted = mac.windows[3]!.frame
        mac.windows[3]!.frame.size.width = 300
        mac.advance(0.5)
        XCTAssertEqual(mac.windows[3]!.frame, adjusted)
        XCTAssertNotEqual(mac.windows[3]!.frame, slot)
    }

    func testAWindowNotReadyYetIsPickedUpLater() {
        start(windows: 1)
        mac.open(2, focus: false)
        mac.windows[2]!.isReady = false
        settle()
        XCTAssertEqual(tiled, 1)
        mac.windows[2]!.isReady = true
        heartbeat()
        XCTAssertEqual(tiled, 2)
    }

    func testARejectedWindowStopsBeingChecked() {
        start(windows: 1)
        mac.open(2, focus: false)
        mac.windows[2]!.isReady = false
        settle()
        mac.advance(5)
        mac.windows[2]!.isReady = true
        heartbeat()
        XCTAssertEqual(tiled, 1, "after a few seconds it's treated as a dialog or similar")
    }

    func testFixedSizeWindowsFloat() {
        start(windows: 1)
        mac.open(2, focus: false, cannotTile: true)
        let frame = mac.windows[2]!.frame
        settle()
        XCTAssertEqual(tiled, 1)
        XCTAssertEqual(mac.windows[2]!.frame, frame, "left where it is")
    }

    func testFloatRuleFromConfig() {
        var config = Config()
        config.floatApps = ["com.example.notes"]
        start(windows: 1, config: config)
        mac.open(2, focus: false, bundleID: "com.example.notes")
        settle()
        XCTAssertEqual(tiled, 1)
        XCTAssertEqual(coordinator.engine.workspace(containing: 2)?.isFloating(2), true)
    }

    func testAppWorkspaceRuleSendsWindowsToTheirWorkspace() {
        var config = Config()
        config.appWorkspaces = ["com.example.mail": 4]
        start(windows: 1, config: config)
        mac.open(2, focus: false, bundleID: "com.example.mail")
        settle()
        XCTAssertEqual(coordinator.engine.workspace(containing: 2)?.id, 4)
        XCTAssertTrue(mac.isParked(2))
        XCTAssertEqual(coordinator.engine.activeWorkspace?.id, 1)
    }

    // MARK: - Windows going away

    func testClosingTheFocusedWindowFocusesAnother() {
        start(windows: 2)
        mac.close(window: 2)
        coordinator.windowDestroyed()
        mac.advance(0.5)
        XCTAssertEqual(tiled, 1)
        XCTAssertEqual(mac.focusRequests.last, 1)
        XCTAssertEqual(mac.windows[1]!.frame.width, 1584, "the remaining window takes the space")
    }

    func testClosingABackgroundWindowLeavesFocusAlone() {
        start(windows: 2)
        mac.close(window: 1)
        coordinator.windowDestroyed()
        mac.advance(0.5)
        XCTAssertTrue(mac.focusRequests.isEmpty)
        XCTAssertEqual(coordinator.engine.focusedWindow, 2)
    }

    func testMissedCloseEventIsCaughtByTheHeartbeat() {
        start(windows: 2)
        mac.close(window: 1)
        heartbeat()
        XCTAssertEqual(tiled, 1)
    }

    func testMinimizedWindowKeepsItsSlotAndComesBack() {
        start(windows: 3)
        let before = mac.windows.mapValues(\.frame)
        mac.windows[2]!.onScreen = false
        settle()
        XCTAssertEqual(tiled, 2)
        XCTAssertTrue(mac.focusRequests.isEmpty, "macOS picks the next window itself")

        mac.windows[2]!.onScreen = true
        settle()
        XCTAssertEqual(mac.windows.mapValues(\.frame), before)
    }

    // MARK: - Native Spaces and fullscreen

    func testSwitchingNativeSpaceDoesntMoveOrFocusAnything() {
        start(windows: 2)
        let moves = mac.moveCount
        for id: WindowID in [1, 2] { mac.windows[id]!.onScreen = false }
        coordinator.scheduleReconcile(full: true)
        mac.advance(0.1)
        XCTAssertEqual(mac.moveCount, moves)
        XCTAssertTrue(mac.focusRequests.isEmpty, "focusing a window on another Space would drag you back to it")
    }

    func testReturningToANativeSpaceRestoresTheLayout() {
        start(windows: 3)
        let before = mac.windows.mapValues(\.frame)
        for id: WindowID in [1, 2, 3] { mac.windows[id]!.onScreen = false }
        coordinator.scheduleReconcile(full: true)
        mac.advance(0.1)

        // A window opened on the other Space takes the slot there.
        mac.open(4)
        coordinator.scheduleReconcile(full: true)
        mac.advance(0.5)
        XCTAssertEqual(mac.windows[4]!.frame.width, 1584)

        mac.windows[4]!.onScreen = false
        for id: WindowID in [1, 2, 3] { mac.windows[id]!.onScreen = true }
        coordinator.scheduleReconcile(full: true)
        mac.advance(0.5)
        for id: WindowID in [1, 2, 3] { XCTAssertEqual(mac.windows[id]!.frame, before[id]) }
    }

    func testNativeFullscreenWindowIsLeftAlone() {
        start(windows: 2)
        mac.windows[2]!.fullScreen = true
        let fullscreenFrame = CGRect(x: 0, y: 0, width: 1600, height: 1000)
        mac.windows[2]!.frame = fullscreenFrame
        mac.windows[1]!.onScreen = false
        coordinator.scheduleReconcile(full: true)
        mac.advance(0.5)
        XCTAssertEqual(mac.windows[2]!.frame, fullscreenFrame)

        mac.windows[2]!.fullScreen = false
        mac.windows[1]!.onScreen = true
        heartbeat()
        XCTAssertEqual(tiled, 2)
        XCTAssertNotEqual(mac.windows[2]!.frame, fullscreenFrame)
    }

    // MARK: - Focus

    func testEmptyWorkspaceDoesntBounceBack() {
        start(windows: 2)
        coordinator.run("workspace-2")
        XCTAssertEqual(coordinator.engine.activeWorkspace?.id, 2)
        XCTAssertTrue(mac.isParked(1))
        for _ in 0..<5 { heartbeat() }
        XCTAssertEqual(coordinator.engine.activeWorkspace?.id, 2)
    }

    func testEmptyWorkspaceTakesKeyboardFocusFromHiddenWindows() {
        start(windows: 1)
        coordinator.run("workspace-2")
        XCTAssertEqual(mac.clearFocusCount, 1, "keystrokes must not go to a window out of sight")
    }

    func testEmptyWorkspaceBouncesBackEvenIfFocusCantBeCleared() {
        // clearFocus has no effect here: macOS keeps saying the hidden window is focused.
        start(windows: 1)
        coordinator.run("workspace-2")
        mac.tilefyIsFrontmost = false
        for _ in 0..<3 { heartbeat() }
        XCTAssertEqual(coordinator.engine.activeWorkspace?.id, 2)
    }

    func testCmdTabBackAfterEmptyWorkspaceRevealsTheWindow() {
        start(windows: 1)
        coordinator.run("workspace-2")
        heartbeat()
        mac.userFocuses(1)
        coordinator.systemFocusChanged()
        XCTAssertEqual(coordinator.engine.activeWorkspace?.id, 1)
        XCTAssertFalse(mac.isParked(1))
    }

    func testWindowOpenedRightAfterASwitchStillGetsFocus() {
        start(windows: 1)
        coordinator.run("workspace-2")
        mac.open(2, pid: 200)
        coordinator.scheduleReconcile(full: false)
        mac.advance(0.1)
        XCTAssertEqual(coordinator.engine.focusedWindow, 2)
    }

    func testRapidFocusCommandsArentUndoneByLateReports() {
        start(windows: 3)
        mac.focusDelay = 0.2
        coordinator.run("focus-up")     // 3 -> 2
        coordinator.run("focus-left")   // 2 -> 1
        mac.advance(0.21)               // reports of 2, then 1, come in around here
        coordinator.systemFocusChanged()
        XCTAssertEqual(coordinator.engine.focusedWindow, 1)
    }

    func testFocusSurvivesTheWindowListComingBackEmpty() {
        // Seen on a real Mac: Tilefy lost focus for good, so shortcuts did nothing until a click.
        start(windows: 2)
        XCTAssertEqual(coordinator.engine.focusedWindow, 2)
        for id: WindowID in [1, 2] { mac.windows[id]!.onScreen = false }
        coordinator.scheduleReconcile(full: true)
        mac.advance(0.1)
        XCTAssertNil(coordinator.engine.focusedWindow)

        for id: WindowID in [1, 2] { mac.windows[id]!.onScreen = true }
        coordinator.scheduleReconcile(full: true)
        mac.advance(0.1)
        XCTAssertEqual(coordinator.engine.focusedWindow, 2, "the window macOS says is focused, not just any")
        coordinator.run("focus-left")
        XCTAssertEqual(coordinator.engine.focusedWindow, 1, "shortcuts work again")
    }

    func testFocusOnAnEmptyDisplayIsntPulledBack() {
        mac = SimulatedMac()
        mac.monitors.append(Monitor(
            id: 2,
            frame: CGRect(x: 1600, y: 0, width: 1000, height: 800),
            visibleFrame: CGRect(x: 1600, y: 0, width: 1000, height: 800)
        ))
        mac.open(1)
        coordinator = WindowCoordinator(config: Config(), system: mac)
        coordinator.start()
        coordinator.run("focus-monitor-next")
        XCTAssertEqual(coordinator.engine.focusedMonitor, 2)
        for _ in 0..<3 { heartbeat() }
        XCTAssertEqual(coordinator.engine.focusedMonitor, 2)
    }

    func testCmdTabToAHiddenWorkspaceSwitchesToIt() {
        start(windows: 1)
        coordinator.run("workspace-2")
        mac.open(2, pid: 200)
        settle()
        mac.userFocuses(1)
        coordinator.systemFocusChanged()
        XCTAssertEqual(coordinator.engine.activeWorkspace?.id, 1)
        XCTAssertTrue(mac.isParked(2))
        XCTAssertFalse(mac.isParked(1))
    }

    func testClickingAWindowMovesFocusAndScrollsTheRow() {
        var config = Config()
        config.defaultLayout = .scrolling
        start(windows: 5, config: config)
        XCTAssertTrue(mac.isParked(1))
        mac.userFocuses(1)
        coordinator.systemFocusChanged()
        XCTAssertFalse(mac.isParked(1))
        XCTAssertEqual(coordinator.engine.focusedWindow, 1)
    }

    func testLateFocusReportOfThePreviousWindowIsIgnored() {
        start(windows: 2)
        mac.focusDelay = 0.2
        coordinator.run("focus-left")
        XCTAssertEqual(coordinator.engine.focusedWindow, 1)
        // macOS hasn't caught up, and reports the old window.
        coordinator.systemFocusChanged()
        XCTAssertEqual(coordinator.engine.focusedWindow, 1, "must not snap back")
        mac.advance(0.3)
        coordinator.systemFocusChanged()
        XCTAssertEqual(coordinator.engine.focusedWindow, 1)
    }

    func testAppRefusingFocusIsCorrectedByReality() {
        start(windows: 2)
        mac.refuseFocus = true
        coordinator.run("focus-left")
        XCTAssertEqual(coordinator.engine.focusedWindow, 1)
        mac.advance(WindowCoordinator.focusGuard + 0.1)
        coordinator.systemFocusChanged()
        XCTAssertEqual(coordinator.engine.focusedWindow, 2, "window 2 really still has focus")
    }

    func testUntrackedAppInFrontHidesBorder() {
        start(windows: 1)
        mac.advance(0.01)
        XCTAssertNotNil(mac.border)
        mac.frontPID = 999
        coordinator.systemFocusChanged()
        XCTAssertNil(mac.border)
    }

    func testBorderReturnsWhenReturningFromSettings() {
        start(windows: 1)
        mac.tilefyIsFrontmost = true
        coordinator.systemFocusChanged()
        XCTAssertNil(mac.border)
        mac.userFocuses(1)
        coordinator.systemFocusChanged()
        XCTAssertEqual(mac.border, mac.windows[1]!.frame)
    }

    func testFocusBorderCanBeTurnedOff() {
        var config = Config()
        config.focusBorder = false
        start(windows: 1, config: config)
        coordinator.run("retile")
        XCTAssertNil(mac.border)
    }

    // MARK: - Commands

    func testCloseCommandAsksTheAppToClose() {
        start(windows: 2)
        coordinator.run("close")
        XCTAssertEqual(mac.closed, [2])
        XCTAssertEqual(tiled, 2, "it's gone only once the app actually closes it")
    }

    func testUnknownCommandIsIgnored() {
        start(windows: 1)
        coordinator.run("explode")
        XCTAssertEqual(tiled, 1)
    }

    func testHUDAppearsWhenWorkspaceOrLayoutChanges() {
        start(windows: 1)
        coordinator.run("focus-left")
        XCTAssertTrue(mac.hud.isEmpty)
        coordinator.run("workspace-3")
        coordinator.run("layout-grid")
        XCTAssertEqual(mac.hud, ["3  ·  Dwindle", "3  ·  Grid"])
    }

    func testHUDCanBeTurnedOff() {
        var config = Config()
        config.showHUD = false
        start(windows: 1, config: config)
        coordinator.run("workspace-3")
        XCTAssertTrue(mac.hud.isEmpty)
    }

    func testGapChangesApplyImmediately() {
        start(windows: 1)
        var config = coordinator.config
        config.outerGap = 40
        coordinator.update(config: config)
        XCTAssertEqual(mac.windows[1]!.frame.minX, 40)
    }

    func testStatusReportsState() {
        start(windows: 2)
        coordinator.run("layout-grid")
        coordinator.run("move-to-workspace-3")
        let status = coordinator.status()
        XCTAssertEqual(status.workspace, 3)
        XCTAssertEqual(status.layout, "dwindle")
        XCTAssertEqual(status.focusedWindow, 2)
        XCTAssertEqual(status.occupiedWorkspaces, [1, 3])
        XCTAssertEqual(status.windows, ["1": 1, "2": 3])
    }

    func testScrollSwitchesWorkspacesOnceTheThresholdIsPassed() {
        start(windows: 1)
        coordinator.run("workspace-5")
        mac.open(2)
        settle()
        coordinator.scrolled(dx: 0, dy: -10)
        XCTAssertEqual(coordinator.engine.activeWorkspace?.id, 5, "not far enough yet")
        coordinator.scrolled(dx: 0, dy: -25)
        XCTAssertEqual(coordinator.engine.activeWorkspace?.id, 1)
    }

    // MARK: - Dragging

    private func drag(_ id: WindowID, to frame: CGRect, cursor: CGPoint) {
        mac.mouseDown = true
        mac.windows[id]!.frame = frame
        coordinator.windowGeometryChanged(id)
        mac.advance(0.1)
        mac.mouse = cursor
        mac.mouseDown = false
        mac.advance(0.1)
    }

    func testDraggingOntoAnotherWindowSwapsThem() {
        start(windows: 2)
        let slot1 = mac.windows[1]!.frame
        let slot2 = mac.windows[2]!.frame
        drag(1, to: slot1.offsetBy(dx: 900, dy: 0), cursor: CGPoint(x: slot2.midX, y: slot2.midY))
        XCTAssertEqual(mac.windows[1]!.frame, slot2)
        XCTAssertEqual(mac.windows[2]!.frame, slot1)
    }

    func testDraggingToNowhereSnapsBack() {
        start(windows: 1)
        let slot = mac.windows[1]!.frame
        drag(1, to: slot.offsetBy(dx: 100, dy: 100), cursor: CGPoint(x: slot.midX, y: slot.midY))
        XCTAssertEqual(mac.windows[1]!.frame, slot)
    }

    func testDraggingOntoAnotherDisplayMovesTheWindow() {
        mac = SimulatedMac()
        let second = Monitor(
            id: 2,
            frame: CGRect(x: 1600, y: 0, width: 1000, height: 800),
            visibleFrame: CGRect(x: 1600, y: 0, width: 1000, height: 800)
        )
        mac.monitors.append(second)
        mac.open(1)
        mac.open(2)
        coordinator = WindowCoordinator(config: Config(), system: mac)
        coordinator.start()
        drag(2, to: mac.windows[2]!.frame.offsetBy(dx: 900, dy: 0), cursor: CGPoint(x: 2000, y: 400))
        XCTAssertGreaterThanOrEqual(mac.windows[2]!.frame.minX, 1600)
        XCTAssertEqual(mac.windows[1]!.frame.width, 1584, "the window left behind takes the space")
    }

    func testResizingAWindowResizesTheLayoutAroundIt() {
        start(windows: 2)
        var resized = mac.windows[1]!.frame
        resized.size.width += 200
        drag(1, to: resized, cursor: .zero)
        XCTAssertEqual(mac.windows[1]!.frame.width, resized.width, accuracy: 3)
        XCTAssertFalse(mac.windows[1]!.frame.intersects(mac.windows[2]!.frame))
    }

    func testDraggedWindowIsntPulledAwayMidDrag() {
        start(windows: 2)
        let held = mac.windows[1]!.frame.offsetBy(dx: 50, dy: 50)
        mac.mouseDown = true
        mac.windows[1]!.frame = held
        coordinator.windowGeometryChanged(1)
        mac.open(3, focus: false)
        coordinator.scheduleReconcile(full: false)
        mac.advance(0.2)
        XCTAssertEqual(mac.windows[1]!.frame, held)
        mac.mouseDown = false
        mac.advance(0.5)
        XCTAssertNotEqual(mac.windows[1]!.frame, held)
    }

    func testFloatsStayWhereTheyreDropped() {
        start(windows: 1)
        mac.open(2, cannotTile: true)
        settle()
        let dropped = CGRect(x: 700, y: 300, width: 500, height: 400)
        drag(2, to: dropped, cursor: CGPoint(x: 950, y: 500))
        XCTAssertEqual(mac.windows[2]!.frame, dropped)
    }

    func testMovementWithoutTheMouseIsntTreatedAsADrag() {
        start(windows: 2)
        let moved = mac.windows[1]!.frame.offsetBy(dx: 30, dy: 0)
        mac.windows[1]!.frame = moved
        coordinator.windowGeometryChanged(1)
        mac.advance(0.2)
        XCTAssertEqual(mac.windows[1]!.frame, moved, "stays put until the next layout or ⌃⌥E")
        coordinator.run("retile")
        XCTAssertNotEqual(mac.windows[1]!.frame, moved)
    }

    // MARK: - Pausing and stopping

    func testPauseBringsParkedWindowsBackAndLeavesTheRestAlone() {
        start(windows: 2)
        coordinator.run("workspace-2")
        mac.open(3, pid: 200)
        settle()
        XCTAssertTrue(mac.isParked(1))

        coordinator.setPaused(true)
        XCTAssertFalse(mac.isParked(1))
        XCTAssertFalse(mac.isParked(2))

        let frames = mac.windows.mapValues(\.frame)
        mac.open(4, focus: false)
        heartbeat()
        coordinator.run("layout-grid")
        XCTAssertEqual(mac.windows[3]!.frame, frames[3], "nothing moves while paused")
        XCTAssertEqual(tiled, 1, "new windows wait until tiling resumes")
    }

    func testResumeTilesEverythingAgain() {
        start(windows: 2)
        coordinator.setPaused(true)
        mac.open(3, focus: false)
        mac.windows[1]!.frame = CGRect(x: 5, y: 5, width: 200, height: 200)
        coordinator.setPaused(false)
        XCTAssertEqual(tiled, 3)
        XCTAssertNotEqual(mac.windows[1]!.frame.width, 200)
    }

    func testQuittingBringsParkedWindowsBack() {
        var config = Config()
        config.defaultLayout = .scrolling
        start(windows: 6, config: config)
        let parked = mac.windows.keys.filter { mac.isParked($0) }
        XCTAssertFalse(parked.isEmpty)
        coordinator.stop()
        for id in mac.windows.keys { XCTAssertFalse(mac.isParked(id), "window \(id)") }
        let origins = parked.map { mac.windows[$0]!.frame.origin }
        XCTAssertEqual(origins.count, Array(Set(origins.map(\.x))).count, "cascaded so each can be clicked")
    }

    func testNothingHappensAfterStopping() {
        start(windows: 1)
        coordinator.stop()
        let frame = mac.windows[1]!.frame
        mac.open(2)
        heartbeat()
        coordinator.run("layout-grid")
        XCTAssertEqual(mac.windows[1]!.frame, frame)
    }

    // MARK: - Displays

    func testUnpluggingADisplayKeepsItsWindowsReachable() {
        mac = SimulatedMac()
        let second = Monitor(
            id: 2,
            frame: CGRect(x: 1600, y: 0, width: 1000, height: 800),
            visibleFrame: CGRect(x: 1600, y: 0, width: 1000, height: 800)
        )
        mac.monitors.append(second)
        mac.open(1)
        mac.open(2)
        mac.windows[2]!.frame.origin.x = 1800
        coordinator = WindowCoordinator(config: Config(), system: mac)
        coordinator.start()
        let workspace = coordinator.engine.workspace(containing: 2)!.id

        mac.monitors.removeLast()
        coordinator.displaysChanged()
        coordinator.run("workspace-\(workspace)")
        XCTAssertFalse(mac.isParked(2))
        XCTAssertLessThanOrEqual(mac.windows[2]!.frame.maxX, 1600)
    }

    func testDockChangesRelayout() {
        start(windows: 1)
        mac.monitors[0].visibleFrame.size.height -= 100
        coordinator.displaysChanged()
        XCTAssertEqual(mac.windows[1]!.frame.maxY, 1000 - 100 - 8)
    }
}
