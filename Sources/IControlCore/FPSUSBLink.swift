import Foundation

public enum FPSLinkEvent: Sendable {
    case acknowledgement(milliseconds: Double, contacts: Int, orientation: Int)
    case deviceCursor(available: Bool, visible: Bool)
    case failed(String)
}

/// Direct usbmux stream, separate from video. Bounded writes and the device
/// watchdog prevent buffered movement from being replayed after a stall.
public final class FPSUSBLink: @unchecked Sendable {
    public let supportsDeviceCursor: Bool
    private let socket: SocketConnection
    private let writer = DispatchQueue(label: "icontrol.fps.write", qos: .userInteractive)
    private let lock = NSLock()
    private let callback: @Sendable (FPSLinkEvent) -> Void
    private var timer: DispatchSourceTimer?
    private var running = true
    private var sequence: UInt32 = 0
    private var queued = 0
    private var sent: [UInt32: TimeInterval] = [:]
    private var lastReport: TimeInterval = 0
    private var lastCursorFlags: UInt8?

    public static func connect(mux: USBMux, device: USBDevice, token: String,
                               callback: @escaping @Sendable (FPSLinkEvent) -> Void = { _ in }) throws -> FPSUSBLink {
        let socket = try mux.connect(deviceID: device.deviceID, port: FPSWire.port)
        do { return try FPSUSBLink(socket: socket, token: token, callback: callback) }
        catch { socket.close(); throw error }
    }

    public init(socket: SocketConnection, token: String,
                callback: @escaping @Sendable (FPSLinkEvent) -> Void = { _ in }) throws {
        self.socket = socket; self.callback = callback
        let secret = try FPSAccessToken.bytes(token)
        let greeting = try socket.read(count: 8, timeout: 1500)
        supportsDeviceCursor = greeting == FPSWire.greeting
        if greeting == FPSWire.legacyGreeting {
            throw ControlError("iPad 仍在运行旧版 FPS 控制端。请打开“安装 / 配置控制端”升级至 1.4.0，再测试游戏按钮。")
        }
        guard supportsDeviceCursor || greeting == FPSWire.touchOnlyGreeting else {
            throw ControlError("iPad FPS 控制端未就绪，请安装 / 配置新版控制端")
        }
        try socket.write(secret, timeout: 1500)
        let reply = try socket.read(count: 8, timeout: 1500)
        if reply == Data("BUSY0001".utf8) { throw ControlError("FPS 输入通道正被另一个客户端使用") }
        guard reply == FPSWire.ready else { throw ControlError("FPS 通道凭据不匹配，请重新安装 / 配置控制端") }
        DispatchQueue(label: "icontrol.fps.ack", qos: .userInteractive).async { [self] in receive() }
        let heartbeat = DispatchSource.makeTimerSource(queue: writer)
        heartbeat.schedule(deadline: .now(), repeating: .milliseconds(100), leeway: .milliseconds(5))
        heartbeat.setEventHandler { [weak self] in self?.write(opcode: 3, state: nil) }
        timer = heartbeat; heartbeat.resume()
    }

    public func send(_ state: FPSState) { enqueue(opcode: 1, state: state) }
    public func releaseAll() { enqueue(opcode: 2, state: nil) }
    public func setDeviceCursor(_ cursor: FPSDeviceCursor?) {
        guard supportsDeviceCursor else { return }
        enqueue(opcode: 4, state: nil, cursor: cursor)
    }

    private func enqueue(opcode: UInt8, state: FPSState?, cursor: FPSDeviceCursor? = nil) {
        lock.lock()
        guard running else { lock.unlock(); return }
        guard queued < 16 else { lock.unlock(); fail("FPS 输入通道暂时拥堵，已释放触点。请重新连接。"); return }
        queued += 1; lock.unlock()
        let created = ProcessInfo.processInfo.systemUptime
        writer.async { [self] in
            defer { lock.lock(); queued -= 1; lock.unlock() }
            if ProcessInfo.processInfo.systemUptime - created > 0.15 {
                fail("FPS 输入发送延迟过高，已停止游戏输入。请重新连接。"); return
            }
            write(opcode: opcode, state: state, cursor: cursor)
        }
    }

    private func write(opcode: UInt8, state: FPSState?, cursor: FPSDeviceCursor? = nil) {
        lock.lock()
        guard running else { lock.unlock(); return }
        sequence &+= 1; let seq = sequence
        sent[seq] = ProcessInfo.processInfo.systemUptime
        if sent.count > 256 { sent.removeAll(keepingCapacity: true) }
        lock.unlock()
        do {
            let bytes = try opcode == 4 ? FPSWire.cursor(cursor, sequence: seq)
                : state.map { try FPSWire.state($0, sequence: seq) } ?? FPSWire.control(opcode, sequence: seq)
            try socket.write(bytes, timeout: 150)
        } catch { fail("FPS 输入连接中断，已停止游戏输入。") }
    }

    private func receive() {
        defer { socket.close() }
        do {
            while true {
                lock.lock(); let alive = running; lock.unlock()
                guard alive else { return }
                let ack = try socket.read(count: 8, timeout: 1500)
                guard ack[0] == 128, ack[1] <= FPSWire.maximumContacts, ack[2] <= 3,
                      (supportsDeviceCursor ? ack[3] <= 3 && (ack[3] != 2) : ack[3] == 0) else {
                    throw ControlError("FPS 确认帧无效")
                }
                let seq = ack.uint32BE(at: 4), now = ProcessInfo.processInfo.systemUptime
                lock.lock()
                let when = sent.removeValue(forKey: seq)
                let report = now - lastReport > 0.20
                if report { lastReport = now }
                lock.unlock()
                if lastCursorFlags != ack[3] {
                    lastCursorFlags = ack[3]
                    callback(.deviceCursor(available: supportsDeviceCursor && ack[3] & 1 != 0,
                                           visible: supportsDeviceCursor && ack[3] & 2 != 0))
                }
                if report, let when {
                    callback(.acknowledgement(milliseconds: max(0, now - when) * 1000,
                                              contacts: Int(ack[1]), orientation: Int(ack[2])))
                }
            }
        } catch { fail("FPS 输入连接中断，已释放触点。") }
    }

    private func fail(_ message: String) {
        lock.lock()
        let report = running; running = false
        timer?.cancel(); timer = nil
        lock.unlock()
        socket.cancel()
        if report { callback(.failed(message)) }
    }

    public func stop() {
        lock.lock()
        guard running else { lock.unlock(); return }
        running = false; timer?.cancel(); timer = nil
        sequence &+= 1; let seq = sequence
        lock.unlock()
        writer.async { [self] in
            try? socket.write(FPSWire.control(2, sequence: seq), timeout: 100)
            socket.cancel()
        }
    }
    deinit { socket.cancel() }
}
