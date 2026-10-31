import CoreGraphics

public typealias WindowID = UInt32
public typealias MonitorID = UInt32

public enum Direction: String, CaseIterable, Sendable {
    case left, right, up, down

    var axis: Axis { self == .left || self == .right ? .horizontal : .vertical }
}

public enum Axis: String, Codable, Sendable {
    /// Children sit side by side.
    case horizontal
    /// Children sit on top of each other.
    case vertical

    var flipped: Axis { self == .horizontal ? .vertical : .horizontal }
}

/// A rectangle in Accessibility coordinates: origin at the top-left of the primary display, y grows down.
public struct Monitor: Equatable, Sendable {
    public var id: MonitorID
    /// The whole display.
    public var frame: CGRect
    /// The display minus the menu bar and Dock.
    public var visibleFrame: CGRect

    public init(id: MonitorID, frame: CGRect, visibleFrame: CGRect) {
        self.id = id
        self.frame = frame
        self.visibleFrame = visibleFrame
    }
}

public struct Insets: Equatable, Codable, Sendable {
    public var top: CGFloat
    public var left: CGFloat
    public var bottom: CGFloat
    public var right: CGFloat

    public init(top: CGFloat = 0, left: CGFloat = 0, bottom: CGFloat = 0, right: CGFloat = 0) {
        self.top = top
        self.left = left
        self.bottom = bottom
        self.right = right
    }
}

extension CGRect {
    func inset(by insets: Insets) -> CGRect {
        CGRect(
            x: minX + insets.left,
            y: minY + insets.top,
            width: max(0, width - insets.left - insets.right),
            height: max(0, height - insets.top - insets.bottom)
        )
    }

    var center: CGPoint { CGPoint(x: midX, y: midY) }

    /// Splits along `axis`, giving the first part `ratio` of the space that is left after `gap`.
    func split(along axis: Axis, ratio: CGFloat, gap: CGFloat) -> (CGRect, CGRect) {
        switch axis {
        case .horizontal:
            let first = ((width - gap) * ratio).rounded()
            return (
                CGRect(x: minX, y: minY, width: first, height: height),
                CGRect(x: minX + first + gap, y: minY, width: width - first - gap, height: height)
            )
        case .vertical:
            let first = ((height - gap) * ratio).rounded()
            return (
                CGRect(x: minX, y: minY, width: width, height: first),
                CGRect(x: minX, y: minY + first + gap, width: width, height: height - first - gap)
            )
        }
    }

    /// Divides into `count` parts of equal size along `axis`, separated by `gap`. Rounding differs
    /// by at most a point between parts, and they always exactly fill the space.
    func slices(_ count: Int, along axis: Axis, gap: CGFloat) -> [CGRect] {
        guard count > 0 else { return [] }
        let extent = axis == .horizontal ? width : height
        let start = axis == .horizontal ? minX : minY
        let size = (extent - gap * CGFloat(count - 1)) / CGFloat(count)

        return (0..<count).map { index in
            let i = CGFloat(index)
            let from = (start + i * (size + gap)).rounded()
            let to = index == count - 1 ? start + extent : (start + i * (size + gap) + size).rounded()
            switch axis {
            case .horizontal: return CGRect(x: from, y: minY, width: to - from, height: height)
            case .vertical: return CGRect(x: minX, y: from, width: width, height: to - from)
            }
        }
    }
}

/// Finds the nearest window from `origin` in `direction`. Only windows that overlap on the
/// perpendicular axis count, so moving "right" never jumps diagonally.
public func neighbor(
    of origin: WindowID,
    direction: Direction,
    in frames: [WindowID: CGRect]
) -> WindowID? {
    guard let source = frames[origin] else { return nil }
    let tolerance: CGFloat = 1

    func distance(to candidate: CGRect) -> CGFloat? {
        let d: CGFloat
        let overlap: CGFloat
        switch direction {
        case .left:
            d = source.minX - candidate.maxX
            overlap = min(source.maxY, candidate.maxY) - max(source.minY, candidate.minY)
        case .right:
            d = candidate.minX - source.maxX
            overlap = min(source.maxY, candidate.maxY) - max(source.minY, candidate.minY)
        case .up:
            d = source.minY - candidate.maxY
            overlap = min(source.maxX, candidate.maxX) - max(source.minX, candidate.minX)
        case .down:
            d = candidate.minY - source.maxY
            overlap = min(source.maxX, candidate.maxX) - max(source.minX, candidate.minX)
        }
        return d >= -tolerance && overlap > tolerance ? d : nil
    }

    return frames
        .filter { $0.key != origin }
        .compactMap { id, frame in distance(to: frame).map { (id: id, distance: $0, frame: frame) } }
        .min { a, b in
            if a.distance != b.distance { return a.distance < b.distance }
            // Same distance (a stack on the far side): prefer the topmost / leftmost, deterministically.
            if a.frame.minY != b.frame.minY { return a.frame.minY < b.frame.minY }
            if a.frame.minX != b.frame.minX { return a.frame.minX < b.frame.minX }
            return a.id < b.id
        }?.id
}

/// Where to park a window so that it is out of sight on `monitor`.
///
/// macOS will not let a window go fully off-screen, so one pixel stays visible in a bottom corner.
/// The corner chosen is the one that overlaps other displays least, otherwise a parked window
/// would show up on the neighbouring display.
public func hiddenOrigin(for size: CGSize, on monitor: Monitor, among monitors: [Monitor]) -> CGPoint {
    let bottom = monitor.frame.maxY - 1
    let right = CGPoint(x: monitor.frame.maxX - 1, y: bottom)
    let left = CGPoint(x: monitor.frame.minX - size.width + 1, y: bottom)

    func overlap(_ origin: CGPoint) -> CGFloat {
        let rect = CGRect(origin: origin, size: size)
        return monitors
            .filter { $0.id != monitor.id }
            .map { rect.intersection($0.frame) }
            .filter { !$0.isNull }
            .reduce(0) { $0 + $1.width * $1.height }
    }
    return overlap(left) < overlap(right) ? left : right
}
