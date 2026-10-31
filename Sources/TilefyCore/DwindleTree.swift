import CoreGraphics

/// Hyprland-style dwindle: a binary tree where each new window splits the focused one.
/// The split direction follows the shape of the space being split unless the user overrode it.
final class DwindleTree {
    final class Node {
        weak var parent: Node?
        var window: WindowID?
        var first: Node?
        var second: Node?
        var ratio: CGFloat = 0.5
        /// Set by toggle-split. Nil means "decide from the aspect ratio".
        var axisOverride: Axis?
        // Recorded on each layout pass so resizing knows which ancestor to adjust.
        var lastAxis: Axis = .horizontal
        var lastRect: CGRect = .zero

        init(window: WindowID?) { self.window = window }

        var isLeaf: Bool { window != nil }
    }

    private(set) var root: Node?

    var leaves: [WindowID] {
        var result: [WindowID] = []
        func walk(_ node: Node?) {
            guard let node else { return }
            if let window = node.window { result.append(window) }
            walk(node.first)
            walk(node.second)
        }
        walk(root)
        return result
    }

    private func leaf(_ id: WindowID, from node: Node? = nil) -> Node? {
        guard let node = node ?? root else { return nil }
        if node.window == id { return node }
        if let first = node.first, let found = leaf(id, from: first) { return found }
        if let second = node.second, let found = leaf(id, from: second) { return found }
        return nil
    }

    private func lastLeaf() -> Node? {
        var node = root
        while let current = node, !current.isLeaf { node = current.second }
        return node
    }

    /// Splits `target` (or the most recent leaf) to make room for `id`.
    func insert(_ id: WindowID, splitting target: WindowID?) {
        guard root != nil else {
            root = Node(window: id)
            return
        }
        guard let node = target.flatMap({ leaf($0) }) ?? lastLeaf(), let existing = node.window else { return }
        let first = Node(window: existing)
        let second = Node(window: id)
        first.parent = node
        second.parent = node
        node.window = nil
        node.first = first
        node.second = second
    }

    func remove(_ id: WindowID) {
        guard let node = leaf(id) else { return }
        guard let parent = node.parent else {
            root = nil
            return
        }
        let sibling = parent.first === node ? parent.second! : parent.first!
        // The parent takes over the sibling's role, which keeps the parent's place in its own parent.
        parent.window = sibling.window
        parent.first = sibling.first
        parent.second = sibling.second
        parent.ratio = sibling.ratio
        parent.axisOverride = sibling.axisOverride
        parent.first?.parent = parent
        parent.second?.parent = parent
    }

    func swap(_ a: WindowID, _ b: WindowID) {
        guard let nodeA = leaf(a), let nodeB = leaf(b) else { return }
        nodeA.window = b
        nodeB.window = a
    }

    /// Puts another window in the same place in the tree.
    func replace(_ old: WindowID, with new: WindowID) {
        leaf(old)?.window = new
    }

    func toggleSplit(of id: WindowID) {
        guard let parent = leaf(id)?.parent else { return }
        parent.axisOverride = parent.lastAxis.flipped
    }

    /// Grows `id` by `delta` points along `axis`, by moving the nearest split on that axis.
    func grow(_ id: WindowID, along axis: Axis, by delta: CGFloat) {
        var child = leaf(id)
        var ancestor = child?.parent
        while let node = ancestor {
            if node.lastAxis == axis {
                let extent = axis == .horizontal ? node.lastRect.width : node.lastRect.height
                guard extent > 0 else { return }
                let change = delta / extent
                node.ratio = min(0.9, max(0.1, node.ratio + (node.first === child ? change : -change)))
                return
            }
            child = node
            ancestor = node.parent
        }
    }

    func balance() {
        func walk(_ node: Node?) {
            guard let node else { return }
            node.ratio = 0.5
            walk(node.first)
            walk(node.second)
        }
        walk(root)
    }

    /// Lays out the tree, skipping `suspended` windows. A subtree with nothing visible gives its
    /// space to its sibling, while the structure stays intact for when those windows return.
    func frames(in bounds: CGRect, gap: CGFloat, suspended: Set<WindowID>) -> [WindowID: CGRect] {
        var result: [WindowID: CGRect] = [:]

        func hasVisibleWindow(_ node: Node?) -> Bool {
            guard let node else { return false }
            if let window = node.window { return !suspended.contains(window) }
            return hasVisibleWindow(node.first) || hasVisibleWindow(node.second)
        }

        func place(_ node: Node?, in rect: CGRect) {
            guard let node else { return }
            if let window = node.window {
                if !suspended.contains(window) { result[window] = rect }
                return
            }
            let firstVisible = hasVisibleWindow(node.first)
            let secondVisible = hasVisibleWindow(node.second)
            guard firstVisible && secondVisible else {
                place(firstVisible ? node.first : node.second, in: rect)
                return
            }
            let axis = node.axisOverride ?? (rect.width >= rect.height ? .horizontal : .vertical)
            node.lastAxis = axis
            node.lastRect = rect
            let (a, b) = rect.split(along: axis, ratio: node.ratio, gap: gap)
            place(node.first, in: a)
            place(node.second, in: b)
        }

        place(root, in: bounds)
        return result
    }

    // MARK: - Saving and restoring

    indirect enum Shape: Codable, Equatable {
        case leaf(WindowID)
        case split(ratio: CGFloat, axis: Axis?, first: Shape, second: Shape)
    }

    var shape: Shape? {
        func describe(_ node: Node) -> Shape? {
            if let window = node.window { return .leaf(window) }
            guard let first = node.first.flatMap(describe), let second = node.second.flatMap(describe) else { return nil }
            return .split(ratio: node.ratio, axis: node.axisOverride, first: first, second: second)
        }
        return root.flatMap(describe)
    }

    func restore(_ shape: Shape?) {
        func build(_ shape: Shape) -> Node {
            switch shape {
            case let .leaf(window):
                return Node(window: window)
            case let .split(ratio, axis, first, second):
                let node = Node(window: nil)
                node.ratio = ratio
                node.axisOverride = axis
                let a = build(first)
                let b = build(second)
                a.parent = node
                b.parent = node
                node.first = a
                node.second = b
                return node
            }
        }
        root = shape.map(build)
    }
}
