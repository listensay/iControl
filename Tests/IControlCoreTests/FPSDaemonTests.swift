import Foundation
import Darwin
import TestSupport
@testable import IControlCore

struct NativeFrame {
    let sequence: UInt32, active: Int, rotation: Int, canceled: Bool
    let ids: Set<Int>
    let edges: [Int: (kind: String, x: Double, y: Double)]
    init?(_ line: String) {
        var fields: [String: String] = [:]
        for item in line.split(separator: " ").dropFirst() {
            let pair = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if pair.count == 2 { fields[String(pair[0])] = String(pair[1]) }
        }
        guard let sequence = UInt32(fields["seq"] ?? ""), let active = Int(fields["active"] ?? ""),
              let rotation = Int(fields["rotation"] ?? "") else { return nil }
        self.sequence = sequence; self.active = active; self.rotation = rotation
        canceled = fields["canceled"] == "1"
        ids = Set((fields["ids"] ?? "").split(separator: ",").compactMap { Int($0) })
        var edges: [Int: (String, Double, Double)] = [:]
        for edge in (fields["edges"] ?? "").split(separator: ",") {
            let values = edge.split(separator: ":")
            if values.count == 4, let id = Int(values[0]), let x = Double(values[2]), let y = Double(values[3]) {
                edges[id] = (String(values[1]), x, y)
            }
        }
        self.edges = edges
    }
}

/// Runs the same compiled networking and state-transition code as the arm64
/// daemon, replacing only HID dispatch with a flushed event log.
final class NativeFPSFixture {
    static var executable: URL {
        if let path = ProcessInfo.processInfo.environment["ICONTROL_FPSD_SIMULATOR"] { return URL(fileURLWithPath: path) }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("work/fps-daemon-simulator")
    }
    let root: URL, tokenFile: URL, eventLog: URL, output: URL
    let process = Process()
    let token = String(repeating: "a5", count: 32)
    private let outputHandle: FileHandle
    private(set) var port: UInt16 = 0

    init(interfaceOrientation: Int? = nil, cursorAvailable: Bool = true) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("fps-native-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        tokenFile = root.appendingPathComponent("token"); eventLog = root.appendingPathComponent("events.log")
        output = root.appendingPathComponent("process.log")
        try Data(token.utf8).write(to: tokenFile)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenFile.path)
        _ = FileManager.default.createFile(atPath: output.path, contents: Data())
        outputHandle = try FileHandle(forWritingTo: output)
        process.executableURL = Self.executable
        process.arguments = ["--port", "0", "--token-file", tokenFile.path, "--event-log", eventLog.path]
        if let interfaceOrientation { process.arguments! += ["--interface-orientation", String(interfaceOrientation)] }
        process.standardOutput = outputHandle; process.standardError = outputHandle
        if !cursorAvailable {
            process.environment = ProcessInfo.processInfo.environment.merging(["ICONTROL_FPSD_TEST_NO_CURSOR": "1"]) { _, new in new }
        }
        try process.run()
        let ready = waitUntil(3) {
            let text = (try? String(contentsOf: self.output)) ?? ""
            for line in text.split(separator: "\n") where line.hasPrefix("FPS_READY port=") {
                self.port = UInt16(line.split(separator: " ")[1].dropFirst(5)) ?? 0
            }
            return self.port > 0 || !self.process.isRunning
        }
        guard ready, port > 0 else { stop(); throw ControlError("Native FPS test daemon did not start") }
    }
    @discardableResult
    func waitUntil(_ seconds: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        repeat { if condition() { return true }; Thread.sleep(forTimeInterval: 0.005) }
        while ProcessInfo.processInfo.systemUptime < deadline
        return condition()
    }
    var frames: [NativeFrame] { ((try? String(contentsOf: eventLog)) ?? "").split(separator: "\n").compactMap { NativeFrame(String($0)) } }
    func connect(token override: String? = nil, expected: Data = FPSWire.ready, fragmented: Bool = false) throws -> SocketConnection {
        let socket = try SocketConnection.loopback(port: port)
        do {
            XCTAssertEqual(try socket.read(count: 8), FPSWire.greeting)
            let bytes = try FPSAccessToken.bytes(override ?? token)
            if fragmented { for byte in bytes { try socket.write(Data([byte])); Thread.sleep(forTimeInterval: 0.001) } }
            else { try socket.write(bytes) }
            XCTAssertEqual(try socket.read(count: 8), expected)
            return socket
        } catch { socket.close(); throw error }
    }
    func send(_ state: FPSState, sequence: UInt32, socket: SocketConnection, fragmented: Bool = false) throws -> Data {
        let bytes = try FPSWire.state(state, sequence: sequence)
        if fragmented { for byte in bytes { try socket.write(Data([byte])); Thread.sleep(forTimeInterval: 0.001) } }
        else { try socket.write(bytes) }
        return try socket.read(count: 8)
    }
    func heartbeat(_ socket: SocketConnection, sequence: UInt32) throws -> Data {
        try socket.write(FPSWire.control(3, sequence: sequence)); return try socket.read(count: 8)
    }
    func stop() {
        if process.isRunning {
            _ = Darwin.kill(process.processIdentifier, SIGCONT)
            process.terminate()
            if !waitUntil(2, { !self.process.isRunning }) { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
        }
    }
    deinit { stop(); try? outputHandle.close(); try? FileManager.default.removeItem(at: root) }
}

private final class FPSLinkProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var acknowledgements = 0, contacts = 0
    private var failures: [String] = []
    func record(_ event: FPSLinkEvent) {
        lock.lock(); defer { lock.unlock() }
        switch event {
        case .acknowledgement(_, let count, _): acknowledgements += 1; contacts = count
        case .failed(let message): failures.append(message)
        case .deviceCursor: break
        }
    }
    var snapshot: (acks: Int, contacts: Int, failures: Int) {
        lock.lock(); defer { lock.unlock() }; return (acknowledgements, contacts, failures.count)
    }
}

final class FPSDaemonTests: TestCase {
    private let sample = FPSState(contacts: [
        .init(id: 1, point: .init(x: 0.2, y: 0.3)),
        .init(id: 2, point: .init(x: 0.6, y: 0.5)),
        .init(id: 3, point: .init(x: 0.9, y: 0.6))
    ], orientation: .portrait)

    func testAuthenticationSingleOwnerAndUnauthenticatedProbes() throws {
        let daemon = try NativeFPSFixture(), owner = try daemon.connect(fragmented: true)
        defer { owner.close(); daemon.stop() }
        XCTAssertEqual(try daemon.send(sample, sequence: 1, socket: owner)[1], 3)
        let denied = try daemon.connect(token: String(repeating: "b6", count: 32), expected: Data("DENY0001".utf8))
        denied.close()
        let busy = try daemon.connect(expected: Data("BUSY0001".utf8)); busy.close()
        let probe = try SocketConnection.loopback(port: daemon.port)
        XCTAssertEqual(try probe.read(count: 8), FPSWire.greeting); probe.close()
        XCTAssertEqual(try daemon.heartbeat(owner, sequence: 2)[1], 3)
        XCTAssertEqual(daemon.frames.last?.active, 3)
        XCTAssertFalse(daemon.frames.contains(where: { $0.active == 0 }), "Rejected connections must never release the owner's fingers")
        owner.close()
        XCTAssertTrue(daemon.waitUntil(1) { daemon.frames.last?.active == 0 })
        let successor = try daemon.connect(); successor.close()
    }

    func testFragmentedStateRotationAndIndependentFingerEdges() throws {
        let daemon = try NativeFPSFixture(), socket = try daemon.connect()
        defer { socket.close(); daemon.stop() }
        var state = sample; state.orientation = .clockwise
        let ack = try daemon.send(state, sequence: 1, socket: socket, fragmented: true)
        XCTAssertEqual(ack[1], 3); XCTAssertEqual(ack[2], 1)
        let first = try XCTUnwrap(daemon.frames.last), edge = try XCTUnwrap(first.edges[1])
        XCTAssertLessThan(abs(edge.x - 0.3), 0.00002); XCTAssertLessThan(abs(edge.y - 0.8), 0.00002)
        state.contacts.removeAll(where: { $0.id == 2 })
        _ = try daemon.send(state, sequence: 2, socket: socket)
        let second = try XCTUnwrap(daemon.frames.last)
        XCTAssertEqual(second.ids, Set([1, 3])); XCTAssertEqual(second.edges[2]?.kind, "up")
        XCTAssertTrue(second.edges[1] == nil && second.edges[3] == nil, "Stationary movement and firing fingers retain their identity")
        try socket.write(FPSWire.control(2, sequence: 3))
        XCTAssertEqual(try socket.read(count: 8)[1], 0)
        let last = try XCTUnwrap(daemon.frames.last)
        XCTAssertEqual(last.edges[1]?.kind, "up"); XCTAssertEqual(last.edges[3]?.kind, "up"); XCTAssertTrue(last.canceled)
    }

    func testOrientationChangeReleasesAndReanchors() throws {
        let daemon = try NativeFPSFixture(), socket = try daemon.connect()
        defer { socket.close(); daemon.stop() }
        _ = try daemon.send(sample, sequence: 1, socket: socket)
        var rotated = sample; rotated.orientation = .counterclockwise
        _ = try daemon.send(rotated, sequence: 2, socket: socket)
        let changed = daemon.frames.filter { $0.sequence == 2 }
        XCTAssertEqual(changed.count, 2)
        XCTAssertEqual(changed.first?.active, 0); XCTAssertTrue(changed.first?.canceled == true)
        XCTAssertEqual(changed.last?.rotation, 3); XCTAssertEqual(changed.last?.active, 3)
        let edge = try XCTUnwrap(changed.last?.edges[1])
        XCTAssertLessThan(abs(edge.x - 0.7), 0.00002); XCTAssertLessThan(abs(edge.y - 0.2), 0.00002)
    }

    func testCalibratedPreviewReachesEveryNativeActionAndReleases() throws {
        let daemon = try NativeFPSFixture(), socket = try daemon.connect()
        defer { socket.close(); daemon.stop() }
        var profile = FPSProfile(); profile.orientation = .counterclockwise; profile.touchMapping.rotation = 1
        for index in profile.bindings.indices { profile.bindings[index].enabled = true }
        var sequence: UInt32 = 0
        for binding in profile.bindings {
            let frames = try FPSInputPreview.action(binding.action, profile: profile)
            sequence += 1; _ = try daemon.send(frames[0], sequence: sequence, socket: socket)
            let frame = try XCTUnwrap(daemon.frames.last), edge = try XCTUnwrap(frame.edges[Int(binding.action.touchID)])
            XCTAssertEqual(frame.ids, [Int(binding.action.touchID)])
            // 90° calibration followed by the device's 270° is an identity.
            XCTAssertLessThan(abs(edge.x - binding.point.x), 0.00004)
            XCTAssertLessThan(abs(edge.y - binding.point.y), 0.00004)
            sequence += 1; _ = try daemon.send(try XCTUnwrap(frames.last), sequence: sequence, socket: socket)
            XCTAssertEqual(daemon.frames.last?.active, 0)
            XCTAssertEqual(daemon.frames.last?.edges[Int(binding.action.touchID)]?.kind, "up")
        }
    }

    func testWatchdogHasOneDeadlineForFragmentedHeaderAndBody() throws {
        let daemon = try NativeFPSFixture(), socket = try daemon.connect()
        defer { socket.close(); daemon.stop() }
        _ = try daemon.send(sample, sequence: 1, socket: socket)
        let began = ProcessInfo.processInfo.systemUptime
        Thread.sleep(forTimeInterval: 0.20)
        let packet = try FPSWire.state(sample, sequence: 2)
        try socket.write(Data(packet.prefix(10))) // complete header, incomplete body
        XCTAssertThrowsError(try socket.read(count: 8, timeout: 900))
        let elapsed = ProcessInfo.processInfo.systemUptime - began
        XCTAssertGreaterThanOrEqual(elapsed, 0.30); XCTAssertLessThan(elapsed, 0.70)
        XCTAssertTrue(daemon.waitUntil(1) { daemon.frames.last?.active == 0 })
        XCTAssertTrue(daemon.frames.last?.canceled == true)
    }

    func testMalformedContactsReservedBytesAndSequenceReleaseOwner() throws {
        let daemon = try NativeFPSFixture(); defer { daemon.stop() }
        for fault in 0..<5 {
            let socket = try daemon.connect(); defer { socket.close() }
            _ = try daemon.send(sample, sequence: 1, socket: socket)
            var bad = try FPSWire.state(sample, sequence: 2)
            switch fault {
            case 0: bad[16] = bad[8] // duplicate identifier
            case 1: bad[9] = 1 // reserved contact byte
            case 2: bad[1] = 11 // excessive contacts
            case 3: bad[2] = 4 // unknown orientation
            default: bad = try FPSWire.state(sample, sequence: 1) // replay
            }
            try socket.write(bad)
            XCTAssertThrowsError(try socket.read(count: 8, timeout: 800))
            XCTAssertTrue(daemon.waitUntil(1) { daemon.frames.last?.active == 0 })
            socket.close()
        }
    }

    func testSwiftLinkHeartbeatReleaseAndLifetime() throws {
        let daemon = try NativeFPSFixture(), probe = FPSLinkProbe()
        defer { daemon.stop() }
        var link: FPSUSBLink? = try FPSUSBLink(socket: .loopback(port: daemon.port), token: daemon.token, callback: { probe.record($0) })
        weak var owner = link
        link?.send(sample)
        XCTAssertTrue(daemon.waitUntil(1) { daemon.frames.last?.active == 3 })
        Thread.sleep(forTimeInterval: 0.65)
        XCTAssertEqual(daemon.frames.last?.active, 3, "Heartbeat must preserve held contacts beyond the watchdog interval")
        XCTAssertGreaterThanOrEqual(probe.snapshot.acks, 2); XCTAssertEqual(probe.snapshot.contacts, 3)
        link?.releaseAll()
        XCTAssertTrue(daemon.waitUntil(1) { daemon.frames.last?.active == 0 })
        link?.stop(); link = nil
        XCTAssertTrue(daemon.waitUntil(1) { owner == nil }, "Stopped link must release its reader, timer and socket")
        XCTAssertEqual(probe.snapshot.failures, 0)
    }

    func testSwiftLinkFailureAndBoundedQueueRelease() throws {
        let daemon = try NativeFPSFixture(), probe = FPSLinkProbe()
        defer { daemon.stop() }
        let link = try FPSUSBLink(socket: .loopback(port: daemon.port), token: daemon.token, callback: { probe.record($0) })
        defer { link.stop() }
        link.send(sample)
        XCTAssertTrue(daemon.waitUntil(1) { daemon.frames.last?.active == 3 })
        _ = Darwin.kill(daemon.process.processIdentifier, SIGSTOP)
        for _ in 0..<10000 { link.send(sample) }
        XCTAssertTrue(daemon.waitUntil(1) { probe.snapshot.failures == 1 })
        _ = Darwin.kill(daemon.process.processIdentifier, SIGCONT)
        XCTAssertTrue(daemon.waitUntil(1) { daemon.frames.last?.active == 0 })
        link.send(sample); link.releaseAll(); link.stop()
        XCTAssertEqual(probe.snapshot.failures, 1, "Connection failure is reported once")
    }

    func testShutdownReleasesAndInvalidTokenFilesAreRejected() throws {
        let daemon = try NativeFPSFixture(), socket = try daemon.connect()
        defer { socket.close(); daemon.stop() }
        _ = try daemon.send(sample, sequence: 1, socket: socket)
        daemon.stop()
        XCTAssertEqual(daemon.frames.last?.active, 0); XCTAssertTrue(daemon.frames.last?.canceled == true)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: daemon.tokenFile.path)
        let insecure = try ProcessRunner.run(executable: NativeFPSFixture.executable,
            arguments: ["--token-file", daemon.tokenFile.path], timeout: 2)
        XCTAssertEqual(insecure.status, 3)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: daemon.tokenFile.path)
        let symlink = daemon.root.appendingPathComponent("link-token")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: daemon.tokenFile)
        XCTAssertEqual(try ProcessRunner.run(executable: NativeFPSFixture.executable,
            arguments: ["--token-file", symlink.path], timeout: 2).status, 3)
        try Data((daemon.token + "\n").utf8).write(to: daemon.tokenFile)
        XCTAssertEqual(try ProcessRunner.run(executable: NativeFPSFixture.executable,
            arguments: ["--token-file", daemon.tokenFile.path], timeout: 2).status, 3)
    }
}
