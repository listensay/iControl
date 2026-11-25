import TestSupport
import Foundation
@testable import IControlCore

final class WebSocketTests: TestCase {
    private func request(origin: String = "http://127.0.0.1:18080", path: String = "/vnc") -> Data {
        Data("GET \(path) HTTP/1.1\r\nHost: 127.0.0.1:18080\r\nConnection: keep-alive, Upgrade\r\nUpgrade: websocket\r\nOrigin: \(origin)\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Protocol: binary\r\n\r\n".utf8)
    }
    func testRFCHandshakeAndOriginValidation() throws {
        let parsed = try HTTPRequest.parse(request())
        let response = try parsed.webSocketResponse(expectedOrigin: "http://127.0.0.1:18080")
        XCTAssertTrue(String(decoding: response, as: UTF8.self).contains("Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo="))
        XCTAssertThrowsError(try HTTPRequest.parse(request(origin: "https://another-site.example")).webSocketResponse(expectedOrigin: "http://127.0.0.1:18080"))
        XCTAssertThrowsError(try HTTPRequest.parse(Data("GET / HTTP/1.1\r\nHost: one\r\nHost: two\r\n\r\n".utf8)))
        XCTAssertThrowsError(try HTTPRequest.parse(Data("GET / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)))
    }

    func testMaskedFramesHandleAllLengthFormsAndRejectUnmaskedFrames() throws {
        for size in [0, 125, 126, 65535, 65536] {
            let payload = Data((0..<size).map { UInt8(truncatingIfNeeded: $0) })
            let server = try LoopbackFixture { socket in try socket.write(maskedFrame(payload), timeout: 5000) }
            defer { server.stop() }
            let socket = try SocketConnection.loopback(port: server.port)
            defer { socket.close() }
            let frame = try WebSocketFrame.readClient(from: socket)
            XCTAssertEqual(frame.payload, payload)
            XCTAssertTrue(frame.isFinal)
        }
        let unmasked = try LoopbackFixture { socket in try socket.write(Data([130, 0])) }
        defer { unmasked.stop() }
        let socket = try SocketConnection.loopback(port: unmasked.port)
        defer { socket.close() }
        XCTAssertThrowsError(try WebSocketFrame.readClient(from: socket))
    }

    func testOversizedAndFragmentedControlFramesAreRejectedWithoutReadingPayload() throws {
        for header in [Data([130, 255, 0, 0, 0, 0, 1, 0, 0, 0]), Data([9, 128])] {
            let server = try LoopbackFixture { socket in try socket.write(header) }
            defer { server.stop() }
            let socket = try SocketConnection.loopback(port: server.port)
            defer { socket.close() }
            XCTAssertThrowsError(try WebSocketFrame.readClient(from: socket))
        }
    }

    func testLocalServerRequiresTokenAndBlocksDirectoryTraversal() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("local viewer".utf8).write(to: directory.appendingPathComponent("index.html"))
        let server = try LocalViewerServer(resources: directory, targetPort: 1, preferredPort: 0)
        defer { server.stop() }
        func fetch(_ path: String) throws -> String {
            let socket = try SocketConnection.loopback(port: server.port)
            defer { socket.close() }
            try socket.write(Data("GET \(path) HTTP/1.1\r\nHost: 127.0.0.1:\(server.port)\r\n\r\n".utf8))
            return try readHTTPHeader(socket)
        }
        XCTAssertTrue(try fetch(server.url.path).contains("200 OK"))
        XCTAssertTrue(try fetch("/index.html").contains("403 Forbidden"))
        let prefix = server.url.deletingLastPathComponent().path
        XCTAssertTrue(try fetch(prefix + "/%2e%2e/secret.html").contains("403 Forbidden"))
    }

    func testBinaryBridgeFragmentationPingIdleAndStop() throws {
        let echo = try LoopbackFixture { socket in
            while true {
                guard let bytes = try socket.readSome(timeout: 5000) else { throw ControlError("timeout") }
                if bytes.isEmpty { return }
                try socket.write(bytes)
            }
        }
        defer { echo.stop() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = try LocalViewerServer(resources: directory, targetPort: echo.port, preferredPort: 0)
        defer { server.stop() }
        let socket = try SocketConnection.loopback(port: server.port)
        defer { socket.close() }
        let path = server.url.deletingLastPathComponent().path + "/vnc"
        let header = String(decoding: request(origin: "http://127.0.0.1:\(server.port)", path: path), as: UTF8.self)
            .replacingOccurrences(of: "Host: 127.0.0.1:18080", with: "Host: 127.0.0.1:\(server.port)")
        try socket.write(Data(header.utf8))
        XCTAssertTrue(try readHTTPHeader(socket).contains("101 Switching Protocols"))
        try socket.write(maskedFrame(Data("abc".utf8), final: false))
        try socket.write(maskedFrame(Data("def".utf8), opcode: 0))
        var echoed = Data()
        while echoed.count < 6 {
            let frame = try readServerFrame(socket)
            XCTAssertEqual(frame.0, 2); echoed.append(frame.1)
        }
        XCTAssertEqual(echoed, Data("abcdef".utf8))
        Thread.sleep(forTimeInterval: 1.25)
        try socket.write(maskedFrame(Data("alive".utf8), opcode: 9))
        let pong = try readServerFrame(socket)
        XCTAssertEqual(pong.0, 10); XCTAssertEqual(pong.1, Data("alive".utf8))
        server.stop()
        eventually { server.activeSessionCount() == 0 }
        XCTAssertThrowsError(try socket.read(count: 1, timeout: 1000))
    }
}
