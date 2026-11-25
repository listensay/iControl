import Foundation
import CTransport
import Darwin

private final class ViewerSession {
    let socket: SocketConnection
    var remote: SocketConnection?
    init(socket: SocketConnection) { self.socket = socket }
}

/// Serves bundled viewer assets and a binary WebSocket bridge on loopback only.
/// Each launch uses a random URL path; WebSocket upgrades also require our origin.
public final class LocalViewerServer: @unchecked Sendable {
    public let port: UInt16
    public let url: URL
    private let origin: String
    private let token: String
    private let resources: URL
    private let targetPort: UInt16
    private let listener: SocketConnection
    private let lock = NSLock()
    private var running = true
    private var sessions: [UUID: ViewerSession] = [:]

    public init(resources: URL, targetPort: UInt16, preferredPort: UInt16 = 18080) throws {
        self.resources = resources.resolvingSymlinksInPath()
        self.targetPort = targetPort
        token = UUID().uuidString.replacingOccurrences(of: "-", with: "") + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        var descriptor = ic_listen_loopback(preferredPort)
        if descriptor < 0, errno == EADDRINUSE, preferredPort != 0 { descriptor = ic_listen_loopback(0) }
        guard descriptor >= 0 else { throw ControlError.socket("无法打开控制画面") }
        listener = SocketConnection(descriptor: descriptor)
        port = ic_bound_port(descriptor)
        origin = "http://127.0.0.1:\(port)"
        url = URL(string: "\(origin)/\(token)/index.html")!
        DispatchQueue(label: "icontrol.viewer.accept", qos: .userInitiated).async { [self] in acceptRequests() }
    }

    public func stop() {
        lock.lock()
        guard running else { lock.unlock(); return }
        running = false
        listener.cancel()
        for session in sessions.values { session.socket.cancel(); session.remote?.cancel() }
        lock.unlock()
    }

    public func activeSessionCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        return sessions.count
    }

    private func isRunning() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return running
    }

    private func acceptRequests() {
        defer { listener.close() }
        while isRunning() {
            let fd = ic_accept_timeout(listener.descriptor, 500)
            if fd == -2 { continue }
            guard fd >= 0 else { stop(); return }
            let session = ViewerSession(socket: SocketConnection(descriptor: fd))
            let id = UUID()
            lock.lock()
            if !running || sessions.count >= 32 { lock.unlock(); session.socket.close(); continue }
            sessions[id] = session
            lock.unlock()
            DispatchQueue.global(qos: .userInitiated).async { [self] in serve(session, id: id) }
        }
    }

    private func serve(_ session: ViewerSession, id: UUID) {
        defer {
            lock.lock(); sessions.removeValue(forKey: id); lock.unlock()
            session.socket.close()
            session.remote?.close()
        }
        do {
            let request = try HTTPRequest.read(from: session.socket)
            guard request.headers["host"] == "127.0.0.1:\(port)",
                  let path = request.path.removingPercentEncoding, path.hasPrefix("/\(token)/"),
                  !path.contains("?"), !path.contains("#"), !path.contains("\\"), !path.contains("\0") else {
                try respond(session.socket, status: "403 Forbidden", type: "text/plain", body: Data("Forbidden".utf8))
                return
            }
            let relative = String(path.dropFirst(token.count + 2))
            if relative == "vnc" {
                try session.socket.write(request.webSocketResponse(expectedOrigin: origin))
                let remote = try SocketConnection.loopback(port: targetPort)
                lock.lock(); session.remote = remote; let proceed = running; lock.unlock()
                guard proceed else { remote.cancel(); return }
                bridge(session.socket, remote: remote)
                return
            }
            let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
            guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.hasPrefix(".") }) else {
                try respond(session.socket, status: "403 Forbidden", type: "text/plain", body: Data())
                return
            }
            let file = resources.appendingPathComponent(relative).resolvingSymlinksInPath()
            guard file.path.hasPrefix(resources.path + "/"),
                  let size = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  size.isRegularFile == true, (size.fileSize ?? Int.max) <= WebSocketFrame.maximumPayload else {
                try respond(session.socket, status: "404 Not Found", type: "text/plain", body: Data())
                return
            }
            let types = ["html": "text/html; charset=utf-8", "js": "text/javascript; charset=utf-8", "css": "text/css", "svg": "image/svg+xml", "png": "image/png", "json": "application/json"]
            guard let type = types[file.pathExtension] else {
                try respond(session.socket, status: "404 Not Found", type: "text/plain", body: Data())
                return
            }
            try respond(session.socket, status: "200 OK", type: type, body: Data(contentsOf: file))
        } catch {
            // An interrupted or rejected local request does not affect other sessions.
        }
    }

    private func respond(_ socket: SocketConnection, status: String, type: String, body: Data) throws {
        let csp = "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self' ws://127.0.0.1:\(port); frame-ancestors 'none'; base-uri 'none'"
        let headers = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nContent-Security-Policy: \(csp)\r\n\r\n"
        try socket.write(Data(headers.utf8), timeout: 5000)
        try socket.write(body, timeout: 10000)
    }

    private func bridge(_ client: SocketConnection, remote: SocketConnection) {
        let outputLock = NSLock()
        let pump = DispatchGroup()
        func send(_ payload: Data, opcode: UInt8 = 2) throws {
            outputLock.lock(); defer { outputLock.unlock() }
            try client.write(WebSocketFrame.server(opcode: opcode, payload: payload), timeout: 5000)
        }
        pump.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { client.cancel(); pump.leave() }
            do {
                while true {
                    guard let bytes = try remote.readSome(timeout: 1000) else { continue }
                    if bytes.isEmpty { try? send(Data([3, 232]), opcode: 8); return }
                    try send(bytes)
                }
            } catch { return }
        }
        do {
            var fragmented = false
            var messageBytes = 0
            while true {
                // A silent, authenticated VNC session can stay open indefinitely.
                // Polling the first byte lets shutdown cancel it immediately.
                let frame = try WebSocketFrame.readClient(from: client, idleTimeout: 24 * 60 * 60 * 1000)
                switch frame.opcode {
                case 2:
                    guard !fragmented else { throw ControlError("WebSocket 分片顺序错误") }
                    fragmented = !frame.isFinal
                    messageBytes = frame.payload.count
                    try remote.write(frame.payload, timeout: 5000)
                case 0:
                    guard fragmented else { throw ControlError("WebSocket 分片顺序错误") }
                    messageBytes += frame.payload.count
                    guard messageBytes <= WebSocketFrame.maximumPayload else { throw ControlError("WebSocket 消息过长") }
                    fragmented = !frame.isFinal
                    try remote.write(frame.payload, timeout: 5000)
                case 8:
                    try? send(frame.payload, opcode: 8)
                    client.cancel(); remote.cancel(); pump.wait(); return
                case 9: try send(frame.payload, opcode: 10)
                case 10: break
                default: throw ControlError("控制画面只接受二进制数据")
                }
            }
        } catch {
            try? send(Data([3, 234]), opcode: 8)
        }
        client.cancel(); remote.cancel(); pump.wait()
    }
}
