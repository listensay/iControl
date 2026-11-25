import Foundation

/// Converts held WASD keys to one continuous touch. The most recently pressed
/// key wins on each axis, and releasing it restores the still-held opposite.
struct FPSKeyboardJoystick: Sendable {
    static let releaseDelay = 0.040
    // Separate down and drag by a display frame, including when immediate
    // keyboard/button edges call advance before the periodic timer fires.
    static let anchorInterval = 1.0 / 60.0
    private var anchorTime: TimeInterval?
    private var neutralSince: TimeInterval?
    private var current = FPSPoint(x: 0, y: 0)
    private var target = FPSPoint(x: 0, y: 0)
    private var startsNewDirection = false
    private struct Turn: Sendable {
        var started: TimeInterval
        var duration: TimeInterval
        var angle: Double
        var delta: Double
    }
    private var turn: Turn?
    private struct Reanchor: Sendable {
        var liftedAt: TimeInterval
        var centerAt: TimeInterval?
    }
    private var reanchor: Reanchor?

    mutating func releasedAllKeys() {
        // A timer may never observe the empty key set during a quick handoff.
        // Reset the logical turn without emitting a center or lifting the finger.
        startsNewDirection = true; turn = nil
    }

    mutating func point(keys: [String], now: TimeInterval, turnDuration: Double,
                        recenterOnAxisRelease: Bool) -> FPSPoint? {
        let horizontal = keys.last { $0 == "KeyA" || $0 == "KeyD" }
        let vertical = keys.last { $0 == "KeyW" || $0 == "KeyS" }
        guard horizontal != nil || vertical != nil else {
            // A canceled reset must never put a finger back down after stop.
            if let reset = reanchor, reset.centerAt == nil {
                reanchor = nil; anchorTime = nil; neutralSince = nil
                current = .init(x: 0, y: 0); target = current; turn = nil
                startsNewDirection = false; return nil
            }
            reanchor = nil
            guard anchorTime != nil else { return nil }
            // Stop immediately, but keep this finger at the center briefly so
            // a quick key handoff doesn't lift and re-anchor the game joystick.
            current = .init(x: 0, y: 0); target = current; turn = nil
            startsNewDirection = false
            if neutralSince == nil { neutralSince = now }
            if now - neutralSince! >= Self.releaseDelay {
                anchorTime = nil; neutralSince = nil; return nil
            }
            return current
        }
        let x = horizontal == "KeyD" ? 1.0 : horizontal == "KeyA" ? -1.0 : 0
        let y = vertical == "KeyS" ? 1.0 : vertical == "KeyW" ? -1.0 : 0
        let length = hypot(x, y)
        let next = FPSPoint(x: x / length, y: y / length)
        if var reset = reanchor {
            // Read the latest held keys throughout the reset; a rapid new
            // direction must not be overwritten by the direction that began it.
            current = next; target = next; turn = nil; startsNewDirection = false
            if let centerAt = reset.centerAt {
                guard now - centerAt >= Self.anchorInterval else { return .init(x: 0, y: 0) }
                reanchor = nil; return current
            }
            guard now - reset.liftedAt >= Self.anchorInterval else { return nil }
            reset.centerAt = now; reanchor = reset; anchorTime = now; neutralSince = nil
            return .init(x: 0, y: 0)
        }
        if anchorTime == nil {
            anchorTime = now; neutralSince = nil; target = next; current = next; turn = nil
            startsNewDirection = false
            return .init(x: 0, y: 0)
        }
        // Down must reach the game at the center before the first drag.
        guard now - anchorTime! >= Self.anchorInterval else {
            // Keys may change while the center is held. Start the first drag
            // in the current direction, rather than interpolating an old one.
            target = next; current = next; turn = nil
            return .init(x: 0, y: 0)
        }
        if neutralSince != nil || startsNewDirection {
            neutralSince = nil; target = next; current = next; turn = nil
            startsNewDirection = false
        } else {
            updateTurn(now: now)
            if next != target {
                let reversesAxis = target.x * next.x < 0 || target.y * next.y < 0
                let releasesAxis = (target.x != 0 && next.x == 0) || (target.y != 0 && next.y == 0)
                target = next
                if releasesAxis && recenterOnAxisRelease && !reversesAxis {
                    // A coordinate snap cannot clear a floating joystick's
                    // shifted origin. Lift only movement, then center down and
                    // drag on separate frames. Other fingers remain owned.
                    current = next; turn = nil; anchorTime = nil; neutralSince = nil
                    reanchor = Reanchor(liftedAt: now); return nil
                }
                let dot = current.x * next.x + current.y * next.y
                if turnDuration == 0 || dot < -0.999999 || reversesAxis || releasesAxis {
                    // An opposing key reverses its axis immediately, including
                    // when a diagonal's other axis was released between ticks.
                    // Releasing one diagonal axis also snaps to the held axis;
                    // a straight direction must have no residual side motion.
                    current = next; turn = nil
                } else {
                    let angle = atan2(current.y, current.x)
                    let difference = atan2(next.y, next.x) - angle
                    turn = Turn(started: now, duration: turnDuration, angle: angle,
                                delta: atan2(sin(difference), cos(difference)))
                }
            }
        }
        return current
    }

    private mutating func updateTurn(now: TimeInterval) {
        guard let turn else { return }
        let progress = min(1, max(0, (now - turn.started) / turn.duration))
        if progress == 1 { current = target; self.turn = nil }
        else {
            let angle = turn.angle + turn.delta * progress
            current = .init(x: cos(angle), y: sin(angle))
        }
    }
}
