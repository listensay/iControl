import Foundation
import CryptoKit

public struct HTTPRequest {
    public let path: String
    public let headers: [String: String]

    public static func read(from socket: SocketConnection, timeout: TimeInterval = 4) throws -> HTTPRequest {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var bytes = Data()
        while bytes.count < 16384 {
            let remaining = Int32((deadline - ProcessInfo.processInfo.systemUptime) * 1000)
            guard remaining > 0 else { throw ControlError("本机请求超时") }
            bytes.append(try socket.read(count: 1, timeout: remaining))
            if bytes.suffix(4) == Data([13, 10, 13, 10]) { return try parse(bytes) }
        }
        throw ControlError("本机请求头过长")
    }

    public static func parse(_ bytes: Data) throws -> HTTPRequest {
        guard bytes.count <= 16384, let text = String(data: bytes, encoding: .ascii), text.hasSuffix("\r\n\r\n") else {
            throw ControlError("无效的 HTTP 请求")
        }
        let lines = text.components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ", omittingEmptySubsequences: false)
        guard first.count == 3, first[0] == "GET", first[2] == "HTTP/1.1", first[1].hasPrefix("/") else {
            throw ControlError("只接受本机 GET 请求")
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" "), !line.hasPrefix("\t") else {
                throw ControlError("无效的 HTTP 请求头")
            }
            let key = String(line[..<colon]).lowercased()
            guard !key.isEmpty, headers[key] == nil else { throw ControlError("重复的 HTTP 请求头") }
            headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard headers["transfer-encoding"] == nil, headers["content-length"] == nil || headers["content-length"] == "0" else {
            throw ControlError("GET 请求不能带有数据体")
        }
        return HTTPRequest(path: String(first[1]), headers: headers)
    }

    public func webSocketResponse(expectedOrigin: String) throws -> Data {
        let connectionTokens = headers["connection", default: ""].lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard headers["upgrade"]?.lowercased() == "websocket", connectionTokens.contains("upgrade"),
              headers["sec-websocket-version"] == "13", headers["origin"] == expectedOrigin,
              let key = headers["sec-websocket-key"], Data(base64Encoded: key)?.count == 16 else {
            throw ControlError("拒绝了无效的控制画面请求")
        }
        let protocols = headers["sec-websocket-protocol", default: ""].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard protocols.isEmpty || protocols.contains("binary") else { throw ControlError("画面客户端协议不受支持") }
        let digest = Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))
        let accept = Data(digest).base64EncodedString()
        let protocolHeader = protocols.contains("binary") ? "Sec-WebSocket-Protocol: binary\r\n" : ""
        return Data(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\(protocolHeader)\r\n").utf8)
    }
}

public struct WebSocketFrame {
    public let opcode: UInt8
    public let isFinal: Bool
    public let payload: Data
    public static let maximumPayload = 4 * 1024 * 1024

    public static func readClient(from socket: SocketConnection, idleTimeout: Int32 = 30000) throws -> WebSocketFrame {
        var header = try socket.read(count: 1, timeout: idleTimeout)
        header.append(try socket.read(count: 1, timeout: 5000))
        let opcode = header[0] & 15
        let final = header[0] & 128 != 0
        guard header[0] & 112 == 0, header[1] & 128 != 0, [0, 1, 2, 8, 9, 10].contains(opcode) else {
            throw ControlError("无效的 WebSocket 数据帧")
        }
        var length = UInt64(header[1] & 127)
        if length == 126 {
            let extra = try socket.read(count: 2, timeout: 5000)
            length = UInt64(extra[0]) << 8 | UInt64(extra[1])
            guard length >= 126 else { throw ControlError("WebSocket 长度编码不合法") }
        } else if length == 127 {
            let extra = try socket.read(count: 8, timeout: 5000)
            length = extra.reduce(0) { ($0 << 8) | UInt64($1) }
            guard extra[0] & 128 == 0, length >= 65536 else { throw ControlError("WebSocket 长度编码不合法") }
        }
        guard length <= UInt64(maximumPayload), opcode < 8 || (final && length <= 125), !(opcode == 8 && length == 1) else {
            throw ControlError("WebSocket 数据帧超出限制")
        }
        let mask = try socket.read(count: 4, timeout: 5000)
        var payload = try socket.read(count: Int(length), timeout: 5000)
        for index in payload.indices { payload[index] ^= mask[index % 4] }
        return WebSocketFrame(opcode: opcode, isFinal: final, payload: payload)
    }

    public static func server(opcode: UInt8 = 2, payload: Data) -> Data {
        precondition(payload.count <= maximumPayload)
        var result = Data([128 | opcode])
        if payload.count < 126 {
            result.append(UInt8(payload.count))
        } else if payload.count <= 65535 {
            result.append(126)
            result.append(UInt8(truncatingIfNeeded: payload.count >> 8))
            result.append(UInt8(truncatingIfNeeded: payload.count))
        } else {
            result.append(127)
            let count = UInt64(payload.count)
            for shift in stride(from: 56, through: 0, by: -8) { result.append(UInt8(truncatingIfNeeded: count >> shift)) }
        }
        result.append(payload)
        return result
    }
}
