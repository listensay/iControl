import Foundation

/// One touch steers the wheel for as long as a movement key is held. Horizontal
/// and vertical travel add independently, as in QtScrcpy's KMT_STEER_WHEEL.
/// The latest opposing key wins on each axis; key repeat does not change it.
struct FPSKeyboardJoystick: Sendable {
    // A center down must survive one display frame before the initial drag.
    static let anchorInterval = 1.0 / 60.0
    private var anchorTime: TimeInterval?
    private var hasDragged = false
    private var current = FPSPoint(x: 0, y: 0)
    private var target = FPSPoint(x: 0, y: 0)
    private struct Travel: Sendable {
        var started: TimeInterval
        var duration: TimeInterval
        var from: FPSPoint
    }
    private var travel: Travel?

    mutating func point(keys: [String], now: TimeInterval, turnDuration: Double) -> FPSPoint? {
        let horizontal = keys.last { $0 == "KeyA" || $0 == "KeyD" }
        let vertical = keys.last { $0 == "KeyW" || $0 == "KeyS" }
        guard horizontal != nil || vertical != nil else {
            // Stop without a return-to-center animation or a delayed lift.
            // A new press after this up edge starts a fresh center down.
            self = Self(); return nil
        }
        let next = FPSPoint(x: horizontal == "KeyD" ? 1 : horizontal == "KeyA" ? -1 : 0,
                            y: vertical == "KeyS" ? 1 : vertical == "KeyW" ? -1 : 0)
        if anchorTime == nil {
            anchorTime = now; target = next
            return current
        }
        guard now - anchorTime! >= Self.anchorInterval else {
            // New keys during the center dwell choose the first drag's target.
            target = next; return current
        }
        if !hasDragged {
            hasDragged = true
            beginTravel(to: next, now: anchorTime! + Self.anchorInterval, duration: turnDuration)
        } else {
            updateTravel(now: now)
            if next != target {
                // Replace the old trajectory, starting at its current position.
                // Never queue obsolete directions or lift on an axis release.
                beginTravel(to: next, now: now, duration: turnDuration)
            }
        }
        updateTravel(now: now)
        return current
    }

    private mutating func beginTravel(to next: FPSPoint, now: TimeInterval, duration: Double) {
        let distance = max(abs(next.x - current.x), abs(next.y - current.y))
        target = next
        if duration == 0 || distance == 0 {
            current = next; travel = nil
        } else {
            // Constant travel speed: one axis' full offset takes the configured
            // time, a full reversal takes twice that, short corrections less.
            travel = Travel(started: now, duration: duration * distance, from: current)
        }
    }

    private mutating func updateTravel(now: TimeInterval) {
        guard let travel else { return }
        let progress = min(1, max(0, (now - travel.started) / travel.duration))
        if progress == 1 { current = target; self.travel = nil }
        else {
            current = .init(x: travel.from.x + (target.x - travel.from.x) * progress,
                            y: travel.from.y + (target.y - travel.from.y) * progress)
        }
    }
}
