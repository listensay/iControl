import Foundation
import TestSupport
@testable import IControlCore

final class FPSCursorTests {
    func testCursorToggleRetainsKeyboardAndReleasesLookAndMouseBindings() throws {
        let profile = FPSProfile()
        var engine = try FPSInputEngine(profile: profile); _ = engine.start()
        _ = engine.keyDown("KeyW", now: 0); _ = engine.keyDown("Control", now: 0.01)
        _ = engine.keyDown("MouseLeft", now: 0.02)
        engine.mouseMoved(dx: 3, dy: 1, now: 0.03); _ = engine.advance(now: 0.03)
        XCTAssertEqual(Set(engine.state.contacts.map(\.id)), [1, 2, FPSAction.fire.touchID, FPSAction.crouch.touchID])
        let toggle = engine.setCursorMode(true, now: 0.04)
        XCTAssertEqual(toggle.count, 1)
        XCTAssertTrue(engine.cursorMode && engine.captured)
        XCTAssertEqual(Set(engine.state.contacts.map(\.id)), [1, FPSAction.crouch.touchID])
        XCTAssertFalse(engine.pressed.contains("MouseLeft"))
        engine.mouseMoved(dx: 300, dy: 100, now: 0.05); _ = engine.advance(now: 0.05)
        XCTAssertFalse(engine.state.contacts.contains { $0.id == 2 })
        XCTAssertTrue(engine.keyDown("MouseLeft", now: 0.06).isEmpty)
        _ = engine.pointerDown(at: .init(x: 0.4, y: 0.3), now: 0.07)
        XCTAssertEqual(Set(engine.state.contacts.map(\.id)), [1, 2, FPSAction.crouch.touchID])
        _ = engine.setCursorMode(false, now: 0.08)
        XCTAssertFalse(engine.cursorMode)
        XCTAssertEqual(Set(engine.state.contacts.map(\.id)), [1, FPSAction.crouch.touchID])
        engine.mouseMoved(dx: 2, dy: 0, now: 0.09); _ = engine.advance(now: 0.09); _ = engine.advance(now: 0.10)
        XCTAssertTrue(engine.state.contacts.contains { $0.id == 2 })
        _ = engine.releaseAll(); XCTAssertFalse(engine.cursorMode); XCTAssertTrue(engine.state.contacts.isEmpty)
        XCTAssertTrue(engine.pointerDown(at: .init(x: 0.2, y: 0.3), now: 0.11).isEmpty)
    }

    func testPointerClickDragCalibrationFinalMoveAndNativeEdges() throws {
        var profile = FPSProfile(); profile.lookEnabled = false
        profile.touchMapping.rotation = 2; profile.touchMapping.offsetX = 0.02
        var engine = try FPSInputEngine(profile: profile); _ = engine.start()
        _ = engine.setCursorMode(true, now: 0)
        let daemon = try NativeFPSFixture(), socket = try daemon.connect()
        defer { socket.close(); daemon.stop() }
        var sequence: UInt32 = 0
        func send(_ frames: [FPSState]) throws {
            for frame in frames { sequence += 1; _ = try daemon.send(frame, sequence: sequence, socket: socket) }
        }
        let start = FPSPoint(x: 0.3, y: 0.4), end = FPSPoint(x: 0.7, y: 0.6)
        try send(engine.pointerDown(at: start, now: 0.01))
        XCTAssertEqual(engine.state.contacts, [.init(id: 2, point: profile.touchMapping.apply(start))])
        XCTAssertTrue(engine.pointerDown(at: end, now: 0.011).isEmpty)
        engine.pointerMoved(to: .init(x: .nan, y: 0.5))
        XCTAssertEqual(engine.state.contacts.first?.point, profile.touchMapping.apply(start))
        engine.pointerMoved(to: end)
        let lift = engine.pointerUp(now: 0.02)
        XCTAssertEqual(lift.count, 2, "Drag endpoint must reach the device before up, even between input ticks")
        XCTAssertEqual(lift.first?.contacts.first?.point, profile.touchMapping.apply(end))
        XCTAssertTrue(lift.last!.contacts.isEmpty)
        try send(lift)
        XCTAssertEqual(daemon.frames.compactMap { $0.edges[2]?.kind }, ["down", "move", "up"])
        XCTAssertTrue(engine.pointerUp(now: 0.03).isEmpty)
        XCTAssertTrue(engine.pointerDown(at: .init(x: 1.01, y: 0), now: 0.04).isEmpty)
        _ = engine.pointerDown(at: start, now: 0.05)
        XCTAssertTrue(engine.releaseAll().contacts.isEmpty)
    }

    func testViewportRejectsBlackBarsAndClampsDraggingAtEdges() throws {
        let rect = FPSViewport(x: 120, y: 30, width: 640, height: 480)
        XCTAssertEqual(rect.normalized(x: 440, y: 270), .init(x: 0.5, y: 0.5))
        XCTAssertEqual(rect.normalized(x: 120, y: 30), .init(x: 0, y: 0))
        XCTAssertTrue(rect.normalized(x: 100, y: 270) == nil)
        XCTAssertTrue(rect.normalized(x: 440, y: 550) == nil)
        XCTAssertEqual(rect.normalized(x: 100, y: 550, clamp: true), .init(x: 0, y: 1))
        XCTAssertTrue(rect.normalized(x: .nan, y: 0, clamp: true) == nil)
        XCTAssertFalse(FPSViewport(x: 0, y: 0, width: 0, height: 1).isValid)
    }

    func testCursorShortcutLegacyDefaultsPersistenceAndCapturePath() throws {
        let profile = FPSProfile()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as? [String: Any])
        object.removeValue(forKey: "cursorToggleKey")
        XCTAssertEqual(try JSONDecoder().decode(FPSProfile.self, from: JSONSerialization.data(withJSONObject: object)), profile)
        for key in FPSKey.cursorChoices {
            XCTAssertTrue(FPSKey.macKeyCodes.values.contains(key))
            XCTAssertFalse(FPSKey.choices.contains(key), "Cursor shortcuts must not conflict with button mappings")
            var custom = profile; custom.cursorToggleKey = key; try custom.validate()
            XCTAssertEqual(try JSONDecoder().decode(FPSProfile.self, from: JSONEncoder().encode(custom)), custom)
        }
        var invalid = profile; invalid.cursorToggleKey = "KeyW"
        XCTAssertThrowsError(try invalid.validate())
    }
}
