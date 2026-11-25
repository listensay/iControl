import Foundation
import TestSupport
@testable import IControlCore

final class FPSMappingTests: TestCase {
    private func near(_ actual: Double, _ expected: Double) {
        XCTAssertLessThan(abs(actual - expected), 0.000001)
    }

    func testLegacyProfileAndCalibrationPersistence() throws {
        let original = FPSProfile()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        for key in ["swapMouseAxes", "invertX", "touchMapping"] { object.removeValue(forKey: key) }
        let legacy = try JSONDecoder().decode(FPSProfile.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(legacy, original)
        var profile = legacy
        profile.swapMouseAxes = true; profile.invertX = true; profile.touchMapping.rotation = 3
        profile.touchMapping.mirrorX = true; profile.touchMapping.offsetX = 0.01; profile.touchMapping.offsetY = -0.02
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fps-mapping-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try FPSProfileLibrary(profiles: [profile]).save(to: url)
        XCTAssertEqual(try FPSProfileLibrary.load(from: url).profiles[0], profile)
    }

    func testCalibratedTouchPositionsAndBounds() throws {
        let point = FPSPoint(x: 0.2, y: 0.3)
        let expected = [FPSPoint(x: 0.2, y: 0.3), .init(x: 0.3, y: 0.8),
                        .init(x: 0.8, y: 0.7), .init(x: 0.7, y: 0.2)]
        for rotation in 0...3 {
            var mapping = FPSCoordinateMapping(); mapping.rotation = rotation; try mapping.validate()
            near(mapping.apply(point).x, expected[rotation].x); near(mapping.apply(point).y, expected[rotation].y)
        }
        var mapping = FPSCoordinateMapping()
        mapping.offsetX = 0.1; mapping.offsetY = -0.1; mapping.rotation = 1
        mapping.mirrorX = true; mapping.mirrorY = true
        let corrected = mapping.apply(point); near(corrected.x, 0.8); near(corrected.y, 0.3)
        XCTAssertTrue(mapping.apply(.init(x: 1, y: 0)).isValid)
        mapping.rotation = 4; XCTAssertThrowsError(try mapping.validate())
        mapping.rotation = 0; mapping.offsetX = .nan; XCTAssertThrowsError(try mapping.validate())
        mapping.offsetX = 0; mapping.offsetY = 0.26; XCTAssertThrowsError(try mapping.validate())
    }

    func testMouseAxesCanBeCorrectedIndependentlyOfTouchPositions() throws {
        for swap in [false, true] {
            for inverted in [false, true] {
                for horizontal in [false, true] {
                    var profile = FPSProfile(); profile.swapMouseAxes = swap
                    profile.invertX = inverted; profile.invertY = inverted
                    var engine = try FPSInputEngine(profile: profile); engine.setAspect(2); _ = engine.start()
                    engine.mouseMoved(dx: horizontal ? 5 : 0, dy: horizontal ? 0 : 5, now: 1)
                    _ = engine.advance(now: 1); _ = engine.advance(now: 1.01)
                    let point = try XCTUnwrap(engine.state.contacts.first(where: { $0.id == 2 })?.point)
                    let movesX = horizontal != swap, sign = inverted ? -1.0 : 1.0
                    near(point.x - profile.look.x, movesX ? 0.006 * sign : 0)
                    near(point.y - profile.look.y, movesX ? 0 : 0.012 * sign)
                    _ = engine.keyDown("MouseLeft", now: 1.02)
                    XCTAssertEqual(engine.state.contacts.first(where: { $0.id == FPSAction.fire.touchID })?.point,
                                   profile.bindings[0].point, "Mouse-axis options must not move action targets")
                }
            }
        }
    }

    func testEverySelectableKeyAndEveryActionCanProduceAContact() throws {
        let nativeKeys = Set(FPSKey.macKeyCodes.values)
            .union(["Shift", "Control", "Option"]).union((0...4).compactMap { FPSKey.mouseButton($0) })
        XCTAssertTrue(Set(FPSKey.choices).isSubset(of: nativeKeys), "Every displayed choice must have a capture path")
        for key in FPSKey.choices {
            var profile = FPSProfile()
            for index in profile.bindings.indices { profile.bindings[index].enabled = false }
            profile.bindings[0].enabled = true; profile.bindings[0].trigger = key
            var engine = try FPSInputEngine(profile: profile); _ = engine.start()
            _ = engine.keyDown(key, now: 1)
            XCTAssertEqual(engine.state.contacts.map(\.id), [FPSAction.fire.touchID], "Failed key: \(key)")
            _ = engine.keyUp(key, now: 1.01); XCTAssertTrue(engine.state.contacts.isEmpty)
        }
        var profile = FPSProfile(); profile.touchMapping.rotation = 2
        for index in profile.bindings.indices { profile.bindings[index].enabled = true }
        for binding in profile.bindings {
            var engine = try FPSInputEngine(profile: profile); _ = engine.start()
            _ = engine.keyDown(binding.trigger, now: 1)
            let expected = profile.touchMapping.apply(binding.point)
            XCTAssertEqual(engine.state.contacts, [FPSContact(id: binding.action.touchID, point: expected)])
            let preview = try FPSInputPreview.action(binding.action, profile: profile)
            XCTAssertEqual(preview[0].contacts, engine.state.contacts)
            XCTAssertTrue(preview.last?.contacts.isEmpty == true)
            _ = engine.keyUp(binding.trigger, now: 1.01); _ = engine.advance(now: 1.2)
            XCTAssertTrue(engine.state.contacts.isEmpty)
        }
        profile.bindings[0].enabled = false
        XCTAssertThrowsError(try FPSInputPreview.action(.fire, profile: profile))
    }
}
