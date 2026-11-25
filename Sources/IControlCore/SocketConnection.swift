import Foundation
import Darwin
import CTransport

public struct ControlError: LocalizedError, Equatable {
    public let message: String
    public let code: Int32?

    public init(_ message: String, code: Int32? = nil) {
        self.message = message
        self.code = code
    }

    public var errorDescription: String? { message }

    static func socket(_ action: String, code: Int32 = errno) -> ControlError {
        ControlError("\(action)：\(String(cString: strerror(code)))", code: code)
    }
}

/// Cancellation uses shutdown. The owning worker retains the descriptor until
/// its operation has returned, so a recycled descriptor cannot be closed twice.
public final class SocketConnection: @unchecked Sendable {
    public let descriptor: Int32
    private let lock = NSLock()
    private var isClosed = false

    public init(descriptor: Int32) { self.descriptor = descriptor }

    public static func unix(path: String, timeout: Int32 = 3000) throws -> SocketConnection {
        let fd = ic_connect_unix(path, timeout)
        guard fd >= 0 else { throw ControlError.socket("无法连接 USB 通信服务") }
        return SocketConnection(descriptor: fd)
    }

    public static func loopback(port: UInt16, timeout: Int32 = 3000) throws -> SocketConnection {
        let fd = ic_connect_loopback(port, timeout)
        guard fd >= 0 else { throw ControlError.socket("无法连接本机控制端口") }
        return SocketConnection(descriptor: fd)
    }

    public func read(count: Int, timeout: Int32 = 3000) throws -> Data {
        guard count >= 0, count <= 4 * 1024 * 1024 else { throw ControlError("数据帧长度不合法") }
        var data = Data(count: count)
        let result = data.withUnsafeMutableBytes { bytes in
            ic_read_exact(descriptor, bytes.baseAddress, count, timeout)
        }
        guard result == 0 else { throw ControlError.socket("接收设备数据失败") }
        return data
    }

    public func write(_ data: Data, timeout: Int32 = 3000) throws {
        let result = data.withUnsafeBytes { bytes in
            ic_write_all(descriptor, bytes.baseAddress, data.count, timeout)
        }
        guard result == 0 else { throw ControlError.socket("发送设备数据失败") }
    }

    /// nil is a timeout; empty data is EOF. Each call has a total deadline.
    public func readSome(maximum: Int = 65536, timeout: Int32 = 1000) throws -> Data? {
        guard maximum > 0, maximum <= 4 * 1024 * 1024 else { throw ControlError("读取长度不合法") }
        var data = Data(count: maximum)
        let count = data.withUnsafeMutableBytes { ic_read_some(descriptor, $0.baseAddress, maximum, timeout) }
        if count == -2 { return nil }
        guard count >= 0 else { throw ControlError.socket("读取连接数据失败") }
        data.count = Int(count)
        return data
    }

    public func cancel() {
        lock.lock()
        defer { lock.unlock() }
        if !isClosed { ic_shutdown_socket(descriptor) }
    }

    public func close() {
        lock.lock()
        defer { lock.unlock() }
        if !isClosed {
            isClosed = true
            ic_shutdown_socket(descriptor)
            ic_close_socket(descriptor)
        }
    }

    deinit { close() }
}

extension Data {
    func uint32LE(at offset: Int) -> UInt32 {
        (0..<4).reduce(0) { $0 | (UInt32(self[offset + $1]) << ($1 * 8)) }
    }

    func uint32BE(at offset: Int) -> UInt32 {
        (0..<4).reduce(0) { ($0 << 8) | UInt32(self[offset + $1]) }
    }

    mutating func appendLE(_ value: UInt32) {
        for shift in stride(from: 0, to: 32, by: 8) { append(UInt8(truncatingIfNeeded: value >> shift)) }
    }

    mutating func appendBE(_ value: UInt32) {
        for shift in stride(from: 24, through: 0, by: -8) { append(UInt8(truncatingIfNeeded: value >> shift)) }
    }
}
