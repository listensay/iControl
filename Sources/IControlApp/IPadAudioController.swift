import AVFoundation
import Combine
import Foundation
import IControlCore

struct IPadAudioState: Equatable, Sendable {
    enum Action: Equatable, Sendable { case none, setup, privacy, retry }
    var message: String
    var action: Action = .none
    var sources: [IPadAudioSource] = []
    var sourceID: String?
}

@MainActor
final class IPadAudioController: ObservableObject {
    @Published private(set) var enabled = false
    @Published private(set) var state = IPadAudioState(message: "已关闭")
    private var target: USBDevice?
    private var peers: [USBDevice] = []
    // Only remember the user's explicit choice; an inferred endpoint can change after reconnect.
    private var preferredIDs = UserDefaults.standard.dictionary(forKey: "ipadAudio.inputByUDID") as? [String: String] ?? [:]
    private var monitor: IPadAudioMonitor?
    private var epoch = UUID()
    private var awaitingPermission = false

    /// Pass nil unless the selected USB attachment has connected successfully.
    /// The usbmux deviceID distinguishes reattachments even if the UDID is unchanged.
    func update(device: USBDevice?, attached: [USBDevice]) {
        let others = device.map { target in
            attached.filter { $0.udid != target.udid }.sorted { $0.udid < $1.udid }
        } ?? []
        guard target != device || peers != others else { return }
        target = device
        peers = others
        if enabled { restart() }
    }

    func setEnabled(_ value: Bool) {
        guard enabled != value else { return }
        enabled = value
        restart()
    }

    func select(_ id: String) {
        guard let target, enabled, state.sources.contains(where: { $0.id == id }), id != state.sourceID else { return }
        preferredIDs = preferredIDs.filter { $0.value != id }
        preferredIDs[target.udid] = id
        UserDefaults.standard.set(preferredIDs, forKey: "ipadAudio.inputByUDID")
        restart()
    }

    func retry() { if enabled { restart() } }

    func shutdown() {
        target = nil; peers = []; enabled = false
        restart()
    }

    private func restart() {
        let ticket = UUID()
        epoch = ticket
        monitor?.cancel(); monitor = nil
        guard enabled else { state = .init(message: "已关闭"); return }
        guard let target else { state = .init(message: "连接选定的 USB iPad 后开始监听。"); return }
        guard target.isIPad else {
            state = .init(message: "尚未确认设备是 iPad。请解锁、信任这台 Mac，然后刷新 USB 设备。")
            return
        }
        // A raw SwiftPM executable has no app usage description. Never trigger TCC there.
        guard let usage = Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") as? String,
              !usage.isEmpty else { state = .init(message: "请从打包的 iControl.app 开启声音。"); return }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            state = .init(message: "请允许音频输入。“麦克风”权限也用于 iPad 的 USB 数字音频。")
            guard !awaitingPermission else { return }
            awaitingPermission = true
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                Task { @MainActor in
                    guard let self else { return }
                    self.awaitingPermission = false
                    // Reconcile the *current* intent. Never start the device that requested permission blindly.
                    guard self.enabled, self.target != nil else { return }
                    if granted { self.restart() } else { self.state = Self.denied }
                }
            }
        case .denied: state = Self.denied
        case .restricted: state = .init(message: "系统策略限制了音频输入。请联系管理员解除限制后重试。", action: .retry)
        case .authorized:
            state = .init(message: "正在查找 \(target.name) 的音频输入…")
            let reservedIDs = Set(preferredIDs.filter { $0.key != target.udid }.values)
            let monitor = IPadAudioMonitor(target: target, peers: peers, preferredID: preferredIDs[target.udid], reservedIDs: reservedIDs) { [weak self] snapshot in
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.epoch == ticket else { return }
                    self.state = snapshot
                }
            }
            self.monitor = monitor
            monitor.start()
        @unknown default: state = .init(message: "无法确认音频输入权限。", action: .retry)
        }
    }

    private static var denied: IPadAudioState {
        .init(message: "请在“隐私与安全性 → 麦克风”中允许 iControl，然后重试；若系统提示，请退出并重新打开应用。", action: .privacy)
    }

    deinit { monitor?.cancel() }
}
