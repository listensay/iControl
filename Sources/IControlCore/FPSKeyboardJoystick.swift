import Foundation

/// One touch steers the wheel for as long as a movement key is held. All eight
/// targets stay within the displayed circle so diagonals cannot shift a
/// floating joystick's origin by exceeding its configured travel radius.
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

    mutating func holdPosition() {
        // Coalescing releases freezes the last output, including unfinished
        // travel. A later direction starts here without advancing the old path.
        target = current; travel = nil
    }

    mutating func point(keys: [String], now: TimeInterval, turnDuration: Double) -> FPSPoint? {
        let horizontal = keys.last { $0 == "KeyA" || $0 == "KeyD" }
        let vertical = keys.last { $0 == "KeyW" || $0 == "KeyS" }
        guard horizontal != nil || vertical != nil else {
            // Stop without a return-to-center animation or a delayed lift.
            // A new press after this up edge starts a fresh center down.
            self = Self(); return nil
        }
        let x = horizontal == "KeyD" ? 1.0 : horizontal == "KeyA" ? -1.0 : 0
        let y = vertical == "KeyS" ? 1.0 : vertical == "KeyW" ? -1.0 : 0
        let length = hypot(x, y)
        let next = FPSPoint(x: x / length, y: y / length)
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
                // Once coalesced releases are applied, clear a released axis.
                // Interpolating its old offset would keep steering sideways.
                // Correct only that axis; keep the touch and remaining travel.
                if next.x == 0 { current.x = 0 }
                if next.y == 0 { current.y = 0 }
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
