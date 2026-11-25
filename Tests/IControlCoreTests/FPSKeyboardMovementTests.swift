import Foundation
import TestSupport
@testable import IControlCore

final class FPSKeyboardMovementTests {
    private func direction(_ engine: FPSInputEngine, profile: FPSProfile, aspect: Double = 4.0 / 3.0) throws -> FPSPoint {
        let point = try XCTUnwrap(engine.state.contacts.first { $0.id == 1 }?.point)
        return .init(x: (point.x - profile.joystick.x) * aspect / profile.joystickRadius,
                     y: (point.y - profile.joystick.y) / profile.joystickRadius)
    }
    private func near(_ value: Double, _ expected: Double) {
        XCTAssertLessThan(abs(value - expected), 0.00001)
    }

    func testCenterDownSurvivesRapidButtonEdgesAndAnEarlyTimerTick() throws {
        let profile = FPSProfile()
        var engine = try FPSInputEngine(profile: profile); _ = engine.start()
        _ = engine.keyDown("KeyW", now: 1)
        _ = engine.keyDown("KeyA", now: 1.001)
        _ = engine.keyDown("MouseLeft", now: 1.002)
        _ = engine.advance(now: 1.008)
        XCTAssertEqual(engine.state.contacts.first { $0.id == 1 }?.point, profile.joystick,
                       "A button edge or early timer must not turn the center down into a diagonal drag")
        _ = engine.advance(now: 1.017)
        let vector = try direction(engine, profile: profile)
        near(vector.x, -sqrt(0.5)); near(vector.y, -sqrt(0.5))
        XCTAssertTrue(engine.state.contacts.contains { $0.id == FPSAction.fire.touchID })
    }

    func testDiagonalReleaseReanchorsOnlyMovementAtCenterBeforeStraightDrag() throws {
        let profile = FPSProfile()
        let daemon = try NativeFPSFixture(), socket = try daemon.connect()
        defer { socket.close(); daemon.stop() }
        var engine = try FPSInputEngine(profile: profile); _ = engine.start()
        var sequence: UInt32 = 0
        func send(_ frames: [FPSState]) throws {
            for frame in frames { sequence += 1; _ = try daemon.send(frame, sequence: sequence, socket: socket) }
        }
        try send(engine.keyDown("KeyW", now: 0))
        try send(engine.keyDown("KeyA", now: 0.001))
        try send(engine.advance(now: 0.02))
        try send(engine.keyDown("MouseLeft", now: 5))
        engine.mouseMoved(dx: 10, dy: 0, now: 5)
        try send(engine.advance(now: 5))
        let fire = try XCTUnwrap(engine.state.contacts.first { $0.id == FPSAction.fire.touchID })
        try send(engine.keyUp("KeyA", now: 5.001))
        try send(engine.advance(now: 5.008))
        XCTAssertFalse(engine.state.contacts.contains { $0.id == 1 }, "Reset the game's old joystick origin with a real up edge")
        XCTAssertEqual(daemon.frames.last?.edges[1]?.kind, "up")
        XCTAssertTrue(engine.state.contacts.contains { $0.id == 2 })
        XCTAssertEqual(engine.state.contacts.first { $0.id == fire.id }, fire)
        try send(engine.advance(now: 5.016))
        XCTAssertFalse(engine.state.contacts.contains { $0.id == 1 }, "Keep the up edge separate from the new down")
        // Delayed timer: the center dwell starts when down is actually emitted.
        try send(engine.advance(now: 5.05))
        XCTAssertEqual(engine.state.contacts.first { $0.id == 1 }?.point, profile.joystick)
        XCTAssertEqual(daemon.frames.last?.edges[1]?.kind, "down")
        let nativeCenter = try XCTUnwrap(daemon.frames.last?.edges[1])
        try send(engine.keyDown("MouseRight", now: 5.051))
        try send(engine.advance(now: 5.058))
        XCTAssertEqual(engine.state.contacts.first { $0.id == 1 }?.point, profile.joystick)
        try send(engine.advance(now: 5.067))
        let vector = try direction(engine, profile: profile)
        near(vector.x, 0); near(vector.y, -1)
        let nativeForward = try XCTUnwrap(daemon.frames.last?.edges[1])
        XCTAssertEqual(nativeForward.kind, "move")
        XCTAssertEqual(nativeForward.x, nativeCenter.x, "Forward must be vertical relative to the game's fresh down origin")
        XCTAssertTrue(nativeForward.y < nativeCenter.y)
        XCTAssertEqual(engine.state.contacts.first { $0.id == fire.id }, fire)
        XCTAssertFalse(daemon.frames.dropLast().contains { $0.edges[Int(fire.id)]?.kind == "up" })
        try send([engine.releaseAll()])
    }

    func testRecenterAllDiagonalAxesAndMappedNativeOrigins() throws {
        let axes: [(String, String, FPSPoint, FPSPoint)] = [
            ("KeyW", "KeyA", .init(x: 0, y: -1), .init(x: -1, y: 0)),
            ("KeyW", "KeyD", .init(x: 0, y: -1), .init(x: 1, y: 0)),
            ("KeyS", "KeyA", .init(x: 0, y: 1), .init(x: -1, y: 0)),
            ("KeyS", "KeyD", .init(x: 0, y: 1), .init(x: 1, y: 0))
        ]
        let daemon = try NativeFPSFixture(interfaceOrientation: 3), socket = try daemon.connect()
        defer { socket.close(); daemon.stop() }
        var sequence: UInt32 = 0
        for duration in [0.0, 0.025, 0.060] {
            for heldTime in [0.008, 5.0] {
                for (vertical, horizontal, verticalVector, horizontalVector) in axes {
                    for releaseHorizontal in [true, false] {
                        var profile = FPSProfile(); profile.keyboardTurnDuration = duration
                        profile.touchMapping.rotation = 1
                        profile.touchMapping.offsetX = 0.015; profile.touchMapping.offsetY = -0.01
                        let aspect = 1.5
                        var engine = try FPSInputEngine(profile: profile); engine.setAspect(aspect); _ = engine.start()
                        let initial = engine.keyDown(vertical, now: 0)
                        sequence += 1; _ = try daemon.send(try XCTUnwrap(initial.first), sequence: sequence, socket: socket)
                        _ = engine.advance(now: 0.017)
                        _ = engine.keyDown(horizontal, now: 0.1); _ = engine.advance(now: 0.1 + heldTime)
                        _ = engine.keyDown("MouseLeft", now: 0.1 + heldTime)
                        sequence += 1; _ = try daemon.send(engine.state, sequence: sequence, socket: socket)
                        let fire = try XCTUnwrap(engine.state.contacts.first { $0.id != 1 })
                        let released = releaseHorizontal ? horizontal : vertical
                        let expected = releaseHorizontal ? verticalVector : horizontalVector
                        let releaseTime = 0.101 + heldTime
                        _ = engine.keyUp(released, now: releaseTime)
                        _ = engine.advance(now: releaseTime + 0.008)
                        sequence += 1; _ = try daemon.send(engine.state, sequence: sequence, socket: socket)
                        XCTAssertEqual(daemon.frames.last?.edges[1]?.kind, "up")
                        XCTAssertEqual(engine.state.contacts.first { $0.id == fire.id }, fire)
                        _ = engine.advance(now: releaseTime + 0.025)
                        sequence += 1; _ = try daemon.send(engine.state, sequence: sequence, socket: socket)
                        let center = try XCTUnwrap(daemon.frames.last?.edges[1])
                        XCTAssertEqual(center.kind, "down")
                        for tick in 0..<6 {
                            _ = engine.advance(now: releaseTime + 0.042 + Double(tick) / 120)
                            let contact = try XCTUnwrap(engine.state.contacts.first { $0.id == 1 })
                            let visible = FPSPoint(x: profile.joystick.x + expected.x * profile.joystickRadius / aspect,
                                                   y: profile.joystick.y + expected.y * profile.joystickRadius)
                            XCTAssertEqual(contact.point, profile.touchMapping.apply(visible))
                            XCTAssertEqual(engine.state.contacts.first { $0.id == fire.id }, fire)
                        }
                        sequence += 1; _ = try daemon.send(engine.state, sequence: sequence, socket: socket)
                        let native = try XCTUnwrap(daemon.frames.last?.edges[1])
                        XCTAssertEqual(native.kind, "move")
                        // Compensation and device rotation cancel. Measure the
                        // remaining axis relative to the new native down origin.
                        if releaseHorizontal { XCTAssertEqual(native.x, center.x) }
                        else { XCTAssertEqual(native.y, center.y) }
                        sequence += 1; _ = try daemon.send(engine.releaseAll(), sequence: sequence, socket: socket)
                    }
                }
            }
        }
    }

    func testRecenterUsesLatestKeysAndCancelsWithoutPhantomDown() throws {
        let profile = FPSProfile()
        for stopAtCenter in [false, true] {
            var engine = try FPSInputEngine(profile: profile); _ = engine.start()
            _ = engine.keyDown("KeyW", now: 0); _ = engine.keyDown("KeyA", now: 0.001)
            _ = engine.advance(now: 0.02)
            _ = engine.keyUp("KeyA", now: 1); _ = engine.advance(now: 1.008)
            XCTAssertFalse(engine.state.contacts.contains { $0.id == 1 })
            if stopAtCenter {
                _ = engine.advance(now: 1.025)
                XCTAssertEqual(engine.state.contacts.first?.point, profile.joystick)
            }
            _ = engine.keyUp("KeyW", now: stopAtCenter ? 1.026 : 1.009)
            for tick in 1...24 { _ = engine.advance(now: 1.026 + Double(tick) / 120) }
            XCTAssertTrue(engine.state.contacts.isEmpty, "Stopped keys cannot resume a pending direction")
            _ = engine.keyDown("KeyS", now: 2); _ = engine.advance(now: 2.017)
            near(try direction(engine, profile: profile).y, 1)
        }
        var engine = try FPSInputEngine(profile: profile); _ = engine.start()
        _ = engine.keyDown("KeyW", now: 0); _ = engine.keyDown("KeyA", now: 0.001)
        _ = engine.advance(now: 0.02)
        _ = engine.keyUp("KeyA", now: 1); _ = engine.advance(now: 1.008)
        _ = engine.keyDown("KeyD", now: 1.009)
        _ = engine.keyUp("KeyW", now: 1.01)
        _ = engine.advance(now: 1.025); _ = engine.advance(now: 1.042)
        let latest = try direction(engine, profile: profile)
        near(latest.x, 1); near(latest.y, 0)
        _ = engine.keyDown("KeyW", now: 2); _ = engine.advance(now: 2.1)
        _ = engine.keyUp("KeyD", now: 2.101); _ = engine.advance(now: 2.109)
        XCTAssertTrue(engine.releaseAll().contacts.isEmpty)
        XCTAssertTrue(engine.advance(now: 2.2).isEmpty, "Capture release cancels pending down immediately")
    }

    func testRecenterDefaultMigrationPersistenceAndNativePreview() throws {
        var profile = FPSProfile()
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as? [String: Any])
        json.removeValue(forKey: "keyboardRecenterOnAxisRelease")
        let migrated = try JSONDecoder().decode(FPSProfile.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertTrue(migrated.keyboardRecenterOnAxisRelease, "Existing saved layouts must get the correction")
        profile.keyboardRecenterOnAxisRelease = false
        XCTAssertFalse(try JSONDecoder().decode(FPSProfile.self, from: JSONEncoder().encode(profile)).keyboardRecenterOnAxisRelease)
        let daemon = try NativeFPSFixture(), socket = try daemon.connect()
        defer { socket.close(); daemon.stop() }
        let frames = try FPSInputPreview.movement(profile: migrated, aspect: 4.0 / 3.0)
        for (index, frame) in frames.enumerated() { _ = try daemon.send(frame, sequence: UInt32(index + 1), socket: socket) }
        let edges = daemon.frames.compactMap { $0.edges[1] }
        XCTAssertEqual(edges.filter { $0.kind == "down" }.count, 5, "Initial down plus four diagonal-to-axis corrections")
        XCTAssertEqual(edges.filter { $0.kind == "up" }.count, 5)
        for down in edges where down.kind == "down" {
            XCTAssertLessThan(abs(down.x - profile.joystick.x), 0.00003)
            XCTAssertLessThan(abs(down.y - profile.joystick.y), 0.00003)
        }
        XCTAssertEqual(daemon.frames.last?.active, 0)
    }

    func testOppositeKeysPreferLatestAndRestoreHeldDirection() throws {
        var profile = FPSProfile(); profile.keyboardTurnDuration = 0
        for (first, opposite) in [("KeyA", "KeyD"), ("KeyD", "KeyA"), ("KeyW", "KeyS"), ("KeyS", "KeyW")] {
            var engine = try FPSInputEngine(profile: profile); _ = engine.start()
            _ = engine.keyDown(first, now: 0); _ = engine.advance(now: 0.017)
            let initial = try direction(engine, profile: profile)
            _ = engine.keyDown(opposite, now: 0.02)
            let reversed = try direction(engine, profile: profile)
            near(reversed.x, -initial.x); near(reversed.y, -initial.y)
            XCTAssertTrue(engine.keyDown(first, now: 0.03).isEmpty, "Key repeat cannot steal direction priority")
            _ = engine.keyUp(opposite, now: 0.04)
            _ = engine.advance(now: 0.041)
            let restored = try direction(engine, profile: profile)
            near(restored.x, initial.x); near(restored.y, initial.y)
            _ = engine.keyDown(opposite, now: 0.05); _ = engine.keyUp(first, now: 0.06)
            let held = try direction(engine, profile: profile)
            near(held.x, reversed.x); near(held.y, reversed.y)
            XCTAssertEqual(engine.state.contacts.map(\.id), [1])
        }
    }

    func testDiagonalTurnsStayAtFullRadiusAndSettleAcrossTickRates() throws {
        var profile = FPSProfile(); profile.keyboardTurnDuration = 0.060
        profile.keyboardRecenterOnAxisRelease = false
        for rate in [60.0, 120.0, 240.0] {
            var engine = try FPSInputEngine(profile: profile); _ = engine.start()
            _ = engine.keyDown("KeyW", now: 0); _ = engine.advance(now: 0.017)
            _ = engine.keyDown("KeyD", now: 0.1)
            var sawIntermediate = false
            for tick in 1...Int(rate * 0.1) {
                _ = engine.advance(now: 0.1 + Double(tick) / rate)
                let vector = try direction(engine, profile: profile)
                near(hypot(vector.x, vector.y), 1)
                XCTAssertTrue(vector.x >= -0.00001 && vector.x <= sqrt(0.5) + 0.00001)
                if vector.x > 0.00001 && vector.x < sqrt(0.5) - 0.00001 { sawIntermediate = true }
            }
            XCTAssertTrue(sawIntermediate, "A turn must send intermediate angles, not jump between eight targets")
            let diagonal = try direction(engine, profile: profile)
            near(diagonal.x, sqrt(0.5)); near(diagonal.y, -sqrt(0.5))
            _ = engine.keyUp("KeyW", now: 0.25); _ = engine.advance(now: 0.251); _ = engine.advance(now: 0.32)
            let right = try direction(engine, profile: profile); near(right.x, 1); near(right.y, 0)
        }
    }

    func testStopAndQuickKeyHandoffNeverDriftOrReanchor() throws {
        let profile = FPSProfile()
        var engine = try FPSInputEngine(profile: profile); _ = engine.start()
        _ = engine.keyDown("KeyA", now: 0)
        XCTAssertEqual(engine.state.contacts.first?.point, profile.joystick)
        _ = engine.keyDown("MouseLeft", now: 0)
        XCTAssertEqual(engine.state.contacts.first?.point, profile.joystick, "Same-time edges retain the center down")
        _ = engine.advance(now: 0.017)
        _ = engine.keyUp("KeyA", now: 0.02)
        _ = engine.advance(now: 0.021)
        XCTAssertEqual(engine.state.contacts.first?.point, profile.joystick, "No momentum after stopping")
        _ = engine.keyDown("KeyD", now: 0.035)
        near(try direction(engine, profile: profile).x, 1)
        XCTAssertEqual(Set(engine.state.contacts.map(\.id)), [1, FPSAction.fire.touchID])
        _ = engine.keyUp("KeyD", now: 0.04); _ = engine.advance(now: 0.07)
        XCTAssertEqual(engine.state.contacts.first?.point, profile.joystick)
        _ = engine.advance(now: 0.111)
        XCTAssertEqual(engine.state.contacts.map(\.id), [FPSAction.fire.touchID])
        _ = engine.keyDown("KeyW", now: 0.12)
        XCTAssertEqual(engine.state.contacts.first?.point, profile.joystick, "A later movement starts at center")
        XCTAssertTrue(engine.releaseAll().contacts.isEmpty, "Releasing capture bypasses the neutral grace period")
        XCTAssertTrue(engine.advance(now: 0.13).isEmpty)
        _ = engine.start(); _ = engine.keyDown("KeyS", now: 0.2)
        XCTAssertEqual(engine.state.contacts.first?.point, profile.joystick)
    }

    func testRapidChangesTakeShortestArcAndReverseImmediately() throws {
        var profile = FPSProfile(); profile.keyboardTurnDuration = 0.060
        profile.keyboardRecenterOnAxisRelease = false
        var engine = try FPSInputEngine(profile: profile); _ = engine.start()
        _ = engine.keyDown("KeyA", now: 0); _ = engine.advance(now: 0.017)
        _ = engine.keyDown("KeyW", now: 0.02); _ = engine.advance(now: 0.04)
        let mid = try direction(engine, profile: profile)
        XCTAssertTrue(mid.x < 0 && mid.y < 0, "Cross the +/-pi angle boundary through the upper-left quadrant")
        _ = engine.keyUp("KeyW", now: 0.04)
        let unchanged = try direction(engine, profile: profile)
        near(unchanged.x, mid.x); near(unchanged.y, mid.y)
        _ = engine.advance(now: 0.11)
        _ = engine.keyDown("KeyD", now: 0.12)
        let right = try direction(engine, profile: profile)
        near(right.x, 1); near(right.y, 0)
    }

    func testLegacyMouseJoystickCannotConsumeLookAndSettingsPersist() throws {
        var profile = FPSProfile(); profile.keyboardTurnDuration = 0.040
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as? [String: Any])
        json.removeValue(forKey: "keyboardTurnDuration")
        json["analogJoystick"] = true; json["analogTrigger"] = "Option"; json["analogTravel"] = 100
        let migrated = try JSONDecoder().decode(FPSProfile.self, from: JSONSerialization.data(withJSONObject: json))
        near(migrated.keyboardTurnDuration, 0.025)
        var engine = try FPSInputEngine(profile: migrated); _ = engine.start()
        _ = engine.keyDown("KeyW", now: 0); _ = engine.keyDown("Option", now: 0.01)
        engine.mouseMoved(dx: 5, dy: 2, now: 0.02); _ = engine.advance(now: 0.02); _ = engine.advance(now: 0.03)
        XCTAssertEqual(Set(engine.state.contacts.map(\.id)), [1, 2])
        let look = try XCTUnwrap(engine.state.contacts.first { $0.id == 2 }?.point)
        XCTAssertTrue(look.x > migrated.look.x); XCTAssertTrue(look.y > migrated.look.y)
        near(try direction(engine, profile: migrated).x, 0)
        near(try direction(engine, profile: migrated).y, -1)
        XCTAssertEqual(try JSONDecoder().decode(FPSProfile.self, from: JSONEncoder().encode(profile)), profile)
        profile.keyboardTurnDuration = 0.081; XCTAssertThrowsError(try profile.validate())
        profile.keyboardTurnDuration = .nan; XCTAssertThrowsError(try profile.validate())
    }

    func testMovementPreviewReachesNativeDaemonWithOneFingerLifecycle() throws {
        var profile = FPSProfile(); profile.touchMapping.rotation = 1
        profile.keyboardRecenterOnAxisRelease = false
        let frames = try FPSInputPreview.movement(profile: profile, aspect: 4.0 / 3.0)
        XCTAssertTrue(frames.last!.contacts.isEmpty)
        let vectors = frames.compactMap { $0.contacts.first?.point }
        XCTAssertTrue(vectors.count > 60)
        let daemon = try NativeFPSFixture(interfaceOrientation: 3), socket = try daemon.connect()
        defer { socket.close(); daemon.stop() }
        for (index, frame) in frames.enumerated() {
            _ = try daemon.send(frame, sequence: UInt32(index + 1), socket: socket)
        }
        let edges = daemon.frames.compactMap { $0.edges[1] }
        XCTAssertEqual(edges.filter { $0.kind == "down" }.count, 1)
        XCTAssertTrue(edges.filter { $0.kind == "move" }.count >= 8, "All eight directions must reach the native movement contact")
        XCTAssertEqual(edges.filter { $0.kind == "up" }.count, 1)
        XCTAssertEqual(daemon.frames.last?.active, 0)
        // The profile compensation (90°) and native landscape transform
        // (270°) cancel, so native coordinates match the visible layout.
        let first = try XCTUnwrap(edges.first)
        XCTAssertLessThan(abs(first.x - profile.joystick.x), 0.00003)
        XCTAssertLessThan(abs(first.y - profile.joystick.y), 0.00003)
        let diagonal = sqrt(0.5)
        let targets: [FPSPoint] = [
            .init(x: 0, y: -1), .init(x: diagonal, y: -diagonal),
            .init(x: 1, y: 0), .init(x: diagonal, y: diagonal),
            .init(x: 0, y: 1), .init(x: -diagonal, y: diagonal),
            .init(x: -1, y: 0), .init(x: -diagonal, y: -diagonal)
        ]
        for (index, expected) in targets.enumerated() {
            let visible = FPSPoint(x: profile.joystick.x + expected.x * profile.joystickRadius / (4.0 / 3.0),
                                   y: profile.joystick.y + expected.y * profile.joystickRadius)
            XCTAssertEqual(frames[index * 9 + 8].contacts.first?.point, profile.touchMapping.apply(visible))
        }
        profile.joystickEnabled = false
        XCTAssertThrowsError(try FPSInputPreview.movement(profile: profile, aspect: 4.0 / 3.0))
    }

    func testReleaseAndPressBetweenTicksNeverEmitCenter() throws {
        var profile = FPSProfile(); profile.keyboardTurnDuration = 0
        var engine = try FPSInputEngine(profile: profile); _ = engine.start()
        _ = engine.keyDown("KeyA", now: 0); _ = engine.advance(now: 0.017)
        XCTAssertTrue(engine.keyUp("KeyA", now: 0.022).isEmpty)
        let frames = engine.keyDown("KeyD", now: 0.024)
        XCTAssertEqual(frames.count, 1)
        near(try direction(engine, profile: profile).x, 1)
        XCTAssertFalse(frames.contains { $0.contacts.first?.point == profile.joystick })
        _ = engine.keyUp("KeyD", now: 0.03); _ = engine.advance(now: 0.035)
        XCTAssertEqual(engine.state.contacts.first?.point, profile.joystick)
    }

    func testLongHeldDirectionThenNewPressDoesNotCarryOldAngle() throws {
        let keys: [(String, FPSPoint)] = [
            ("KeyW", .init(x: 0, y: -1)), ("KeyD", .init(x: 1, y: 0)),
            ("KeyS", .init(x: 0, y: 1)), ("KeyA", .init(x: -1, y: 0))
        ]
        for duration in [0.025, 0.060] {
            var profile = FPSProfile(); profile.keyboardTurnDuration = duration
            for (oldKey, _) in keys {
                for (newKey, expected) in keys where newKey != oldKey {
                    var engine = try FPSInputEngine(profile: profile); _ = engine.start()
                    _ = engine.keyDown(oldKey, now: 0); _ = engine.advance(now: 0.017)
                    _ = engine.advance(now: 5)
                    _ = engine.keyDown("MouseLeft", now: 5)
                    let fire = try XCTUnwrap(engine.state.contacts.first { $0.id != 1 })
                    XCTAssertTrue(engine.keyUp(oldKey, now: 5.001).isEmpty)
                    // No timer tick sees the empty key set. The next press is
                    // still a new direction, rather than a turn from the old one.
                    let frames = engine.keyDown(newKey, now: 5.003)
                    let actual = try direction(engine, profile: profile)
                    near(actual.x, expected.x); near(actual.y, expected.y)
                    XCTAssertEqual(engine.state.contacts.first { $0.id == fire.id }, fire)
                    XCTAssertFalse(frames.contains { $0.contacts.first { $0.id == 1 }?.point == profile.joystick })
                    _ = engine.advance(now: 5.010)
                    let afterTick = try direction(engine, profile: profile)
                    near(afterTick.x, expected.x); near(afterTick.y, expected.y)
                }
            }
        }
    }

    func testDiagonalAxisReversalAndReleasedAxisReachNativeWithoutDetour() throws {
        let diagonal = sqrt(0.5)
        let scenarios: [(String?, String, FPSPoint)] = [
            (nil, "KeyA", .init(x: -diagonal, y: -diagonal)),
            (nil, "KeyS", .init(x: diagonal, y: diagonal)),
            ("KeyW", "KeyA", .init(x: -1, y: 0)),
            ("KeyD", "KeyS", .init(x: 0, y: 1))
        ]
        let daemon = try NativeFPSFixture(), socket = try daemon.connect()
        defer { socket.close(); daemon.stop() }
        var sequence: UInt32 = 0
        for (released, next, expected) in scenarios {
            var profile = FPSProfile(); profile.orientation = .portrait
            profile.keyboardTurnDuration = 0.060
            var engine = try FPSInputEngine(profile: profile); _ = engine.start()
            _ = engine.keyDown("KeyW", now: 0)
            sequence += 1; _ = try daemon.send(engine.state, sequence: sequence, socket: socket)
            _ = engine.keyDown("KeyD", now: 0.01); _ = engine.advance(now: 4)
            _ = engine.keyDown("MouseLeft", now: 4)
            sequence += 1; _ = try daemon.send(engine.state, sequence: sequence, socket: socket)
            if let released { _ = engine.keyUp(released, now: 4.001) }
            let changed = engine.keyDown(next, now: 4.003)
            let actual = try direction(engine, profile: profile)
            near(actual.x, expected.x); near(actual.y, expected.y)
            XCTAssertEqual(changed.count, 1)
            sequence += 1; _ = try daemon.send(engine.state, sequence: sequence, socket: socket)
            let native = try XCTUnwrap(daemon.frames.last?.edges[1])
            XCTAssertEqual(native.kind, "move")
            XCTAssertLessThan(abs(native.x - (profile.joystick.x + expected.x * profile.joystickRadius / (4.0 / 3.0))), 0.00003)
            XCTAssertLessThan(abs(native.y - (profile.joystick.y + expected.y * profile.joystickRadius)), 0.00003)
            XCTAssertEqual(daemon.frames.last?.active, 2)
            sequence += 1; _ = try daemon.send(engine.releaseAll(), sequence: sequence, socket: socket)
        }
    }

    func testReleasingOneDiagonalAxisRestoresStraightDirectionOnFirstTick() throws {
        let axes: [(String, String, FPSPoint, FPSPoint)] = [
            ("KeyW", "KeyA", .init(x: 0, y: -1), .init(x: -1, y: 0)),
            ("KeyW", "KeyD", .init(x: 0, y: -1), .init(x: 1, y: 0)),
            ("KeyS", "KeyA", .init(x: 0, y: 1), .init(x: -1, y: 0)),
            ("KeyS", "KeyD", .init(x: 0, y: 1), .init(x: 1, y: 0))
        ]
        let daemon = try NativeFPSFixture(), socket = try daemon.connect()
        defer { socket.close(); daemon.stop() }
        var sequence: UInt32 = 0
        for duration in [0.025, 0.060] {
            for heldTime in [0.008, 5.0] {
                for (vertical, horizontal, verticalVector, horizontalVector) in axes {
                    for releaseHorizontal in [true, false] {
                        var profile = FPSProfile(); profile.keyboardTurnDuration = duration
                        profile.keyboardRecenterOnAxisRelease = false
                        var engine = try FPSInputEngine(profile: profile); _ = engine.start()
                        _ = engine.keyDown(vertical, now: 0); _ = engine.advance(now: 0.017)
                        _ = engine.keyDown(horizontal, now: 0.1); _ = engine.advance(now: 0.1 + heldTime)
                        _ = engine.keyDown("MouseLeft", now: 0.1 + heldTime)
                        sequence += 1; _ = try daemon.send(engine.state, sequence: sequence, socket: socket)
                        let fire = try XCTUnwrap(engine.state.contacts.first { $0.id != 1 })
                        let released = releaseHorizontal ? horizontal : vertical
                        let expected = releaseHorizontal ? verticalVector : horizontalVector
                        let releaseTime = 0.101 + heldTime
                        XCTAssertTrue(engine.keyUp(released, now: releaseTime).isEmpty)
                        let frames = engine.advance(now: releaseTime + 1.0 / 120.0)
                        XCTAssertEqual(frames.count, 1)
                        let vector = try direction(engine, profile: profile)
                        near(vector.x, expected.x); near(vector.y, expected.y)
                        sequence += 1; _ = try daemon.send(engine.state, sequence: sequence, socket: socket)
                        let native = try XCTUnwrap(daemon.frames.last?.edges[1])
                        XCTAssertEqual(native.kind, "move", "Return to straight movement must keep the same finger")
                        XCTAssertLessThan(abs(native.x - (profile.joystick.x + expected.x * profile.joystickRadius / (4.0 / 3.0))), 0.00003)
                        XCTAssertLessThan(abs(native.y - (profile.joystick.y + expected.y * profile.joystickRadius)), 0.00003)
                        for tick in 2...12 {
                            _ = engine.advance(now: releaseTime + Double(tick) / 120.0)
                            let next = try direction(engine, profile: profile)
                            near(next.x, expected.x); near(next.y, expected.y)
                            XCTAssertEqual(engine.state.contacts.first { $0.id == fire.id }, fire)
                        }
                        sequence += 1; _ = try daemon.send(engine.releaseAll(), sequence: sequence, socket: socket)
                    }
                }
            }
        }
    }
}
