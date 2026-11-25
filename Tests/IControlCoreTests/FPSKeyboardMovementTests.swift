import Foundation
import TestSupport
@testable import IControlCore

final class FPSKeyboardMovementTests {
    private func direction(_ engine: FPSInputEngine, profile: FPSProfile, aspect: Double = 4.0 / 3.0) throws -> FPSPoint {
        var mapped = try XCTUnwrap(engine.state.contacts.first { $0.id == 1 }?.point)
        let mapping = profile.touchMapping
        if mapping.mirrorX { mapped.x = 1 - mapped.x }
        if mapping.mirrorY { mapped.y = 1 - mapped.y }
        var point: FPSPoint
        switch mapping.rotation {
        case 1: point = .init(x: 1 - mapped.y, y: mapped.x)
        case 2: point = .init(x: 1 - mapped.x, y: 1 - mapped.y)
        case 3: point = .init(x: mapped.y, y: 1 - mapped.x)
        default: point = mapped
        }
        point.x -= mapping.offsetX; point.y -= mapping.offsetY
        return .init(x: (point.x - profile.joystick.x) * aspect / profile.joystickRadius,
                     y: (point.y - profile.joystick.y) / profile.joystickRadius)
    }
    private func near(_ value: Double, _ expected: Double, tolerance: Double = 0.00001) {
        XCTAssertLessThan(abs(value - expected), tolerance)
    }
    private func near(_ point: FPSPoint, _ expected: FPSPoint) {
        near(point.x, expected.x); near(point.y, expected.y)
    }

    func testCenterDownSurvivesRapidEdgesAndInitialTravelIsSmooth() throws {
        let profile = FPSProfile()
        var engine = try FPSInputEngine(profile: profile); _ = engine.start()
        _ = engine.keyDown("KeyW", now: 1)
        _ = engine.keyDown("KeyA", now: 1.001)
        _ = engine.keyDown("MouseLeft", now: 1.002)
        _ = engine.advance(now: 1.008)
        XCTAssertEqual(engine.state.contacts.first { $0.id == 1 }?.point, profile.joystick)
        _ = engine.advance(now: 1.025)
        let first = try direction(engine, profile: profile)
        near(first, .init(x: -1.0 / 3, y: -1.0 / 3))
        _ = engine.advance(now: 1.05)
        near(try direction(engine, profile: profile), .init(x: -1, y: -1))
        XCTAssertTrue(engine.state.contacts.contains { $0.id == FPSAction.fire.touchID })
        XCTAssertTrue(engine.advance(now: 1.06).isEmpty, "A settled wheel must not jitter or resend stationary positions")
    }

    func testAllDiagonalReleasesKeepOneNativeTouchAndOtherFingers() throws {
        let axes = [("KeyW", "KeyA", -1.0, -1.0), ("KeyW", "KeyD", -1.0, 1.0),
                    ("KeyS", "KeyA", 1.0, -1.0), ("KeyS", "KeyD", 1.0, 1.0)]
        let daemon = try NativeFPSFixture(interfaceOrientation: 3), socket = try daemon.connect()
        defer { socket.close(); daemon.stop() }
        var sequence: UInt32 = 0
        func send(_ frames: [FPSState]) throws {
            for frame in frames { sequence += 1; _ = try daemon.send(frame, sequence: sequence, socket: socket) }
        }
        for duration in [0.0, 0.025, 0.060] {
            for (vertical, horizontal, y, x) in axes {
                for releaseHorizontal in [true, false] {
                    var profile = FPSProfile(); profile.keyboardTurnDuration = duration
                    profile.touchMapping.rotation = 1
                    profile.touchMapping.offsetX = 0.015; profile.touchMapping.offsetY = -0.01
                    let aspect = 1.5, firstFrame = daemon.frames.count
                    var engine = try FPSInputEngine(profile: profile); engine.setAspect(aspect); _ = engine.start()
                    try send(engine.keyDown(vertical, now: 0))
                    try send(engine.advance(now: 0.1))
                    try send(engine.keyDown(horizontal, now: 0.2))
                    try send(engine.advance(now: 0.3))
                    near(try direction(engine, profile: profile, aspect: aspect), .init(x: x, y: y))
                    try send(engine.keyDown("MouseLeft", now: 1))
                    try send(engine.keyDown("MouseRight", now: 1))
                    engine.mouseMoved(dx: 3, dy: 2, now: 1); try send(engine.advance(now: 1))
                    let fire = try XCTUnwrap(engine.state.contacts.first { $0.id == FPSAction.fire.touchID })
                    let aim = try XCTUnwrap(engine.state.contacts.first { $0.id == FPSAction.aim.touchID })
                    try send(engine.keyUp(releaseHorizontal ? horizontal : vertical, now: 1.001))
                    if duration > 0 {
                        near(try direction(engine, profile: profile, aspect: aspect), .init(x: x, y: y))
                    }
                    var intermediate = false
                    for tick in 1...24 {
                        let now = 1.001 + Double(tick) / 120
                        engine.mouseMoved(dx: 0.2, dy: 0, now: now)
                        try send(engine.advance(now: now))
                        let vector = try direction(engine, profile: profile, aspect: aspect)
                        let releasedValue = releaseHorizontal ? abs(vector.x) : abs(vector.y)
                        if releasedValue > 0.00001 && releasedValue < 0.99999 { intermediate = true }
                        // The still-held axis keeps its full offset throughout.
                        if releaseHorizontal { near(vector.y, y) } else { near(vector.x, x) }
                        XCTAssertTrue((0...1.00001).contains(releasedValue))
                        XCTAssertEqual(engine.state.contacts.first { $0.id == fire.id }, fire)
                        XCTAssertEqual(engine.state.contacts.first { $0.id == aim.id }, aim)
                        XCTAssertTrue(engine.state.contacts.contains { $0.id == 2 })
                    }
                    XCTAssertEqual(intermediate, duration > 0)
                    let expected = FPSPoint(x: releaseHorizontal ? 0 : x, y: releaseHorizontal ? y : 0)
                    near(try direction(engine, profile: profile, aspect: aspect), expected)
                    let native = try XCTUnwrap(daemon.frames.reversed().compactMap { $0.edges[1] }.first)
                    let visible = FPSPoint(x: profile.joystick.x + expected.x * profile.joystickRadius / aspect,
                                           y: profile.joystick.y + expected.y * profile.joystickRadius)
                    // Profile compensation and device landscape rotation cancel.
                    near(native.x, visible.x + profile.touchMapping.offsetX, tolerance: 0.00003)
                    near(native.y, visible.y + profile.touchMapping.offsetY, tolerance: 0.00003)
                    let activeFrames = Array(daemon.frames.dropFirst(firstFrame))
                    XCTAssertTrue(activeFrames.allSatisfy { $0.ids.contains(1) }, "Changing direction cannot interrupt movement")
                    let edges = activeFrames.compactMap { $0.edges[1] }
                    XCTAssertEqual(edges.filter { $0.kind == "down" }.count, 1)
                    XCTAssertFalse(edges.contains { $0.kind == "up" })
                    XCTAssertTrue(edges.dropFirst().allSatisfy { $0.kind == "move" })
                    try send([engine.releaseAll()])
                    XCTAssertEqual(daemon.frames.last?.edges[1]?.kind, "up")
                    XCTAssertEqual(daemon.frames.last?.active, 0)
                }
            }
        }
    }

    func testIndependentAxesAndLinearTravelAcrossTickRates() throws {
        for rate in [60.0, 120.0, 240.0] {
            var profile = FPSProfile(); profile.keyboardTurnDuration = 0.060
            var engine = try FPSInputEngine(profile: profile); _ = engine.start()
            _ = engine.keyDown("KeyW", now: 0); _ = engine.advance(now: 0.1)
            _ = engine.keyDown("KeyD", now: 0.2)
            for tick in 1...Int(rate * 0.1) {
                let elapsed = Double(tick) / rate
                _ = engine.advance(now: 0.2 + elapsed)
                let vector = try direction(engine, profile: profile)
                near(vector.y, -1, tolerance: 0.00001)
                near(vector.x, min(1, elapsed / 0.060))
            }
            _ = engine.keyUp("KeyD", now: 0.4)
            for tick in 1...Int(rate * 0.1) {
                let elapsed = Double(tick) / rate
                _ = engine.advance(now: 0.4 + elapsed)
                near(try direction(engine, profile: profile), .init(x: max(0, 1 - elapsed / 0.060), y: -1))
            }
        }
    }

    func testRapidRetargetReplacesOldTravelWithoutSnapOrBacklog() throws {
        var profile = FPSProfile(); profile.keyboardTurnDuration = 0.060
        var engine = try FPSInputEngine(profile: profile); _ = engine.start()
        _ = engine.keyDown("KeyW", now: 0); _ = engine.advance(now: 0.1)
        _ = engine.keyDown("KeyA", now: 0.2); _ = engine.advance(now: 0.218)
        near(try direction(engine, profile: profile), .init(x: -0.3, y: -1))
        _ = engine.keyUp("KeyA", now: 0.218)
        near(try direction(engine, profile: profile), .init(x: -0.3, y: -1))
        _ = engine.keyDown("KeyD", now: 0.218)
        near(try direction(engine, profile: profile), .init(x: -0.3, y: -1))
        _ = engine.advance(now: 0.248)
        near(try direction(engine, profile: profile), .init(x: 0.2, y: -1))
        _ = engine.keyDown("KeyA", now: 0.248)
        for tick in 1...12 {
            _ = engine.advance(now: 0.248 + Double(tick) / 120)
            let vector = try direction(engine, profile: profile)
            near(vector.y, -1); XCTAssertTrue(vector.x <= 0.2 + 0.00001 && vector.x >= -1.00001)
        }
        near(try direction(engine, profile: profile), .init(x: -1, y: -1))
        _ = engine.advance(now: 5)
        near(try direction(engine, profile: profile), .init(x: -1, y: -1))
    }

    func testReversalsTravelStraightAtBoundedSpeed() throws {
        var profile = FPSProfile(); profile.keyboardTurnDuration = 0.025
        var engine = try FPSInputEngine(profile: profile); _ = engine.start()
        _ = engine.keyDown("KeyA", now: 0); _ = engine.advance(now: 0.1)
        _ = engine.keyDown("KeyD", now: 0.2)
        near(try direction(engine, profile: profile), .init(x: -1, y: 0))
        for elapsed in [0.008, 0.025, 0.04, 0.05, 0.08] {
            _ = engine.advance(now: 0.2 + elapsed)
            near(try direction(engine, profile: profile), .init(x: min(1, -1 + elapsed / 0.025), y: 0))
        }
        XCTAssertTrue(engine.advance(now: 0.4).isEmpty)
    }

    func testStopDuringAnchorOrTravelAndCaptureReleaseCannotResume() throws {
        let daemon = try NativeFPSFixture(), socket = try daemon.connect()
        defer { socket.close(); daemon.stop() }
        var sequence: UInt32 = 0
        for stopAt in [0.005, 0.025, 0.1] {
            let profile = FPSProfile()
            var engine = try FPSInputEngine(profile: profile); _ = engine.start()
            func send(_ frames: [FPSState]) throws {
                for frame in frames { sequence += 1; _ = try daemon.send(frame, sequence: sequence, socket: socket) }
            }
            try send(engine.keyDown("KeyW", now: 0))
            try send(engine.keyDown("MouseLeft", now: 0))
            try send(engine.advance(now: stopAt))
            try send(engine.keyUp("KeyW", now: stopAt))
            try send(engine.advance(now: stopAt + 1.0 / 120))
            XCTAssertEqual(engine.state.contacts.map(\.id), [FPSAction.fire.touchID])
            XCTAssertEqual(daemon.frames.last?.edges[1]?.kind, "up", "Stop on the first tick, without center dwell or delayed lift")
            let count = daemon.frames.count
            for tick in 2...24 { try send(engine.advance(now: stopAt + Double(tick) / 120)) }
            XCTAssertEqual(daemon.frames.count, count, "Stopping cancels the entire trajectory")
            try send(engine.keyDown("KeyS", now: 1))
            XCTAssertEqual(engine.state.contacts.first { $0.id == 1 }?.point, profile.joystick)
            XCTAssertEqual(daemon.frames.last?.edges[1]?.kind, "down")
            try send([engine.releaseAll()])
            XCTAssertEqual(daemon.frames.last?.active, 0)
            XCTAssertTrue(engine.advance(now: 1.1).isEmpty)
        }
    }

    func testLegacyRecenterProfilesKeepLayoutAndUseContinuousWheel() throws {
        var profile = FPSProfile(); profile.name = "Saved game layout"
        profile.joystick = .init(x: 0.24, y: 0.79); profile.joystickRadius = 0.093
        profile.keyLinks = [.init(source: "KeyB", target: "KeyR")]
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as? [String: Any])
        for legacyValue in [true, false] {
            json["keyboardRecenterOnAxisRelease"] = legacyValue
            let migrated = try JSONDecoder().decode(FPSProfile.self, from: JSONSerialization.data(withJSONObject: json))
            XCTAssertEqual(migrated, profile, "Migration must preserve all geometry, bindings, links and timing")
            let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(migrated)) as? [String: Any])
            XCTAssertTrue(encoded["keyboardRecenterOnAxisRelease"] == nil, "The obsolete reset option must not return on save")
            let frames = try FPSInputPreview.movement(profile: migrated, aspect: 4.0 / 3.0)
            XCTAssertTrue(frames.dropLast(9).allSatisfy { $0.contacts.contains { $0.id == 1 } })
        }
        json.removeValue(forKey: "keyboardTurnDuration")
        let migrated = try JSONDecoder().decode(FPSProfile.self, from: JSONSerialization.data(withJSONObject: json))
        near(migrated.keyboardTurnDuration, 0.025)
        profile.keyboardTurnDuration = 0.081; XCTAssertThrowsError(try profile.validate())
        profile.keyboardTurnDuration = .nan; XCTAssertThrowsError(try profile.validate())
    }

    func testOppositeKeysPreferLatestAndRestoreHeldDirection() throws {
        var profile = FPSProfile(); profile.keyboardTurnDuration = 0
        for (first, opposite) in [("KeyA", "KeyD"), ("KeyD", "KeyA"), ("KeyW", "KeyS"), ("KeyS", "KeyW")] {
            var engine = try FPSInputEngine(profile: profile); _ = engine.start()
            _ = engine.keyDown(first, now: 0); _ = engine.advance(now: 0.017)
            let initial = try direction(engine, profile: profile)
            _ = engine.keyDown(opposite, now: 0.02)
            near(try direction(engine, profile: profile), .init(x: -initial.x, y: -initial.y))
            XCTAssertTrue(engine.keyDown(first, now: 0.03).isEmpty, "Repeat cannot steal direction priority")
            _ = engine.keyUp(opposite, now: 0.04)
            near(try direction(engine, profile: profile), initial)
            XCTAssertEqual(engine.state.contacts.map(\.id), [1])
        }
    }

    func testMovementPreviewReachesNativeDaemonWithOneFingerLifecycle() throws {
        var profile = FPSProfile(); profile.touchMapping.rotation = 1
        let frames = try FPSInputPreview.movement(profile: profile, aspect: 4.0 / 3.0)
        let daemon = try NativeFPSFixture(interfaceOrientation: 3), socket = try daemon.connect()
        defer { socket.close(); daemon.stop() }
        for (index, frame) in frames.enumerated() {
            _ = try daemon.send(frame, sequence: UInt32(index + 1), socket: socket)
        }
        let edges = daemon.frames.compactMap { $0.edges[1] }
        XCTAssertEqual(edges.filter { $0.kind == "down" }.count, 1)
        XCTAssertEqual(edges.filter { $0.kind == "up" }.count, 1)
        XCTAssertTrue(edges.filter { $0.kind == "move" }.count > 8)
        XCTAssertEqual(daemon.frames.last?.active, 0)
        let targets: [FPSPoint] = [.init(x: 0, y: -1), .init(x: 1, y: -1), .init(x: 1, y: 0), .init(x: 1, y: 1),
                                   .init(x: 0, y: 1), .init(x: -1, y: 1), .init(x: -1, y: 0), .init(x: -1, y: -1)]
        for (index, expected) in targets.enumerated() {
            let visible = FPSPoint(x: profile.joystick.x + expected.x * profile.joystickRadius / (4.0 / 3.0),
                                   y: profile.joystick.y + expected.y * profile.joystickRadius)
            XCTAssertEqual(frames[index * 9 + 8].contacts.first?.point, profile.touchMapping.apply(visible))
        }
        profile.joystickEnabled = false
        XCTAssertThrowsError(try FPSInputPreview.movement(profile: profile, aspect: 4.0 / 3.0))
    }

    func testAllUpHandoffWithinTickRetargetsWithoutCenterOrLift() throws {
        for duration in [0.0, 0.025, 0.060] {
            var profile = FPSProfile(); profile.keyboardTurnDuration = duration
            var engine = try FPSInputEngine(profile: profile); _ = engine.start()
            _ = engine.keyDown("KeyA", now: 0); _ = engine.advance(now: 5)
            _ = engine.keyDown("MouseLeft", now: 5)
            XCTAssertTrue(engine.keyUp("KeyA", now: 5.001).isEmpty)
            let frames = engine.keyDown("KeyD", now: 5.003)
            XCTAssertFalse(frames.contains { $0.contacts.first { $0.id == 1 }?.point == profile.joystick })
            near(try direction(engine, profile: profile), .init(x: duration == 0 ? 1 : -1, y: 0))
            _ = engine.advance(now: 5.2)
            near(try direction(engine, profile: profile), .init(x: 1, y: 0))
            _ = engine.keyUp("KeyD", now: 5.21); _ = engine.advance(now: 5.218)
            XCTAssertEqual(engine.state.contacts.map(\.id), [FPSAction.fire.touchID])
            _ = engine.keyDown("KeyW", now: 5.22)
            XCTAssertEqual(engine.state.contacts.first { $0.id == 1 }?.point, profile.joystick)
        }
    }

    func testReleaseDuringPartialDiagonalTravelReturnsWithoutOvershoot() throws {
        var profile = FPSProfile(); profile.keyboardTurnDuration = 0.060
        var engine = try FPSInputEngine(profile: profile); _ = engine.start()
        _ = engine.keyDown("KeyW", now: 0); _ = engine.advance(now: 0.1)
        _ = engine.keyDown("KeyD", now: 0.2); _ = engine.advance(now: 0.212)
        near(try direction(engine, profile: profile), .init(x: 0.2, y: -1))
        _ = engine.keyUp("KeyD", now: 0.212)
        _ = engine.advance(now: 0.218)
        near(try direction(engine, profile: profile), .init(x: 0.1, y: -1))
        _ = engine.advance(now: 0.225)
        near(try direction(engine, profile: profile), .init(x: 0, y: -1))
        XCTAssertTrue(engine.advance(now: 0.3).isEmpty)
    }

    func testLegacyMouseJoystickCannotConsumeLookAndSettingsPersist() throws {
        var profile = FPSProfile(); profile.keyboardTurnDuration = 0.040
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as? [String: Any])
        json["analogJoystick"] = true; json["analogTrigger"] = "Option"; json["analogTravel"] = 100
        let migrated = try JSONDecoder().decode(FPSProfile.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(migrated, profile)
        var engine = try FPSInputEngine(profile: migrated); _ = engine.start()
        _ = engine.keyDown("KeyW", now: 0); _ = engine.keyDown("Option", now: 0.01)
        engine.mouseMoved(dx: 5, dy: 2, now: 0.02); _ = engine.advance(now: 0.02); _ = engine.advance(now: 0.06)
        XCTAssertEqual(Set(engine.state.contacts.map(\.id)), [1, 2])
        let look = try XCTUnwrap(engine.state.contacts.first { $0.id == 2 }?.point)
        XCTAssertTrue(look.x > migrated.look.x); XCTAssertTrue(look.y > migrated.look.y)
        near(try direction(engine, profile: migrated), .init(x: 0, y: -1))
        XCTAssertEqual(try JSONDecoder().decode(FPSProfile.self, from: JSONEncoder().encode(profile)), profile)
    }
}
