import Foundation
import Security
import CTransport
import Darwin
import CryptoKit

public struct SSHCredentials: Sendable {
    public let username: String
    public let password: String
    public let administratorPassword: String

    public init(username: String, password: String, administratorPassword: String? = nil) throws {
        guard username.range(of: #"^[A-Za-z_][A-Za-z0-9_-]{0,63}$"#, options: .regularExpression) != nil else {
            throw ControlError("SSH 用户名格式不正确")
        }
        guard !password.isEmpty, !password.contains("\n"), !password.contains("\r"), !password.contains("\0") else {
            throw ControlError("请输入 iPad 的 SSH 登录密码")
        }
        let admin = administratorPassword ?? password
        guard !admin.contains("\n"), !admin.contains("\r"), !admin.contains("\0") else {
            throw ControlError("管理员密码不能含有换行符")
        }
        self.username = username; self.password = password; self.administratorPassword = admin
    }
}

public enum ControlPassword {
    public static func generate() -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789")
        return String((0..<8).map { _ in alphabet.randomElement()! })
    }
    public static func validate(_ password: String) throws {
        guard password.utf8.count == 8, password.utf8.allSatisfy({ $0 >= 33 && $0 <= 126 }) else {
            throw ControlError("控制密码需要正好 8 个可打印的英文字符或数字")
        }
    }
}

/// Passwords are sent only to a native SSH_ASKPASS child over a private socket.
/// They never appear in process arguments, the environment, or log files.
public final class AskpassServer: @unchecked Sendable {
    public let path: String
    public let token: String
    private let listener: SocketConnection
    private let lock = NSLock()
    private var password: String
    private var running = true
    private var active: SocketConnection?

    public init(password: String) throws {
        self.password = password
        token = UUID().uuidString + UUID().uuidString
        path = "/tmp/icontrol-\(getuid())-\(UUID().uuidString.prefix(20)).sock"
        let fd = ic_listen_unix(path)
        guard fd >= 0 else { throw ControlError.socket("无法创建安全密码通道") }
        listener = SocketConnection(descriptor: fd)
        DispatchQueue(label: "icontrol.askpass", qos: .userInitiated).async { [self] in serve() }
    }

    public func stop() {
        lock.lock()
        if running { running = false; password = ""; listener.cancel(); active?.cancel() }
        lock.unlock()
    }

    private func serve() {
        defer { listener.close(); try? FileManager.default.removeItem(atPath: path) }
        while true {
            lock.lock(); let alive = running; lock.unlock()
            if !alive { return }
            let fd = ic_accept_timeout(listener.descriptor, 500)
            if fd == -2 { continue }
            guard fd >= 0 else { return }
            let client = SocketConnection(descriptor: fd)
            lock.lock(); active = client; let proceed = running; lock.unlock()
            if proceed {
                do {
                    let size = Int(try client.read(count: 4, timeout: 2000).uint32BE(at: 0))
                    guard size > 0, size < 256 else { throw ControlError("密码通道请求无效") }
                    let request = String(decoding: try client.read(count: size, timeout: 2000), as: UTF8.self)
                    lock.lock(); let secret = running && request == token ? password : ""; lock.unlock()
                    guard !secret.isEmpty else { throw ControlError("密码通道身份不匹配") }
                    let bytes = Data(secret.utf8)
                    var response = Data(); response.appendBE(UInt32(bytes.count)); response.append(bytes)
                    try client.write(response, timeout: 2000)
                } catch { }
            }
            lock.lock(); active = nil; lock.unlock()
            client.close()
        }
    }

    public static func reply(environment: [String: String], prompt: String) throws -> String {
        guard prompt.lowercased().contains("password"),
              let path = environment["ICONTROL_ASKPASS_SOCKET"], let token = environment["ICONTROL_ASKPASS_TOKEN"] else {
            throw ControlError("不支持的密码提示")
        }
        let socket = try SocketConnection.unix(path: path, timeout: 2000)
        defer { socket.close() }
        let bytes = Data(token.utf8)
        var request = Data(); request.appendBE(UInt32(bytes.count)); request.append(bytes)
        try socket.write(request, timeout: 2000)
        let size = Int(try socket.read(count: 4, timeout: 2000).uint32BE(at: 0))
        guard size > 0, size <= 65536 else { throw ControlError("密码通道响应无效") }
        return String(decoding: try socket.read(count: size, timeout: 2000), as: UTF8.self)
    }
}

public enum PasswordStore {
    private static let service = "com.icontrol.mac.vnc"
    private static func query(device: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: device]
    }
    public static func load(device: String) throws -> String? {
        var request = query(device: device)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw ControlError("无法读取钥匙串中的控制密码（\(status)）") }
        return String(data: data, encoding: .utf8)
    }
    public static func save(_ password: String, device: String) throws {
        let value: [String: Any] = [kSecValueData as String: Data(password.utf8)]
        var status = SecItemUpdate(query(device: device) as CFDictionary, value as CFDictionary)
        if status == errSecItemNotFound {
            var item = query(device: device)
            item.merge(value) { _, new in new }
            item[kSecAttrLabel as String] = "iControl · iPad 控制密码"
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw ControlError("无法把控制密码保存到钥匙串（\(status)）") }
    }
    public static func remove(device: String) throws {
        let status = SecItemDelete(query(device: device) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw ControlError("无法删除已保存的控制密码（\(status)）") }
    }
}

public enum SSHTrust {
    public static func alias(for device: String) -> String {
        "icontrol-" + SHA256.hash(data: Data(device.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }
    public static func reset(device: String, supportDirectory: URL) throws {
        let file = supportDirectory.appendingPathComponent("known_hosts")
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        let target = alias(for: device)
        let contents = try String(contentsOf: file, encoding: .utf8)
        let filtered = contents.components(separatedBy: .newlines).filter { line in
            guard let hosts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).first else { return true }
            return !hosts.split(separator: ",").contains(Substring(target))
        }.joined(separator: "\n")
        try Data(filtered.utf8).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
