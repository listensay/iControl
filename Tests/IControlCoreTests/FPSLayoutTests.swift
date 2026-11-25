import Foundation
import TestSupport
@testable import IControlCore

final class FPSLayoutTests: TestCase {
    private func near(_ actual: Double, _ expected: Double) { XCTAssertLessThan(abs(actual - expected), 0.000001) }

    func testLegacySizesAndCustomSizePersistence() throws {
        let original = FPSProfile()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        var bindings = try XCTUnwrap(object["bindings"] as? [[String: Any]])
        for index in bindings.indices { bindings[index].removeValue(forKey: "size") }
        object["bindings"] = bindings
        let legacy = try JSONDecoder().decode(FPSProfile.self, from: JSONSerialization.data(withJSONObject: object))
        try legacy.validate()
        XCTAssertEqual(legacy, original, "Existing layouts must load without losing positions or bindings")
        var custom = legacy; custom.bindings[0].size = 0.16
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fps-layout-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try FPSProfileLibrary(profiles: [custom]).save(to: url)
        XCTAssertEqual(try FPSProfileLibrary.load(from: url).profiles[0], custom)
        custom.bindings[0].size = .nan
        XCTAssertThrowsError(try custom.validate())
        custom.bindings[0].size = 0.3
        XCTAssertThrowsError(try custom.validate())
    }

    func testGeometryClampsToScreenAndRejectsInvalidValues() throws {
        var editor = FPSLayoutEditor(profile: FPSProfile())
        try editor.geometry(target: "joystick", point: .init(x: 0, y: 0), radius: 0.18, aspect: 2)
        near(editor.draft.joystick.x, 0.09); near(editor.draft.joystick.y, 0.18)
        try editor.geometry(target: "joystick", point: .init(x: 1, y: 1), aspect: 0.75)
        near(editor.draft.joystick.x, 0.76); near(editor.draft.joystick.y, 0.82)
        try editor.geometry(target: "look", point: .init(x: 1, y: 1), width: 2, height: 2)
        near(editor.draft.lookWidth, 0.65); near(editor.draft.lookHeight, 0.80)
        near(editor.draft.look.x, 0.675); near(editor.draft.look.y, 0.60)
        try editor.geometry(target: "fire", point: .init(x: 1, y: 0), size: 20)
        near(editor.draft.bindings[0].size, 0.22)
        let before = editor.draft
        XCTAssertThrowsError(try editor.geometry(target: "look", width: .infinity))
        XCTAssertThrowsError(try editor.geometry(target: "fire", point: .init(x: .nan, y: 0)))
        try editor.geometry(target: "unknown", point: .init(x: 0.3, y: 0.3))
        XCTAssertEqual(editor.draft, before)
        try editor.draft.validate()
    }

    func testDragIsOneUndoStepAndCancelledDragIsDiscarded() throws {
        let original = FPSProfile()
        var editor = FPSLayoutEditor(profile: original)
        editor.beginInteraction()
        for step in 1...60 {
            try editor.geometry(target: "fire", point: .init(x: 0.9 - Double(step) / 200, y: 0.5))
        }
        editor.endInteraction()
        let moved = editor.draft
        XCTAssertNotEqual(moved, original); XCTAssertTrue(editor.hasChanges)
        editor.undo(); XCTAssertEqual(editor.draft, original); XCTAssertFalse(editor.canUndo)
        XCTAssertTrue(editor.canRedo)
        editor.redo(); XCTAssertEqual(editor.draft, moved)
        editor.beginInteraction()
        try editor.geometry(target: "fire", size: 0.18)
        editor.endInteraction(cancelled: true)
        XCTAssertEqual(editor.draft, moved)
        editor.undo(); XCTAssertEqual(editor.draft, original)
        editor.redo(); XCTAssertEqual(editor.draft, moved)
        XCTAssertEqual(original.bindings[0].point.x, 0.91, "A draft must not modify the saved profile")
    }

    func testResetAndRejectedBindingPreserveUndoHistory() throws {
        var profile = FPSProfile(); profile.name = "自定义游戏"
        var editor = FPSLayoutEditor(profile: profile, selection: "map")
        XCTAssertEqual(editor.selection, "map", "Disabled actions can be arranged before enabling them")
        try editor.geometry(target: "look", width: 0.2)
        let custom = editor.draft
        try editor.reset(); XCTAssertEqual(editor.draft, profile)
        editor.undo(); XCTAssertEqual(editor.draft, custom)
        XCTAssertThrowsError(try editor.edit { $0.bindings[1].trigger = "MouseLeft" })
        XCTAssertEqual(editor.draft, custom); XCTAssertTrue(editor.canRedo)
        try editor.geometry(target: "jump", size: 0.12)
        XCTAssertFalse(editor.canRedo, "A fresh edit must discard the old redo branch")
        XCTAssertEqual(editor.draft.id, profile.id); XCTAssertEqual(editor.draft.name, profile.name)
    }

    func testPreviewShowsDisabledBindingsAndEditedPointsDriveInput() throws {
        var editor = FPSLayoutEditor(profile: FPSProfile(), selection: "fire")
        try editor.geometry(target: "fire", point: .init(x: 0.73, y: 0.29), size: 0.14)
        let json = try editor.draft.viewerJSON(editing: true, selection: "map", session: "test-session", sequence: 12)
        let preview = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let bindings = try XCTUnwrap(preview["bindings"] as? [[String: Any]])
        XCTAssertEqual(bindings.count, FPSAction.allCases.count)
        near(try XCTUnwrap(bindings.first { $0["id"] as? String == "fire" }?["size"] as? Double), 0.14)
        let metadata = try XCTUnwrap(preview["editor"] as? [String: Any])
        XCTAssertEqual(metadata["selected"] as? String, "map"); XCTAssertEqual(metadata["sequence"] as? Int, 12)
        let normalJSON = try editor.draft.viewerJSON()
        let normal = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(normalJSON.utf8)) as? [String: Any])
        XCTAssertEqual((normal["bindings"] as? [[String: Any]])?.count, editor.draft.bindings.filter(\.enabled).count)
        XCTAssertTrue(normal["editor"] == nil)
        var engine = try FPSInputEngine(profile: editor.draft); _ = engine.start()
        _ = engine.keyDown("MouseLeft", now: 1)
        XCTAssertEqual(engine.state.contacts.first(where: { $0.id == FPSAction.fire.touchID })?.point,
                       FPSPoint(x: 0.73, y: 0.29))
    }
}
