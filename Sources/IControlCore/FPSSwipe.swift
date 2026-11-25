import Foundation

public enum FPSSwipeDirection: String, CaseIterable, Codable, Sendable {
    case up, down, left, right
    public var title: String {
        switch self { case .up: return "上滑"; case .down: return "下滑"; case .left: return "左滑"; case .right: return "右滑" }
    }
}

/// Endpoints are in displayed coordinates; the same calibration applies to
/// every point along the gesture. Duration excludes the final lift interval.
public struct FPSSwipe: Codable, Equatable, Sendable {
    public var end: FPSPoint
    public var duration: Double
    public init(end: FPSPoint = .init(x: 0.5, y: 0.3), duration: Double = 0.25) {
        self.end = end; self.duration = duration
    }
    public static func starting(at point: FPSPoint) -> Self {
        .init(end: .init(x: point.x, y: point.y >= 0.2 ? point.y - 0.2 : point.y + 0.2))
    }
    public func direction(from start: FPSPoint) -> FPSSwipeDirection {
        let dx = end.x - start.x, dy = end.y - start.y
        return abs(dx) > abs(dy) ? (dx < 0 ? .left : .right) : (dy < 0 ? .up : .down)
    }
    public func distance(from start: FPSPoint) -> Double { hypot(end.x - start.x, end.y - start.y) }
    public mutating func set(direction: FPSSwipeDirection, distance: Double, from start: FPSPoint) {
        let d = min(0.9, max(0.01, distance))
        switch direction {
        case .up: end = .init(x: start.x, y: max(0, start.y - d))
        case .down: end = .init(x: start.x, y: min(1, start.y + d))
        case .left: end = .init(x: max(0, start.x - d), y: start.y)
        case .right: end = .init(x: min(1, start.x + d), y: start.y)
        }
    }
    public func validate(from start: FPSPoint) throws {
        guard end.isValid, duration.isFinite, (0.08...2).contains(duration), distance(from: start) >= 0.005 else {
            throw ControlError("滑动起点和终点需要分开，时长需要 0.08–2 秒")
        }
    }
}
