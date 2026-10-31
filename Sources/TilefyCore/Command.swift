/// Everything a keybinding can do. Parsed from strings like "focus-left" or "workspace-3".
public enum Command: Equatable, Sendable {
    case focus(Direction)
    case swap(Direction)
    case focusNextInWorkspace
    case focusPreviousInWorkspace
    case workspace(Int)
    case workspaceNext
    case workspacePrevious
    case workspaceLast
    /// Moves the focused window, and follows it when `follow` is true.
    case moveToWorkspace(Int, follow: Bool)
    case focusMonitorNext
    case moveToMonitorNext
    case moveWorkspaceToMonitorNext
    case moveToScratchpad
    case toggleScratchpad
    case toggleGroup
    case removeFromGroup
    case groupNext
    case groupPrevious
    case moveIntoGroup(Direction)
    case toggleSticky
    case layout(LayoutKind)
    case toggleDwindleScrolling
    case layoutNext
    case toggleSplit
    case toggleFloat
    case fullscreen
    case fullWidth
    case cycleWidth
    case center
    case promote
    case stack
    case unstack
    case grow(width: Int, height: Int)
    case balance
    case retile
    case close

    public init?(_ string: String) {
        func trailingNumber(after prefix: String) -> Int? {
            guard string.hasPrefix(prefix), let n = Int(string.dropFirst(prefix.count)), (1...9).contains(n) else {
                return nil
            }
            return n
        }

        if let n = trailingNumber(after: "workspace-") {
            self = .workspace(n)
            return
        }
        if let n = trailingNumber(after: "move-to-workspace-") {
            self = .moveToWorkspace(n, follow: true)
            return
        }
        if let n = trailingNumber(after: "send-to-workspace-") {
            self = .moveToWorkspace(n, follow: false)
            return
        }
        for direction in Direction.allCases {
            if string == "focus-\(direction.rawValue)" {
                self = .focus(direction)
                return
            }
            if string == "swap-\(direction.rawValue)" {
                self = .swap(direction)
                return
            }
            if string == "move-into-group-\(direction.rawValue)" {
                self = .moveIntoGroup(direction)
                return
            }
        }
        for kind in LayoutKind.allCases where string == "layout-\(kind.rawValue)" {
            self = .layout(kind)
            return
        }

        switch string {
        case "focus-next": self = .focusNextInWorkspace
        case "focus-previous": self = .focusPreviousInWorkspace
        case "workspace-next": self = .workspaceNext
        case "workspace-previous": self = .workspacePrevious
        case "workspace-last": self = .workspaceLast
        case "focus-monitor-next": self = .focusMonitorNext
        case "move-to-monitor-next": self = .moveToMonitorNext
        case "move-workspace-to-monitor-next": self = .moveWorkspaceToMonitorNext
        case "move-to-scratchpad": self = .moveToScratchpad
        case "toggle-scratchpad": self = .toggleScratchpad
        case "toggle-group": self = .toggleGroup
        case "remove-from-group": self = .removeFromGroup
        case "group-next": self = .groupNext
        case "group-previous": self = .groupPrevious
        case "toggle-sticky": self = .toggleSticky
        case "layout-toggle": self = .toggleDwindleScrolling
        case "layout-next": self = .layoutNext
        case "toggle-split": self = .toggleSplit
        case "toggle-float": self = .toggleFloat
        case "fullscreen": self = .fullscreen
        case "full-width": self = .fullWidth
        case "cycle-width": self = .cycleWidth
        case "center": self = .center
        case "promote": self = .promote
        case "stack": self = .stack
        case "unstack": self = .unstack
        case "grow-width": self = .grow(width: 60, height: 0)
        case "shrink-width": self = .grow(width: -60, height: 0)
        case "grow-height": self = .grow(width: 0, height: 60)
        case "shrink-height": self = .grow(width: 0, height: -60)
        case "balance": self = .balance
        case "retile": self = .retile
        case "close": self = .close
        default: return nil
        }
    }
}
