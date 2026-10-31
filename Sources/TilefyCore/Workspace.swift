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

    /// Window groups: several windows sharing one tile, with one showing. Keyed by the window
    /// currently holding the tile, and listing all members in tab order, including that one.
    /// The layouts only ever see the window holding the tile.
    public private(set) var groups: [WindowID: [WindowID]] = [:]

    var masterRatio: CGFloat = 0.55
    let dwindle = DwindleTree()
    var strip = ScrollingStrip()

    public init(id: Int, layout: LayoutKind) {
        self.id = id
        self.layout = layout
    }

    public var visibleTiled: [WindowID] { order.filter { !suspended.contains($0) } }
    public var isEmpty: Bool { order.isEmpty && floating.isEmpty }
    public var allWindows: [WindowID] { order + floating + behindGroups }

    /// Grouped windows that aren't the one showing.
    private var behindGroups: [WindowID] {
        groups.flatMap { slot, members in members.filter { $0 != slot } }.sorted()
    }

    public func contains(_ id: WindowID) -> Bool {
        order.contains(id) || floating.contains(id) || groups.values.contains { $0.contains(id) }
    }

    /// The window holding the tile for the group `id` is in, if it's in one.
    public func groupSlot(of id: WindowID) -> WindowID? {
        groups.first { $0.value.contains(id) }?.key
    }

    /// The other members of a tile's group that should share its frame.
    func visibleBehind(_ slot: WindowID) -> [WindowID] {
        (groups[slot] ?? []).filter { $0 != slot && !suspended.contains($0) }
    }
    public func isFloating(_ id: WindowID) -> Bool { floating.contains(id) }

    func setFocused(_ id: WindowID?) {
        if let id, groupSlot(of: id) != id, groupSlot(of: id) != nil { activateInGroup(id) }
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
        if leaveGroup(id) { return }
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
        // In a group, the next member takes over the tile, so the tile stays filled.
        if groupSlot(of: id) == id, let next = groups[id]?.first(where: { $0 != id && !suspended.contains($0) }) {
            let wasFocused = focused == id
            activateInGroup(next)
            if wasFocused { focused = next }
            suspended.insert(id)
            return
        }
        if let slot = groupSlot(of: id), slot != id {
            suspended.insert(id)
            return
        }
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
        // The whole group was away, and this member is first back. It takes the tile.
        if let slot = groupSlot(of: id), slot != id, suspended.contains(slot) { activateInGroup(id) }
        // Everything was away, so nothing has focus. A workspace with windows shouldn't stay that way.
        if focused == nil, order.contains(id) { setFocused(id) }
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
            // A member leaves the group behind it. A group of one stops being a group.
            if !leaveGroup(id) {
                groups[id] = nil
                detachTile(id)
            }
            floating.append(id)
            focused = id
        }
    }

    /// Takes a tile out of the layout, without touching focus.
    private func detachTile(_ id: WindowID) {
        guard let index = order.firstIndex(of: id) else { return }
        order.remove(at: index)
        dwindle.remove(id)
        strip.remove(id)
        if fullscreen == id { fullscreen = nil }
        if lastTiledFocus == id {
            lastTiledFocus = order[..<index].last { !suspended.contains($0) } ?? visibleTiled.first
        }
    }

    // MARK: - Groups

    /// Puts another window in a tile's place in every layout.
    private func replaceTile(_ old: WindowID, with new: WindowID) {
        guard let index = order.firstIndex(of: old) else { return }
        order[index] = new
        dwindle.replace(old, with: new)
        strip.replace(old, with: new)
        if fullscreen == old { fullscreen = new }
        if lastTiledFocus == old { lastTiledFocus = new }
    }

    /// Makes `id` the member showing in its group.
    func activateInGroup(_ id: WindowID) {
        guard let slot = groupSlot(of: id), slot != id, let members = groups[slot] else { return }
        replaceTile(slot, with: id)
        groups[slot] = nil
        groups[id] = members
        if focused == slot { focused = id }
    }

    /// Removes `id` from a group it shares with others. Returns false if it isn't in such a group,
    /// in which case the caller still has a window to deal with.
    private func leaveGroup(_ id: WindowID) -> Bool {
        guard let slot = groupSlot(of: id), let members = groups[slot] else { return false }
        guard members.count > 1 else {
            groups[slot] = nil
            return false
        }
        if slot == id {
            let position = members.firstIndex(of: id)!
            let others = members.filter { $0 != id }
            let next = others[..<min(position, others.count)].last { !suspended.contains($0) }
                ?? others.first { !suspended.contains($0) }
                ?? others[0]
            activateInGroup(next)
        }
        groups[groupSlot(of: id)!]?.removeAll { $0 == id }
        suspended.remove(id)
        // The remaining members may all be away, in which case focus has to go elsewhere.
        if let focused, suspended.contains(focused) { focusNeighbour(ofRemovedIndex: order.firstIndex(of: focused)) }
        return true
    }

    /// Makes a tile a group, or breaks up the group it's in, giving each member its own tile.
    func toggleGroup(_ id: WindowID) {
        guard order.contains(id) else { return }
        guard let members = groups[id] else {
            groups[id] = [id]
            return
        }
        groups[id] = nil
        lastTiledFocus = id
        for member in members where member != id {
            insertTiled(member)
        }
    }

    /// Adds a tile to the group on the tile `target`, which becomes a group if it wasn't one.
    func addToGroup(_ id: WindowID, target: WindowID) {
        guard order.contains(target), id != target else { return }
        if groups[target] == nil { groups[target] = [target] }
        groups[target]?.append(id)
        activateInGroup(id)
    }

    /// Moves a tile, or a member of another group, into the group on `target`.
    func moveIntoGroup(_ id: WindowID, target: WindowID) {
        guard order.contains(target), id != target, groupSlot(of: target) != groupSlot(of: id) || groupSlot(of: id) == nil else { return }
        if !leaveGroup(id) { detachTile(id) }
        addToGroup(id, target: target)
        focused = id
        lastTiledFocus = id
    }

    /// Takes a member out of its group, into a tile of its own next to the group.
    func removeFromGroup(_ id: WindowID) {
        guard let members = groups[groupSlot(of: id) ?? id] else { return }
        guard members.count > 1 else {
            groups[id] = nil
            return
        }
        _ = leaveGroup(id)
        lastTiledFocus = groupSlot(of: members.first { $0 != id }!)
        insertTiled(id)
        focused = id
        lastTiledFocus = id
    }

    /// Shows the next or previous member. Returns the window now showing.
    @discardableResult
    func cycleGroup(of id: WindowID, by delta: Int) -> WindowID? {
        guard let members = groups[groupSlot(of: id) ?? id]?.filter({ !suspended.contains($0) }),
              members.count > 1, let index = members.firstIndex(of: id)
        else { return nil }
        let next = members[(index + delta + members.count) % members.count]
        activateInGroup(next)
        focused = next
        lastTiledFocus = next
        return next
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

// MARK: - Saving and restoring

struct SavedWorkspace: Codable, Equatable {
    var id: Int
    var layout: LayoutKind
    var monitor: MonitorID?
    var order: [WindowID]
    var floating: [WindowID]
    var groups: [WindowID: [WindowID]]
    var focused: WindowID?
    var lastTiledFocus: WindowID?
    var fullscreen: WindowID?
    var masterRatio: CGFloat
    var dwindle: DwindleTree.Shape?
    var columns: [ScrollingStrip.Column]
    var offset: CGFloat
    var defaultWidth: CGFloat
}

extension Workspace {
    var saved: SavedWorkspace {
        SavedWorkspace(
            id: id,
            layout: layout,
            monitor: monitor,
            order: order,
            floating: floating,
            groups: groups,
            focused: focused,
            lastTiledFocus: lastTiledFocus,
            fullscreen: fullscreen,
            masterRatio: masterRatio,
            dwindle: dwindle.shape,
            columns: strip.columns,
            offset: strip.offset,
            defaultWidth: strip.defaultWidth
        )
    }

    /// Restores everything, with all windows away until they're found on screen again.
    convenience init(restoring saved: SavedWorkspace) {
        self.init(id: saved.id, layout: saved.layout)
        monitor = saved.monitor
        order = saved.order
        floating = saved.floating
        groups = saved.groups
        focused = saved.focused
        lastTiledFocus = saved.lastTiledFocus
        fullscreen = saved.fullscreen
        masterRatio = saved.masterRatio
        dwindle.restore(saved.dwindle)
        strip.columns = saved.columns
        strip.offset = saved.offset
        strip.defaultWidth = saved.defaultWidth
        suspended = Set(allWindows)
    }
}
