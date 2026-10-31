import CoreGraphics
import Foundation

/// What Tilefy learned on inspecting a window it hasn't seen before.
public enum WindowInspection: Equatable {
    /// A normal window. `cannotTile` means it has a fixed size or is a utility window, so it floats.
    case manage(id: WindowID, pid: Int32, frame: CGRect, cannotTile: Bool, bundleID: String?, title: String?)
    /// A dialog, panel or similar, or a window whose details aren't filled in yet.
    case reject(id: WindowID)
}

/// How the focused window's outline should look.
public enum BorderStyle: Equatable, Sendable {
    case normal, grouped, sticky
}

public enum Frontmost: Equatable {
    case tilefy
    case app(pid: Int32, focusedWindow: WindowID?)
    case unknown
}

/// Everything `WindowCoordinator` needs from macOS. The real implementation uses Accessibility,
/// and the tests use a simulated Mac, so the coordination logic can run without a screen.
public protocol WindowSystem: AnyObject {
    func currentMonitors() -> [Monitor]
    /// Windows on the current Space of some display, neither minimized nor hidden.
    /// Windows Tilefy parked in a corner still count, as one pixel of them is showing.
    func onScreenWindows() -> [WindowID: Int32]
    func attachToRunningApps()
    func inspectWindows(pid: Int32, among ids: Set<WindowID>) -> [WindowInspection]
    func isGone(_ id: WindowID) -> Bool
    func isFullScreen(_ id: WindowID) -> Bool
    func frame(of id: WindowID) -> CGRect?
    func frontmost() -> Frontmost
    func forget(_ id: WindowID)

    /// Moves windows to match `plan`, without blocking, then gives keyboard focus to `focus`.
    /// `completion` runs on the main thread once the window that has focus is in place.
    /// A nonzero `animationDuration` slides windows between on-screen places over that many seconds.
    func carryOut(
        plan: LayoutPlan,
        skipping: WindowID?,
        focus: WindowID?,
        monitors: [Monitor],
        animationDuration: Double,
        completion: @escaping () -> Void
    )
    func setPosition(of id: WindowID, to origin: CGPoint)
    func close(_ id: WindowID)
    /// Takes keyboard focus away from all windows.
    func clearFocus()

    func showBorder(around frame: CGRect?, width: Double, style: BorderStyle)
    func showHUD(_ text: String, on monitor: Monitor)

    func loadState() -> Data?
    func saveState(_ data: Data)
    /// Changes when window IDs stop being meaningful, which is at every boot.
    var sessionID: String { get }

    var isMouseDown: Bool { get }
    var mouseLocation: CGPoint { get }
    var now: Date { get }
    func after(_ delay: TimeInterval, _ block: @escaping () -> Void)
}
