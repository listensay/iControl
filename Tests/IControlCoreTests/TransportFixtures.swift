import Foundation
import TestSupport
import CTransport
import Darwin
@testable import IControlCore

func eventually(_ timeout: TimeInterval = 3, file: StaticString = #filePath, line: UInt = #line,
                _ predicate: () -> Bool) {
    let end = ProcessInfo.processInfo.systemUptime + timeout
    while ProcessInfo.processInfo.systemUptime < end {
        if predicate() { return }
        usleep(10000)
    }
    XCTAssertTrue(predicate(), "Condition did not become true", file: file, line: line)
}

final class FakeMux: @unchecked Sendable {
    typealias Handler = @Sendable ([String: Any], SocketConnection) throws -> Void
    let path = "/tmp/ic-mux-test-\(UUID().uuidString.prefix(18)).sock"
    let listener: SocketConnection
    private let handler: Handler
    private let lock = NSLock()
    private var running = true
    private var clients: [UUID: SocketConnection] = [:]
    private let workers = DispatchGroup()
    var mux: USBMux { USBMux(socketPath: path, timeout: 1000) }
    init(handler: @escaping Handler) throws {
        self.handler = handler
        let fd = ic_listen_unix(path)
        guard fd >= 0 else { throw ControlError("Cannot listen") }
        listener = SocketConnection(descriptor: fd)
        workers.enter()
        DispatchQueue.global().async { [self] in
            defer { listener.close(); workers.leave() }
            while true {
                lock.lock(); let alive = running; lock.unlock()
                if !alive { return }
                let fd = ic_accept_timeout(listener.descriptor, 100)
                if fd == -2 { continue }
                if fd < 0 { return }
                let socket = SocketConnection(descriptor: fd), id = UUID()
                lock.lock(); clients[id] = socket; lock.unlock()
                workers.enter()
                DispatchQueue.global().async { [self] in
                    defer {
                        socket.close(); lock.lock(); clients.removeValue(forKey: id); lock.unlock(); workers.leave()
                    }
                    do { try handler(FakeMux.request(socket), socket) } catch { }
                }
            }
        }
    }
    func stop() {
        lock.lock(); running = false; listener.cancel(); for client in clients.values { client.cancel() }; lock.unlock()
        _ = workers.wait(timeout: .now() + 5)
        try? FileManager.default.removeItem(atPath: path)
    }
    static func request(_ socket: SocketConnection) throws -> [String: Any] {
        let header = try socket.read(count: 16, timeout: 2000)
        let size = Int(header.uint32LE(at: 0)) - 16
        guard size > 0 && size <= 1024 * 1024 else { throw ControlError("Bad request") }
        let body = try socket.read(count: size, timeout: 2000)
        return try PropertyListSerialization.propertyList(from: body, options: [], format: nil) as! [String: Any]
    }
    static func reply(_ value: [String: Any], to socket: SocketConnection, fragmented: Bool = false, tag: UInt32 = 1) throws {
        let body = try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
        var data = Data(); data.appendLE(UInt32(body.count + 16)); data.appendLE(1); data.appendLE(8); data.appendLE(tag); data.append(body)
        if fragmented {
            for start in stride(from: 0, to: data.count, by: 7) { try socket.write(data.subdata(in: start..<min(start + 7, data.count))) }
        } else { try socket.write(data) }
    }
    static let device = USBDevice(deviceID: 7, udid: "test-ipad", name: "Test iPad", productType: "iPad7,3", version: "17.7.11")
}

final class LoopbackFixture: @unchecked Sendable {
    let listener: SocketConnection
    let port: UInt16
    private let lock = NSLock()
    private var client: SocketConnection?
    private let worker = DispatchGroup()
    init(handler: @escaping @Sendable (SocketConnection) throws -> Void) throws {
        let fd = ic_listen_loopback(0)
        guard fd >= 0 else { throw ControlError("Cannot listen") }
        listener = SocketConnection(descriptor: fd); port = ic_bound_port(fd)
        worker.enter()
        DispatchQueue.global().async { [self] in
            defer { listener.close(); worker.leave() }
            let fd = ic_accept_timeout(listener.descriptor, 5000)
            guard fd >= 0 else { return }
            let socket = SocketConnection(descriptor: fd)
            lock.lock(); client = socket; lock.unlock()
            defer { socket.close() }
            do { try handler(socket) } catch { }
        }
    }
    func stop() {
        listener.cancel(); lock.lock(); client?.cancel(); lock.unlock()
        _ = worker.wait(timeout: .now() + 5)
    }
}

func readHTTPHeader(_ socket: SocketConnection) throws -> String {
    var bytes = Data()
    while bytes.count < 16384 {
        bytes.append(try socket.read(count: 1, timeout: 2000))
        if bytes.suffix(4) == Data([13, 10, 13, 10]) { return String(decoding: bytes, as: UTF8.self) }
    }
    throw ControlError("Header too long")
}

func maskedFrame(_ payload: Data, opcode: UInt8 = 2, final: Bool = true) -> Data {
    var data = WebSocketFrame.server(opcode: opcode, payload: payload)
    if !final { data[0] &= 127 }
    data[1] |= 128
    let headerSize = payload.count < 126 ? 2 : (payload.count <= 65535 ? 4 : 10)
    let mask: [UInt8] = [17, 34, 51, 68]
    var output = data.subdata(in: 0..<headerSize)
    output.append(contentsOf: mask)
    for (index, byte) in payload.enumerated() { output.append(byte ^ mask[index % 4]) }
    return output
}

func readServerFrame(_ socket: SocketConnection) throws -> (UInt8, Data) {
    let header = try socket.read(count: 2, timeout: 3000)
    XCTAssertEqual(header[1] & 128, 0)
    var size = Int(header[1] & 127)
    if size == 126 {
        let more = try socket.read(count: 2); size = Int(more[0]) << 8 | Int(more[1])
    } else if size == 127 {
        let more = try socket.read(count: 8); size = more.reduce(0) { ($0 << 8) | Int($1) }
    }
    guard size <= WebSocketFrame.maximumPayload else { throw ControlError("Large frame") }
    return (header[0] & 15, try socket.read(count: size, timeout: 5000))
}
