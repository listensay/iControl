import Foundation
import Security
import CryptoKit

public enum FPSAccessToken {
    public static func generate() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw ControlError("无法生成 FPS 通道凭据")
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
    public static func bytes(_ token: String) throws -> Data {
        guard token.utf8.count == 64, token.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw ControlError("FPS 控制端凭据缺失或无效，请重新安装 / 配置控制端")
        }
        let chars = Array(token.utf8)
        func nibble(_ value: UInt8) -> UInt8 { value <= 57 ? value - 48 : value - 87 }
        return Data(stride(from: 0, to: 64, by: 2).map { nibble(chars[$0]) << 4 | nibble(chars[$0 + 1]) })
    }
    public static func keychainAccount(device: String) -> String { "fps:" + device }
}

/// v1: 8-byte greeting, 32-byte random authentication token, 8-byte reply.
/// State header = opcode/count/orientation/reserved/sequence (network order).
/// Each 8-byte contact = id/reserved/u16 x/u16 y/u16 reserved. All coordinates
/// are normalized in the displayed iPad orientation, independent of VNC scale.
public enum FPSWire {
    public static let port: UInt16 = 5902
    /// Revision 14 adds optional device cursor frames and ACK status flags.
    /// Revision 13 contains the orientation fix and keeps touch-only support.
    public static let greeting = Data("ICFPS014".utf8)
    public static let touchOnlyGreeting = Data("ICFPS013".utf8)
    public static let legacyGreeting = Data("ICFPS001".utf8)
    public static let ready = Data("READY001".utf8)
    public static let maximumContacts = 10
    public static let maximumIdentifier: UInt8 = 16
    public static let watchdogMilliseconds = 350

    /// Optional opcode 4 extension. A cursor is a visual position, never a
    /// contact. Only revision 14 daemons accept it; revision 13 remains usable
    /// for touch input and Mac cursor clicking.
    public static func cursor(_ cursor: FPSDeviceCursor?, sequence: UInt32) throws -> Data {
        guard cursor?.point.isValid ?? true else { throw ControlError("iPad 鼠标坐标无效") }
        var bytes = Data([4, cursor == nil ? 0 : 1, UInt8(cursor?.orientation.rawValue ?? 255), 0])
        bytes.appendBE(sequence)
        if let cursor {
            bytes.append(contentsOf: [0, 0])
            for value in [cursor.point.x, cursor.point.y] {
                let scaled = UInt16((value * 65535).rounded())
                bytes.append(contentsOf: [UInt8(scaled >> 8), UInt8(truncatingIfNeeded: scaled)])
            }
            bytes.append(contentsOf: [0, 0])
        }
        return bytes
    }
    public static func decodeCursor(_ bytes: Data) throws -> FPSDeviceCursor? {
        guard bytes.count >= 8, bytes[0] == 4, bytes[1] <= 1, bytes[3] == 0,
              let orientation = FPSOrientation(rawValue: Int(bytes[2])),
              bytes.count == 8 + Int(bytes[1]) * 8 else { throw ControlError("iPad 鼠标数据帧无效") }
        if bytes[1] == 0 { return nil }
        guard bytes[8] == 0, bytes[9] == 0, bytes[14] == 0, bytes[15] == 0 else {
            throw ControlError("iPad 鼠标数据帧无效")
        }
        let x = UInt16(bytes[10]) << 8 | UInt16(bytes[11]), y = UInt16(bytes[12]) << 8 | UInt16(bytes[13])
        return FPSDeviceCursor(point: .init(x: Double(x) / 65535, y: Double(y) / 65535), orientation: orientation)
    }

    public static func state(_ state: FPSState, sequence: UInt32) throws -> Data {
        guard state.contacts.count <= maximumContacts,
              Set(state.contacts.map(\.id)).count == state.contacts.count,
              state.contacts.allSatisfy({ (1...maximumIdentifier).contains($0.id) && $0.point.isValid }) else {
            throw ControlError("FPS 多点触摸状态无效")
        }
        var bytes = Data([1, UInt8(state.contacts.count), UInt8(state.orientation.rawValue), 0])
        bytes.appendBE(sequence)
        for contact in state.contacts.sorted(by: { $0.id < $1.id }) {
            bytes.append(contentsOf: [contact.id, 0])
            for value in [contact.point.x, contact.point.y] {
                let scaled = UInt16((value * 65535).rounded())
                bytes.append(contentsOf: [UInt8(scaled >> 8), UInt8(truncatingIfNeeded: scaled)])
            }
            bytes.append(contentsOf: [0, 0])
        }
        return bytes
    }
    public static func control(_ opcode: UInt8, sequence: UInt32) -> Data {
        var bytes = Data([opcode, 0, 255, 0]); bytes.appendBE(sequence); return bytes
    }
    public static func decode(_ bytes: Data) throws -> (opcode: UInt8, sequence: UInt32, state: FPSState) {
        guard bytes.count >= 8, [1, 2, 3].contains(bytes[0]), bytes[1] <= maximumContacts, bytes[3] == 0,
              let orientation = FPSOrientation(rawValue: Int(bytes[2])),
              bytes.count == 8 + Int(bytes[1]) * 8,
              bytes[0] == 1 || bytes[1] == 0 else { throw ControlError("FPS 数据帧无效") }
        var contacts: [FPSContact] = []
        for i in 0..<Int(bytes[1]) {
            let offset = 8 + i * 8, id = bytes[offset]
            guard (1...maximumIdentifier).contains(id), bytes[offset + 1] == 0,
                  bytes[offset + 6] == 0, bytes[offset + 7] == 0,
                  !contacts.contains(where: { $0.id == id }) else { throw ControlError("FPS 触点编号无效") }
            let x = UInt16(bytes[offset + 2]) << 8 | UInt16(bytes[offset + 3])
            let y = UInt16(bytes[offset + 4]) << 8 | UInt16(bytes[offset + 5])
            contacts.append(FPSContact(id: id, point: FPSPoint(x: Double(x) / 65535, y: Double(y) / 65535)))
        }
        return (bytes[0], bytes.uint32BE(at: 4), FPSState(contacts: contacts, orientation: orientation))
    }
}

public struct FPSDeviceCursor: Equatable, Sendable {
    public var point: FPSPoint
    public var orientation: FPSOrientation
    public init(point: FPSPoint, orientation: FPSOrientation = .automatic) {
        self.point = point; self.orientation = orientation
    }
}

public enum FPSDaemonPackage {
    public static func verifiedData(in resources: URL) throws -> Data {
        let directory = resources.appendingPathComponent("FPSDaemon")
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("manifest.json"))) as? [String: Any]
        guard manifest?["protocol"] as? Int == 1, let expected = manifest?["sha256"] as? String,
              expected.count == 64 else { throw ControlError("FPS 控制端资源清单无效") }
        let bytes = try Data(contentsOf: directory.appendingPathComponent("icontrol-fpsd"))
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        guard digest == expected else { throw ControlError("FPS 控制端 SHA256 校验失败，已停止安装") }
        return bytes
    }
    public static func launchPlist(prefix: String) throws -> Data {
        guard prefix == "" || prefix == "/var/jb" else { throw ControlError("FPS 安装路径无效") }
        return try PropertyListSerialization.data(fromPropertyList: [
            "Label": "com.icontrol.fpsd", "UserName": "root",
            "ProgramArguments": [prefix + "/usr/local/libexec/icontrol-fpsd", "--token-file", "/var/mobile/Library/iControl/fps-token"],
            "RunAtLoad": true, "KeepAlive": true, "ThrottleInterval": 3, "ProcessType": "Interactive",
            "StandardOutPath": "/var/mobile/Library/iControl/fpsd.log", "StandardErrorPath": "/var/mobile/Library/iControl/fpsd.log"
        ], format: .xml, options: 0)
    }
}
