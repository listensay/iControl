import Foundation

/// Rendered framebuffer bounds in web-view points, with a top-left origin.
public struct FPSViewport: Equatable, Sendable {
    public var x: Double, y: Double, width: Double, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public var isValid: Bool {
        [x, y, width, height].allSatisfy(\.isFinite) && width > 0 && height > 0
    }
    public func normalized(x pointX: Double, y pointY: Double, clamp: Bool = false) -> FPSPoint? {
        guard isValid, pointX.isFinite, pointY.isFinite else { return nil }
        let point = FPSPoint(x: (pointX - x) / width, y: (pointY - y) / height)
        if point.isValid { return point }
        return clamp ? FPSPoint(x: min(1, max(0, point.x)), y: min(1, max(0, point.y))) : nil
    }
}
