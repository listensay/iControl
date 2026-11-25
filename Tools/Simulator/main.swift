import Foundation
import Darwin
import CTransport
import CoreGraphics
import CoreText
import IControlCore

/// Development fixture only. The real application never starts this process.
/// A QA app must carry IControlDemoSocket in Info.plist and displays a visible
/// "模拟设备" label before it can use this endpoint.
final class SimulatediPad: @unchecked Sendable {
    let socketPath: String
    let logPath: String
    let statePath: String
    let fpsPort: UInt16?
    let fpsEventLog: String?
    let listener: SocketConnection
    let lock = NSLock()
    var keyCount = 0, pointerCount = 0, clipboardCount = 0
    let width: UInt16 = 640, height: UInt16 = 480

    init(socketPath: String, logPath: String, fpsPort: UInt16? = nil, fpsEventLog: String? = nil) throws {
        self.socketPath = socketPath; self.logPath = logPath; self.statePath = socketPath + ".state"
        self.fpsPort = fpsPort; self.fpsEventLog = fpsEventLog
        let fd = ic_listen_unix(socketPath)
        guard fd >= 0 else { throw ControlError("Cannot create simulator") }
        listener = SocketConnection(descriptor: fd)
        _ = FileManager.default.createFile(atPath: logPath, contents: Data())
    }
    func currentID() -> UInt32? {
        let value = (try? String(contentsOfFile: statePath))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "7"
        return UInt32(value)
    }
    func record(_ message: String) {
        lock.lock(); defer { lock.unlock() }
        guard let file = FileHandle(forWritingAtPath: logPath) else { return }
        do { try file.seekToEnd(); try file.write(contentsOf: Data((message + "\n").utf8)); try file.close() } catch { }
    }
    func run() {
        print("Simulator ready: \(socketPath)")
        fflush(stdout)
        while true {
            let fd = ic_accept_timeout(listener.descriptor, 500)
            if fd == -2 { continue }
            guard fd >= 0 else { return }
            let socket = SocketConnection(descriptor: fd)
            DispatchQueue.global().async { [self] in
                defer { socket.close() }
                do { try handle(socket) } catch { }
            }
        }
    }
    func handle(_ socket: SocketConnection) throws {
        let header = try socket.read(count: 16)
        let length = Int(little(header, at: 0)) - 16
        guard length > 0, length < 1024 * 1024 else { return }
        let request = try PropertyListSerialization.propertyList(from: socket.read(count: length), options: [], format: nil) as! [String: Any]
        if request["MessageType"] as? String == "ListDevices" {
            let devices: [[String: Any]] = currentID().map { [["DeviceID": $0, "Properties": ["ConnectionType": "USB", "SerialNumber": "icontrol-simulated-ipad"]]] } ?? []
            try reply(["DeviceList": devices], socket: socket)
            return
        }
        guard let deviceID = currentID(), request["DeviceID"] as? UInt32 == deviceID || (request["DeviceID"] as? NSNumber)?.uint32Value == deviceID else {
            try reply(["Number": 2], socket: socket); return
        }
        let encoded = (request["PortNumber"] as? NSNumber)?.uint16Value ?? 0
        let port = (encoded >> 8) | ((encoded & 255) << 8)
        guard port == 5901 || port == 62078 || (port == FPSWire.port && fpsPort != nil) else { try reply(["Number": 3], socket: socket); return }
        if port == FPSWire.port, let fpsPort {
            let native = try SocketConnection.loopback(port: fpsPort)
            defer { native.close() }
            try reply(["Number": 0], socket: socket)
            record("fps-usb-session device-id=\(deviceID)")
            let watcher = DispatchSource.makeTimerSource(queue: .global())
            watcher.schedule(deadline: .now(), repeating: .milliseconds(50))
            watcher.setEventHandler { [self] in
                if currentID() != deviceID { socket.cancel(); native.cancel() }
            }
            watcher.resume(); defer { watcher.cancel() }
            var sent: UInt64 = 0, received: UInt64 = 0
            ic_relay(socket.descriptor, native.descriptor, &sent, &received)
            record("fps-usb-ended device-id=\(deviceID)")
            return
        }
        try reply(["Number": 0], socket: socket)
        if port == 62078 {
            let size = Int(big(try socket.read(count: 4), at: 0))
            _ = try socket.read(count: size)
            let data = try PropertyListSerialization.data(fromPropertyList: ["Value": ["DeviceName": "模拟 iPad · 界面测试", "ProductType": "iPad7,3", "ProductVersion": "17.7.11"]], format: .xml, options: 0)
            var bytes = Data(); appendBig(UInt32(data.count), to: &bytes); bytes.append(data); try socket.write(bytes)
        } else { try vnc(socket, deviceID: deviceID) }
    }
    func reply(_ value: [String: Any], socket: SocketConnection) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
        var bytes = Data()
        for value in [UInt32(data.count + 16), 1, 8, 1] { for shift in stride(from: 0, to: 32, by: 8) { bytes.append(UInt8(truncatingIfNeeded: value >> shift)) } }
        bytes.append(data); try socket.write(bytes)
    }
    func vnc(_ socket: SocketConnection, deviceID: UInt32) throws {
        try socket.write(Data("RFB 003.008\n".utf8))
        _ = try socket.read(count: 12)
        try socket.write(Data([1, 1]))
        guard try socket.read(count: 1)[0] == 1 else { return }
        try socket.write(Data([0, 0, 0, 0]))
        _ = try socket.read(count: 1)
        var initialization = Data(); appendShort(width, to: &initialization); appendShort(height, to: &initialization)
        initialization.append(contentsOf: [32, 24, 0, 1, 0, 255, 0, 255, 0, 255, 0, 8, 16, 0, 0, 0])
        let name = Data("SIMULATED IPAD - UI VERIFICATION ONLY".utf8)
        appendBig(UInt32(name.count), to: &initialization); initialization.append(name); try socket.write(initialization)
        record("vnc-session device-id=\(deviceID)")
        while currentID() == deviceID {
            let type = try socket.read(count: 1, timeout: 30000)[0]
            switch type {
            case 0: _ = try socket.read(count: 19)
            case 2:
                let header = try socket.read(count: 3)
                let count = Int(header[1]) << 8 | Int(header[2])
                guard count <= 256 else { return }; _ = try socket.read(count: count * 4)
            case 3:
                _ = try socket.read(count: 9)
                Thread.sleep(forTimeInterval: 0.08)
                var update = Data([0, 0, 0, 1])
                appendShort(0, to: &update); appendShort(0, to: &update)
                appendShort(width, to: &update); appendShort(height, to: &update); appendBig(0, to: &update)
                update.append(image(deviceID: deviceID)); try socket.write(update, timeout: 5000)
            case 4:
                let event = try socket.read(count: 7)
                lock.lock(); keyCount += 1; lock.unlock()
                record("key down=\(event[0]) keysym=\(big(event, at: 3))")
            case 5:
                let event = try socket.read(count: 5)
                lock.lock(); pointerCount += 1; lock.unlock()
                record("pointer mask=\(event[0]) x=\(Int(event[1]) << 8 | Int(event[2])) y=\(Int(event[3]) << 8 | Int(event[4]))")
            case 6:
                let header = try socket.read(count: 7)
                let count = Int(big(header, at: 3))
                guard count >= 0 && count < 1024 * 1024 else { return }
                _ = try socket.read(count: count)
                lock.lock(); clipboardCount += count; lock.unlock()
                record("clipboard bytes=\(count)")
            default: return
            }
        }
    }
    func image(deviceID: UInt32) -> Data {
        lock.lock(); let keys = keyCount, pointer = pointerCount, clipboard = clipboardCount; lock.unlock()
        var pixels = Data(count: Int(width) * Int(height) * 4)
        pixels.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress, width: Int(width), height: Int(height), bitsPerComponent: 8, bytesPerRow: Int(width) * 4,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
            context.setFillColor(CGColor(red: 0.055, green: 0.09, blue: 0.16, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: Int(width), height: Int(height)))
            context.setFillColor(CGColor(red: 0.12, green: 0.32, blue: 0.70, alpha: 1)); context.fill(CGRect(x: 0, y: 350, width: 640, height: 130))
            func text(_ string: String, y: CGFloat, size: CGFloat) {
                let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
                let attributes: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font, NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 0.85, green: 0.91, blue: 1, alpha: 1)]
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
                context.textPosition = CGPoint(x: 44, y: y); CTLineDraw(line, context)
            }
            text("SIMULATED IPAD", y: 403, size: 30)
            text("UI verification only", y: 370, size: 16)
            text("USB device ID: \(deviceID)", y: 278, size: 23)
            text("Pointer events received: \(pointer)", y: 226, size: 23)
            text("Key events received: \(keys)", y: 174, size: 23)
            text("Clipboard bytes received: \(clipboard)", y: 122, size: 23)
            if let fpsEventLog, let log = try? String(contentsOfFile: fpsEventLog),
               let frame = log.split(separator: "\n").last {
                let fields = frame.split(separator: " ")
                let active = fields.first(where: { $0.hasPrefix("active=") })?.dropFirst(7) ?? "0"
                let ids = fields.first(where: { $0.hasPrefix("ids=") })?.dropFirst(4) ?? ""
                text("FPS contacts: \(active)   finger IDs: \(ids)", y: 70, size: 16)
                text("WASD + mouse look + fire / aim. F8 releases.", y: 40, size: 15)
            } else { text("Click, drag, scroll, and type here.", y: 48, size: 17) }
        }
        return pixels
    }
    func little(_ data: Data, at offset: Int) -> UInt32 { (0..<4).reduce(0) { $0 | UInt32(data[offset + $1]) << ($1 * 8) } }
    func big(_ data: Data, at offset: Int) -> UInt32 { (0..<4).reduce(0) { ($0 << 8) | UInt32(data[offset + $1]) } }
    func appendBig(_ value: UInt32, to data: inout Data) { for shift in stride(from: 24, through: 0, by: -8) { data.append(UInt8(truncatingIfNeeded: value >> shift)) } }
    func appendShort(_ value: UInt16, to data: inout Data) { data.append(UInt8(truncatingIfNeeded: value >> 8)); data.append(UInt8(truncatingIfNeeded: value)) }
}

guard (3...5).contains(CommandLine.arguments.count) else { fputs("Usage: iControlSimulator SOCKET LOG [NATIVE_FPS_PORT [FPS_EVENT_LOG]]\n", stderr); exit(2) }
let fpsPort = CommandLine.arguments.count >= 4 ? UInt16(CommandLine.arguments[3]) : nil
do { try SimulatediPad(socketPath: CommandLine.arguments[1], logPath: CommandLine.arguments[2],
    fpsPort: fpsPort, fpsEventLog: CommandLine.arguments.count == 5 ? CommandLine.arguments[4] : nil).run() }
catch { fputs("\(error)\n", stderr); exit(1) }
