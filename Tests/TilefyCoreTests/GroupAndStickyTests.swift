import CoreGraphics
import XCTest
@testable import TilefyCore

private let screen = Monitor(
    id: 1,
    frame: CGRect(x: 0, y: 0, width: 1600, height: 1000),
    visibleFrame: CGRect(x: 0, y: 25, width: 1600, height: 975)
)
private let bounds = CGRect(x: 0, y: 25, width: 1600, height: 975)

private func makeEngine(layout: LayoutKind = .dwindle, windows: Int = 0) -> TilingEngine {
    let engine = TilingEngine(options: TilingOptions(innerGap: 0, outerGap: 0, defaultLayout: layout))
    engine.setMonitors([screen])
    for i in 0..<windows { engine.addWindow(WindowID(i + 1)) }
    return engine
}

final class GroupTests: XCTestCase {
    func testNewWindowsJoinAFocusedGroup() {
        let engine = makeEngine(windows: 2)
        engine.perform(.toggleGroup)
        engine.addWindow(3)
        let frames = engine.plan().frames
        XCTAssertEqual(frames[3], frames[2], "they share a tile")
        XCTAssertEqual(frames[2]?.width, 800, "and the layout still sees two tiles")
        XCTAssertEqual(engine.focusedWindow, 3)
        XCTAssertEqual(engine.activeWorkspace?.visibleTiled.sorted(), [1, 3])
    }

    func testCyclingShowsEachMember() {
        let engine = makeEngine(windows: 1)
        engine.perform(.toggleGroup)
        engine.addWindow(2)
        engine.addWindow(3)
        XCTAssertEqual(engine.focusedWindow, 3)
        engine.perform(.groupNext)
        XCTAssertEqual(engine.focusedWindow, 1, "wraps around")
        engine.perform(.groupPrevious)
        XCTAssertEqual(engine.focusedWindow, 3)
        XCTAssertEqual(engine.groupPosition(of: 3)?.index, 3)
        XCTAssertEqual(engine.groupPosition(of: 3)?.count, 3)
    }

    func testBreakingUpGivesEachItsOwnTile() {
        let engine = makeEngine(windows: 1)
        engine.perform(.toggleGroup)
        engine.addWindow(2)
        engine.addWindow(3)
        engine.perform(.toggleGroup)
        XCTAssertEqual(engine.activeWorkspace?.visibleTiled.count, 3)
        XCTAssertFalse(engine.plan().frames[1]!.intersects(engine.plan().frames[2]!))
        XCTAssertNil(engine.groupPosition(of: 1))
    }

    func testMovingIntoAGroupInADirection() {
        let engine = makeEngine(windows: 2)
        _ = engine.plan()
        engine.perform(.moveIntoGroup(.left))
        let frames = engine.plan().frames
        XCTAssertEqual(frames[1], bounds)
        XCTAssertEqual(frames[2], bounds)
        XCTAssertEqual(engine.focusedWindow, 2)
        XCTAssertEqual(engine.groupPosition(of: 2)?.count, 2)
    }

    func testTakingAWindowOutOfAGroup() {
        let engine = makeEngine(windows: 2)
        _ = engine.plan()
        engine.perform(.moveIntoGroup(.left))
        engine.perform(.removeFromGroup)
        let frames = engine.plan().frames
        XCTAssertEqual(frames[1]?.width, 800)
        XCTAssertEqual(frames[2]?.width, 800)
        XCTAssertEqual(engine.focusedWindow, 2)
    }

    func testClosingTheShowingMemberShowsAnother() {
        let engine = makeEngine(windows: 1)
        engine.perform(.toggleGroup)
        engine.addWindow(2)
        engine.addWindow(3)
        engine.removeWindow(3)
        XCTAssertEqual(engine.focusedWindow, 2)
        XCTAssertEqual(engine.plan().frames[2], bounds)
        engine.removeWindow(2)
        engine.removeWindow(1)
        XCTAssertNil(engine.focusedWindow)
        XCTAssertTrue(engine.plan().frames.isEmpty)
    }

    func testClosingAHiddenMemberChangesNothingVisible() {
        let engine = makeEngine(windows: 1)
        engine.perform(.toggleGroup)
        engine.addWindow(2)
        engine.removeWindow(1)
        XCTAssertEqual(engine.focusedWindow, 2)
        XCTAssertEqual(engine.groupPosition(of: 2)?.count, 1)
    }

    func testMinimizingTheShowingMemberKeepsTheTileFilled() {
        let engine = makeEngine(windows: 1)
        engine.perform(.toggleGroup)
        engine.addWindow(2)
        engine.suspendWindow(2)
        XCTAssertEqual(engine.focusedWindow, 1)
        XCTAssertEqual(engine.plan().frames[1], bounds)
        XCTAssertNil(engine.plan().frames[2])
        engine.resumeWindow(2)
        XCTAssertEqual(engine.plan().frames[2], bounds)
    }

    func testFocusingAHiddenMemberFromMacOSShowsIt() {
        let engine = makeEngine(windows: 1)
        engine.perform(.toggleGroup)
        engine.addWindow(2)
        engine.focusChanged(to: 1)
        XCTAssertEqual(engine.focusedWindow, 1)
        XCTAssertEqual(engine.activeWorkspace?.visibleTiled, [1])
    }

    func testAGroupTravelsBetweenWorkspaces() {
        let engine = makeEngine(windows: 1)
        engine.perform(.toggleGroup)
        engine.addWindow(2)
        engine.perform(.moveToWorkspace(3, follow: true))
        XCTAssertEqual(engine.activeWorkspace?.id, 3)
        XCTAssertEqual(engine.groupPosition(of: 2)?.count, 2)
        XCTAssertEqual(engine.workspace(containing: 1)?.id, 3)
        XCTAssertEqual(engine.focusedWindow, 2)
    }

    func testAHiddenWorkspaceParksEveryMember() {
        let engine = makeEngine(windows: 1)
        engine.perform(.toggleGroup)
        engine.addWindow(2)
        engine.perform(.workspace(2))
        XCTAssertEqual(engine.plan().hidden.keys.sorted(), [1, 2])
    }

    func testGroupsWorkInEveryLayout() {
        for layout in LayoutKind.allCases {
            let engine = makeEngine(layout: layout, windows: 3)
            engine.perform(.toggleGroup)
            engine.addWindow(4)
            let plan = engine.plan()
            XCTAssertEqual(plan.frames.count + plan.hidden.count, 4, "\(layout)")
            XCTAssertEqual(plan.frames[4], plan.frames[3], "\(layout)")
        }
    }

    func testFloatingAMemberLeavesTheGroupBehind() {
        let engine = makeEngine(windows: 1)
        engine.perform(.toggleGroup)
        engine.addWindow(2)
        engine.perform(.toggleFloat)
        XCTAssertEqual(engine.workspace(containing: 2)?.isFloating(2), true)
        XCTAssertEqual(engine.plan().frames[1], bounds)
        XCTAssertEqual(engine.groupPosition(of: 1)?.count, 1)
    }
}

final class StickyTests: XCTestCase {
    func testStickyWindowFollowsAcrossWorkspaces() {
        let engine = makeEngine(windows: 2)
        engine.perform(.toggleSticky)
        XCTAssertEqual(engine.workspace(containing: 2)?.isFloating(2), true)
        _ = engine.plan()
        engine.perform(.workspace(3))
        let plan = engine.plan()
        XCTAssertNil(plan.hidden[2], "stays on screen")
        XCTAssertNotNil(plan.hidden[1])
        XCTAssertEqual(engine.workspace(containing: 2)?.id, 3)
        XCTAssertEqual(engine.focusedWindow, 2, "an otherwise empty workspace focuses it")
    }

    func testTurningStickyOffLeavesItFloatingOnThatWorkspace() {
        let engine = makeEngine(windows: 2)
        engine.perform(.toggleSticky)
        engine.perform(.workspace(3))
        engine.perform(.toggleSticky)
        XCTAssertFalse(engine.isSticky(2))
        engine.perform(.workspace(1))
        XCTAssertNotNil(engine.plan().hidden[2])
    }

    func testTilingAStickyWindowEndsIt() {
        let engine = makeEngine(windows: 2)
        engine.perform(.toggleSticky)
        engine.perform(.toggleFloat)
        XCTAssertFalse(engine.isSticky(2))
        XCTAssertEqual(engine.workspace(containing: 2)?.isFloating(2), false)
    }

    func testClosingAStickyWindowForgetsIt() {
        let engine = makeEngine(windows: 2)
        engine.perform(.toggleSticky)
        engine.removeWindow(2)
        XCTAssertTrue(engine.stickyWindows.isEmpty)
    }
}
