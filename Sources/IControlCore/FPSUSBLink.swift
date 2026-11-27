import Foundation
import CRustInput

public enum FPSLinkEvent: Sendable {
    case acknowledgement(milliseconds: Double, contacts: Int, orientation: Int)
    case deviceCursor(available: Bool, visible: Bool)
    case failed(String)
}

private final class FPSNoticeSink: Sendable {
    let receive: @Sendable (FPSLinkEvent) -> Void
    init(_ receive: @escaping @Sendable (FPSLinkEvent) -> Void) { self.receive = receive }
}
private func receiveFPSNotice(_ context: UnsafeMutableRawPointer?, _ kind: Int32, _ ms: Double,
                              _ a: UInt8, _ b: UInt8, _ message: UnsafePointer<CChar>?) {
    guard let context else { return }
    let sink = Unmanaged<FPSNoticeSink>.fromOpaque(context).takeUnretainedValue()
    switch kind {
    case 1: sink.receive(.acknowledgement(milliseconds: ms, contacts: Int(a), orientation: Int(b)))
    case 2: sink.receive(.deviceCursor(available: a != 0, visible: b != 0))
    case 3: sink.receive(.failed(message.map { String(cString: $0) } ?? "FPS 输入连接中断。"))
    default: break
    }
}
private func releaseFPSSink(_ context: UnsafeMutableRawPointer?) {
    if let context { Unmanaged<FPSNoticeSink>.fromOpaque(context).release() }
}

/// USBMux still opens the native tunnel; Rust takes exclusive ownership after Connect.
/// All methods after init only submit to the session mailbox (never wait for an ACK or join).
public final class FPSUSBLink: @unchecked Sendable {
    public let supportsDeviceCursor: Bool
    private let handle: OpaquePointer

    public static func connect(mux: USBMux, device: USBDevice, token: String,
                               callback: @escaping @Sendable (FPSLinkEvent) -> Void = { _ in }) throws -> FPSUSBLink {
        let socket = try mux.connect(deviceID: device.deviceID, port: FPSWire.port)
        return try FPSUSBLink(socket: socket, token: token, callback: callback)
    }
    public init(socket: SocketConnection, token: String,
                callback: @escaping @Sendable (FPSLinkEvent) -> Void = { _ in }) throws {
        let secret = try FPSAccessToken.bytes(token)
        let fd = try socket.takeForFPS()
        let sink = Unmanaged.passRetained(FPSNoticeSink(callback)).toOpaque()
        var supported: UInt8 = 0
        var error = [CChar](repeating: 0, count: 512)
        let opened = secret.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            error.withUnsafeMutableBufferPointer { text in
                ic_fps_open(fd, bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, sink,
                            receiveFPSNotice, releaseFPSSink, &supported, text.baseAddress, text.count)
            }
        }
        guard let opened else { throw ControlError(String(cString: error)) }
        self.handle = opened; supportsDeviceCursor = supported != 0
    }
    private func use<T>(_ body: (OpaquePointer) -> T) -> T { withExtendedLifetime(self) { body(handle) } }
    public func startCapture(profile: FPSProfile, aspect: Double) throws {
        let ok = try FPSRustProfile.withConfig(profile, aspect: aspect) { p, buttons, links in
            use { ic_fps_capture($0, p, buttons.baseAddress, buttons.count, links.baseAddress, links.count) }
        }
        guard ok != 0 else { throw ControlError("无法启动 FPS 输入，请重新连接。") }
    }
    public func key(_ code: String, down: Bool) {
        if let k = FPSRustProfile.key(code) { use { ic_fps_key($0, k, down ? 1 : 0) } }
    }
    public func pulse(_ action: FPSAction) { use { ic_fps_pulse($0, action.touchID) } }
    public func cursorMode(_ on: Bool) { use { ic_fps_mode($0, on ? 1 : 0) } }
    public func setAspect(_ value: Double) { use { ic_fps_aspect($0, value) } }
    public func mouse(dx: Double, dy: Double, age: TimeInterval) { use { ic_fps_mouse($0, ICPoint(x: dx, y: dy), age) } }
    public func pointerMoved(_ point: FPSPoint, age: TimeInterval = 0) { use { ic_fps_pointer_move($0, point.raw, age) } }
    public func pointerDown(_ point: FPSPoint) { use { ic_fps_pointer_down($0, point.raw) } }
    public func pointerUp() { use { ic_fps_pointer_up($0) } }
    public func pointerHoverOutside() { use { ic_fps_pointer_hide($0) } }
    public func releaseAll() { use { ic_fps_release($0) } }
    public func send(_ state: FPSState) {
        let contacts = state.contacts.map { ICContact(point: $0.point.raw, id: $0.id) }
        contacts.withUnsafeBufferPointer { buf in use { ic_fps_state($0, UInt8(state.orientation.rawValue), buf.baseAddress, buf.count) } }
    }
    public func setDeviceCursor(_ cursor: FPSDeviceCursor?) {
        guard supportsDeviceCursor else { return }
        if let cursor {
            var point = cursor.point.raw
            use { ic_fps_cursor($0, UInt8(cursor.orientation.rawValue), &point) }
        } else { use { ic_fps_cursor($0, 255, nil) } }
    }
    public func stop() { use { ic_fps_stop($0) } }
    deinit { ic_fps_destroy(handle) }
}
