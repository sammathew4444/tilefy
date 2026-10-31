import CoreGraphics
import XCTest
@testable import TilefyCore

private let screen = Monitor(
    id: 1,
    frame: CGRect(x: 0, y: 0, width: 1600, height: 1000),
    visibleFrame: CGRect(x: 0, y: 25, width: 1600, height: 975)
)
private let bounds = CGRect(x: 0, y: 25, width: 1600, height: 975)

private func makeEngine(
    layout: LayoutKind = .dwindle,
    windows: Int = 0,
    monitors: [Monitor] = [screen],
    gap: CGFloat = 0
) -> TilingEngine {
    let engine = TilingEngine(options: TilingOptions(innerGap: gap, outerGap: 0, defaultLayout: layout))
    engine.setMonitors(monitors)
    for i in 0..<windows { engine.addWindow(WindowID(i + 1)) }
    return engine
}

private func assertNoOverlap(_ frames: [WindowID: CGRect], file: StaticString = #filePath, line: UInt = #line) {
    let list = Array(frames)
    for i in list.indices {
        for j in list.indices where j > i {
            let overlap = list[i].value.intersection(list[j].value)
            XCTAssertTrue(
                overlap.isNull || overlap.isEmpty,
                "\(list[i].key) \(list[i].value) overlaps \(list[j].key) \(list[j].value)",
                file: file,
                line: line
            )
        }
    }
}

final class TilingLayoutTests: XCTestCase {
    func testEveryTilingLayoutFitsAndNeverOverlaps() {
        for layout in LayoutKind.allCases where layout != .monocle && layout != .scrolling {
            for count in 1...9 {
                let frames = makeEngine(layout: layout, windows: count, gap: 8).plan().frames
                XCTAssertEqual(frames.count, count, "\(layout) with \(count) windows")
                assertNoOverlap(frames)
                for frame in frames.values {
                    XCTAssertTrue(bounds.contains(frame), "\(layout) placed \(frame) outside the screen")
                    XCTAssertGreaterThan(frame.width, 0)
                    XCTAssertGreaterThan(frame.height, 0)
                }
            }
        }
    }

    func testTilingLayoutsFillTheScreenWithoutGaps() {
        for layout in LayoutKind.allCases where layout != .monocle && layout != .scrolling {
            for count in 1...9 {
                let frames = makeEngine(layout: layout, windows: count).plan().frames
                let area = frames.values.reduce(CGFloat(0)) { $0 + $1.width * $1.height }
                XCTAssertEqual(area, bounds.width * bounds.height, accuracy: 1, "\(layout) with \(count) windows")
            }
        }
    }

    func testEqualPartsReallyAreEqual() {
        // Found on a real display: with gaps, three columns came out 333, 330 and 329 wide.
        for count in 2...9 {
            let parts = CGRect(x: 8, y: 39, width: 1008, height: 661).slices(count, along: .horizontal, gap: 8)
            let widths = parts.map(\.width)
            XCTAssertLessThanOrEqual(widths.max()! - widths.min()!, 1, "\(count) parts: \(widths)")
            XCTAssertEqual(parts.first?.minX, 8)
            XCTAssertEqual(parts.last?.maxX, 1016, "fills the space exactly")
            for (left, right) in zip(parts, parts.dropFirst()) {
                XCTAssertEqual(right.minX - left.maxX, 8, "gaps are exact")
            }
        }
    }

    func testDwindleSplitsFocusedWindowAlongItsLongSide() {
        let engine = makeEngine(windows: 2)
        var frames = engine.plan().frames
        XCTAssertEqual(frames[1], CGRect(x: 0, y: 25, width: 800, height: 975))
        XCTAssertEqual(frames[2], CGRect(x: 800, y: 25, width: 800, height: 975))

        // Window 2 is focused and taller than wide, so the next split is top/bottom.
        engine.addWindow(3)
        frames = engine.plan().frames
        XCTAssertEqual(frames[1]?.width, 800)
        XCTAssertEqual(frames[2]?.minX, 800)
        XCTAssertEqual(frames[3]?.minX, 800)
        XCTAssertEqual(frames[2]?.maxY, frames[3]?.minY)
    }

    func testDwindleSplitsWhicheverWindowIsFocused() {
        let engine = makeEngine(windows: 2)
        engine.focusChanged(to: 1)
        engine.addWindow(3)
        let frames = engine.plan().frames
        XCTAssertEqual(frames[2], CGRect(x: 800, y: 25, width: 800, height: 975), "window 2 is untouched")
        XCTAssertEqual(frames[1]?.maxY, frames[3]?.minY, "1 and 3 share the left half")
    }

    func testToggleSplitFlipsTheAxis() {
        let engine = makeEngine(windows: 2)
        _ = engine.plan()
        engine.perform(.toggleSplit)
        let frames = engine.plan().frames
        XCTAssertEqual(frames[1]?.width, 1600)
        XCTAssertEqual(frames[2]?.width, 1600)
    }

    func testDwindleCollapsesWhenAWindowCloses() {
        let engine = makeEngine(windows: 3)
        engine.removeWindow(2)
        let frames = engine.plan().frames
        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(frames[1]?.width, 800)
        XCTAssertEqual(frames[3]?.height, 975)
    }

    func testGrowMovesTheNearestSplit() {
        let engine = makeEngine(windows: 2)
        _ = engine.plan()
        engine.focusChanged(to: 1)
        engine.perform(.grow(width: 160, height: 0))
        XCTAssertEqual(engine.plan().frames[1]?.width, 960)
        engine.focusChanged(to: 2)
        engine.perform(.grow(width: 160, height: 0))
        XCTAssertEqual(engine.plan().frames[1]?.width, 800, "growing the right window shrinks the left")
        engine.perform(.grow(width: 0, height: 100))
        XCTAssertEqual(engine.plan().frames[1]?.width, 800, "no vertical split exists to move")
    }

    func testMasterAndStack() {
        let engine = makeEngine(layout: .master, windows: 4)
        let frames = engine.plan().frames
        XCTAssertEqual(frames[1]?.width, 880)
        XCTAssertEqual(frames[1]?.height, 975)
        XCTAssertEqual(frames[2]?.minX, 880)
        XCTAssertEqual(frames[2]?.height ?? 0, 325, accuracy: 1)
    }

    func testPromoteSwapsWithMaster() {
        let engine = makeEngine(layout: .master, windows: 3)
        let masterFrame = engine.plan().frames[engine.activeWorkspace!.visibleTiled[0]]
        engine.focusChanged(to: 3)
        engine.perform(.promote)
        XCTAssertEqual(engine.plan().frames[3], masterFrame)
        engine.perform(.promote)
        XCTAssertNotEqual(engine.plan().frames[3], masterFrame, "promoting the master swaps it back out")
    }

    func testCenteredMasterKeepsMasterInTheMiddle() {
        let frames = makeEngine(layout: .centeredMaster, windows: 5).plan().frames
        let master = frames[1]!
        XCTAssertEqual(master.midX, 800, accuracy: 2)
        XCTAssertTrue(frames.contains { $0.key != 1 && $0.value.maxX <= master.minX })
        XCTAssertTrue(frames.contains { $0.key != 1 && $0.value.minX >= master.maxX })
    }

    func testGridStretchesTheLastRow() {
        let frames = makeEngine(layout: .grid, windows: 5).plan().frames
        XCTAssertEqual(frames.count, 5)
        let topRow = frames.values.filter { $0.minY == bounds.minY }
        let bottomRow = frames.values.filter { $0.minY != bounds.minY }
        XCTAssertEqual(topRow.count, 3)
        XCTAssertEqual(bottomRow.count, 2)
        XCTAssertTrue(bottomRow.allSatisfy { $0.width == 800 }, "the shorter last row fills the width")
    }

    func testMonocleStacksEverythingAndCyclesFocus() {
        let engine = makeEngine(layout: .monocle, windows: 3)
        XCTAssertTrue(engine.plan().frames.values.allSatisfy { $0 == bounds })
        XCTAssertEqual(engine.focusedWindow, 3)
        engine.perform(.focus(.right))
        XCTAssertEqual(engine.focusedWindow, 1, "wraps around")
        engine.perform(.focus(.left))
        XCTAssertEqual(engine.focusedWindow, 3)
    }

    func testSwitchingLayoutKeepsAllWindows() {
        let engine = makeEngine(windows: 5)
        for _ in LayoutKind.allCases {
            engine.perform(.layoutNext)
            let plan = engine.plan()
            XCTAssertEqual(plan.frames.count + plan.hidden.count, 5, "\(engine.activeWorkspace!.layout)")
        }
    }

    func testLayoutToggleMatchesOmarchy() {
        let engine = makeEngine()
        XCTAssertEqual(engine.activeWorkspace?.layout, .dwindle)
        engine.perform(.toggleDwindleScrolling)
        XCTAssertEqual(engine.activeWorkspace?.layout, .scrolling)
        engine.perform(.toggleDwindleScrolling)
        XCTAssertEqual(engine.activeWorkspace?.layout, .dwindle)
    }

    func testFullscreenFillsWorkspaceAndClearsWhenFocusMoves() {
        let engine = makeEngine(windows: 2)
        engine.perform(.fullscreen)
        XCTAssertEqual(engine.plan().frames[2], bounds)
        engine.focusChanged(to: 1)
        XCTAssertNil(engine.activeWorkspace?.fullscreen)
        XCTAssertEqual(engine.plan().frames[2]?.width, 800)
    }
}

final class ScrollingTests: XCTestCase {
    func testNewWindowsKeepExistingSizes() {
        let engine = makeEngine(layout: .scrolling, windows: 1)
        let first = engine.plan().frames[1]
        engine.focusChanged(to: 1)
        engine.addWindow(2)
        XCTAssertEqual(engine.plan().frames[1], first)
        XCTAssertEqual(first?.width, 800)
    }

    func testViewportFollowsFocusAndHidesFarColumns() {
        let engine = makeEngine(layout: .scrolling, windows: 6)
        let atEnd = engine.plan()
        XCTAssertEqual(atEnd.frames[6]?.maxX, 1600, "focused last column sits at the right edge")
        XCTAssertNotNil(atEnd.hidden[1], "the far left column is parked")

        engine.focusChanged(to: 1)
        let atStart = engine.plan()
        XCTAssertEqual(atStart.frames[1]?.minX, 0)
        XCTAssertNotNil(atStart.hidden[6])
    }

    func testPartlyVisibleColumnPeeksOnSingleDisplay() {
        let engine = makeEngine(layout: .scrolling, windows: 3)
        for id: WindowID in [1, 2, 3] {
            engine.focusChanged(to: id)
            engine.perform(.cycleWidth)  // ⅔ wide
        }
        engine.focusChanged(to: 1)
        let plan = engine.plan()
        XCTAssertNotNil(plan.frames[2], "the next column peeks from the edge")
        XCTAssertGreaterThan(plan.frames[2]!.maxX, 1600)
    }

    func testPartlyVisibleColumnIsHiddenWhenItWouldSpillOntoAnotherDisplay() {
        let second = Monitor(
            id: 2,
            frame: CGRect(x: 1600, y: 0, width: 1600, height: 1000),
            visibleFrame: CGRect(x: 1600, y: 25, width: 1600, height: 975)
        )
        let engine = makeEngine(layout: .scrolling, monitors: [screen, second])
        for id: WindowID in 1...3 { engine.addWindow(id) }
        for id: WindowID in [1, 2, 3] {
            engine.focusChanged(to: id)
            engine.perform(.cycleWidth)
        }
        engine.focusChanged(to: 1)
        XCTAssertNotNil(engine.plan().hidden[2])
    }

    func testCycleWidthWraps() {
        let engine = makeEngine(layout: .scrolling, windows: 1)
        XCTAssertEqual(engine.plan().frames[1]?.width, 800)
        engine.perform(.cycleWidth)
        XCTAssertEqual(engine.plan().frames[1]?.width ?? 0, 1067, accuracy: 1)
        engine.perform(.cycleWidth)
        XCTAssertEqual(engine.plan().frames[1]?.width, 1600)
        engine.perform(.cycleWidth)
        XCTAssertEqual(engine.plan().frames[1]?.width, 800)
    }

    func testCenter() {
        let engine = makeEngine(layout: .scrolling, windows: 1)
        engine.perform(.center)
        XCTAssertEqual(engine.plan().frames[1]?.midX, 800)
    }

    func testSwapCarriesColumnWidth() {
        let engine = makeEngine(layout: .scrolling, windows: 2)
        engine.perform(.cycleWidth)  // window 2 is now ⅔
        engine.perform(.swap(.left))
        let frames = engine.plan().frames
        XCTAssertLessThan(frames[2]!.minX, frames[1]!.minX)
        XCTAssertEqual(frames[2]?.width ?? 0, 1067, accuracy: 1)
    }

    func testStackAndUnstack() {
        let engine = makeEngine(layout: .scrolling, windows: 2)
        engine.perform(.stack)
        var frames = engine.plan().frames
        XCTAssertEqual(frames[1]?.minX, frames[2]?.minX)
        XCTAssertEqual(frames[1]?.maxY, frames[2]?.minY)

        engine.perform(.unstack)
        frames = engine.plan().frames
        XCTAssertEqual(frames[2]?.minX, frames[1]?.maxX)
    }

    func testClosingAWindowPullsTheRowBack() {
        let engine = makeEngine(layout: .scrolling, windows: 4)
        _ = engine.plan()
        engine.removeWindow(4)
        engine.removeWindow(3)
        let frames = engine.plan().frames
        XCTAssertEqual(frames[1]?.minX, 0)
        XCTAssertEqual(frames[2]?.maxX, 1600)
    }
}

final class WorkspaceTests: XCTestCase {
    func testSwitchingHidesTheOldWorkspaceAndShowsTheNew() {
        let engine = makeEngine(windows: 2)
        engine.perform(.workspace(2))
        engine.addWindow(3)
        let plan = engine.plan()
        XCTAssertEqual(plan.hidden.keys.sorted(), [1, 2])
        XCTAssertEqual(plan.frames[3], bounds)
        XCTAssertEqual(plan.focused, 3)

        engine.perform(.workspace(1))
        let back = engine.plan()
        XCTAssertEqual(back.hidden.keys.sorted(), [3])
        XCTAssertEqual(back.focused, 2)
    }

    func testMoveWindowAndFollow() {
        let engine = makeEngine(windows: 2)
        engine.perform(.moveToWorkspace(3, follow: true))
        XCTAssertEqual(engine.activeWorkspace?.id, 3)
        XCTAssertEqual(engine.focusedWindow, 2)
        XCTAssertEqual(engine.plan().frames[2], bounds)
    }

    func testMoveWindowWithoutFollowing() {
        let engine = makeEngine(windows: 2)
        engine.perform(.moveToWorkspace(3, follow: false))
        XCTAssertEqual(engine.activeWorkspace?.id, 1)
        XCTAssertEqual(engine.focusedWindow, 1)
        let plan = engine.plan()
        XCTAssertEqual(plan.frames[1], bounds)
        XCTAssertNotNil(plan.hidden[2])
    }

    func testFocusFromMacOSRevealsAHiddenWorkspace() {
        let engine = makeEngine(windows: 1)
        engine.perform(.workspace(2))
        engine.focusChanged(to: 1)
        XCTAssertEqual(engine.activeWorkspace?.id, 1)
    }

    func testWorkspaceNextAndPreviousVisitOccupiedOnly() {
        let engine = makeEngine(windows: 1)
        engine.perform(.workspace(5))
        engine.addWindow(2)
        engine.perform(.workspaceNext)
        XCTAssertEqual(engine.activeWorkspace?.id, 1)
        engine.perform(.workspacePrevious)
        XCTAssertEqual(engine.activeWorkspace?.id, 5)
        engine.perform(.workspaceLast)
        XCTAssertEqual(engine.activeWorkspace?.id, 1)
    }

    func testEachWorkspaceKeepsItsOwnLayout() {
        let engine = makeEngine()
        engine.perform(.layout(.grid))
        engine.perform(.workspace(2))
        XCTAssertEqual(engine.activeWorkspace?.layout, .dwindle)
        engine.perform(.workspace(1))
        XCTAssertEqual(engine.activeWorkspace?.layout, .grid)
    }

    func testFloatingWindowsStayPutAndComeBack() {
        let floatFrame = CGRect(x: 50, y: 60, width: 300, height: 200)
        let engine = TilingEngine(options: TilingOptions(innerGap: 0, outerGap: 0), currentFrame: { _ in floatFrame })
        engine.setMonitors([screen])
        engine.addWindow(1)
        engine.addWindow(2, floating: true)
        var plan = engine.plan()
        XCTAssertNil(plan.frames[2], "a float isn't moved while its workspace is showing")
        XCTAssertEqual(plan.frames[1], bounds, "and takes no tiling space")

        engine.perform(.workspace(2))
        plan = engine.plan()
        XCTAssertNotNil(plan.hidden[2])

        engine.perform(.workspace(1))
        XCTAssertEqual(engine.plan().frames[2], floatFrame)
        XCTAssertNil(engine.plan().frames[2], "only restored once")
    }

    func testToggleFloatRemovesFromLayoutAndBack() {
        let engine = makeEngine(windows: 2)
        engine.perform(.toggleFloat)
        let floated = engine.plan()
        XCTAssertEqual(floated.frames[1], bounds)
        let floatFrame = floated.frames[2]
        XCTAssertEqual(floatFrame?.midX, bounds.midX, "lifts out of its tile, centered")
        XCTAssertLessThan(floatFrame?.width ?? .infinity, bounds.width)
        XCTAssertNil(engine.plan().frames[2], "then it's left alone")

        engine.perform(.toggleFloat)
        XCTAssertEqual(engine.plan().frames.count, 2)
    }

    func testSuspendedWindowsKeepTheirSlot() {
        for layout in LayoutKind.allCases {
            let engine = makeEngine(layout: layout, windows: 3)
            let before = engine.plan().frames
            engine.suspendWindow(2)
            let during = engine.plan()
            XCTAssertNil(during.frames[2], "\(layout)")
            XCTAssertNil(during.hidden[2], "\(layout): a suspended window must not be moved")
            engine.resumeWindow(2)
            XCTAssertEqual(engine.plan().frames, before, "\(layout)")
        }
    }

    func testSuspendingFocusedWindowMovesFocus() {
        let engine = makeEngine(windows: 3)
        engine.suspendWindow(3)
        XCTAssertEqual(engine.focusedWindow, 2)
    }

    func testClosingFocusedWindowMovesFocus() {
        let engine = makeEngine(windows: 3)
        engine.removeWindow(3)
        XCTAssertEqual(engine.focusedWindow, 2)
        engine.removeWindow(2)
        XCTAssertEqual(engine.focusedWindow, 1)
        engine.removeWindow(1)
        XCTAssertNil(engine.focusedWindow)
    }
}

final class FocusAndDragTests: XCTestCase {
    func testDirectionalFocus() {
        let engine = makeEngine(windows: 3)
        _ = engine.plan()
        // [1] [2 over 3], focus on 3
        engine.perform(.focus(.up))
        XCTAssertEqual(engine.focusedWindow, 2)
        engine.perform(.focus(.left))
        XCTAssertEqual(engine.focusedWindow, 1)
        engine.perform(.focus(.left))
        XCTAssertEqual(engine.focusedWindow, 1, "nothing to the left, and no other display")
    }

    func testDirectionalSwap() {
        let engine = makeEngine(windows: 2)
        let before = engine.plan().frames
        engine.perform(.swap(.left))
        let after = engine.plan().frames
        XCTAssertEqual(after[1], before[2])
        XCTAssertEqual(after[2], before[1])
        XCTAssertEqual(engine.focusedWindow, 2, "focus stays on the moved window")
    }

    func testDropOnAnotherTileSwaps() {
        let engine = makeEngine(windows: 2)
        let before = engine.plan().frames
        engine.drop(1, at: CGPoint(x: 1200, y: 400))
        XCTAssertEqual(engine.plan().frames[1], before[2])
    }

    func testDropOnNothingSnapsBack() {
        let engine = makeEngine(windows: 1)
        let before = engine.plan().frames
        engine.drop(1, at: CGPoint(x: 1200, y: 400))
        XCTAssertEqual(engine.plan().frames, before)
    }
}

final class MonitorTests: XCTestCase {
    private let right = Monitor(
        id: 2,
        frame: CGRect(x: 1600, y: 0, width: 1000, height: 800),
        visibleFrame: CGRect(x: 1600, y: 0, width: 1000, height: 800)
    )

    func testEachMonitorGetsItsOwnWorkspace() {
        let engine = makeEngine(monitors: [screen, right])
        engine.addWindow(1, monitor: 1)
        engine.addWindow(2, monitor: 2)
        let plan = engine.plan()
        XCTAssertEqual(plan.frames[1], bounds)
        XCTAssertEqual(plan.frames[2], right.visibleFrame)
        XCTAssertEqual(engine.activeWorkspaceID(on: 1), 1)
        XCTAssertEqual(engine.activeWorkspaceID(on: 2), 2)
    }

    func testFocusCrossesDisplays() {
        let engine = makeEngine(monitors: [screen, right])
        engine.addWindow(1, monitor: 1)
        engine.addWindow(2, monitor: 2)
        _ = engine.plan()
        engine.focusChanged(to: 1)
        engine.perform(.focus(.right))
        XCTAssertEqual(engine.focusedWindow, 2)
    }

    func testSwapAtScreenEdgeMovesWindowAcrossDisplays() {
        let engine = makeEngine(monitors: [screen, right])
        engine.addWindow(1, monitor: 1)
        engine.addWindow(3, monitor: 1)
        engine.focusChanged(to: 3)
        _ = engine.plan()
        engine.perform(.swap(.right))
        let plan = engine.plan()
        XCTAssertEqual(plan.frames[3], right.visibleFrame)
        XCTAssertEqual(plan.frames[1], bounds)
    }

    func testDisconnectKeepsWindowsAndReconnectRestores() {
        let engine = makeEngine(monitors: [screen, right])
        engine.addWindow(1, monitor: 1)
        engine.addWindow(2, monitor: 2)
        engine.setMonitors([screen])
        let unplugged = engine.plan()
        XCTAssertNotNil(unplugged.hidden[2], "still managed, reachable by workspace number")

        engine.setMonitors([screen, right])
        XCTAssertEqual(engine.plan().frames[2], right.visibleFrame)
    }

    func testHiddenOriginAvoidsNeighbouringDisplay() {
        let size = CGSize(width: 500, height: 400)
        let lone = hiddenOrigin(for: size, on: screen, among: [screen])
        XCTAssertEqual(lone.x, 1599)
        XCTAssertEqual(lone.y, 999)

        let tallNeighbour = Monitor(
            id: 3,
            frame: CGRect(x: 1600, y: 0, width: 1000, height: 1400),
            visibleFrame: CGRect(x: 1600, y: 0, width: 1000, height: 1400)
        )
        let withNeighbour = hiddenOrigin(for: size, on: screen, among: [screen, tallNeighbour])
        XCTAssertEqual(withNeighbour.x, -499, "parks on the left, away from the display on the right")

        // A shorter neighbour ends above the corner, so the default corner is still clear.
        XCTAssertEqual(hiddenOrigin(for: size, on: screen, among: [screen, right]).x, 1599)
    }
}

final class CommandParsingTests: XCTestCase {
    func testParsesCommands() {
        XCTAssertEqual(Command("focus-left"), .focus(.left))
        XCTAssertEqual(Command("swap-down"), .swap(.down))
        XCTAssertEqual(Command("workspace-3"), .workspace(3))
        XCTAssertEqual(Command("move-to-workspace-9"), .moveToWorkspace(9, follow: true))
        XCTAssertEqual(Command("send-to-workspace-2"), .moveToWorkspace(2, follow: false))
        XCTAssertEqual(Command("layout-centeredMaster"), .layout(.centeredMaster))
        XCTAssertEqual(Command("grow-width"), .grow(width: 60, height: 0))
    }

    func testRejectsUnknownCommands() {
        XCTAssertNil(Command("workspace-0"))
        XCTAssertNil(Command("workspace-10"))
        XCTAssertNil(Command("nonsense"))
    }
}
