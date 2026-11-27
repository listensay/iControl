import CRustInput

// The indices below are internal capture codes, not device HID usage IDs.
// Rust reserves 0...3 for WASD and 4...8 for the five mouse buttons.
enum FPSRustProfile {
    private static let codes: [String: UInt16] = {
        let mouse = ["MouseLeft", "MouseRight", "MouseMiddle", "MouseBack", "MouseForward"]
        let keys = ["KeyW", "KeyA", "KeyS", "KeyD"] + mouse + FPSKey.choices.filter { !mouse.contains($0) }
        return Dictionary(uniqueKeysWithValues: keys.enumerated().map { ($0.element, UInt16($0.offset)) })
    }()
    static func key(_ code: String) -> UInt16? { codes[code] }

    // Profile validation and graph expansion happen once, not at input frequency.
    static func withConfig<T>(_ p: FPSProfile, aspect: Double, _ body: (UnsafePointer<ICProfile>, UnsafeBufferPointer<ICButton>, UnsafeBufferPointer<ICLinkKey>) -> T) throws -> T {
        try p.validate()
        let map = p.touchMapping
        func bit(_ v: Bool) -> UInt8 { v ? 1 : 0 }
        var config = ICProfile(joystick: p.joystick.raw, look: p.look.raw, offset: ICPoint(x: map.offsetX, y: map.offsetY),
            aspect: aspect, radius: p.joystickRadius, turn_duration: p.keyboardTurnDuration, look_width: p.lookWidth,
            look_height: p.lookHeight, sensitivity: p.sensitivity, joystick_enabled: bit(p.joystickEnabled),
            smooth: bit(p.smoothKeyboardSteering), look_enabled: bit(p.lookEnabled), swap_axes: bit(p.swapMouseAxes),
            invert_x: bit(p.invertX), invert_y: bit(p.invertY), mapping: UInt8(map.rotation) | (bit(map.mirrorX) << 2) | (bit(map.mirrorY) << 3),
            orientation: UInt8(p.orientation.rawValue))
        let buttons: [ICButton] = try p.buttons.filter(\.enabled).map { b in
            guard let trigger = key(b.trigger) else { throw ControlError("不支持的 FPS 按键：\(b.trigger)") }
            return ICButton(point: b.point.raw, end: b.swipe.end.raw, duration: b.swipe.duration,
                            trigger: trigger, behavior: b.behavior == .hold ? 0 : b.behavior == .tap ? 1 : 2,
                            preferred: b.preferredTouchID ?? 0)
        }
        let links = FPSKey.linkSources.flatMap { source -> [ICLinkKey] in
            guard let from = key(source) else { return [] }
            // Cursor toggles have an AppKit side effect. The native capture adapter
            // publishes that mode edge separately; don't toggle it twice in Rust.
            return p.linkedKeys(from: source).dropFirst().compactMap { name in
                key(name).map { ICLinkKey(source: from, target: $0) }
            }
        }
        return buttons.withUnsafeBufferPointer { b in links.withUnsafeBufferPointer { l in body(&config, b, l) } }
    }
}

extension FPSPoint {
    var raw: ICPoint { ICPoint(x: x, y: y) }
}
