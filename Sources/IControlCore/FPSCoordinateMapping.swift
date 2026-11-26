import Foundation

/// Converts positions from the visible framebuffer before the device applies
/// its interface orientation. The default preserves existing profiles.
public struct FPSCoordinateMapping: Codable, Equatable, Sendable {
    public var rotation = 0
    public var mirrorX = false
    public var mirrorY = false
    public var offsetX = 0.0
    public var offsetY = 0.0

    public init() { }

    public func validate() throws {
        guard (0...3).contains(rotation), offsetX.isFinite, offsetY.isFinite,
              (-0.25...0.25).contains(offsetX), (-0.25...0.25).contains(offsetY) else {
            throw ControlError("触点旋转或偏移超出支持范围")
        }
    }

    public func apply(_ point: FPSPoint) -> FPSPoint {
        // Offsets are measured in the displayed axes, before rotation.
        let x = min(1, max(0, point.x + offsetX))
        let y = min(1, max(0, point.y + offsetY))
        var result: FPSPoint
        switch rotation {
        case 1: result = FPSPoint(x: y, y: 1 - x)
        case 2: result = FPSPoint(x: 1 - x, y: 1 - y)
        case 3: result = FPSPoint(x: 1 - y, y: x)
        default: result = FPSPoint(x: x, y: y)
        }
        if mirrorX { result.x = 1 - result.x }
        if mirrorY { result.y = 1 - result.y }
        return result
    }
}

extension FPSProfile {
    public func touchState(_ contacts: [FPSContact]) -> FPSState {
        FPSState(contacts: contacts.map { FPSContact(id: $0.id, point: touchMapping.apply($0.point)) },
                 orientation: orientation)
    }
}

/// Explicit layout tests use the same mapping and input engine as gameplay.
/// Merely moving or resizing a marker never produces an input preview.
public enum FPSInputPreview {
    public static let interval = 1.0 / 60.0

    /// Approach W+A from each neighboring direction while the camera turns.
    public static func diagonalWithLook(profile: FPSProfile, aspect: Double) throws -> [FPSState] {
        guard profile.joystickEnabled, profile.lookEnabled else {
            throw ControlError("请先启用 WASD 移动和鼠标转向映射")
        }
        var engine = try FPSInputEngine(profile: profile)
        engine.setAspect(aspect); _ = engine.start()
        var frames = [engine.state]
        for tick in 1...600 {
            let now = Double(tick) * interval
            switch tick {
            case 20, 330: _ = engine.keyDown("KeyA", now: now)
            case 34: _ = engine.keyDown("KeyW", now: now)
            case 210, 480: _ = engine.keyUp("KeyA", now: now)
            default: break
            }
            engine.mouseMoved(dx: tick % 120 < 60 ? 16 : -16, dy: 0, now: now)
            _ = engine.advance(now: now); frames.append(engine.state)
        }
        frames.append(engine.releaseAll())
        return frames
    }

    public static func action(_ action: FPSAction, profile: FPSProfile) throws -> [FPSState] {
        try button(action.id, profile: profile)
    }

    public static func button(_ id: String, profile: FPSProfile) throws -> [FPSState] {
        guard profile.buttons.contains(where: { $0.id == id && $0.enabled }) else {
            throw ControlError("此动作尚未启用，请先勾选“启用此动作”")
        }
        var engine = try FPSInputEngine(profile: profile); _ = engine.start()
        _ = engine.pulse(button: id, now: 0)
        let button = profile.buttons.first { $0.id == id }!
        if button.behavior == .swipe {
            var frames = [engine.state]
            for tick in 1...Int(ceil(button.swipe.duration / interval) + 2) {
                _ = engine.advance(now: Double(tick) * interval); frames.append(engine.state)
            }
            return frames + [engine.releaseAll()]
        }
        let down = engine.state
        return Array(repeating: down, count: 7) + [profile.touchState([])]
    }

    public static func look(horizontal: Bool, profile: FPSProfile, aspect: Double) throws -> [FPSState] {
        var engine = try FPSInputEngine(profile: profile)
        engine.setAspect(aspect); _ = engine.start()
        var frames: [FPSState] = []
        for tick in 0..<12 {
            let now = Double(tick) * interval
            engine.mouseMoved(dx: horizontal ? 3 : 0, dy: horizontal ? 0 : 3, now: now)
            _ = engine.advance(now: now); frames.append(engine.state)
        }
        frames.append(engine.releaseAll())
        return frames
    }

    /// Exercises all eight WASD targets with overlapping keys, using the same
    /// engine and timing as capture. No mouse movement is part of this test.
    public static func movement(profile: FPSProfile, aspect: Double) throws -> [FPSState] {
        guard profile.joystickEnabled else { throw ControlError("请先启用 WASD 移动映射") }
        var engine = try FPSInputEngine(profile: profile)
        engine.setAspect(aspect); _ = engine.start()
        let changes: [(down: String?, up: String?)] = [
            ("KeyW", nil), ("KeyD", nil), (nil, "KeyW"), ("KeyS", nil),
            (nil, "KeyD"), ("KeyA", nil), (nil, "KeyS"), ("KeyW", nil),
            (nil, "KeyA"), (nil, "KeyW")
        ]
        var frames: [FPSState] = []
        for (index, change) in changes.enumerated() {
            let now = Double(index * 9) * interval
            if let down = change.down { _ = engine.keyDown(down, now: now) }
            if let up = change.up { _ = engine.keyUp(up, now: now) }
            frames.append(engine.state)
            for tick in 1..<9 {
                _ = engine.advance(now: now + Double(tick) * interval); frames.append(engine.state)
            }
        }
        frames.append(engine.releaseAll())
        return frames
    }

    /// W alone for one second, without mouse input or any other action. This
    /// distinguishes center alignment from a diagonal-to-forward transition.
    public static func forward(profile: FPSProfile, aspect: Double) throws -> [FPSState] {
        guard profile.joystickEnabled else { throw ControlError("请先启用 WASD 移动映射") }
        var engine = try FPSInputEngine(profile: profile)
        engine.setAspect(aspect); _ = engine.start()
        _ = engine.keyDown("KeyW", now: 0)
        var frames = [engine.state]
        for tick in 1...60 {
            _ = engine.advance(now: Double(tick) * interval); frames.append(engine.state)
        }
        _ = engine.keyUp("KeyW", now: 1)
        _ = engine.advance(now: 1); frames.append(engine.state)
        return frames
    }
}
