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
        openUnmanagedWindow()
        let moves = mac.moveCount
        for id: WindowID in [1, 2] { mac.windows[id]!.onScreen = false }
        coordinator.scheduleReconcile(full: true)
        mac.advance(0.1)
        XCTAssertEqual(tiled, 0)
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

    /// A window of some other app, that keeps the on-screen list from being empty.
    private func openUnmanagedWindow() {
        mac.open(99, pid: 999, focus: false)
        mac.windows[99]!.isReady = false
    }

    func testFocusSurvivesAllWindowsGoingAwayAndReturning() {
        // Seen on a real Mac: Tilefy lost focus for good, so shortcuts did nothing until a click.
        start(windows: 2)
        openUnmanagedWindow()
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

    func testAnEmptyWindowListIsntBelieved() {
        start(windows: 2)
        let frames = mac.windows.mapValues(\.frame)
        let moves = mac.moveCount
        for id: WindowID in [1, 2] { mac.windows[id]!.onScreen = false }
        coordinator.scheduleReconcile(full: true)
        mac.advance(0.1)
        XCTAssertEqual(coordinator.engine.focusedWindow, 2, "nothing is marked as away")
        XCTAssertEqual(tiled, 2)
        XCTAssertEqual(mac.moveCount, moves)
        for id: WindowID in [1, 2] { mac.windows[id]!.onScreen = true }
        coordinator.scheduleReconcile(full: true)
        mac.advance(0.1)
        XCTAssertEqual(mac.windows.mapValues(\.frame), frames)
    }

    func testClosingTheLastWindowIsNoticedEvenThoughTheListIsEmpty() {
        start(windows: 1)
        mac.close(window: 1)
        coordinator.windowDestroyed()
        mac.advance(0.5)
        XCTAssertFalse(coordinator.engine.isTracked(1))
    }

    func testAWindowThatDriftsIsPutBack() {
        start(windows: 2)
        let slot = mac.windows[1]!.frame
        mac.windows[1]!.frame.size.height += 16  // What Claude's window did on a real Mac.
        heartbeat()
        XCTAssertEqual(mac.windows[1]!.frame, slot)
    }

    func testASmallDifferenceIsntDrift() {
        start(windows: 1)
        mac.advance(0.5)  // Past the check that follows a new window.
        mac.windows[1]!.frame.origin.y += 1  // Some apps round to their own pixel grid.
        let applies = mac.applyCount
        heartbeat()
        heartbeat()
        XCTAssertEqual(mac.applyCount, applies)
    }

    func testAStubbornWindowGetsAFewTriesThenIsLeftAlone() {
        start(windows: 2)
        mac.advance(0.5)  // Past the check that follows a new window.
        mac.windows[1]!.frame.size.height += 100
        mac.windows[1]!.isStubborn = true
        let applies = mac.applyCount
        for _ in 0..<10 { heartbeat() }
        XCTAssertEqual(mac.applyCount - applies, WindowCoordinator.driftAttemptLimit, "doesn't fight it forever")
    }

    func testAStubbornWindowGetsNewTriesWhenItsSlotChanges() {
        start(windows: 2)
        mac.windows[1]!.frame.size.height += 100
        mac.windows[1]!.isStubborn = true
        for _ in 0..<10 { heartbeat() }
        coordinator.run("layout-master")
        mac.windows[1]!.isStubborn = false
        mac.windows[1]!.frame.size.height += 100
        heartbeat()
        let wanted = coordinator.engine.plan().frames[1]
        XCTAssertEqual(mac.windows[1]!.frame, wanted)
    }

    func testDriftIsntCorrectedWhileTheMouseIsDown() {
        start(windows: 2)
        mac.advance(0.5)  // Past the check that follows a new window.
        let moved = mac.windows[1]!.frame.offsetBy(dx: 40, dy: 0)
        mac.windows[1]!.frame = moved
        mac.mouseDown = true
        heartbeat()
        XCTAssertEqual(mac.windows[1]!.frame, moved)
    }

    func testFloatsArentTreatedAsDrifting() {
        start(windows: 1)
        mac.open(2, cannotTile: true)
        settle()
        let moved = CGRect(x: 300, y: 300, width: 400, height: 300)
        mac.windows[2]!.frame = moved
        heartbeat()
        XCTAssertEqual(mac.windows[2]!.frame, moved)
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

    // MARK: - Saving and restoring

    /// What quitting and relaunching Tilefy does, with the same windows still open.
    private func restartTilefy(config: Config = Config()) {
        coordinator.stop()
        coordinator = WindowCoordinator(config: config, system: mac)
        coordinator.start()
        mac.advance(0.5)
    }

    func testARestartRestoresEverythingExactly() {
        start(windows: 4)
        coordinator.run("focus-left")
        coordinator.run("grow-width")
        coordinator.run("toggle-split")
        coordinator.run("move-to-workspace-3")
        coordinator.run("layout-grid")
        coordinator.run("workspace-1")
        mac.advance(1.5)
        let frames = mac.windows.mapValues(\.frame)
        let status = coordinator.status()

        restartTilefy()
        XCTAssertEqual(coordinator.status(), status)
        XCTAssertEqual(mac.windows.mapValues(\.frame), frames)
        XCTAssertEqual(coordinator.engine.workspaces[3]?.layout, .grid)
    }

    func testARestartRestoresFloatsAndGroupsAndSticky() {
        start(windows: 3)
        coordinator.run("toggle-group")
        mac.open(4)
        settle()
        XCTAssertEqual(coordinator.engine.groupPosition(of: 4)?.count, 2)
        coordinator.run("focus-left")
        coordinator.run("toggle-sticky")
        let floater = coordinator.engine.focusedWindow!
        restartTilefy()
        XCTAssertEqual(coordinator.engine.groupPosition(of: 4)?.count, 2)
        XCTAssertTrue(coordinator.engine.isSticky(floater))
        XCTAssertEqual(coordinator.engine.workspace(containing: floater)?.isFloating(floater), true)
    }

    func testARestartForgetsWindowsThatClosedMeanwhile() {
        start(windows: 3)
        mac.advance(1.5)
        coordinator.stop()
        mac.close(window: 2)
        coordinator = WindowCoordinator(config: Config(), system: mac)
        coordinator.start()
        XCTAssertFalse(coordinator.engine.isTracked(2))
        XCTAssertEqual(tiled, 2)
        XCTAssertFalse(mac.windows[1]!.frame.intersects(mac.windows[3]!.frame))
    }

    func testARestartPicksUpWindowsThatOpenedMeanwhile() {
        start(windows: 1)
        mac.advance(1.5)
        coordinator.stop()
        mac.open(2)
        coordinator = WindowCoordinator(config: Config(), system: mac)
        coordinator.start()
        XCTAssertEqual(tiled, 2)
    }

    func testAWindowMinimizedOverARestartReturnsToItsWorkspace() {
        start(windows: 2)
        coordinator.run("move-to-workspace-3")
        coordinator.run("workspace-1")
        mac.advance(1.5)
        mac.windows[2]!.onScreen = false
        restartTilefy()
        XCTAssertFalse(coordinator.engine.isTracked(2))
        mac.windows[2]!.onScreen = true
        coordinator.scheduleReconcile(full: false)
        mac.advance(0.1)
        XCTAssertEqual(coordinator.engine.workspace(containing: 2)?.id, 3)
    }

    func testAReusedWindowIDIsntMistakenForTheOldWindow() {
        mac = SimulatedMac()
        mac.open(1, pid: 100, bundleID: "com.example.old")
        coordinator = WindowCoordinator(config: Config(), system: mac)
        coordinator.start()
        coordinator.run("move-to-workspace-3")
        coordinator.run("workspace-1")
        mac.advance(1.5)
        coordinator.stop()
        mac.windows[1]!.bundleID = "com.example.new"
        coordinator = WindowCoordinator(config: Config(), system: mac)
        coordinator.start()
        XCTAssertEqual(coordinator.engine.workspace(containing: 1)?.id, 1, "treated as a new window")
    }

    func testAfterARebootAppsGoBackToTheirWorkspaces() {
        mac = SimulatedMac()
        mac.open(1, pid: 100, bundleID: "com.example.mail")
        mac.windows[1]!.title = "Inbox"
        mac.open(2, pid: 200, bundleID: "com.example.browser")
        coordinator = WindowCoordinator(config: Config(), system: mac)
        coordinator.start()
        coordinator.run("focus-left")
        coordinator.run("move-to-workspace-4")
        coordinator.run("layout-grid")
        mac.advance(1.5)
        coordinator.stop()

        // New boot: new IDs, and new processes.
        let state = mac.savedState
        mac = SimulatedMac()
        mac.savedState = state
        mac.session = "boot-2"
        mac.open(50, pid: 300, focus: false, bundleID: "com.example.browser")
        coordinator = WindowCoordinator(config: Config(), system: mac)
        coordinator.start()
        XCTAssertEqual(coordinator.engine.workspaces[4]?.layout, .grid, "layouts are restored")

        mac.open(51, pid: 301, bundleID: "com.example.mail")
        mac.windows[51]!.title = "Inbox"
        settle()
        XCTAssertEqual(coordinator.engine.workspace(containing: 51)?.id, 4)
    }

    func testPlacementsFromBeforeARebootExpire() {
        mac = SimulatedMac()
        mac.open(1, pid: 100, bundleID: "com.example.mail")
        coordinator = WindowCoordinator(config: Config(), system: mac)
        coordinator.start()
        coordinator.run("move-to-workspace-4")
        coordinator.run("workspace-1")
        mac.advance(1.5)
        coordinator.stop()

        let state = mac.savedState
        mac = SimulatedMac()
        mac.savedState = state
        mac.session = "boot-2"
        coordinator = WindowCoordinator(config: Config(), system: mac)
        coordinator.start()
        mac.advance(WindowCoordinator.placementWindow + 1)
        mac.open(51, pid: 301, bundleID: "com.example.mail")
        settle()
        XCTAssertNotEqual(coordinator.engine.workspace(containing: 51)?.id, 4, "by now it's just a new window")
    }

    func testACorruptSaveIsIgnored() {
        mac = SimulatedMac()
        mac.savedState = Data("not json".utf8)
        mac.open(1)
        coordinator = WindowCoordinator(config: Config(), system: mac)
        coordinator.start()
        XCTAssertEqual(tiled, 1)
    }

    func testStateIsSavedSoonAfterAChange() {
        start(windows: 1)
        mac.savedState = nil
        coordinator.run("layout-grid")
        XCTAssertNil(mac.savedState, "not on every change")
        mac.advance(1.5)
        XCTAssertNotNil(mac.savedState)
    }

    // MARK: - Animations

    func testCommandsAnimateByDefault() {
        start(windows: 2)
        coordinator.run("layout-grid")
        XCTAssertEqual(mac.lastAnimationDuration, Config().animationDuration)
    }

    func testAnimationsCanBeTurnedOff() {
        var config = Config()
        config.animations = false
        start(windows: 2, config: config)
        coordinator.run("layout-grid")
        XCTAssertEqual(mac.lastAnimationDuration, 0)
    }

    func testFirstLaunchAndCorrectionsDontAnimate() {
        start(windows: 2)
        XCTAssertEqual(mac.lastAnimationDuration, 0)
        mac.advance(0.5)
        coordinator.run("layout-grid")
        mac.windows[1]!.frame.size.height += 16
        heartbeat()
        XCTAssertEqual(mac.lastAnimationDuration, 0)
    }

    // MARK: - Groups and sticky, through the coordinator

    func testGroupsAndStickyTintTheBorder() {
        start(windows: 2)
        XCTAssertEqual(mac.borderStyle, .normal)
        coordinator.run("toggle-group")
        XCTAssertEqual(mac.borderStyle, .grouped)
        coordinator.run("toggle-group")
        coordinator.run("toggle-sticky")
        XCTAssertEqual(mac.borderStyle, .sticky)
    }

    func testHUDSaysWhichGroupMemberIsShowing() {
        start(windows: 1)
        coordinator.run("toggle-group")
        mac.open(2)
        settle()
        coordinator.run("group-next")
        XCTAssertEqual(mac.hud.last, "Group  ·  1 of 2")
        coordinator.run("toggle-group")
        XCTAssertEqual(mac.hud.last, "Not grouped")
    }

    // MARK: - Trackpad swipes

    private func swipe(fingers: Int, from: CGFloat, to: CGFloat) {
        for step in 0...10 {
            let x = from + (to - from) * CGFloat(step) / 10
            coordinator.trackpadTouches((0..<fingers).map { CGPoint(x: x + CGFloat($0) * 0.05, y: 0.5) })
        }
        coordinator.trackpadTouches([])
    }

    func testSwipesMoveAlongTheRowInTheScrollingLayout() {
        var config = Config()
        config.defaultLayout = .scrolling
        start(windows: 3, config: config)
        XCTAssertEqual(coordinator.engine.focusedWindow, 3)
        swipe(fingers: 4, from: 0.3, to: 0.45)  // Fingers right: the row follows them, showing what's left.
        XCTAssertEqual(coordinator.engine.focusedWindow, 2)
        swipe(fingers: 4, from: 0.45, to: 0.3)
        XCTAssertEqual(coordinator.engine.focusedWindow, 3)
    }

    func testSwipesChangeWorkspaceInOtherLayouts() {
        start(windows: 1)
        coordinator.run("workspace-5")
        mac.open(2)
        settle()
        swipe(fingers: 4, from: 0.3, to: 0.45)
        XCTAssertEqual(coordinator.engine.activeWorkspace?.id, 1)
    }

    func testOnlyTheChosenFingerCountSwipes() {
        var config = Config()
        config.defaultLayout = .scrolling
        start(windows: 3, config: config)
        swipe(fingers: 3, from: 0.3, to: 0.8)
        XCTAssertEqual(coordinator.engine.focusedWindow, 3)
        config.swipeFingers = 3
        coordinator.update(config: config)
        swipe(fingers: 3, from: 0.3, to: 0.45)
        XCTAssertEqual(coordinator.engine.focusedWindow, 2)
    }

    func testSwipesCanBeTurnedOff() {
        var config = Config()
        config.defaultLayout = .scrolling
        config.trackpadSwipes = false
        start(windows: 3, config: config)
        swipe(fingers: 4, from: 0.3, to: 0.8)
        XCTAssertEqual(coordinator.engine.focusedWindow, 3)
    }
}

final class MotionTests: XCTestCase {
    private let monitor = Monitor(
        id: 1,
        frame: CGRect(x: 0, y: 0, width: 1000, height: 800),
        visibleFrame: CGRect(x: 0, y: 25, width: 1000, height: 775)
    )

    func testInterpolationEndsExactlyOnTarget() {
        let from = CGRect(x: 0, y: 0, width: 100, height: 100)
        let to = CGRect(x: 500, y: 300, width: 200, height: 50)
        XCTAssertEqual(FrameAnimation.interpolate(from: from, to: to, progress: 0), from)
        XCTAssertEqual(FrameAnimation.interpolate(from: from, to: to, progress: 1), to)
        XCTAssertEqual(FrameAnimation.interpolate(from: from, to: to, progress: 2), to, "never overshoots")
    }

    func testEasingStartsFastAndNeverGoesBackward() {
        XCTAssertGreaterThan(FrameAnimation.eased(0.5), 0.5)
        var last = 0.0
        for step in 1...20 {
            let value = FrameAnimation.eased(Double(step) / 20)
            XCTAssertGreaterThanOrEqual(value, last)
            last = value
        }
    }

    func testOnlyOnScreenMovesAnimate() {
        let onScreen = CGRect(x: 100, y: 100, width: 300, height: 300)
        let elsewhere = CGRect(x: 500, y: 100, width: 300, height: 300)
        let parked = CGRect(x: 999, y: 799, width: 300, height: 300)
        XCTAssertTrue(FrameAnimation.isWorthAnimating(from: onScreen, to: elsewhere, monitors: [monitor]))
        XCTAssertFalse(FrameAnimation.isWorthAnimating(from: parked, to: onScreen, monitors: [monitor]), "coming back from a corner")
        XCTAssertFalse(FrameAnimation.isWorthAnimating(from: onScreen, to: parked, monitors: [monitor]))
        XCTAssertFalse(FrameAnimation.isWorthAnimating(from: onScreen, to: onScreen, monitors: [monitor]))
    }
}

final class SwipeRecognizerTests: XCTestCase {
    private func fingers(_ count: Int, x: CGFloat, y: CGFloat = 0.5) -> [CGPoint] {
        (0..<count).map { CGPoint(x: x + CGFloat($0) * 0.05, y: y) }
    }

    func testAHorizontalSwipeIsRecognized() {
        var swipes = SwipeRecognizer(fingers: 4)
        XCTAssertNil(swipes.update(touches: fingers(4, x: 0.5)))
        XCTAssertNil(swipes.update(touches: fingers(4, x: 0.45)))
        XCTAssertEqual(swipes.update(touches: fingers(4, x: 0.39)), .fingersLeft)
    }

    func testALongSwipeGivesSeveralSteps() {
        var swipes = SwipeRecognizer(fingers: 4)
        _ = swipes.update(touches: fingers(4, x: 0.1))
        XCTAssertEqual(swipes.update(touches: fingers(4, x: 0.25)), .fingersRight)
        XCTAssertEqual(swipes.update(touches: fingers(4, x: 0.4)), .fingersRight)
        XCTAssertNil(swipes.update(touches: fingers(4, x: 0.45)))
    }

    func testTheWrongNumberOfFingersDoesNothing() {
        var swipes = SwipeRecognizer(fingers: 4)
        _ = swipes.update(touches: fingers(3, x: 0.1))
        XCTAssertNil(swipes.update(touches: fingers(3, x: 0.9)))
        _ = swipes.update(touches: fingers(2, x: 0.1))
        XCTAssertNil(swipes.update(touches: fingers(2, x: 0.9)))
    }

    func testAFingerLiftingRestartsTheCount() {
        var swipes = SwipeRecognizer(fingers: 4)
        _ = swipes.update(touches: fingers(4, x: 0.1))
        XCTAssertNil(swipes.update(touches: fingers(3, x: 0.2)))
        XCTAssertNil(swipes.update(touches: fingers(4, x: 0.5)), "a new starting point, so no jump")
        XCTAssertEqual(swipes.update(touches: fingers(4, x: 0.65)), .fingersRight)
    }

    func testAVerticalSwipeIsLeftForMissionControl() {
        var swipes = SwipeRecognizer(fingers: 4)
        _ = swipes.update(touches: fingers(4, x: 0.5, y: 0.2))
        XCTAssertNil(swipes.update(touches: fingers(4, x: 0.5, y: 0.5)))
        XCTAssertNil(swipes.update(touches: fingers(4, x: 0.9, y: 0.5)), "ignored until the fingers lift")
        XCTAssertNil(swipes.update(touches: []))
        _ = swipes.update(touches: fingers(4, x: 0.1))
        XCTAssertEqual(swipes.update(touches: fingers(4, x: 0.3)), .fingersRight)
    }
}
