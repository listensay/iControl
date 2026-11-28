import AVFoundation
import CoreAudio
import Foundation
import IControlCore

struct IPadAudioSource: Identifiable, Equatable, Sendable {
    let id: String                 // AVFoundation endpoint UID, never the localized name
    let name: String
    enum Match: Int, Sendable { case manual, soleTablet, deviceName, serial }
    let match: Match

    /// IDAM endpoints don't always publish a USB serial. Prefer positive identity;
    /// use a name or a generic iPad endpoint only when its USB context is unambiguous.
    init?(_ input: AVCaptureDevice, target: USBDevice, peers: [USBDevice]) {
        guard input.isConnected, input.hasMediaType(.audio), !input.hasMediaType(.video),
              !input.hasMediaType(.muxed), !input.uniqueID.isEmpty else { return nil }
        let transport = UInt32(truncatingIfNeeded: input.transportType)
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn, kAudioDeviceTransportTypeBluetooth,
             kAudioDeviceTransportTypeBluetoothLE, kAudioDeviceTransportTypeAirPlay,
             kAudioDeviceTransportTypeContinuityCaptureWired, kAudioDeviceTransportTypeContinuityCaptureWireless,
             kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeAutoAggregate:
            return nil
        default: break // Some IDAM drivers do not report USB as their HAL transport.
        }
        let uid = input.uniqueID.lowercased()
        let model = input.modelID.lowercased()
        let label = input.localizedName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let metadata = [uid, model, label].joined(separator: " ")
        guard !["microphone", "continuity", "headset", "airpods", "麦克风", "麥克風", "マイク"].contains(where: metadata.contains),
              metadata.range(of: #"\bmic\b"#, options: .regularExpression) == nil else { return nil }

        let sameName = label == target.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let driver = uid + " " + model
        let tabletInput = ["idam", "ipad", "ios audio", "ios device"].contains(where: driver.contains)
        let matchesTarget = Self.containsUDID(target.udid, in: uid)
        guard !driver.contains("simulator"), matchesTarget || !driver.contains("iphone"),
              !peers.contains(where: { Self.containsUDID($0.udid, in: uid) }) else { return nil }
        // Do not present an unrelated USB mic simply because it is external or the default.
        guard matchesTarget || tabletInput || sameName || label.contains("ipad") || label.contains("idam") || label == "ios device" else { return nil }
        let peerHasName = peers.contains { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == label }
        let genericLabel = ["ipad", "ipad audio", "ios device", "ios audio", "idam"].contains(label)
        if !matchesTarget {
            // A previous tablet's audio endpoint may outlive its USB attachment.
            guard uid.range(of: #"(?<![0-9a-f])(?:[0-9a-f]{8}-?[0-9a-f]{16}|[0-9a-f]{40})(?![0-9a-f])"#, options: .regularExpression) == nil,
                  !peerHasName || sameName || genericLabel else { return nil }
        }
        id = input.uniqueID
        name = input.localizedName
        let appleUSB = transport == kAudioDeviceTransportTypeUSB && input.manufacturer.lowercased().contains("apple")
        if matchesTarget { match = .serial }
        else if sameName && !peerHasName && !genericLabel && (tabletInput || appleUSB) { match = .deviceName }
        else if peers.isEmpty && (tabletInput || appleUSB) && genericLabel { match = .soleTablet }
        else { match = .manual }
    }

    /// Never break ties by discovery order. A generic IDAM input is usable only
    /// with one tablet attached and one candidate, not just one unreserved UID.
    static func resolve(_ sources: [Self], preferredID: String?, reservedIDs: Set<String>) -> Self? {
        if let preferred = sources.first(where: { $0.id == preferredID }) { return preferred }
        let eligible = sources.filter { $0.match == .serial || !reservedIDs.contains($0.id) }
        guard let rank = eligible.map(\.match.rawValue).max(), rank > Match.manual.rawValue else { return nil }
        let best = eligible.filter { $0.match.rawValue == rank }
        guard best.count == 1, best[0].match != .soleTablet || sources.count == 1 else { return nil }
        return best[0]
    }

    private static func containsUDID(_ udid: String, in uid: String) -> Bool {
        let hex = udid.lowercased().replacingOccurrences(of: "-", with: "")
        guard [24, 40].contains(hex.count), hex.allSatisfy(\.isHexDigit) else { return false }
        // Require a whole serial, not a suffix or another device's serial with a shared prefix.
        let serial = hex.count == 24 ? "\(hex.prefix(8))-?\(hex.dropFirst(8))" : hex
        return uid.range(of: "(?<![0-9a-f])\(serial)(?![0-9a-f])", options: .regularExpression) != nil
    }
}
