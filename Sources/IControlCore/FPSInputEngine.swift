import Foundation

public struct FPSContact: Equatable, Sendable {
    public var id: UInt8
    public var point: FPSPoint
    public init(id: UInt8, point: FPSPoint) { self.id = id; self.point = point }
}

public struct FPSState: Equatable, Sendable {
    public var contacts: [FPSContact]
    public var orientation: FPSOrientation
    public init(contacts: [FPSContact] = [], orientation: FPSOrientation = .automatic) {
        self.contacts = contacts; self.orientation = orientation
    }
}

/// Produces complete contact sets. Removing one finger never ends other fingers.
/// IDs 1 and 2 are reserved for movement and mouse look. Buttons keep a leased
/// ID until released; this supports custom buttons on existing v1 daemons.
public struct FPSInputEngine: Sendable {
    public let profile: FPSProfile
    public private(set) var captured = false
    public private(set) var cursorMode = false
    public private(set) var state = FPSState()
    public private(set) var pressed = Set<String>()
    private var physicalKeys = Set<String>()
    private var keySources: [String: Set<String>] = [:]
    private let buttons: [FPSButton]
    private var taps: [String: TimeInterval] = [:]
    private struct SwipeRun: Sendable { var start: TimeInterval?; var liftedAfter: TimeInterval? }
    private var swipes: [String: SwipeRun] = [:]
    private var buttonIdentifiers: [String: UInt8] = [:]
    private var aspect = 4.0 / 3.0
    private var pendingX = 0.0, pendingY = 0.0
    private var lookPosition: FPSPoint?
    private var pointerPosition: FPSPoint?
    private var lastMouse: TimeInterval = 0
    private var movementKeys: [String] = []
    private var keyboardJoystick = FPSKeyboardJoystick()

    public init(profile: FPSProfile) throws { try profile.validate(); self.profile = profile; buttons = profile.buttons }
    public mutating func setAspect(_ value: Double) {
        if value.isFinite, (0.4...3.0).contains(value) { aspect = value }
    }
    public mutating func start() -> FPSState {
        _ = releaseAll(); captured = true; return state
    }
    @discardableResult
    public mutating func releaseAll() -> FPSState {
        captured = false; cursorMode = false; pointerPosition = nil
        pressed.removeAll(); taps.removeAll(); swipes.removeAll(); pendingX = 0; pendingY = 0
        physicalKeys.removeAll(); keySources.removeAll()
        lookPosition = nil; movementKeys.removeAll(); keyboardJoystick = FPSKeyboardJoystick()
        buttonIdentifiers.removeAll()
        state = FPSState(orientation: profile.orientation); return state
    }

    public mutating func keyDown(_ code: String, now: TimeInterval) -> [FPSState] {
        guard captured, !(cursorMode && code.hasPrefix("Mouse")),
              (FPSKey.movement.contains(code) || FPSKey.choices.contains(code)),
              physicalKeys.insert(code).inserted else { return [] }
        let linked = profile.linkedKeys(from: code)
        var activated = Set<String>()
        for key in linked where key != FPSKey.cursorAction {
            keySources[key, default: []].insert(code)
            if pressed.insert(key).inserted { activated.insert(key) }
        }
        if FPSKey.movement.contains(code), activated.contains(code) { movementKeys.append(code) }
        let bindings = buttons.filter { $0.enabled && activated.contains($0.trigger) && $0.behavior == .tap }
        var frames: [FPSState] = []
        if linked.contains(FPSKey.cursorAction) { frames += setCursorMode(!cursorMode, now: now) }
        if bindings.contains(where: { taps[$0.id] != nil }) {
            for binding in bindings { taps[binding.id] = nil }
            frames += advance(now: now)
        }
        for binding in bindings {
            taps[binding.id] = now + 0.070
        }
        for binding in buttons where binding.enabled && activated.contains(binding.trigger) && binding.behavior == .swipe {
            // A repeated press starts a new finger after an explicit lift.
            if swipes.removeValue(forKey: binding.id) != nil { frames += advance(now: now) }
            swipes[binding.id] = SwipeRun()
        }
        frames += advance(now: now); return frames
    }
    public mutating func keyUp(_ code: String, now: TimeInterval) -> [FPSState] {
        guard captured, physicalKeys.remove(code) != nil else { return [] }
        var released = Set<String>()
        for key in profile.linkedKeys(from: code) {
            guard var sources = keySources[key] else { continue }
            sources.remove(code)
            if sources.isEmpty {
                keySources[key] = nil; pressed.remove(key); released.insert(key)
            } else { keySources[key] = sources }
        }
        guard !released.isEmpty else { return [] }
        if released.contains(where: { FPSKey.movement.contains($0) }) {
            movementKeys.removeAll { released.contains($0) }
            if movementKeys.isEmpty { keyboardJoystick.releasedAllKeys() }
        }
        // Coalesce a release and the next direction within one input tick.
        // This prevents a center snapshot between a quick A -> D handoff.
        if released.isSubset(of: FPSKey.movement) { return [] }
        return advance(now: now)
    }
    public mutating func setCursorMode(_ enabled: Bool, now: TimeInterval) -> [FPSState] {
        guard captured, enabled != cursorMode else { return [] }
        cursorMode = enabled; pointerPosition = nil; lookPosition = nil
        pendingX = 0; pendingY = 0
        pressed = pressed.filter { !$0.hasPrefix("Mouse") }
        physicalKeys = physicalKeys.filter { !$0.hasPrefix("Mouse") }
        keySources = keySources.filter { !$0.key.hasPrefix("Mouse") }
        let mouseButtons = Set(buttons.filter { $0.trigger.hasPrefix("Mouse") }.map(\.id))
        taps = taps.filter { !mouseButtons.contains($0.key) }
        swipes = swipes.filter { !mouseButtons.contains($0.key) }
        // ID 2 is explicitly lifted before it can become a cursor click.
        return advance(now: now)
    }
    public mutating func pointerDown(at point: FPSPoint, now: TimeInterval) -> [FPSState] {
        guard captured, cursorMode, point.isValid, pointerPosition == nil else { return [] }
        pointerPosition = point; return advance(now: now)
    }
    public mutating func pointerMoved(to point: FPSPoint) {
        guard captured, cursorMode, pointerPosition != nil, point.isValid else { return }
        pointerPosition = point
    }
    public mutating func pointerUp(now: TimeInterval) -> [FPSState] {
        guard captured, cursorMode, pointerPosition != nil else { return [] }
        var frames = advance(now: now)
        pointerPosition = nil; frames += advance(now: now); return frames
    }
    public mutating func pulse(_ action: FPSAction, now: TimeInterval) -> [FPSState] {
        pulse(button: action.id, now: now)
    }
    public mutating func pulse(button id: String, now: TimeInterval) -> [FPSState] {
        guard captured, let button = buttons.first(where: { $0.id == id && $0.enabled }) else { return [] }
        var frames: [FPSState] = []
        if button.behavior == .swipe {
            if swipes.removeValue(forKey: id) != nil { frames += advance(now: now) }
            swipes[id] = SwipeRun(); frames += advance(now: now); return frames
        }
        if taps[id] != nil {
            taps[id] = nil; frames += advance(now: now)
        }
        taps[id] = now + 0.070; frames += advance(now: now); return frames
    }
    public mutating func mouseMoved(dx: Double, dy: Double, now: TimeInterval) {
        guard captured, !cursorMode, dx.isFinite, dy.isFinite else { return }
        let factor = 0.0012 * profile.sensitivity
        let horizontal = profile.swapMouseAxes ? dy : dx
        let vertical = profile.swapMouseAxes ? dx : dy
        pendingX = min(2, max(-2, pendingX + horizontal * factor * (profile.invertX ? -1 : 1)))
        pendingY = min(2, max(-2, pendingY + vertical * factor * aspect * (profile.invertY ? -1 : 1)))
        if dx != 0 || dy != 0 { lastMouse = now }
    }

    /// Called at 120 Hz. Mouse deltas are coalesced between ticks; button edges
    /// are sent immediately. A rebase ends only the look contact for one tick.
    public mutating func advance(now: TimeInterval) -> [FPSState] {
        guard captured else { return [] }
        taps = taps.filter { $0.value > now }
        swipes = swipes.filter { $0.value.liftedAfter.map { now < $0 } ?? true }
        var contacts: [FPSContact] = []
        if profile.joystickEnabled,
           let direction = keyboardJoystick.point(keys: movementKeys, now: now, turnDuration: profile.keyboardTurnDuration,
                                                  recenterOnAxisRelease: profile.keyboardRecenterOnAxisRelease) {
            var point = profile.joystick
            point.x += direction.x * profile.joystickRadius / aspect
            point.y += direction.y * profile.joystickRadius
            point.x = min(0.995, max(0.005, point.x)); point.y = min(0.995, max(0.005, point.y))
            contacts.append(FPSContact(id: 1, point: point))
        }

        let hasMotion = abs(pendingX) + abs(pendingY) > 0.000001
        if hasMotion {
            if let position = lookPosition {
                let stepX = min(0.10, profile.lookWidth * 0.45), stepY = min(0.10, profile.lookHeight * 0.45)
                let dx = min(stepX, max(-stepX, pendingX)), dy = min(stepY, max(-stepY, pendingY))
                let next = FPSPoint(x: position.x + dx, y: position.y + dy)
                let minX = profile.look.x - profile.lookWidth / 2, maxX = profile.look.x + profile.lookWidth / 2
                let minY = profile.look.y - profile.lookHeight / 2, maxY = profile.look.y + profile.lookHeight / 2
                if next.x < minX || next.x > maxX || next.y < minY || next.y > maxY {
                    // Re-anchor on the following tick, retaining all unconsumed motion.
                    lookPosition = nil
                } else {
                    lookPosition = next; pendingX -= dx; pendingY -= dy
                }
            } else { lookPosition = profile.look }
        } else if now - lastMouse > 0.15 { lookPosition = nil }
        if cursorMode, let pointerPosition { contacts.append(FPSContact(id: 2, point: pointerPosition)) }
        else if !cursorMode, profile.lookEnabled, let lookPosition { contacts.append(FPSContact(id: 2, point: lookPosition)) }

        let active = buttons.filter { $0.enabled && (taps[$0.id] != nil || swipes[$0.id] != nil || ($0.behavior == .hold && pressed.contains($0.trigger))) }
        // Retain held buttons before admitting new ones at the ten-finger limit.
        let admitted = Array((active.filter { buttonIdentifiers[$0.id] != nil }
                              + active.filter { buttonIdentifiers[$0.id] == nil }).prefix(FPSWire.maximumContacts - contacts.count))
        let admittedIDs = Set(admitted.map(\.id))
        let previous = buttonIdentifiers
        buttonIdentifiers = buttonIdentifiers.filter { admittedIDs.contains($0.key) }
        // Do not reuse a just-released ID in the same snapshot: the daemon needs
        // an up edge before a different button can start a new finger with it.
        var unavailable = Set(previous.values)
        for binding in admitted where buttonIdentifiers[binding.id] == nil {
            let preferred = binding.preferredTouchID.flatMap { unavailable.contains($0) ? nil : $0 }
            let identifier = preferred ?? (UInt8(3)...FPSWire.maximumIdentifier).reversed().first { !unavailable.contains($0) }
            if let identifier {
                buttonIdentifiers[binding.id] = identifier; unavailable.insert(identifier)
            }
        }
        for binding in admitted {
            if let identifier = buttonIdentifiers[binding.id] {
                var point = binding.point
                if var run = swipes[binding.id] {
                    if run.start == nil { run.start = now }
                    let progress = min(1, max(0, (now - run.start!) / binding.swipe.duration))
                    point = .init(x: binding.point.x + (binding.swipe.end.x - binding.point.x) * progress,
                                  y: binding.point.y + (binding.swipe.end.y - binding.point.y) * progress)
                    // Send the actual endpoint for at least one tick before up,
                    // including after a slow frame or a delayed admission.
                    if progress == 1, run.liftedAfter == nil { run.liftedAfter = now + 1.0 / 120.0 }
                    swipes[binding.id] = run
                }
                contacts.append(FPSContact(id: identifier, point: point))
            }
        }
        let next = profile.touchState(contacts)
        guard next != state else { return [] }
        state = next; return [next]
    }
}
