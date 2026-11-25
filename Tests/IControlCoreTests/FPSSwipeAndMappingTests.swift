import Foundation
import TestSupport
@testable import IControlCore

final class FPSSwipeAndMappingTests {
    func testLegacyDaemonRequiresUpgradeBeforeCapture() throws {
        let fixture = try LoopbackFixture { socket in
            try socket.write(FPSWire.legacyGreeting)
            // A rejected old daemon must receive no authentication or touches.
            XCTAssertThrowsError(try socket.read(count: 1, timeout: 1000))
        }
        defer { fixture.stop() }
        let socket = try SocketConnection.loopback(port: fixture.port)
        defer { socket.close() }
        do {
            _ = try FPSUSBLink(socket: socket, token: String(repeating: "a5", count: 32))
            XCTFail("Old daemon should not appear ready")
        } catch { XCTAssertTrue(error.localizedDescription.contains("升级至 1.4.0")) }
        socket.close()
    }

    func testAllMappingsCRUDAndLegacyPersistence() throws {
        let original = FPSProfile()
        var editor = FPSLayoutEditor(profile: original)
        for target in original.mappingTargets { try editor.removeMapping(target.id) }
        XCTAssertTrue(editor.draft.mappingTargets.isEmpty); try editor.draft.validate()
        var engine = try FPSInputEngine(profile: editor.draft); _ = engine.start()
        _ = engine.keyDown("KeyW", now: 0); engine.mouseMoved(dx: 20, dy: 30, now: 0); _ = engine.advance(now: 0.01)
        XCTAssertTrue(engine.state.contacts.isEmpty)
        for target in original.mappingTargets { try editor.addMapping(target.id) }
        XCTAssertEqual(editor.draft.mappingTargets.count, original.mappingTargets.count)
        try editor.edit { profile in
            var button = profile.buttons.first { $0.id == "fire" }!
            button.title = "主武器开火"; button.point = .init(x: 0.82, y: 0.42); profile.updateButton(button)
        }
        try editor.removeMapping("fire"); editor.undo()
        XCTAssertEqual(editor.draft.buttons.first { $0.id == "fire" }?.title, "主武器开火")
        editor.redo(); XCTAssertFalse(editor.draft.buttons.contains { $0.id == "fire" })
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mapping-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try FPSProfileLibrary(profiles: [editor.draft]).save(to: url)
        XCTAssertEqual(try FPSProfileLibrary.load(from: url).profiles[0], editor.draft)
    }

    func testSwipesEveryDirectionKeepHeldFingersAndFinishAtEndpoint() throws {
        for direction in FPSSwipeDirection.allCases {
            var profile = FPSProfile(); let id = try profile.addCustomButton(swipe: true)
            var button = profile.buttons.first { $0.id == id }!
            button.point = .init(x: 0.5, y: 0.5); button.swipe.duration = 0.2
            button.swipe.set(direction: direction, distance: 0.25, from: button.point); profile.updateButton(button)
            var engine = try FPSInputEngine(profile: profile); _ = engine.start()
            _ = engine.keyDown("KeyW", now: 0); _ = engine.keyDown("MouseLeft", now: 0.01)
            _ = engine.keyDown(button.trigger, now: 0.02)
            let finger = engine.state.contacts.first { $0.id != 1 && $0.id != FPSAction.fire.touchID }!
            XCTAssertEqual(finger.point, button.point)
            _ = engine.keyUp(button.trigger, now: 0.03)
            _ = engine.advance(now: 0.12)
            let mid = engine.state.contacts.first { $0.id == finger.id }!.point
            XCTAssertLessThan(abs(mid.x - (button.point.x + button.swipe.end.x) / 2), 0.0001)
            XCTAssertLessThan(abs(mid.y - (button.point.y + button.swipe.end.y) / 2), 0.0001)
            _ = engine.advance(now: 0.25)
            XCTAssertEqual(engine.state.contacts.first { $0.id == finger.id }?.point, button.swipe.end)
            _ = engine.advance(now: 0.27)
            XCTAssertEqual(Set(engine.state.contacts.map(\.id)), [1, FPSAction.fire.touchID])
            let preview = try FPSInputPreview.button(id, profile: profile)
            XCTAssertEqual(preview.first?.contacts.first?.point, button.point)
            XCTAssertTrue(preview.contains { $0.contacts.first?.point == button.swipe.end })
            XCTAssertTrue(preview.last!.contacts.isEmpty)
            _ = engine.keyDown(button.trigger, now: 0.3); XCTAssertEqual(engine.releaseAll().contacts.count, 0)
            XCTAssertTrue(engine.advance(now: 1).isEmpty)
        }
    }

    func testSwipePersistenceValidationRetriggerAndCalibration() throws {
        var profile = FPSProfile(); let id = try profile.addCustomButton(swipe: true)
        profile.touchMapping.rotation = 1
        let saved = try JSONDecoder().decode(FPSProfile.self, from: JSONEncoder().encode(profile))
        XCTAssertEqual(saved, profile)
        let button = profile.buttons.first { $0.id == id }!
        var engine = try FPSInputEngine(profile: profile); _ = engine.start()
        _ = engine.keyDown(button.trigger, now: 0)
        _ = engine.keyUp(button.trigger, now: 0.04)
        let retrigger = engine.keyDown(button.trigger, now: 0.06)
        XCTAssertEqual(retrigger.count, 2); XCTAssertTrue(retrigger[0].contacts.isEmpty)
        XCTAssertEqual(retrigger[1].contacts.first?.point, profile.touchMapping.apply(button.point))
        profile.customButtons[0].swipe.end = profile.customButtons[0].point
        XCTAssertThrowsError(try profile.validate())
    }

    func testNativeInterfaceOrientationEnumsAndSwipeEdges() throws {
        for (orientation, rotation) in [(3, 3), (4, 1)] {
            let daemon = try NativeFPSFixture(interfaceOrientation: orientation), socket = try daemon.connect()
            defer { socket.close(); daemon.stop() }
            var profile = FPSProfile(); let id = try profile.addCustomButton(swipe: true)
            let preview = try FPSInputPreview.button(id, profile: profile)
            for (index, state) in preview.enumerated() {
                let ack = try daemon.send(state, sequence: UInt32(index + 1), socket: socket)
                XCTAssertEqual(Int(ack[2]), rotation)
            }
            let frames = daemon.frames
            XCTAssertEqual(frames.first?.edges.values.first?.kind, "down")
            XCTAssertTrue(frames.contains { $0.edges.values.contains { $0.kind == "move" } })
            XCTAssertEqual(frames.last?.edges.values.first?.kind, "up")
            XCTAssertEqual(frames.last?.active, 0)
            let start = profile.customButtons[0].point
            let edge = frames.first!.edges.values.first!
            let expected = rotation == 1 ? FPSPoint(x: start.y, y: 1 - start.x) : FPSPoint(x: 1 - start.y, y: start.x)
            XCTAssertLessThan(abs(edge.x - expected.x), 0.00005)
            XCTAssertLessThan(abs(edge.y - expected.y), 0.00005)
        }
    }
}
