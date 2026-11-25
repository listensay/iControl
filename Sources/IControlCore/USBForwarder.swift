import Foundation
import CTransport
import Darwin

public struct ForwarderSnapshot: Sendable {
    public let running: Bool
    public let activeClients: Int
    public let totalClients: Int
    public let bytesToDevice: UInt64
    public let bytesFromDevice: UInt64
    public let lastError: String?
}

private final class ForwardSession {
    let client: SocketConnection
    var device: SocketConnection?
    init(client: SocketConnection) { self.client = client }
}

public final class USBForwarder: @unchecked Sendable {
    public let localPort: UInt16
    public let device: USBDevice
    private let listener: SocketConnection
    private let mux: USBMux
    private let devicePort: UInt16
    private let lock = NSLock()
    private var running = true
    private var sessions: [UUID: ForwardSession] = [:]
    private var totalClients = 0
    private var bytesToDevice: UInt64 = 0
    private var bytesFromDevice: UInt64 = 0
    private var lastError: String?

    public init(mux: USBMux = USBMux(), device: USBDevice, devicePort: UInt16 = 5901, preferredPort: UInt16 = 15901) throws {
        self.mux = mux
        self.device = device
        self.devicePort = devicePort
        var fd = ic_listen_loopback(preferredPort)
        // A busy port belongs to its existing owner. Choose a free one instead.
        if fd < 0, errno == EADDRINUSE, preferredPort != 0 { fd = ic_listen_loopback(0) }
        guard fd >= 0 else { throw ControlError.socket("无法创建 USB 控制连接") }
        listener = SocketConnection(descriptor: fd)
        localPort = ic_bound_port(fd)
        DispatchQueue(label: "icontrol.usb.accept", qos: .userInitiated).async { [self] in acceptClients() }
    }

    public func snapshot() -> ForwarderSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return ForwarderSnapshot(running: running, activeClients: sessions.values.filter { $0.device != nil }.count,
                                 totalClients: totalClients, bytesToDevice: bytesToDevice,
                                 bytesFromDevice: bytesFromDevice, lastError: lastError)
    }

    public func stop() {
        lock.lock()
        guard running else { lock.unlock(); return }
        running = false
        listener.cancel()
        for session in sessions.values {
            session.client.cancel()
            session.device?.cancel()
        }
        lock.unlock()
    }

    private func acceptClients() {
        defer { listener.close() }
        while snapshot().running {
            let fd = ic_accept_timeout(listener.descriptor, 500)
            if fd == -2 { continue }
            if fd < 0 {
                if snapshot().running {
                    lock.lock(); lastError = "USB 转发监听已停止"; lock.unlock()
                    stop()
                }
                break
            }
            let id = UUID()
            let session = ForwardSession(client: SocketConnection(descriptor: fd))
            lock.lock()
            if !running || sessions.count >= 8 {
                lock.unlock(); session.client.close(); continue
            }
            sessions[id] = session
            lock.unlock()
            DispatchQueue.global(qos: .userInitiated).async { [self] in relay(session, id: id) }
        }
    }

    private func relay(_ session: ForwardSession, id: UUID) {
        defer {
            lock.lock()
            let remote = session.device
            sessions.removeValue(forKey: id)
            lock.unlock()
            session.client.close()
            remote?.close()
        }
        do {
            let remote = try mux.connect(deviceID: device.deviceID, port: devicePort)
            lock.lock()
            session.device = remote
            let shouldRun = running
            if shouldRun { totalClients += 1; lastError = nil }
            lock.unlock()
            guard shouldRun else { remote.cancel(); return }
            var sent: UInt64 = 0
            var received: UInt64 = 0
            ic_relay(session.client.descriptor, remote.descriptor, &sent, &received)
            lock.lock()
            bytesToDevice += sent
            bytesFromDevice += received
            lock.unlock()
        } catch {
            lock.lock(); lastError = error.localizedDescription; lock.unlock()
        }
    }
}
