import CoreGraphics

/// Turns a stream of small scroll deltas into discrete steps. A trackpad sends many tiny events
/// per swipe, and without this a single swipe would fly through every workspace.
public struct ScrollAccumulator {
    public enum Step: Equatable, Sendable {
        case left, right, up, down
    }

    private var horizontal: CGFloat = 0
    private var vertical: CGFloat = 0
    private let threshold: CGFloat

    public init(threshold: CGFloat = 30) {
        self.threshold = threshold
    }

    public mutating func add(dx: CGFloat, dy: CGFloat) -> Step? {
        // Follow the dominant axis, so a slightly diagonal swipe doesn't trigger both.
        if abs(dx) > abs(dy) {
            horizontal += dx
            vertical = 0
        } else {
            vertical += dy
            horizontal = 0
        }
        if horizontal >= threshold {
            horizontal = 0
            return .left
        }
        if horizontal <= -threshold {
            horizontal = 0
            return .right
        }
        if vertical >= threshold {
            vertical = 0
            return .up
        }
        if vertical <= -threshold {
            vertical = 0
            return .down
        }
        return nil
    }

    public mutating func reset() {
        horizontal = 0
        vertical = 0
    }
}
