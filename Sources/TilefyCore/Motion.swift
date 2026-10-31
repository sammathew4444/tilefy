import CoreGraphics

/// The math behind window animations.
public enum FrameAnimation {
    /// Fast at first and settling gently, which feels responsive even over a short duration.
    public static func eased(_ progress: Double) -> Double {
        let p = min(1, max(0, progress))
        return 1 - pow(1 - p, 3)
    }

    public static func interpolate(from: CGRect, to: CGRect, progress: Double) -> CGRect {
        let t = CGFloat(eased(progress))
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { (a + (b - a) * t).rounded() }
        return CGRect(
            x: mix(from.minX, to.minX),
            y: mix(from.minY, to.minY),
            width: mix(from.width, to.width),
            height: mix(from.height, to.height)
        )
    }

    /// Windows animate only between two on-screen places. A window coming back from being parked would
    /// otherwise fly in from a corner, and workspace switches should be instant.
    public static func isWorthAnimating(from: CGRect, to: CGRect, monitors: [Monitor]) -> Bool {
        func isOnScreen(_ rect: CGRect) -> Bool {
            monitors.contains { $0.frame.contains(CGPoint(x: rect.midX, y: rect.midY)) }
        }
        return isOnScreen(from) && isOnScreen(to) && from != to
    }
}

/// Recognizes horizontal swipes from raw finger positions, in 0...1 trackpad coordinates.
public struct SwipeRecognizer {
    public enum Step: Equatable, Sendable {
        case fingersLeft, fingersRight
    }

    private let fingers: Int
    private let threshold: CGFloat
    private var baseline: CGPoint?
    /// This gesture turned out to be vertical, like Mission Control. Ignore it until the fingers lift.
    private var isIgnoringGesture = false

    public init(fingers: Int, threshold: CGFloat = 0.1) {
        self.fingers = fingers
        self.threshold = threshold
    }

    /// Call with every finger currently on the trackpad. A long swipe can give several steps.
    public mutating func update(touches: [CGPoint]) -> Step? {
        guard touches.count == fingers else {
            if touches.isEmpty { isIgnoringGesture = false }
            baseline = nil
            return nil
        }
        guard !isIgnoringGesture else { return nil }

        let count = CGFloat(touches.count)
        let center = CGPoint(
            x: touches.reduce(0) { $0 + $1.x } / count,
            y: touches.reduce(0) { $0 + $1.y } / count
        )
        guard let start = baseline else {
            baseline = center
            return nil
        }
        let dx = center.x - start.x
        let dy = center.y - start.y
        if abs(dy) > threshold, abs(dy) > abs(dx) {
            isIgnoringGesture = true
            baseline = nil
            return nil
        }
        guard abs(dx) >= threshold, abs(dx) > abs(dy) * 1.5 else { return nil }
        baseline = center
        return dx < 0 ? .fingersLeft : .fingersRight
    }
}
