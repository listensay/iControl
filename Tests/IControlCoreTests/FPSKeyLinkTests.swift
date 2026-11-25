import Foundation
import TestSupport
@testable import IControlCore

final class FPSKeyLinkTests {
    private func linkedProfile() -> FPSProfile {
        var profile = FPSProfile()
        profile.bindings[3].trigger = "KeyB"
        profile.bindings[4].trigger = "Escape"; profile.bindings[4].behavior = .hold
        profile.keyLinks = [.init(source: "KeyB", target: "Escape")]
        return profile
    }

    func testEscapeMappingKeepsCaptureMovementAndPointer() throws {
        let escape = try XCTUnwrap(FPSKey.macKeyCodes[53])
        XCTAssertEqual(escape, "Escape"); XCTAssertEqual(FPSKey.title(escape), "Esc")
        XCTAssertTrue(FPSKey.choices.contains(escape))
        XCTAssertTrue(FPSKey.macKeyCodes[100] == nil); XCTAssertFalse(FPSKey.linkTargets.contains("F8"))
        for cursor in [false, true] {
            var profile = FPSProfile(); profile.bindings[3].trigger = escape
            let restored = try JSONDecoder().decode(FPSProfile.self, from: JSONEncoder().encode(profile))
            var engine = try FPSInputEngine(profile: restored); _ = engine.start()
            _ = engine.keyDown("KeyW", now: 0); _ = engine.advance(now: 1)
            if cursor {
                _ = engine.setCursorMode(true, now: 1)
                _ = engine.pointerDown(at: .init(x: 0.4, y: 0.5), now: 1)
            } else { _ = engine.keyDown("MouseLeft", now: 1) }
            let retained = engine.state.contacts
            let daemon = try NativeFPSFixture(), socket = try daemon.connect()
            defer { socket.close(); daemon.stop() }
            _ = try daemon.send(engine.state, sequence: 1, socket: socket)
            let down = engine.keyDown(escape, now: 1.01)
            XCTAssertEqual(down.count, 1)
            XCTAssertTrue(engine.captured && engine.cursorMode == cursor)
            XCTAssertTrue(retained.allSatisfy { engine.state.contacts.contains($0) })
            XCTAssertTrue(engine.state.contacts.contains { $0.id == FPSAction.crouch.touchID })
            _ = try daemon.send(try XCTUnwrap(down.first), sequence: 2, socket: socket)
            let up = engine.keyUp(escape, now: 1.02)
            XCTAssertEqual(engine.state.contacts, retained)
            XCTAssertTrue(engine.captured && engine.pressed.contains("KeyW"))
            _ = try daemon.send(try XCTUnwrap(up.first), sequence: 3, socket: socket)
            XCTAssertEqual(daemon.frames.last?.edges[Int(FPSAction.crouch.touchID)]?.kind, "up")
            XCTAssertEqual(daemon.frames.last?.ids, Set(retained.map { Int($0.id) }))
        }
    }

    func testLinkedHoldsPressAndReleaseTogetherAndKeepOtherOwners() throws {
        var profile = linkedProfile()
        profile.keyLinks.append(.init(source: "KeyC", target: "Escape"))
        var engine = try FPSInputEngine(profile: profile); _ = engine.start()
        _ = engine.keyDown("KeyW", now: 0); _ = engine.advance(now: 1)
        _ = engine.keyDown("MouseLeft", now: 1)
        let baseline = engine.state.contacts
        let daemon = try NativeFPSFixture(), socket = try daemon.connect()
        defer { socket.close(); daemon.stop() }
        _ = try daemon.send(engine.state, sequence: 1, socket: socket)
        let down = engine.keyDown("KeyB", now: 1.01)
        XCTAssertEqual(down.count, 1, "Linked holds must arrive in one contact snapshot")
        _ = try daemon.send(try XCTUnwrap(down.first), sequence: 2, socket: socket)
        XCTAssertEqual(daemon.frames.last?.edges[Int(FPSAction.crouch.touchID)]?.kind, "down")
        XCTAssertEqual(daemon.frames.last?.edges[Int(FPSAction.reload.touchID)]?.kind, "down")
        XCTAssertTrue(engine.keyDown("KeyB", now: 1.015).isEmpty)
        let up = engine.keyUp("KeyB", now: 1.02)
        XCTAssertEqual(up.count, 1)
        _ = try daemon.send(try XCTUnwrap(up.first), sequence: 3, socket: socket)
        XCTAssertEqual(daemon.frames.last?.edges[Int(FPSAction.crouch.touchID)]?.kind, "up")
        XCTAssertEqual(daemon.frames.last?.edges[Int(FPSAction.reload.touchID)]?.kind, "up")
        XCTAssertEqual(engine.state.contacts, baseline)

        _ = engine.keyDown("KeyB", now: 1.03)
        _ = engine.keyDown("Escape", now: 1.04)
        _ = engine.keyDown("KeyC", now: 1.05)
        let escapeContact = try XCTUnwrap(engine.state.contacts.first { $0.id == FPSAction.reload.touchID })
        _ = engine.keyUp("KeyB", now: 1.06)
        XCTAssertFalse(engine.state.contacts.contains { $0.id == FPSAction.crouch.touchID })
        XCTAssertTrue(engine.state.contacts.contains(escapeContact))
        _ = engine.keyUp("Escape", now: 1.07)
        XCTAssertTrue(engine.state.contacts.contains(escapeContact), "C still owns the linked Esc hold")
        _ = engine.keyUp("KeyC", now: 1.08)
        XCTAssertEqual(engine.state.contacts, baseline)
        XCTAssertTrue(engine.captured)
    }

    func testLinkedCursorTogglesOnceAndRetainsLinkedKeyboardActions() throws {
        var profile = linkedProfile()
        profile.keyLinks += [.init(source: "KeyB", target: FPSKey.cursorAction),
                             .init(source: "Escape", target: FPSKey.cursorAction),
                             .init(source: "Escape", target: "KeyB")]
        try profile.validate()
        XCTAssertEqual(profile.linkedKeys(from: "KeyB"), ["KeyB", "Escape", FPSKey.cursorAction])
        var engine = try FPSInputEngine(profile: profile); _ = engine.start()
        _ = engine.keyDown("KeyW", now: 0); _ = engine.advance(now: 1)
        _ = engine.keyDown("MouseLeft", now: 1)
        engine.mouseMoved(dx: 5, dy: 0, now: 1); _ = engine.advance(now: 1)
        _ = engine.keyDown("KeyB", now: 1.01)
        XCTAssertTrue(engine.cursorMode && engine.captured)
        XCTAssertEqual(Set(engine.state.contacts.map(\.id)), [1, FPSAction.crouch.touchID, FPSAction.reload.touchID])
        XCTAssertTrue(engine.keyDown("KeyB", now: 1.02).isEmpty)
        XCTAssertTrue(engine.cursorMode, "Key repeat and multiple graph paths must not toggle twice")
        _ = engine.keyUp("KeyB", now: 1.03)
        XCTAssertTrue(engine.cursorMode)
        XCTAssertEqual(engine.state.contacts.map(\.id), [1])
        _ = engine.pointerDown(at: .init(x: 0.4, y: 0.5), now: 1.04)
        _ = engine.keyDown("KeyB", now: 1.05)
        XCTAssertFalse(engine.cursorMode)
        XCTAssertEqual(Set(engine.state.contacts.map(\.id)), [1, FPSAction.crouch.touchID, FPSAction.reload.touchID])
        XCTAssertFalse(engine.pressed.contains("MouseLeft"))
        _ = engine.releaseAll()
        XCTAssertTrue(engine.pressed.isEmpty && engine.state.contacts.isEmpty)
        _ = engine.start(); _ = engine.keyDown("KeyB", now: 2)
        XCTAssertTrue(engine.cursorMode, "Release capture must clear all physical-key ownership")
    }

    func testLinkedTapAndSwipeFinishAfterReleaseAndCanRetrigger() throws {
        var profile = FPSProfile()
        profile.customButtons = [.init(name: "B 点按", trigger: "KeyB", point: .init(x: 0.3, y: 0.3)),
                                 .init(name: "Esc 滑动", trigger: "Escape", point: .init(x: 0.5, y: 0.7), behavior: .swipe)]
        profile.customButtons[1].swipe = .init(end: .init(x: 0.5, y: 0.4), duration: 0.1)
        profile.keyLinks = [.init(source: "KeyB", target: "Escape")]
        var engine = try FPSInputEngine(profile: profile); _ = engine.start()
        _ = engine.keyDown("KeyW", now: 0); _ = engine.advance(now: 1)
        _ = engine.keyDown("MouseLeft", now: 1)
        let baseline = engine.state.contacts
        _ = engine.keyDown("KeyB", now: 1.01)
        XCTAssertEqual(engine.state.contacts.count, baseline.count + 2)
        _ = engine.keyUp("KeyB", now: 1.02)
        XCTAssertEqual(engine.state.contacts.count, baseline.count + 2)
        _ = engine.advance(now: 1.09)
        XCTAssertEqual(engine.state.contacts.count, baseline.count + 1)
        _ = engine.advance(now: 1.12)
        XCTAssertTrue(engine.state.contacts.contains { $0.point == profile.customButtons[1].swipe.end })
        _ = engine.advance(now: 1.14)
        XCTAssertEqual(engine.state.contacts, baseline)
        _ = engine.keyDown("KeyB", now: 1.15)
        XCTAssertEqual(engine.state.contacts.count, baseline.count + 2)
        XCTAssertTrue(engine.captured)
    }

    func testKeyLinksCRUDLegacyPersistenceAndValidation() throws {
        let original = FPSProfile()
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        json.removeValue(forKey: "keyLinks")
        var profile = try JSONDecoder().decode(FPSProfile.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(profile, original)
        let first = try profile.addKeyLink(), second = try profile.addKeyLink()
        XCTAssertEqual(profile.keyLinks.map(\.target), ["Escape", FPSKey.cursorAction])
        profile.keyLinks[0].source = "KeyC"; profile.keyLinks[1].enabled = false
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("fps-links-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        try FPSProfileLibrary(profiles: [profile]).save(to: file)
        XCTAssertEqual(try FPSProfileLibrary.load(from: file).profiles[0], profile)
        XCTAssertEqual(profile.linkedKeys(from: "KeyB"), ["KeyB"])
        XCTAssertEqual(profile.linkedKeys(from: "KeyC"), ["KeyC", "Escape"])
        profile.keyLinks.removeAll { $0.id == first || $0.id == second }
        XCTAssertEqual(profile, original)
        for invalid in [FPSKeyLink(source: "F8", target: "Escape"), .init(source: "KeyW", target: "Escape"),
                        .init(source: "KeyB", target: "KeyW"), .init(source: "KeyB", target: "KeyB"),
                        .init(source: FPSKey.cursorAction, target: "KeyB")] {
            profile.keyLinks = [invalid]; XCTAssertThrowsError(try profile.validate())
        }
        profile.keyLinks = [.init(), .init()]; XCTAssertThrowsError(try profile.validate())
        profile.keyLinks = [.init(), .init(source: "KeyC")]; profile.keyLinks[1].id = profile.keyLinks[0].id
        XCTAssertThrowsError(try profile.validate())
        profile.keyLinks = []
        for _ in 0..<FPSProfile.maximumKeyLinks { try profile.addKeyLink() }
        try profile.validate(); XCTAssertThrowsError(try profile.addKeyLink())
    }
}
