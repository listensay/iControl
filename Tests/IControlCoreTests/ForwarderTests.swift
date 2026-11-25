import TestSupport
import Foundation
import CTransport
import Darwin
@testable import IControlCore

final class ForwarderTests: TestCase {
    func testOccupiedPortIsPreservedAndFallbackPortWorks() throws {
        let existingFD = ic_listen_loopback(0)
        XCTAssertGreaterThanOrEqual(existingFD, 0)
        let existing = SocketConnection(descriptor: existingFD)
        defer { existing.close() }
        let port = ic_bound_port(existingFD)
        let server = try FakeMux { _, socket in
            try FakeMux.reply(["Number": 0], to: socket)
            try socket.write(Data("hello".utf8))
        }
        defer { server.stop() }
        let forwarder = try USBForwarder(mux: server.mux, device: FakeMux.device, preferredPort: port)
        defer { forwarder.stop() }
        XCTAssertNotEqual(forwarder.localPort, port)
        let client = try SocketConnection.loopback(port: forwarder.localPort)
        defer { client.close() }
        XCTAssertEqual(try client.read(count: 5), Data("hello".utf8))
        forwarder.stop()
        let originalClient = try SocketConnection.loopback(port: port)
        defer { originalClient.close() }
        try originalClient.write(Data([42]))
        let acceptedFD = ic_accept_timeout(existingFD, 1000)
        let accepted = SocketConnection(descriptor: acceptedFD)
        defer { accepted.close() }
        XCTAssertEqual(try accepted.read(count: 1), Data([42]))
    }

    func testLargeBidirectionalRelayHandlesBackpressureAndHalfClose() throws {
        let server = try FakeMux { _, socket in
            try FakeMux.reply(["Number": 0], to: socket)
            while true {
                guard let bytes = try socket.readSome(timeout: 5000) else { throw ControlError("Timeout") }
                if bytes.isEmpty { return }
                try socket.write(bytes, timeout: 5000)
            }
        }
        defer { server.stop() }
        let forwarder = try USBForwarder(mux: server.mux, device: FakeMux.device, preferredPort: 0)
        defer { forwarder.stop() }
        let client = try SocketConnection.loopback(port: forwarder.localPort)
        defer { client.close() }
        let payload = Data((0..<(2 * 1024 * 1024)).map { UInt8(truncatingIfNeeded: $0 * 17) })
        let written = expectation(description: "write complete")
        DispatchQueue.global().async {
            do { try client.write(payload, timeout: 10000); ic_shutdown_write(client.descriptor) }
            catch { XCTFail(error.localizedDescription) }
            written.fulfill()
        }
        XCTAssertEqual(try client.read(count: payload.count, timeout: 10000), payload)
        wait(for: [written], timeout: 12)
        eventually { forwarder.snapshot().activeClients == 0 && forwarder.snapshot().bytesFromDevice == UInt64(payload.count) }
        XCTAssertEqual(forwarder.snapshot().bytesToDevice, UInt64(payload.count))
    }

    func testStopCancelsAnIdleRelayAndReleasesItsOwner() throws {
        let server = try FakeMux { _, socket in
            try FakeMux.reply(["Number": 0], to: socket)
            _ = try socket.read(count: 1, timeout: 20000)
        }
        defer { server.stop() }
        var forwarder: USBForwarder? = try USBForwarder(mux: server.mux, device: FakeMux.device, preferredPort: 0)
        let client = try SocketConnection.loopback(port: forwarder!.localPort)
        defer { client.close() }
        eventually { forwarder!.snapshot().activeClients == 1 }
        weak var weakForwarder = forwarder
        let start = ProcessInfo.processInfo.systemUptime
        forwarder?.stop(); forwarder = nil
        eventually { weakForwarder == nil }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 2)
        XCTAssertThrowsError(try client.read(count: 1, timeout: 1000))
    }

    func testCancelDoesNotCloseAndRepeatedCloseDoesNotCloseRecycledDescriptor() throws {
        let fd = ic_listen_loopback(0)
        let socket = SocketConnection(descriptor: fd)
        socket.cancel()
        XCTAssertGreaterThanOrEqual(fcntl(fd, F_GETFD), 0)
        socket.close()
        let otherFD = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(otherFD, 0)
        let duplicated = dup2(otherFD, fd)
        XCTAssertEqual(duplicated, fd)
        socket.close()
        XCTAssertGreaterThanOrEqual(fcntl(fd, F_GETFD), 0)
        Darwin.close(fd)
        if otherFD != fd { Darwin.close(otherFD) }
    }
}
