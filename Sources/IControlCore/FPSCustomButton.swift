import Foundation

/// Custom buttons keep their identity across edits and profile reloads. Wire
/// contact identifiers are leased by the input engine while a button is down.
public struct FPSCustomButton: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var trigger: String
    public var point: FPSPoint
    public var behavior: FPSPressBehavior
    public var enabled: Bool
    public var size: Double
    public var swipe: FPSSwipe

    public init(name: String, trigger: String, point: FPSPoint = .init(x: 0.5, y: 0.5),
                behavior: FPSPressBehavior = .tap, enabled: Bool = true, size: Double = FPSBinding.defaultSize) {
        id = "custom." + UUID().uuidString
        self.name = name; self.trigger = trigger; self.point = point
        self.behavior = behavior; self.enabled = enabled; self.size = size
        swipe = .starting(at: point)
    }
    private enum CodingKeys: String, CodingKey { case id, name, trigger, point, behavior, enabled, size, swipe }
    public init(from decoder: Decoder) throws {
        let v = try decoder.container(keyedBy: CodingKeys.self)
        id = try v.decode(String.self, forKey: .id); name = try v.decode(String.self, forKey: .name)
        trigger = try v.decode(String.self, forKey: .trigger); point = try v.decode(FPSPoint.self, forKey: .point)
        behavior = try v.decode(FPSPressBehavior.self, forKey: .behavior); enabled = try v.decode(Bool.self, forKey: .enabled)
        size = try v.decodeIfPresent(Double.self, forKey: .size) ?? FPSBinding.defaultSize
        swipe = try v.decodeIfPresent(FPSSwipe.self, forKey: .swipe) ?? .starting(at: point)
    }
}

/// The editor and input engine use the same view of preset and custom buttons.
public struct FPSButton: Equatable, Identifiable, Sendable {
    public let id: String
    public var title: String
    public var trigger: String
    public var point: FPSPoint
    public var behavior: FPSPressBehavior
    public var enabled: Bool
    public var size: Double
    public var swipe: FPSSwipe
    public let preferredTouchID: UInt8?
    public var isCustom: Bool { preferredTouchID == nil }
}

extension FPSProfile {
    public static let maximumCustomButtons = 32

    public var buttons: [FPSButton] {
        bindings.sorted { $0.action.touchID < $1.action.touchID }.map {
            FPSButton(id: $0.id, title: $0.name, trigger: $0.trigger, point: $0.point,
                      behavior: $0.behavior, enabled: $0.enabled, size: $0.size, swipe: $0.swipe, preferredTouchID: $0.action.touchID)
        } + customButtons.map {
            FPSButton(id: $0.id, title: $0.name, trigger: $0.trigger, point: $0.point,
                      behavior: $0.behavior, enabled: $0.enabled, size: $0.size, swipe: $0.swipe, preferredTouchID: nil)
        }
    }

    public mutating func updateButton(_ button: FPSButton) {
        if let index = bindings.firstIndex(where: { $0.id == button.id }) {
            bindings[index].trigger = button.trigger; bindings[index].point = button.point
            bindings[index].behavior = button.behavior; bindings[index].enabled = button.enabled
            bindings[index].size = button.size
            bindings[index].name = button.title; bindings[index].swipe = button.swipe
        } else if let index = customButtons.firstIndex(where: { $0.id == button.id }) {
            customButtons[index].name = button.title
            customButtons[index].trigger = button.trigger; customButtons[index].point = button.point
            customButtons[index].behavior = button.behavior; customButtons[index].enabled = button.enabled
            customButtons[index].size = button.size
            customButtons[index].swipe = button.swipe
        }
    }

    @discardableResult
    public mutating func addCustomButton(swipe: Bool = false) throws -> String {
        guard customButtons.count < Self.maximumCustomButtons else {
            throw ControlError("每个配置最多添加 \(Self.maximumCustomButtons) 个自定义按钮")
        }
        let used = Set(buttons.filter(\.enabled).map(\.trigger))
        let preferred = ["KeyG", "KeyT", "KeyV", "KeyB", "KeyH", "MouseMiddle"]
        guard let trigger = (preferred + FPSKey.choices).first(where: { !used.contains($0) }) else {
            throw ControlError("可用按键已用完，请先停用一个按钮或删除不用的自定义按钮")
        }
        var number = 1
        while customButtons.contains(where: { $0.name == "自定义按钮 \(number)" }) { number += 1 }
        let column = customButtons.count % 4, row = (customButtons.count / 4) % 4
        let button = FPSCustomButton(name: swipe ? "滑动按钮 \(number)" : "自定义按钮 \(number)", trigger: trigger,
                                     point: .init(x: 0.36 + Double(column) * 0.08, y: 0.50 + Double(row) * 0.08),
                                     behavior: swipe ? .swipe : .tap)
        customButtons.append(button)
        return button.id
    }

    public var mappingTargets: [(id: String, title: String)] {
        (joystickEnabled ? [("joystick", "WASD 移动摇杆")] : [])
        + (lookEnabled ? [("look", "鼠标转向区域")] : []) + buttons.map { ($0.id, $0.title) }
    }

    @discardableResult public mutating func addPreset(_ action: FPSAction) throws -> String {
        guard !bindings.contains(where: { $0.action == action }) else { return action.id }
        var binding = FPSProfile().bindings.first { $0.action == action }!
        let used = Set(buttons.filter(\.enabled).map(\.trigger))
        if used.contains(binding.trigger) {
            guard let key = FPSKey.choices.first(where: { !used.contains($0) }) else { throw ControlError("没有空闲按键") }
            binding.trigger = key
        }
        binding.enabled = true; bindings.append(binding); return action.id
    }

    public mutating func removeMapping(_ id: String) {
        if id == "joystick" { joystickEnabled = false }
        else if id == "look" { lookEnabled = false }
        else { bindings.removeAll { $0.id == id }; customButtons.removeAll { $0.id == id } }
    }
}
