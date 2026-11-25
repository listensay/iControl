import Foundation
import TestSupport
@testable import IControlCore

final class FPSCustomButtonTests: TestCase {
    func testLegacyProfilesAndCustomButtonsSurviveReload() throws {
        let original = FPSProfile()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        object.removeValue(forKey: "customButtons")
        var profile = try JSONDecoder().decode(FPSProfile.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(profile, original)
        let id = try profile.addCustomButton()
        var button = try XCTUnwrap(profile.buttons.first { $0.id == id })
        button.title = "投掷手雷"; button.trigger = "KeyG"; button.behavior = .hold
        button.point = .init(x: 0.24, y: 0.69); button.size = 0.14
        profile.updateButton(button); try profile.validate()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fps-custom-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try FPSProfileLibrary(profiles: [profile], selectionByDevice: ["test-ipad": profile.id]).save(to: url)
        let saved = try FPSProfileLibrary.load(from: url)
        XCTAssertEqual(saved.profiles[0], profile)
        XCTAssertEqual(saved.profiles[0].customButtons[0].id, id)
        XCTAssertEqual(saved.selectionByDevice["test-ipad"], profile.id)
        XCTAssertEqual(profile.bindings, original.bindings, "Adding a button must preserve existing bindings")
        let preview = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(profile.viewerJSON(editing: true).utf8)) as? [String: Any])
        let marker = try XCTUnwrap((preview["bindings"] as? [[String: Any]])?.first { $0["id"] as? String == id })
        XCTAssertEqual(marker["title"] as? String, "投掷手雷")
        XCTAssertEqual(marker["label"] as? String, "G"); XCTAssertEqual(marker["x"] as? Double, 0.24)
        profile.setPoint(.init(x: 0.8, y: 0.2), target: id)
        XCTAssertEqual(profile.customButtons[0].point, .init(x: 0.8, y: 0.2))
    }

    func testAddDeleteDragUndoAndConflicts() throws {
        let original = FPSProfile()
        var editor = FPSLayoutEditor(profile: original)
        try editor.addCustomButton()
        let id = editor.selection, added = editor.draft
        XCTAssertEqual(added.customButtons.count, 1)
        XCTAssertEqual(added.customButtons[0].id, id)
        XCTAssertTrue(editor.hasChanges)
        editor.undo(); XCTAssertEqual(editor.draft, original); XCTAssertEqual(editor.selection, "joystick")
        editor.redo(); XCTAssertEqual(editor.draft, added)
        editor.select(id); editor.beginInteraction()
        for step in 1...20 { try editor.geometry(target: id, point: .init(x: 0.36 + Double(step) / 100, y: 0.61), size: 0.12) }
        editor.endInteraction(); let moved = editor.draft
        editor.undo(); XCTAssertEqual(editor.draft, added)
        editor.redo(); XCTAssertEqual(editor.draft, moved)
        editor.beginInteraction(); try editor.geometry(target: id, size: 0.20)
        editor.endInteraction(cancelled: true); XCTAssertEqual(editor.draft, moved)
        XCTAssertThrowsError(try editor.edit { $0.customButtons[0].trigger = "MouseLeft" })
        XCTAssertEqual(editor.draft, moved)
        try editor.removeCustomButton(id); XCTAssertTrue(editor.draft.customButtons.isEmpty)
        XCTAssertEqual(editor.selection, "joystick")
        editor.undo(); XCTAssertEqual(editor.draft, moved)
        editor.select(id); try editor.reset(); XCTAssertEqual(editor.draft, original)
        editor.undo(); XCTAssertEqual(editor.draft, moved)
        XCTAssertEqual(original.customButtons.count, 0)
    }

    func testCustomValidationLimitsAndUnoccupiedKeys() throws {
        var profile = FPSProfile()
        for i in profile.bindings.indices { profile.bindings[i].enabled = false }
        for _ in 0..<FPSProfile.maximumCustomButtons { try profile.addCustomButton() }
        try profile.validate()
        XCTAssertEqual(Set(profile.customButtons.map(\.trigger)).count, FPSProfile.maximumCustomButtons)
        XCTAssertEqual(Set(profile.customButtons.map(\.id)).count, FPSProfile.maximumCustomButtons)
        XCTAssertThrowsError(try profile.addCustomButton())
        var invalid = profile; invalid.customButtons[0].trigger = "KeyW"
        XCTAssertThrowsError(try invalid.validate())
        invalid = profile; invalid.customButtons[0].name = "  "
        XCTAssertThrowsError(try invalid.validate())
        invalid = profile; invalid.customButtons[1].id = invalid.customButtons[0].id
        XCTAssertThrowsError(try invalid.validate())
        invalid = profile; invalid.customButtons[0].point.x = .nan
        XCTAssertThrowsError(try invalid.validate())
        invalid = profile; invalid.customButtons[0].size = 0.4
        XCTAssertThrowsError(try invalid.validate())
        invalid = profile; invalid.customButtons[1].trigger = invalid.customButtons[0].trigger
        XCTAssertThrowsError(try invalid.validate())
        invalid.customButtons[1].enabled = false; try invalid.validate()
    }

    func testCustomAndPresetContactLeasesRemainStable() throws {
        var profile = FPSProfile()
        profile.customButtons = [.init(name: "手雷", trigger: "KeyG", point: .init(x: 0.2, y: 0.3), behavior: .hold)]
        profile.bindings[13].enabled = true; profile.bindings[13].behavior = .hold
        var engine = try FPSInputEngine(profile: profile); _ = engine.start()
        _ = engine.keyDown("KeyG", now: 1)
        let custom = try XCTUnwrap(engine.state.contacts.first)
        XCTAssertEqual(custom.id, 16)
        _ = engine.keyDown("Tab", now: 1.01)
        let backpack = try XCTUnwrap(engine.state.contacts.first { $0.point == profile.bindings[13].point })
        XCTAssertNotEqual(backpack.id, custom.id)
        _ = engine.keyDown("MouseLeft", now: 1.02)
        _ = engine.keyDown("KeyW", now: 1.03)
        engine.mouseMoved(dx: 5, dy: 0, now: 1.04); _ = engine.advance(now: 1.05)
        XCTAssertEqual(engine.state.contacts.first { $0.point == custom.point }?.id, custom.id)
        XCTAssertEqual(Set(engine.state.contacts.map(\.id)).count, 5)
        XCTAssertTrue(engine.state.contacts.allSatisfy { $0.id <= FPSWire.maximumIdentifier })
        _ = engine.keyUp("KeyG", now: 1.06)
        XCTAssertFalse(engine.state.contacts.contains { $0.id == custom.id })
        XCTAssertEqual(engine.state.contacts.first { $0.point == backpack.point }?.id, backpack.id)
        XCTAssertTrue(engine.state.contacts.contains { $0.id == FPSAction.fire.touchID })
        XCTAssertTrue(engine.releaseAll().contacts.isEmpty)
    }

    func testTapRetriggerPreviewAndEveryCustomKey() throws {
        for key in FPSKey.choices {
            var profile = FPSProfile()
            for i in profile.bindings.indices { profile.bindings[i].enabled = false }
            profile.customButtons = [.init(name: "测试", trigger: key, point: .init(x: 0.3, y: 0.7))]
            profile.touchMapping.rotation = 1
            var engine = try FPSInputEngine(profile: profile); _ = engine.start()
            _ = engine.keyDown(key, now: 1)
            XCTAssertEqual(engine.state.contacts.count, 1, "Custom binding must trigger for \(key)")
            let contact = try XCTUnwrap(engine.state.contacts.first)
            XCTAssertEqual(contact.point, profile.touchMapping.apply(profile.customButtons[0].point))
            _ = engine.keyUp(key, now: 1.01)
            let retrigger = engine.keyDown(key, now: 1.02)
            XCTAssertEqual(retrigger.count, 2)
            XCTAssertTrue(retrigger[0].contacts.isEmpty)
            XCTAssertEqual(retrigger[1].contacts.first?.id, contact.id)
            _ = engine.advance(now: 1.10); XCTAssertTrue(engine.state.contacts.isEmpty)
            let preview = try FPSInputPreview.button(profile.customButtons[0].id, profile: profile)
            XCTAssertEqual(preview[0].contacts, [contact]); XCTAssertTrue(preview.last?.contacts.isEmpty == true)
        }
    }

    func testCustomContactLimitKeepsHeldButtonsAndAdmitsWaitingButtons() throws {
        var profile = FPSProfile()
        for i in profile.bindings.indices { profile.bindings[i].enabled = false }
        for _ in 0..<FPSProfile.maximumCustomButtons { try profile.addCustomButton() }
        for i in profile.customButtons.indices {
            profile.customButtons[i].behavior = .hold
            profile.customButtons[i].point = .init(x: Double(i + 1) / 40, y: 0.2)
        }
        var engine = try FPSInputEngine(profile: profile); _ = engine.start()
        _ = engine.keyDown("KeyW", now: 1); engine.mouseMoved(dx: 1, dy: 1, now: 1)
        for button in profile.customButtons {
            _ = engine.keyDown(button.trigger, now: 1.01)
            _ = try FPSWire.state(engine.state, sequence: 1)
        }
        XCTAssertEqual(engine.state.contacts.count, FPSWire.maximumContacts)
        let held = engine.state.contacts.filter { $0.id > 2 }
        XCTAssertEqual(held.count, 8)
        for _ in 0..<10 { _ = engine.advance(now: 1.02) }
        XCTAssertEqual(engine.state.contacts.filter { $0.id > 2 }, held)
        _ = engine.keyUp(profile.customButtons[0].trigger, now: 1.03)
        XCTAssertEqual(engine.state.contacts.count, 10)
        XCTAssertFalse(engine.state.contacts.contains { $0.point == profile.customButtons[0].point })
        XCTAssertTrue(engine.state.contacts.contains { $0.point == profile.customButtons[8].point })
        for contact in held where contact.point != profile.customButtons[0].point {
            XCTAssertTrue(engine.state.contacts.contains(contact), "Already held contacts must keep their IDs at capacity")
        }
        XCTAssertTrue(engine.releaseAll().contacts.isEmpty)
    }

    func testNativeDaemonAcceptsCustomButtonsWithoutChangingProtocol() throws {
        let daemon = try NativeFPSFixture(), socket = try daemon.connect()
        defer { socket.close(); daemon.stop() }
        var profile = FPSProfile(); profile.orientation = .portrait
        profile.customButtons = [.init(name: "手雷", trigger: "KeyG", point: .init(x: 0.2, y: 0.3)),
                                 .init(name: "技能", trigger: "KeyT", point: .init(x: 0.7, y: 0.4), behavior: .hold)]
        var engine = try FPSInputEngine(profile: profile); _ = engine.start()
        var sequence: UInt32 = 0
        func send(_ frames: [FPSState]) throws {
            for frame in frames { sequence += 1; _ = try daemon.send(frame, sequence: sequence, socket: socket) }
        }
        try send(engine.keyDown("KeyG", now: 1))
        let grenade = try XCTUnwrap(engine.state.contacts.first)
        XCTAssertEqual(daemon.frames.last?.edges[Int(grenade.id)]?.kind, "down")
        // The first tap expires in the same tick that a different button starts.
        // It must receive an up edge rather than turning into the new button.
        try send(engine.keyDown("KeyT", now: 1.08))
        let skill = try XCTUnwrap(engine.state.contacts.first)
        XCTAssertNotEqual(skill.id, grenade.id)
        XCTAssertEqual(daemon.frames.last?.edges[Int(grenade.id)]?.kind, "up")
        XCTAssertEqual(daemon.frames.last?.edges[Int(skill.id)]?.kind, "down")
        try send(engine.keyDown("MouseLeft", now: 1.09))
        XCTAssertEqual(daemon.frames.last?.active, 2)
        XCTAssertTrue(daemon.frames.last?.edges[Int(skill.id)] == nil)
        try send(engine.keyUp("KeyT", now: 1.10))
        XCTAssertEqual(daemon.frames.last?.edges[Int(skill.id)]?.kind, "up")
        XCTAssertTrue(daemon.frames.last?.edges[Int(FPSAction.fire.touchID)] == nil)
        sequence += 1; _ = try daemon.send(engine.releaseAll(), sequence: sequence, socket: socket)
        XCTAssertEqual(daemon.frames.last?.active, 0)
    }
}
