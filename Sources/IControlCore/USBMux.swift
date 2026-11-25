import Foundation

public struct USBDevice: Identifiable, Equatable, Sendable {
    public let deviceID: UInt32
    public let udid: String
    public var name: String
    public var productType: String
    public var version: String
    public var id: String { udid }
    public var isIPad: Bool { productType.hasPrefix("iPad") }

    public init(deviceID: UInt32, udid: String, name: String = "iPad", productType: String = "", version: String = "") {
        self.deviceID = deviceID
        self.udid = udid
        self.name = name
        self.productType = productType
        self.version = version
    }
}

public struct USBMux: Sendable {
    public let socketPath: String
    public let timeout: Int32
    public init(socketPath: String = "/var/run/usbmuxd", timeout: Int32 = 2000) {
        self.socketPath = socketPath
        self.timeout = timeout
    }

    private func exchange(_ message: [String: Any], on socket: SocketConnection) throws -> [String: Any] {
        var payload = message
        payload["ClientVersionString"] = "iControl 1.0"
        payload["ProgName"] = "iControl"
        payload["kLibUSBMuxVersion"] = 3
        let body = try PropertyListSerialization.data(fromPropertyList: payload, format: .xml, options: 0)
        var request = Data()
        request.appendLE(UInt32(body.count + 16))
        request.appendLE(1)
        request.appendLE(8)
        request.appendLE(1)
        request.append(body)
        try socket.write(request, timeout: timeout)
        let header = try socket.read(count: 16, timeout: timeout)
        let length = Int(header.uint32LE(at: 0))
        guard length >= 16, length <= 4 * 1024 * 1024,
              header.uint32LE(at: 4) == 1,
              header.uint32LE(at: 8) == 8,
              header.uint32LE(at: 12) == 1 else {
            throw ControlError("USB 通信服务返回了无效响应")
        }
        let response = try socket.read(count: length - 16, timeout: timeout)
        guard let plist = try PropertyListSerialization.propertyList(from: response, options: [], format: nil) as? [String: Any] else {
            throw ControlError("USB 通信服务返回了无效数据")
        }
        return plist
    }

    public func devices() throws -> [USBDevice] {
        let socket = try SocketConnection.unix(path: socketPath, timeout: timeout)
        defer { socket.close() }
        let response = try exchange(["MessageType": "ListDevices"], on: socket)
        guard let list = response["DeviceList"] as? [[String: Any]] else {
            throw ControlError("无法读取 USB 设备列表")
        }
        return list.compactMap { entry in
            guard let properties = entry["Properties"] as? [String: Any],
                  properties["ConnectionType"] as? String == "USB",
                  let udid = properties["SerialNumber"] as? String,
                  !udid.isEmpty,
                  let number = entry["DeviceID"] as? NSNumber else { return nil }
            return USBDevice(deviceID: number.uint32Value, udid: udid)
        }
    }

    public func connect(deviceID: UInt32, port: UInt16) throws -> SocketConnection {
        let socket = try SocketConnection.unix(path: socketPath, timeout: timeout)
        do {
            let networkPort = UInt32((port >> 8) | ((port & 0xFF) << 8))
            let response = try exchange([
                "MessageType": "Connect", "DeviceID": deviceID, "PortNumber": networkPort
            ], on: socket)
            guard let number = response["Number"] as? NSNumber else { throw ControlError("设备连接响应缺少状态") }
            switch number.intValue {
            case 0: return socket
            case 2: throw ControlError("iPad 的 USB 数据连接已断开")
            case 3: throw ControlError("iPad 上的服务尚未开启（端口 \(port)）")
            default: throw ControlError("设备拒绝了 USB 连接（状态 \(number.intValue)）")
            }
        } catch {
            socket.close()
            throw error
        }
    }

    public func details(for device: USBDevice) throws -> USBDevice {
        let socket = try connect(deviceID: device.deviceID, port: 62078)
        defer { socket.close() }
        let body = try PropertyListSerialization.data(fromPropertyList: [
            "Label": "iControl", "Request": "GetValue"
        ], format: .xml, options: 0)
        var request = Data()
        request.appendBE(UInt32(body.count))
        request.append(body)
        try socket.write(request, timeout: timeout)
        let length = Int(try socket.read(count: 4, timeout: timeout).uint32BE(at: 0))
        guard length > 0, length <= 1024 * 1024 else { throw ControlError("设备信息长度不合法") }
        let data = try socket.read(count: length, timeout: timeout)
        guard let response = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            throw ControlError("无法读取 iPad 信息")
        }
        if let error = response["Error"] as? String { throw ControlError("请解锁 iPad 并信任这台 Mac（\(error)）") }
        let value = response["Value"] as? [String: Any] ?? [:]
        var result = device
        result.name = value["DeviceName"] as? String ?? "iPad"
        result.productType = value["ProductType"] as? String ?? ""
        result.version = value["ProductVersion"] as? String ?? ""
        return result
    }

    public func vncGreeting(device: USBDevice, port: UInt16 = 5901) throws -> String {
        let socket = try connect(deviceID: device.deviceID, port: port)
        defer { socket.close() }
        let greeting = try socket.read(count: 12, timeout: 2000)
        guard let text = String(data: greeting, encoding: .ascii),
              text.range(of: #"^RFB [0-9]{3}\.[0-9]{3}\n$"#, options: .regularExpression) != nil else {
            throw ControlError("端口 \(port) 的服务没有返回 VNC 协议标识")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func sshPort(device: USBDevice) throws -> UInt16 {
        for port: UInt16 in [22, 44] {
            do {
                let socket = try connect(deviceID: device.deviceID, port: port)
                defer { socket.close() }
                var banner = Data()
                let deadline = ProcessInfo.processInfo.systemUptime + 2.0
                // Read only the version line; OpenSSH permits a preceding notice.
                for _ in 0..<512 {
                    let remaining = Int32((deadline - ProcessInfo.processInfo.systemUptime) * 1000)
                    guard remaining > 0 else { throw ControlError("SSH 服务响应超时") }
                    let byte = try socket.read(count: 1, timeout: remaining)
                    banner.append(byte)
                    if byte.first == 10 {
                        let line = String(decoding: banner, as: UTF8.self)
                        if line.hasPrefix("SSH-") { return port }
                        banner.removeAll(keepingCapacity: true)
                    }
                }
            } catch { continue }
        }
        throw ControlError("iPad 的 SSH 服务没有响应。请在 Sileo 安装 OpenSSH，保持设备解锁后重试。")
    }
}
