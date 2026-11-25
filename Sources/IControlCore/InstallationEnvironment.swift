import Foundation
import CryptoKit

public enum JailbreakMode: String, Sendable { case rootless, rootful }

public struct InstallationEnvironment: Sendable, Equatable {
    public let architecture: String
    public let mode: JailbreakMode
    public let firmware: String
    public let userID: Int
    public let hasSudo: Bool
    public let sudoWithoutPassword: Bool
    public let hasPreferenceLoader: Bool
    public let firmwareSupported: Bool
    public let installedVersion: String
    public let managedByIControl: Bool
    public var prefix: String { mode == .rootless ? "/var/jb" : "" }
    public var canInstall: Bool { firmwareSupported && hasPreferenceLoader && (userID == 0 || hasSudo) }
    public var requirements: [String] {
        var result: [String] = []
        if !firmwareSupported { result.append("控制端需要 iPadOS 14 或以上，当前系统版本未通过检测。") }
        if !hasPreferenceLoader { result.append("请先在 Sileo 中安装 PreferenceLoader，然后重新检测。") }
        if userID != 0 && !hasSudo { result.append("当前 SSH 账户没有管理员权限。请使用 root 账户，或安装并配置 sudo。") }
        return result
    }

    public static func parse(_ output: String) throws -> InstallationEnvironment {
        var values: [String: String] = [:]
        for line in output.components(separatedBy: .newlines) where line.hasPrefix("ICONTROL:") {
            let pair = line.dropFirst(9).split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2, values[String(pair[0])] == nil else { throw ControlError("设备环境信息格式不正确") }
            values[String(pair[0])] = String(pair[1])
        }
        guard let architecture = values["ARCH"], let prefix = values["PREFIX"],
              let firmware = values["FIRMWARE"], let userID = Int(values["UID"] ?? ""), userID >= 0,
              ["SUDO", "SUDO_NOPASS", "PREFERENCELOADER", "FIRMWARE_SUPPORTED", "MANAGED"].allSatisfy({ ["0", "1"].contains(values[$0] ?? "") }) else {
            throw ControlError("未能完整读取越狱环境。请确认 iPad 已越狱并安装 OpenSSH。")
        }
        let mode: JailbreakMode
        if architecture == "iphoneos-arm64", prefix == "/var/jb" { mode = .rootless }
        else if architecture == "iphoneos-arm", prefix.isEmpty { mode = .rootful }
        else { throw ControlError("不支持或不一致的越狱架构：\(architecture)。没有选择安装包。") }
        return InstallationEnvironment(architecture: architecture, mode: mode, firmware: firmware, userID: userID,
                                       hasSudo: values["SUDO"] == "1", sudoWithoutPassword: values["SUDO_NOPASS"] == "1",
                                       hasPreferenceLoader: values["PREFERENCELOADER"] == "1", firmwareSupported: values["FIRMWARE_SUPPORTED"] == "1",
                                       installedVersion: values["INSTALLED"] ?? "", managedByIControl: values["MANAGED"] == "1")
    }
}

public struct ServerPackage: Sendable {
    public let filename: String
    public let sha256: String
    public let architecture: String
    public static let version = "3.2-272"
    public static let rootless = ServerPackage(filename: "com.82flex.trollvnc_3.2-272_iphoneos-arm64.deb",
                                               sha256: "eff873a15d6b5a2afb287111f04a8a89532cb4bf7acbf63b5e3160c8a27753df", architecture: "iphoneos-arm64")
    public static let rootful = ServerPackage(filename: "com.82flex.trollvnc_3.2-272_iphoneos-arm.deb",
                                              sha256: "6e19c0e3df87ba1e83e6ebf2208c3480ce7defb858c2835ac50cef611d385028", architecture: "iphoneos-arm")

    public static func forEnvironment(_ environment: InstallationEnvironment) -> ServerPackage {
        environment.mode == .rootless ? .rootless : .rootful
    }

    public func verifiedData(in directory: URL) throws -> Data {
        let file = directory.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: file.path) else { throw ControlError("应用中的控制端安装包缺失。请重新构建或下载完整应用。") }
        let data = try Data(contentsOf: file)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == sha256 else { throw ControlError("控制端安装包 SHA256 校验失败，已停止安装。") }
        return data
    }
}

public enum ServerConfiguration {
    public static func plist(password: String, scale: Double = 0.65, framesPerSecond: Int = 30) throws -> Data {
        try ControlPassword.validate(password)
        guard [0.5, 0.65, 0.8, 1.0].contains(scale), [15, 30, 60].contains(framesPerSecond) else { throw ControlError("画质设置不受支持") }
        let values: [String: Any] = [
            "ICONTROLConfiguration": 1, "Enabled": true, "BindHost": "127.0.0.1", "Port": 5901,
            "FullPassword": password, "ViewOnlyPassword": "", "ViewOnly": false,
            "DesktopName": "iPad · iControl", "Scale": scale, "FrameRateSpec": String(framesPerSecond),
            "KeepAliveSec": 15, "BonjourEnabled": false, "HttpPort": 0, "FileTransferEnabled": false,
            "ReverseMode": "none", "ReverseSocket": "", "ClipboardEnabled": true,
            "OrientationSync": true, "AutoAssistEnabled": false, "ServerCursor": false,
            "ModifierMap": "std", "KeyLogging": false, "DeferWindowSec": 0.015
        ]
        return try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0)
    }
}
