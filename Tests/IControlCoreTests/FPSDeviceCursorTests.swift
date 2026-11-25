import Foundation
import Darwin
import TestSupport
@testable import IControlCore

final class FPSDeviceCursorTests {
    private let held = FPSState(contacts: [.init(id: 1, point: .init(x: 0.2, y: 0.7))])
    private func send(_ cursor: FPSDeviceCursor?, sequence: UInt32, to socket: SocketConnection) throws -> Data {
        try socket.write(FPSWire.cursor(cursor, sequence: sequence)); return try socket.read(count: 8)
    }
    private func cursorFields(_ daemon: NativeFPSFixture) throws -> [String: String] {
        let text = try String(contentsOf: daemon.eventLog)
        let line = try XCTUnwrap(text.split(separator: "\n").last { $0.hasPrefix("cursor ") })
        return Dictionary(uniqueKeysWithValues: line.split(separator: " ").dropFirst().compactMap { item in
            let pair = item.split(separator: "=", maxSplits: 1)
            return pair.count == 2 ? (String(pair[0]), String(pair[1])) : nil
        })
    }
    func testCursorWireCoordinatesReservedBytesAndTouchSeparation() throws {
        let original = FPSDeviceCursor(point: .init(x: 0.3, y: 0.8), orientation: .counterclockwise)
        let packet = try FPSWire.cursor(original, sequence: 42)
        let decoded = try XCTUnwrap(FPSWire.decodeCursor(packet))
        XCTAssertEqual(packet.count, 16); XCTAssertEqual(packet.uint32BE(at: 4), 42)
        XCTAssertEqual(decoded.orientation, original.orientation)
        XCTAssertLessThan(abs(decoded.point.x - original.point.x), 0.00002)
        XCTAssertLessThan(abs(decoded.point.y - original.point.y), 0.00002)
        XCTAssertTrue(try FPSWire.decodeCursor(FPSWire.cursor(nil, sequence: 43)) == nil)
        XCTAssertThrowsError(try FPSWire.decode(packet))
        for offset in [3, 8, 9, 14, 15] {
            var bad = packet; bad[offset] = 1; XCTAssertThrowsError(try FPSWire.decodeCursor(bad))
        }
        XCTAssertThrowsError(try FPSWire.decodeCursor(Data(packet.dropLast())))
        XCTAssertThrowsError(try FPSWire.cursor(.init(point: .init(x: .nan, y: 0)), sequence: 1))
    }
    func testNativeCursorHoverRotationHideAndRetainedMovement() throws {
        let daemon = try NativeFPSFixture(), socket = try daemon.connect()
        defer { socket.close(); daemon.stop() }
        _ = try daemon.send(held, sequence: 1, socket: socket)
        let before = daemon.frames.count
        let point = FPSPoint(x: 0.2, y: 0.7)
        let expected: [FPSPoint] = [point, .init(x: 0.7, y: 0.8), .init(x: 0.8, y: 0.3), .init(x: 0.3, y: 0.2)]
        for rotation in 0..<4 {
            let cursor = FPSDeviceCursor(point: point, orientation: try XCTUnwrap(FPSOrientation(rawValue: rotation)))
            let ack = try send(cursor, sequence: UInt32(rotation + 2), to: socket)
            XCTAssertEqual(ack[1], 1); XCTAssertEqual(ack[3], 3)
            let fields = try cursorFields(daemon)
            XCTAssertEqual(fields["visible"], "1")
            XCTAssertLessThan(abs(try XCTUnwrap(Double(fields["x"]!)) - expected[rotation].x), 0.00003)
            XCTAssertLessThan(abs(try XCTUnwrap(Double(fields["y"]!)) - expected[rotation].y), 0.00003)
        }
        let hidden = try send(nil, sequence: 6, to: socket)
        XCTAssertEqual(hidden[1], 1); XCTAssertEqual(hidden[3], 1)
        XCTAssertEqual(daemon.frames.count, before, "Showing/moving/hiding the cursor must retain the movement finger")
        _ = try send(.init(point: point), sequence: 7, to: socket)
        try socket.write(FPSWire.control(2, sequence: 8))
        XCTAssertEqual(try socket.read(count: 8)[3], 1)
        XCTAssertEqual(daemon.frames.last?.active, 0)
        XCTAssertEqual(try cursorFields(daemon)["visible"], "0")
    }
    func testRendererFailureAndUnavailableCursorKeepTouchServiceWorking() throws {
        for available in [false, true] {
            let daemon = try NativeFPSFixture(cursorAvailable: available), socket = try daemon.connect()
            defer { socket.close(); daemon.stop() }
            _ = try daemon.send(held, sequence: 1, socket: socket)
            if available {
                let text = try String(contentsOf: daemon.output)
                let line = try XCTUnwrap(text.split(separator: "\n").first { $0.hasPrefix("FPS_CURSOR_RENDERER pid=") })
                let pid = try XCTUnwrap(Int32(line.split(separator: "=").last!))
                _ = Darwin.kill(pid, SIGKILL)
            }
            let ack = try send(.init(point: .init(x: 0.5, y: 0.5)), sequence: 2, to: socket)
            XCTAssertEqual(ack[1], 1); XCTAssertEqual(ack[3], 0)
            XCTAssertEqual(try daemon.send(FPSState(), sequence: 3, socket: socket)[1], 0)
            XCTAssertEqual(try daemon.send(held, sequence: 4, socket: socket)[1], 1)
        }
    }
    func testCursorWatchdogAndRendererParentStallHidePointer() throws {
        let daemon = try NativeFPSFixture(), socket = try daemon.connect()
        defer { socket.close(); daemon.stop() }
        _ = try send(.init(point: .init(x: 0.5, y: 0.5)), sequence: 1, to: socket)
        _ = Darwin.kill(daemon.process.processIdentifier, SIGSTOP)
        XCTAssertTrue(daemon.waitUntil(1) {
            ((try? String(contentsOf: daemon.output)) ?? "").contains("FPS_CURSOR_RENDERER visible=0")
        }, "Renderer must hide even when the touch daemon is stopped")
        _ = Darwin.kill(daemon.process.processIdentifier, SIGCONT)
        XCTAssertTrue(daemon.waitUntil(1) { (try? self.cursorFields(daemon)["visible"]) == "0" })
    }
    func testTouchOnlyDaemonKeepsMacClickModeWithoutCursorOpcode() throws {
        let observed = DispatchSemaphore(value: 0)
        let fixture = try LoopbackFixture { socket in
            try socket.write(FPSWire.touchOnlyGreeting); _ = try socket.read(count: 32); try socket.write(FPSWire.ready)
            while true {
                let header = try socket.read(count: 8)
                XCTAssertNotEqual(header[0], 4)
                let body = try socket.read(count: Int(header[1]) * 8)
                let decoded = try FPSWire.decode(header + body)
                var ack = Data([128, header[1], 0, 0]); ack.appendBE(decoded.sequence); try socket.write(ack)
                if header[0] == 1 { observed.signal() }
            }
        }
        defer { fixture.stop() }
        let link = try FPSUSBLink(socket: .loopback(port: fixture.port), token: String(repeating: "a5", count: 32))
        defer { link.stop() }
        XCTAssertFalse(link.supportsDeviceCursor)
        link.setDeviceCursor(.init(point: .init(x: 0.5, y: 0.5))); link.send(held)
        XCTAssertEqual(observed.wait(timeout: .now() + 1), .success)
    }
}
