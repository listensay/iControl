import Foundation
import CRustInput

public struct FPSContact: Equatable, Sendable {
    public var id: UInt8
    public var point: FPSPoint
    public init(id: UInt8, point: FPSPoint) { self.id = id; self.point = point }
}

public struct FPSState: Equatable, Sendable {
    public var contacts: [FPSContact]
    public var orientation: FPSOrientation
    public init(contacts: [FPSContact] = [], orientation: FPSOrientation = .automatic) {
        self.contacts = contacts; self.orientation = orientation
    }
}

// Only FPSInputEngine can access the handle. Shared storage is read-only;
// every mutation detaches first. Keep the owner alive over each FFI call.
private final class OfflineStorage: @unchecked Sendable {
    private let handle: OpaquePointer
    init(_ handle: OpaquePointer) { self.handle = handle }
    deinit { ic_offline_destroy(handle) }
    func withHandle<T>(_ body: (OpaquePointer) -> T) -> T {
        withExtendedLifetime(self) { body(handle) }
    }
    func copy() -> OfflineStorage {
        // A valid handle always clones (Rust aborts on allocation failure).
        withHandle { OfflineStorage(ic_offline_clone($0)!) }
    }
}

private struct OfflineFrames {
    let orientation: FPSOrientation
    var frames: [FPSState] = []
}

// Called synchronously; neither the Swift context nor the borrowed Rust
// contact buffer escapes the call. A zero-length frame is still an edge.
private func collectOfflineFrame(_ context: UnsafeMutableRawPointer?, _ contacts: UnsafePointer<ICContact>?, _ count: Int) {
    let result = context!.assumingMemoryBound(to: OfflineFrames.self)
    let frame = FPSState(contacts: UnsafeBufferPointer(start: contacts, count: count).map {
        FPSContact(id: $0.id, point: .init(x: $0.point.x, y: $0.point.y))
    }, orientation: result.pointee.orientation)
    result.pointee.frames.append(frame)
}

/// Deterministic, in-memory view of the capture engine. Only `advance` ticks
/// the look engine; all event methods preserve the order of Rust's edges.
public struct FPSInputEngine: Sendable {
    public let profile: FPSProfile
    public private(set) var captured = false
    public private(set) var cursorMode = false
    public private(set) var state = FPSState()
    public var pressed: Set<String> {
        guard captured else { return [] }
        return storage.withHandle { handle in
            Set(Self.keys.compactMap { ic_offline_pressed(handle, $0.value) != 0 ? $0.key : nil })
        }
    }

    private let pristine: OfflineStorage
    private var storage: OfflineStorage
    private let pulseIndices: [String: Int]
    private var aspect = 4.0 / 3.0
    private static let keys: [String: UInt16] = Dictionary(uniqueKeysWithValues:
        (Array(FPSKey.movement) + FPSKey.choices).compactMap { code in
            FPSRustProfile.key(code).map { (code, $0) }
        })
    // Exposed to the legacy deterministic movement tests.
    static let movementReleaseInterval = 1.0 / 120.0

    public init(profile: FPSProfile) throws {
        self.profile = profile
        let (handle, triggers) = try FPSRustProfile.withConfig(profile, aspect: 4.0 / 3.0) { raw, buttons, links in
            (ic_offline_create(raw, buttons.baseAddress, buttons.count, links.baseAddress, links.count), buttons.map(\.trigger))
        }
        guard let handle else { throw ControlError("无法创建离线 FPS 输入引擎") }
        let initial = OfflineStorage(handle)
        pristine = initial; storage = initial
        // Enabled triggers are unique. Resolve custom and preset IDs against
        // the actual serialized config rather than assuming an array order.
        var indices: [String: Int] = [:]
        for button in profile.buttons where button.enabled {
            if let key = FPSRustProfile.key(button.trigger) { indices[button.id] = triggers.firstIndex(of: key) }
        }
        pulseIndices = indices
    }

    private mutating func withWritableHandle<T>(_ body: (OpaquePointer) -> T) -> T {
        if !isKnownUniquelyReferenced(&storage) { storage = storage.copy() }
        return storage.withHandle(body)
    }

    private mutating func edges(_ body: (OpaquePointer, UnsafeMutableRawPointer) -> Void) -> [FPSState] {
        guard captured else { return [] }
        var result = OfflineFrames(orientation: profile.orientation)
        withUnsafeMutablePointer(to: &result) { context in
            withWritableHandle { body($0, UnsafeMutableRawPointer(context)) }
        }
        if let last = result.frames.last { state = last }
        return result.frames
    }

    public mutating func setAspect(_ value: Double) {
        guard (0.4...3.0).contains(value) else { return }
        aspect = value
        if captured { withWritableHandle { ic_offline_aspect($0, value) } }
    }

    public mutating func start() -> FPSState {
        _ = releaseAll(); captured = true
        let value = aspect
        if value != 4.0 / 3.0 { withWritableHandle { ic_offline_aspect($0, value) } }
        return state
    }

    @discardableResult
    public mutating func releaseAll() -> FPSState {
        storage = pristine; captured = false; cursorMode = false
        state = FPSState(orientation: profile.orientation)
        return state
    }

    public mutating func keyDown(_ code: String, now: TimeInterval) -> [FPSState] {
        guard let key = Self.keys[code] else { return [] }
        var newDown = false
        var frames = edges { newDown = ic_offline_key($0, key, 1, now, $1, collectOfflineFrame) != 0 }
        // Like live capture, dispatch the key before its linked cursor action.
        if newDown && profile.linkedKeys(from: code).contains(FPSKey.cursorAction) {
            frames += setCursorMode(!cursorMode, now: now)
        }
        return frames
    }
    public mutating func keyUp(_ code: String, now: TimeInterval) -> [FPSState] {
        guard let key = Self.keys[code] else { return [] }
        return edges { _ = ic_offline_key($0, key, 0, now, $1, collectOfflineFrame) }
    }
    public mutating func setCursorMode(_ enabled: Bool, now: TimeInterval) -> [FPSState] {
        guard captured, now.isFinite, enabled != cursorMode else { return [] }
        cursorMode = enabled
        return edges { ic_offline_mode($0, enabled ? 1 : 0, now, $1, collectOfflineFrame) }
    }
    public mutating func pointerDown(at point: FPSPoint, now: TimeInterval) -> [FPSState] {
        edges { ic_offline_pointer_down($0, ICPoint(x: point.x, y: point.y), now, $1, collectOfflineFrame) }
    }
    public mutating func pointerMoved(to point: FPSPoint) {
        guard captured else { return }
        withWritableHandle { ic_offline_pointer_move($0, ICPoint(x: point.x, y: point.y)) }
    }
    public mutating func pointerUp(now: TimeInterval) -> [FPSState] {
        edges { ic_offline_pointer_up($0, now, $1, collectOfflineFrame) }
    }
    public mutating func pulse(_ action: FPSAction, now: TimeInterval) -> [FPSState] {
        pulse(button: action.id, now: now)
    }
    public mutating func pulse(button id: String, now: TimeInterval) -> [FPSState] {
        guard let index = pulseIndices[id] else { return [] }
        return edges { ic_offline_pulse($0, index, now, $1, collectOfflineFrame) }
    }
    public mutating func mouseMoved(dx: Double, dy: Double, now: TimeInterval) {
        guard captured else { return }
        withWritableHandle { ic_offline_mouse($0, ICPoint(x: dx, y: dy), now) }
    }
    public mutating func advance(now: TimeInterval) -> [FPSState] {
        edges { ic_offline_advance($0, now, $1, collectOfflineFrame) }
    }
}
