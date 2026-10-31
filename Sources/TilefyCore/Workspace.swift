import CoreGraphics

public enum LayoutKind: String, Codable, CaseIterable, Sendable {
    case dwindle, scrolling, master, centeredMaster, grid, monocle

    public var title: String {
        switch self {
        case .dwindle: return "Dwindle"
        case .scrolling: return "Scrolling"
        case .master: return "Master & Stack"
        case .centeredMaster: return "Centered Master"
        case .grid: return "Grid"
        case .monocle: return "Monocle"
        }
    }

    public var summary: String {
        switch self {
        case .dwindle: return "Each new window splits the focused one."
        case .scrolling: return "An endless row of columns that slides to follow focus."
        case .master: return "One large window on the left, the rest stacked on the right."
        case .centeredMaster: return "One large window in the middle, with the rest on both sides."
        case .grid: return "An even grid of equal windows."
        case .monocle: return "Every window fills the screen. Move focus to flip through them."
        }
    }

    public var symbolName: String {
        switch self {
        case .dwindle: return "rectangle.split.2x2"
        case .scrolling: return "rectangle.split.3x1"
        case .master: return "sidebar.squares.right"
        case .centeredMaster: return "rectangle.center.inset.filled"
        case .grid: return "square.grid.2x2"
        case .monocle: return "macwindow"
        }
    }
}

public final class Workspace {
    public let id: Int
    public var layout: LayoutKind
    /// Which monitor this workspace last belonged to.
    public var monitor: MonitorID?

    /// Tiled windows in order. Every layout reads this or a structure kept in sync with it, so
    /// switching layouts never loses windows.
    public private(set) var order: [WindowID] = []
    public private(set) var floating: [WindowID] = []
    public var focused: WindowID?
    /// The tiled window that had focus most recently. New windows go next to it.
    public private(set) var lastTiledFocus: WindowID?
    /// A tiled window temporarily filling the whole workspace.
    public var fullscreen: WindowID?
    /// On another native Space, minimized or hidden: keeps its slot but takes no space.
    public private(set) var suspended: Set<WindowID> = []

    var masterRatio: CGFloat = 0.55
    let dwindle = DwindleTree()
    var strip = ScrollingStrip()

    public init(id: Int, layout: LayoutKind) {
        self.id = id
        self.layout = layout
    }

    public var visibleTiled: [WindowID] { order.filter { !suspended.contains($0) } }
    public var isEmpty: Bool { order.isEmpty && floating.isEmpty }
    public var allWindows: [WindowID] { order + floating }

    public func contains(_ id: WindowID) -> Bool { order.contains(id) || floating.contains(id) }
    public func isFloating(_ id: WindowID) -> Bool { floating.contains(id) }

    func setFocused(_ id: WindowID?) {
        focused = id
        if let id, order.contains(id) { lastTiledFocus = id }
    }

    func insertTiled(_ id: WindowID) {
        let target = lastTiledFocus.flatMap { order.contains($0) ? $0 : nil }
        if let target, let index = order.firstIndex(of: target) {
            order.insert(id, at: index + 1)
        } else {
            order.append(id)
        }
        dwindle.insert(id, splitting: target)
        strip.insert(id, after: target)
    }

    func insertFloating(_ id: WindowID) {
        floating.append(id)
    }

    /// Removes a window from every structure and moves focus to a sensible neighbour.
    func remove(_ id: WindowID) {
        let wasFocused = focused == id
        let index = order.firstIndex(of: id)
        order.removeAll { $0 == id }
        floating.removeAll { $0 == id }
        suspended.remove(id)
        dwindle.remove(id)
        strip.remove(id)
        if fullscreen == id { fullscreen = nil }
        if lastTiledFocus == id { lastTiledFocus = nil }
        if wasFocused { focusNeighbour(ofRemovedIndex: index) }
    }

    /// Takes a window out of the layout but remembers its slot.
    func suspend(_ id: WindowID) {
        guard contains(id), !suspended.contains(id) else { return }
        let index = order.firstIndex(of: id)
        suspended.insert(id)
        if fullscreen == id { fullscreen = nil }
        if focused == id { focusNeighbour(ofRemovedIndex: index) }
        // A float may have focus. Keep its fallback tile on a window that can actually take focus.
        if lastTiledFocus == id, let index {
            lastTiledFocus = order[..<index].last { !suspended.contains($0) } ?? visibleTiled.first
        }
    }

    func resume(_ id: WindowID) {
        suspended.remove(id)
    }

    private func focusNeighbour(ofRemovedIndex index: Int?) {
        let candidates = visibleTiled
        if let index, !candidates.isEmpty {
            // Prefer the window that sat just before the one that left.
            let before = order[..<min(index, order.count)].last { !suspended.contains($0) }
            setFocused(before ?? candidates.first)
        } else {
            setFocused(candidates.first ?? floating.first { !suspended.contains($0) })
        }
    }

    func swap(_ a: WindowID, _ b: WindowID) {
        guard let indexA = order.firstIndex(of: a), let indexB = order.firstIndex(of: b) else { return }
        order.swapAt(indexA, indexB)
        dwindle.swap(a, b)
        strip.swap(a, b)
    }

    /// Master layouts: makes `id` the master, or swaps the master out if it already is.
    func promote(_ id: WindowID) {
        let visible = visibleTiled
        guard let master = visible.first, visible.count > 1 else { return }
        swap(id, id == master ? visible[1] : master)
    }

    func toggleFloating(_ id: WindowID) {
        if floating.contains(id) {
            floating.removeAll { $0 == id }
            insertTiled(id)
            lastTiledFocus = id
        } else if order.contains(id) {
            let index = order.firstIndex(of: id)!
            order.remove(at: index)
            dwindle.remove(id)
            strip.remove(id)
            if fullscreen == id { fullscreen = nil }
            if lastTiledFocus == id {
                lastTiledFocus = order[..<index].last { !suspended.contains($0) } ?? visibleTiled.first
            }
            floating.append(id)
        }
    }

    func toggleSplit(of id: WindowID) {
        dwindle.toggleSplit(of: id)
    }

    func grow(_ id: WindowID, width: CGFloat, height: CGFloat, bounds: CGRect, gap: CGFloat) {
        switch layout {
        case .dwindle:
            if width != 0 { dwindle.grow(id, along: .horizontal, by: width) }
            if height != 0 { dwindle.grow(id, along: .vertical, by: height) }
        case .scrolling:
            strip.grow(id, by: width, viewport: bounds.width, gap: gap)
        case .master, .centeredMaster:
            guard bounds.width > 0, width != 0 else { return }
            // Side columns in centered master take space from both sides of the master.
            let scale: CGFloat = layout == .centeredMaster ? 2 : 1
            let change = width * scale / bounds.width
            let isMaster = visibleTiled.first == id
            masterRatio = min(0.9, max(0.1, masterRatio + (isMaster ? change : -change)))
        case .grid, .monocle:
            break
        }
    }

    func balance() {
        dwindle.balance()
        strip.balance()
        masterRatio = 0.55
    }

    // MARK: - Layout

    /// Frames for every visible tiled window. In the scrolling layout these can lie outside `bounds`.
    func frames(in bounds: CGRect, gap: CGFloat) -> [WindowID: CGRect] {
        let tiled = visibleTiled
        guard !tiled.isEmpty else { return [:] }

        var result: [WindowID: CGRect]
        switch layout {
        case .dwindle:
            result = dwindle.frames(in: bounds, gap: gap, suspended: suspended)
        case .scrolling:
            let focusedTile = focused.flatMap { order.contains($0) ? $0 : lastTiledFocus }
            result = strip.frames(in: bounds, gap: gap, focused: focusedTile, suspended: suspended)
        case .master:
            result = masterFrames(tiled, bounds: bounds, gap: gap)
        case .centeredMaster:
            result = centeredMasterFrames(tiled, bounds: bounds, gap: gap)
        case .grid:
            result = gridFrames(tiled, bounds: bounds, gap: gap)
        case .monocle:
            result = Dictionary(uniqueKeysWithValues: tiled.map { ($0, bounds) })
        }
        if let fullscreen, tiled.contains(fullscreen) {
            result[fullscreen] = bounds
        }
        return result
    }

    private func masterFrames(_ tiled: [WindowID], bounds: CGRect, gap: CGFloat) -> [WindowID: CGRect] {
        guard tiled.count > 1 else { return [tiled[0]: bounds] }
        let (master, stack) = bounds.split(along: .horizontal, ratio: masterRatio, gap: gap)
        var result = [tiled[0]: master]
        let rest = Array(tiled.dropFirst())
        for (window, rect) in zip(rest, stack.slices(rest.count, along: .vertical, gap: gap)) {
            result[window] = rect
        }
        return result
    }

    private func centeredMasterFrames(_ tiled: [WindowID], bounds: CGRect, gap: CGFloat) -> [WindowID: CGRect] {
        guard tiled.count > 2 else { return masterFrames(tiled, bounds: bounds, gap: gap) }
        let masterWidth = ((bounds.width - 2 * gap) * masterRatio).rounded()
        let sideWidth = ((bounds.width - 2 * gap - masterWidth) / 2).rounded()
        let leftSide = CGRect(x: bounds.minX, y: bounds.minY, width: sideWidth, height: bounds.height)
        let master = CGRect(x: leftSide.maxX + gap, y: bounds.minY, width: masterWidth, height: bounds.height)
        let rightSide = CGRect(x: master.maxX + gap, y: bounds.minY, width: bounds.maxX - master.maxX - gap, height: bounds.height)

        // Alternate sides, so the columns stay balanced as windows open.
        let rest = Array(tiled.dropFirst())
        let right = stride(from: 0, to: rest.count, by: 2).map { rest[$0] }
        let left = stride(from: 1, to: rest.count, by: 2).map { rest[$0] }

        var result = [tiled[0]: master]
        for (window, rect) in zip(left, leftSide.slices(left.count, along: .vertical, gap: gap)) {
            result[window] = rect
        }
        for (window, rect) in zip(right, rightSide.slices(right.count, along: .vertical, gap: gap)) {
            result[window] = rect
        }
        return result
    }

    private func gridFrames(_ tiled: [WindowID], bounds: CGRect, gap: CGFloat) -> [WindowID: CGRect] {
        let count = tiled.count
        let columns = Int(Double(count).squareRoot().rounded(.up))
        let rows = Int((Double(count) / Double(columns)).rounded(.up))
        var result: [WindowID: CGRect] = [:]
        var remaining = tiled[...]
        for row in bounds.slices(rows, along: .vertical, gap: gap) {
            let isLast = remaining.count <= columns
            let inRow = isLast ? remaining.count : columns
            // The last row stretches to fill the space, so no hole is left.
            for (window, rect) in zip(remaining.prefix(inRow), row.slices(inRow, along: .horizontal, gap: gap)) {
                result[window] = rect
            }
            remaining = remaining.dropFirst(inRow)
        }
        return result
    }
}
