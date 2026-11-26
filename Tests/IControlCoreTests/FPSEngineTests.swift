import Foundation
import TestSupport
@testable import IControlCore

final class FPSEngineTests: TestCase {
    private func contact(_ state: FPSState, _ id: UInt8) throws -> FPSPoint {
        try XCTUnwrap(state.contacts.first(where: { $0.id == id })?.point)
    }
    private func near(_ actual: Double, _ expected: Double, tolerance: Double = 0.000001) {
        XCTAssertLessThan(abs(actual - expected), tolerance)
    }

    func testJoystickAnchoringDiagonalAndOppositeKeys() throws {
        var profile = FPSProfile(); profile.smoothKeyboardSteering = false; profile.keyboardTurnDuration = 0
        var engine = try FPSInputEngine(profile: profile); engine.setAspect(4.0 / 3.0)
        _ = engine.start()
        _ = engine.keyDown("KeyW", now: 1)
        XCTAssertEqual(try contact(engine.state, 1), profile.joystick, "First contact must anchor at joystick center")
        _ = engine.advance(now: 1.017)
        near(try contact(engine.state, 1).y, profile.joystick.y - profile.joystickRadius)
        _ = engine.keyDown("KeyD", now: 1.02)
        let diagonal = try contact(engine.state, 1)
        near((diagonal.x - profile.joystick.x) * 4.0 / 3.0, profile.joystickRadius / sqrt(2))
        near(diagonal.y - profile.joystick.y, -profile.joystickRadius / sqrt(2))
        _ = engine.keyDown("KeyA", now: 1.03)
        XCTAssertLessThan(try contact(engine.state, 1).x, profile.joystick.x)
        _ = engine.keyDown("KeyS", now: 1.04)
        XCTAssertTrue(try contact(engine.state, 1).y > profile.joystick.y)
        for key in ["KeyW", "KeyD", "KeyA", "KeyS"] { _ = engine.keyUp(key, now: 1.05) }
        _ = engine.advance(now: 1.051)
        XCTAssertTrue(engine.state.contacts.isEmpty, "Stop by lifting on the first tick, without a center animation")
        _ = engine.keyDown("KeyA", now: 1.11)
        XCTAssertEqual(try contact(engine.state, 1), profile.joystick, "A new movement must anchor again")
    }

    func testSimultaneousMoveLookFireAndAim() throws {
        var engine = try FPSInputEngine(profile: FPSProfile()); _ = engine.start()
        _ = engine.keyDown("KeyW", now: 1); _ = engine.keyDown("MouseLeft", now: 1.01)
        _ = engine.keyDown("MouseRight", now: 1.02)
        engine.mouseMoved(dx: 20, dy: -10, now: 1.03); _ = engine.advance(now: 1.04)
        XCTAssertEqual(Set(engine.state.contacts.map(\.id)), Set([UInt8(1), 2, FPSAction.fire.touchID, FPSAction.aim.touchID]))
        let fire = try contact(engine.state, FPSAction.fire.touchID)
        _ = engine.advance(now: 1.05)
        XCTAssertEqual(try contact(engine.state, FPSAction.fire.touchID), fire)
        XCTAssertNotEqual(try contact(engine.state, 2), FPSProfile().look)
        _ = engine.keyUp("MouseRight", now: 1.06)
        XCTAssertFalse(engine.state.contacts.contains(where: { $0.id == FPSAction.aim.touchID }))
        XCTAssertTrue(engine.state.contacts.contains(where: { $0.id == FPSAction.fire.touchID }))
        _ = engine.advance(now: 1.30)
        XCTAssertEqual(Set(engine.state.contacts.map(\.id)), Set([UInt8(1), FPSAction.fire.touchID]))
        _ = engine.releaseAll()
        XCTAssertTrue(engine.state.contacts.isEmpty); XCTAssertTrue(engine.pressed.isEmpty)
        XCTAssertTrue(engine.keyDown("MouseLeft", now: 2).isEmpty)
        engine.mouseMoved(dx: 100, dy: 100, now: 2)
        XCTAssertTrue(engine.advance(now: 2.1).isEmpty)
    }

    func testLookRebasePreservesOtherContactsAndNarrowRegionProgresses() throws {
        var profile = FPSProfile(); profile.lookWidth = 0.10; profile.lookHeight = 0.10
        var engine = try FPSInputEngine(profile: profile); _ = engine.start()
        _ = engine.keyDown("KeyW", now: 1); _ = engine.keyDown("MouseLeft", now: 1)
        engine.mouseMoved(dx: 500, dy: 0, now: 1)
        var sawRelease = false, sawMove = false, distance = 0.0
        var previous: FPSPoint?
        for tick in 0..<100 {
            _ = engine.advance(now: 1 + Double(tick) / 120)
            let current = engine.state.contacts.first(where: { $0.id == 2 })?.point
            XCTAssertTrue(engine.state.contacts.contains(where: { $0.id == 1 }))
            XCTAssertTrue(engine.state.contacts.contains(where: { $0.id == FPSAction.fire.touchID }))
            if let current {
                XCTAssertTrue((profile.look.x - 0.05...profile.look.x + 0.05).contains(current.x))
                if let previous { distance += current.x - previous.x; sawMove = sawMove || current.x != previous.x }
            } else if previous != nil { sawRelease = true }
            previous = current
        }
        XCTAssertTrue(sawRelease); XCTAssertTrue(sawMove)
        near(distance, 0.6, tolerance: 0.00001)
    }

    func testTapDurationRepeatSuppressionAndRapidRetrigger() throws {
        var engine = try FPSInputEngine(profile: FPSProfile()); _ = engine.start()
        _ = engine.keyDown("KeyW", now: 1)
        _ = engine.keyDown("KeyR", now: 1.01)
        XCTAssertTrue(engine.keyDown("KeyR", now: 1.02).isEmpty, "OS key repeat must not retrigger taps")
        _ = engine.keyUp("KeyR", now: 1.025)
        XCTAssertTrue(engine.state.contacts.contains(where: { $0.id == FPSAction.reload.touchID }))
        let retrigger = engine.keyDown("KeyR", now: 1.03)
        XCTAssertEqual(retrigger.count, 2, "Rapid taps need a release edge followed by a fresh down edge")
        XCTAssertFalse(retrigger[0].contacts.contains(where: { $0.id == FPSAction.reload.touchID }))
        XCTAssertTrue(retrigger[1].contacts.contains(where: { $0.id == FPSAction.reload.touchID }))
        XCTAssertTrue(retrigger.allSatisfy { $0.contacts.contains(where: { $0.id == 1 }) })
        _ = engine.advance(now: 1.099)
        XCTAssertTrue(engine.state.contacts.contains(where: { $0.id == FPSAction.reload.touchID }))
        _ = engine.advance(now: 1.101)
        XCTAssertFalse(engine.state.contacts.contains(where: { $0.id == FPSAction.reload.touchID }))
        _ = engine.pulse(.weapon1, now: 2)
        XCTAssertEqual(engine.pulse(.weapon1, now: 2.02).count, 2)
        _ = engine.advance(now: 2.10)
        XCTAssertFalse(engine.state.contacts.contains(where: { $0.id == FPSAction.weapon1.touchID }))
    }

    func testContactLimitAndDeterministicActionIDs() throws {
        var profile = FPSProfile()
        for i in profile.bindings.indices { profile.bindings[i].enabled = true; profile.bindings[i].behavior = .hold }
        var engine = try FPSInputEngine(profile: profile); _ = engine.start()
        _ = engine.keyDown("KeyW", now: 1); engine.mouseMoved(dx: 1, dy: 1, now: 1)
        for binding in profile.bindings { _ = engine.keyDown(binding.trigger, now: 1.01) }
        XCTAssertEqual(engine.state.contacts.count, 10)
        XCTAssertEqual(Set(engine.state.contacts.map(\.id)).count, 10)
        XCTAssertEqual(engine.state.contacts.map(\.id), Array(UInt8(1)...UInt8(10)))
        _ = engine.keyUp("MouseLeft", now: 1.02)
        XCTAssertEqual(engine.state.contacts.count, 10)
        XCTAssertTrue(engine.state.contacts.contains(where: { $0.id == FPSAction.weapon1.touchID }))
        XCTAssertEqual(FPSAction.backpack.touchID, 16)
    }

    func testMouseSensitivityAspectAndInversion() throws {
        var profile = FPSProfile(); profile.sensitivity = 2; profile.invertY = true
        var engine = try FPSInputEngine(profile: profile); engine.setAspect(2); _ = engine.start()
        engine.mouseMoved(dx: 5, dy: 5, now: 1)
        _ = engine.advance(now: 1.017); _ = engine.advance(now: 1.02)
        let point = try contact(engine.state, 2)
        near(point.x - profile.look.x, 0.012); near(point.y - profile.look.y, -0.024)
        engine.mouseMoved(dx: .nan, dy: .infinity, now: 1.03)
        XCTAssertTrue(engine.advance(now: 1.04).isEmpty)
    }

    func testProfileValidationCalibrationAndPersistence() throws {
        var profile = FPSProfile(); try profile.validate()
        profile.bindings[1].trigger = "MouseLeft"
        XCTAssertThrowsError(try profile.validate())
        profile = FPSProfile(); profile.bindings[0].trigger = "KeyW"
        XCTAssertThrowsError(try profile.validate())
        profile = FPSProfile(); profile.sensitivity = .infinity
        XCTAssertThrowsError(try profile.validate())
        profile = FPSProfile(); profile.setPoint(FPSPoint(x: 0, y: 0), target: "look")
        try profile.validate(); near(profile.look.x, profile.lookWidth / 2)
        profile.setPoint(FPSPoint(x: 0.9, y: 0.5), target: "fire")
        near(profile.bindings[0].point.x, 0.9)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fps-library-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        var custom = profile; custom.id = UUID(); custom.name = "测试布局"
        let library = FPSProfileLibrary(profiles: [profile, custom], selectionByDevice: ["ipad-a": custom.id])
        try library.save(to: url)
        let saved = try FPSProfileLibrary.load(from: url)
        XCTAssertEqual(saved.profiles, [profile, custom]); XCTAssertEqual(saved.selectionByDevice["ipad-a"], custom.id)
        XCTAssertThrowsError(try FPSProfileLibrary(profiles: [profile, profile]).validate())
        XCTAssertThrowsError(try FPSProfileLibrary(profiles: []).validate())
    }

    func testWireRoundTripAndMalformedPackets() throws {
        let state = FPSState(contacts: [.init(id: 3, point: .init(x: 0.8, y: 0.2)), .init(id: 1, point: .init(x: 0, y: 1))], orientation: .clockwise)
        let bytes = try FPSWire.state(state, sequence: 0x12345678), decoded = try FPSWire.decode(bytes)
        XCTAssertEqual(decoded.sequence, 0x12345678); XCTAssertEqual(decoded.state.orientation, .clockwise)
        XCTAssertEqual(decoded.state.contacts.map(\.id), [UInt8(1), 3])
        near(decoded.state.contacts[1].point.x, 0.8, tolerance: 1.0 / 65535)
        for offset in [3, 9, 14, 15, 17, 22, 23] {
            var malformed = bytes; malformed[offset] = 1
            XCTAssertThrowsError(try FPSWire.decode(malformed))
        }
        var duplicate = bytes; duplicate[16] = 1
        XCTAssertThrowsError(try FPSWire.decode(duplicate))
        var orientation = bytes; orientation[2] = 4
        XCTAssertThrowsError(try FPSWire.decode(orientation))
        XCTAssertThrowsError(try FPSWire.decode(Data(bytes.dropLast())))
        XCTAssertThrowsError(try FPSWire.state(FPSState(contacts: [.init(id: 17, point: .init(x: 0.5, y: 0.5))]), sequence: 1))
        XCTAssertThrowsError(try FPSWire.state(FPSState(contacts: [.init(id: 1, point: .init(x: .nan, y: 0.5))]), sequence: 1))
        let release = try FPSWire.decode(FPSWire.control(2, sequence: 7))
        XCTAssertEqual(release.opcode, 2); XCTAssertEqual(release.sequence, 7)
        let token = try FPSAccessToken.generate()
        XCTAssertEqual(try FPSAccessToken.bytes(token).count, 32)
        XCTAssertNotEqual(token, try FPSAccessToken.generate())
        XCTAssertThrowsError(try FPSAccessToken.bytes(token.uppercased()))
        XCTAssertThrowsError(try FPSAccessToken.bytes(String(token.dropLast())))
    }
}
