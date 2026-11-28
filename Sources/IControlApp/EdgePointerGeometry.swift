import AppKit

enum EdgePointerSide: String, CaseIterable, Identifiable {
    case left, right, top, bottom
    var id: Self { self }
    var title: String {
        switch self { case .left: "左"; case .right: "右"; case .top: "上"; case .bottom: "下" }
    }
    var verticalSeam: Bool { self == .left || self == .right }
}

enum EdgePointerZone: String, CaseIterable, Identifiable {
    case full, firstHalf, middle, lastHalf
    var id: Self { self }
    var range: ClosedRange<CGFloat> {
        switch self { case .full: 0...1; case .firstHalf: 0...0.5; case .middle: 0.25...0.75; case .lastHalf: 0.5...1 }
    }
    func title(for side: EdgePointerSide) -> String {
        switch self {
        case .full: "整条边缘"
        case .middle: "中间一半"
        case .firstHalf: side.verticalSeam ? "上半段" : "左半段"
        case .lastHalf: side.verticalSeam ? "下半段" : "右半段"
        }
    }
}

/// Screen coordinates here are AppKit desktop *points*, including negative display origins.
/// Remote coordinates are normalized, with (0,0) at the framebuffer's top left.
struct EdgePointerSeam: Equatable {
    let side: EdgePointerSide
    let frame: CGRect
    let zone: EdgePointerZone

    func entryPoint(fraction t: CGFloat) -> CGPoint {
        switch side {
        case .right: .init(x: 0, y: t)
        case .left: .init(x: 1, y: t)
        case .top: .init(x: t, y: 1)
        case .bottom: .init(x: t, y: 0)
        }
    }

    func distanceInside(_ point: CGPoint) -> CGFloat {
        switch side {
        case .left: point.x - frame.minX
        case .right: frame.maxX - point.x
        case .top: frame.maxY - point.y
        case .bottom: point.y - frame.minY
        }
    }

    @MainActor func entry(at p: CGPoint, screens: [NSScreen]) -> CGPoint? {
        guard frame.width > 64, frame.height > 64, (0...4).contains(distanceInside(p)) else { return nil }
        let t = side.verticalSeam ? (frame.maxY - p.y) / frame.height : (p.x - frame.minX) / frame.width
        let margin = 32 / (side.verticalSeam ? frame.height : frame.width)
        guard zone.range.contains(t), (margin...(1 - margin)).contains(t) else { return nil } // leave macOS hot corners alone
        let remote = entryPoint(fraction: t)
        let outside = macPoint(for: remote, inset: -1)
        // A partially shared edge is OK, but never intercept the passage to a real Mac display.
        guard !screens.contains(where: { $0.frame.contains(outside) }) else { return nil }
        return remote
    }

    func macPoint(for remote: CGPoint, inset: CGFloat = 10) -> CGPoint {
        let x = frame.minX + min(frame.width - 2, max(2, remote.x * frame.width))
        let y = frame.maxY - min(frame.height - 2, max(2, remote.y * frame.height))
        switch side {
        case .left: return .init(x: frame.minX + inset, y: y)
        case .right: return .init(x: frame.maxX - inset, y: y)
        case .top: return .init(x: x, y: frame.maxY - inset)
        case .bottom: return .init(x: x, y: frame.minY + inset)
        }
    }

    func virtualSize(framebuffer: CGSize) -> CGSize {
        let scale = side.verticalSeam ? frame.height / framebuffer.height : frame.width / framebuffer.width
        return CGSize(width: framebuffer.width * scale, height: framebuffer.height * scale)
    }

    /// Keep a small amount of negative travel at the seam: slow one-point movements must
    /// accumulate to an exit just like one large movement, without bouncing on entry.
    func advance(_ p: inout CGPoint, dx: CGFloat, dy: CGFloat, space: CGSize) -> Bool {
        let x = p.x + dx / space.width, y = p.y + dy / space.height
        p.x = side == .right ? min(1, x) : side == .left ? max(0, x) : min(1, max(0, x))
        p.y = side == .bottom ? min(1, y) : side == .top ? max(0, y) : min(1, max(0, y))
        switch side {
        case .right: return x * space.width <= -8
        case .left: return (x - 1) * space.width >= 8
        case .top: return (y - 1) * space.height >= 8
        case .bottom: return y * space.height <= -8
        }
    }

    @MainActor static func warp(to appKitPoint: CGPoint) -> Bool {
        guard let primary = NSScreen.screens.first else { return false }
        // Only flip at the Quartz boundary; do not multiply by a Retina scale factor.
        return CGWarpMouseCursorPosition(CGPoint(x: appKitPoint.x, y: primary.frame.maxY - appKitPoint.y)) == .success
    }
}
