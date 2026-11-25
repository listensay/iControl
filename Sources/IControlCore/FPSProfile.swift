import Foundation

public struct FPSPoint: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
    public var isValid: Bool { x.isFinite && y.isFinite && (0...1).contains(x) && (0...1).contains(y) }
}

public enum FPSOrientation: Int, CaseIterable, Codable, Sendable {
    case automatic = 255, portrait = 0, clockwise = 1, upsideDown = 2, counterclockwise = 3
    public var title: String {
        switch self {
        case .automatic: return "跟随 iPad 屏幕"
        case .portrait: return "竖屏 · 0°"
        case .clockwise: return "横屏 · 90°"
        case .upsideDown: return "倒置 · 180°"
        case .counterclockwise: return "横屏 · 270°"
        }
    }
}

public enum FPSAction: String, CaseIterable, Codable, Identifiable, Sendable {
    case fire, aim, jump, crouch, reload, interact, sprint, prone, weapon1, weapon2, leanLeft, leanRight, map, backpack
    public var id: String { rawValue }
    public var touchID: UInt8 { UInt8(Self.allCases.firstIndex(of: self)! + 3) }
    public var title: String {
        switch self {
        case .fire: return "开火"
        case .aim: return "瞄准 / 开镜"
        case .jump: return "跳跃"
        case .crouch: return "蹲下"
        case .reload: return "换弹"
        case .interact: return "拾取 / 交互"
        case .sprint: return "冲刺"
        case .prone: return "趴下"
        case .weapon1: return "武器 1"
        case .weapon2: return "武器 2"
        case .leanLeft: return "左探头"
        case .leanRight: return "右探头"
        case .map: return "地图"
        case .backpack: return "背包"
        }
    }
}

public enum FPSPressBehavior: String, CaseIterable, Codable, Sendable {
    case hold, tap, swipe
    public var title: String {
        switch self { case .hold: return "按住"; case .tap: return "点按"; case .swipe: return "滑动" }
    }
}

public struct FPSBinding: Codable, Equatable, Identifiable, Sendable {
    public static let sizeRange = 0.04...0.22
    public static let defaultSize = 0.075
    public var action: FPSAction
    public var trigger: String
    public var point: FPSPoint
    public var behavior: FPSPressBehavior
    public var enabled: Bool
    /// Marker diameter as a fraction of the rendered display height.
    public var size: Double
    public var name: String
    public var swipe: FPSSwipe
    public var id: String { action.rawValue }
    public init(_ action: FPSAction, _ trigger: String, _ x: Double, _ y: Double,
                behavior: FPSPressBehavior = .hold, enabled: Bool = true, size: Double = defaultSize) {
        self.action = action; self.trigger = trigger; point = FPSPoint(x: x, y: y)
        self.behavior = behavior; self.enabled = enabled; self.size = size
        name = action.title; swipe = .starting(at: point)
    }
    private enum CodingKeys: String, CodingKey { case action, trigger, point, behavior, enabled, size, name, swipe }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        action = try values.decode(FPSAction.self, forKey: .action)
        trigger = try values.decode(String.self, forKey: .trigger)
        point = try values.decode(FPSPoint.self, forKey: .point)
        behavior = try values.decode(FPSPressBehavior.self, forKey: .behavior)
        enabled = try values.decode(Bool.self, forKey: .enabled)
        size = try values.decodeIfPresent(Double.self, forKey: .size) ?? Self.defaultSize
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? action.title
        swipe = try values.decodeIfPresent(FPSSwipe.self, forKey: .swipe) ?? .starting(at: point)
    }
}

public enum FPSKey {
    public static let movement: Set<String> = ["KeyW", "KeyA", "KeyS", "KeyD"]
    public static let cursorChoices = ["Backquote", "F1", "F2", "F3", "F4", "F5", "F6", "F7", "F9", "F10", "F11", "F12"]
    public static let choices = ["MouseLeft", "MouseRight", "MouseMiddle", "MouseBack", "MouseForward",
                                 "Space", "Shift", "Control", "Option", "Tab", "Escape"]
        + "BCEFGHIJKLMNOPQRTUVXYZ".map { "Key\($0)" }
        + (0...9).map { "Digit\($0)" }
    public static let cursorAction = "CursorToggle"
    public static let linkSources = choices.filter { !$0.hasPrefix("Mouse") }
    public static let linkTargets = linkSources + [cursorAction]
    public static func title(_ code: String) -> String {
        switch code {
        case "MouseLeft": return "鼠标左键"
        case "MouseRight": return "鼠标右键"
        case "MouseMiddle": return "鼠标中键"
        case "MouseBack": return "鼠标侧键 1"
        case "MouseForward": return "鼠标侧键 2"
        case "Space": return "空格"
        case "Shift": return "Shift"
        case "Control": return "Ctrl"
        case "Option": return "Option / Alt"
        case "Tab": return "Tab"
        case "Escape": return "Esc"
        case cursorAction: return "呼出 / 收回游戏内鼠标"
        case "Backquote": return "` / ~（反引号）"
        default: return code.replacingOccurrences(of: "Key", with: "").replacingOccurrences(of: "Digit", with: "")
        }
    }
    public static let macKeyCodes: [UInt16: String] = [
        0:"KeyA", 1:"KeyS", 2:"KeyD", 3:"KeyF", 4:"KeyH", 5:"KeyG", 6:"KeyZ", 7:"KeyX", 8:"KeyC", 9:"KeyV", 11:"KeyB",
        12:"KeyQ", 13:"KeyW", 14:"KeyE", 15:"KeyR", 16:"KeyY", 17:"KeyT", 31:"KeyO", 32:"KeyU", 34:"KeyI", 35:"KeyP",
        37:"KeyL", 38:"KeyJ", 40:"KeyK", 45:"KeyN", 46:"KeyM", 18:"Digit1", 19:"Digit2", 20:"Digit3", 21:"Digit4",
        23:"Digit5", 22:"Digit6", 26:"Digit7", 28:"Digit8", 25:"Digit9", 29:"Digit0", 49:"Space", 48:"Tab",
        53:"Escape", 50:"Backquote", 122:"F1", 120:"F2", 99:"F3", 118:"F4", 96:"F5", 97:"F6", 98:"F7",
        101:"F9", 109:"F10", 103:"F11", 111:"F12"
    ]
    public static func mouseButton(_ number: Int) -> String? {
        switch number {
        case 0: return "MouseLeft"
        case 1: return "MouseRight"
        case 2: return "MouseMiddle"
        case 3: return "MouseBack"
        case 4: return "MouseForward"
        default: return nil
        }
    }
}

public struct FPSProfile: Codable, Equatable, Identifiable, Sendable {
    public static let joystickRadiusRange = 0.02...0.18
    public static let keyboardTurnDurationRange = 0.0...0.080
    public static let lookWidthRange = 0.10...0.65
    public static let lookHeightRange = 0.10...0.80
    public var schemaVersion = 1
    public var id = UUID()
    public var name = "通用 FPS"
    public var joystick = FPSPoint(x: 0.15, y: 0.76)
    public var joystickEnabled = true
    /// Time for one full axis offset, in seconds. Steering travels in a straight
    /// line from the current position to the latest target. Releasing an axis
    /// clears that axis immediately while the remaining travel completes.
    /// A full reversal takes twice this time; stopping lifts without animation.
    public var keyboardTurnDuration = 0.025
    public var cursorToggleKey = "Backquote"
    /// Circular travel radius in fractions of display height; X is aspect
    /// adjusted. Straight and diagonal targets have the same distance to center.
    public var joystickRadius = 0.085
    public var look = FPSPoint(x: 0.66, y: 0.43)
    public var lookEnabled = true
    public var lookWidth = 0.38
    public var lookHeight = 0.52
    public var sensitivity = 1.0
    public var swapMouseAxes = false
    public var invertX = false
    public var invertY = false
    public var touchMapping = FPSCoordinateMapping()
    public var wheelSwitchWeapons = true
    public var orientation: FPSOrientation = .automatic
    public var customButtons: [FPSCustomButton] = []
    public var keyLinks: [FPSKeyLink] = []
    public var bindings: [FPSBinding] = [
        .init(.fire, "MouseLeft", 0.91, 0.54),
        .init(.aim, "MouseRight", 0.91, 0.34),
        .init(.jump, "Space", 0.91, 0.78),
        .init(.crouch, "Control", 0.82, 0.86),
        .init(.reload, "KeyR", 0.75, 0.73, behavior: .tap),
        .init(.interact, "KeyF", 0.58, 0.60, behavior: .tap),
        .init(.sprint, "Shift", 0.15, 0.52),
        .init(.prone, "KeyZ", 0.70, 0.86, behavior: .tap),
        .init(.weapon1, "Digit1", 0.43, 0.89, behavior: .tap),
        .init(.weapon2, "Digit2", 0.57, 0.89, behavior: .tap),
        .init(.leanLeft, "KeyQ", 0.48, 0.40, enabled: false),
        .init(.leanRight, "KeyE", 0.56, 0.40, enabled: false),
        .init(.map, "KeyM", 0.93, 0.10, behavior: .tap, enabled: false),
        .init(.backpack, "Tab", 0.06, 0.40, behavior: .tap, enabled: false)
    ]
    public init() { }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, name, joystick, joystickRadius, look, lookWidth, lookHeight, joystickEnabled, lookEnabled
        case keyboardTurnDuration, cursorToggleKey, keyLinks
        case sensitivity, swapMouseAxes, invertX, invertY, touchMapping, wheelSwitchWeapons, orientation, bindings, customButtons
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        joystick = try values.decode(FPSPoint.self, forKey: .joystick)
        joystickEnabled = try values.decodeIfPresent(Bool.self, forKey: .joystickEnabled) ?? true
        keyboardTurnDuration = try values.decodeIfPresent(Double.self, forKey: .keyboardTurnDuration) ?? 0.025
        // Legacy keyboardRecenterOnAxisRelease is intentionally ignored: saved
        // layouts also use continuous steering, without up/down gaps on turns.
        cursorToggleKey = try values.decodeIfPresent(String.self, forKey: .cursorToggleKey) ?? "Backquote"
        joystickRadius = try values.decode(Double.self, forKey: .joystickRadius)
        look = try values.decode(FPSPoint.self, forKey: .look)
        lookEnabled = try values.decodeIfPresent(Bool.self, forKey: .lookEnabled) ?? true
        lookWidth = try values.decode(Double.self, forKey: .lookWidth)
        lookHeight = try values.decode(Double.self, forKey: .lookHeight)
        sensitivity = try values.decode(Double.self, forKey: .sensitivity)
        swapMouseAxes = try values.decodeIfPresent(Bool.self, forKey: .swapMouseAxes) ?? false
        invertX = try values.decodeIfPresent(Bool.self, forKey: .invertX) ?? false
        invertY = try values.decode(Bool.self, forKey: .invertY)
        touchMapping = try values.decodeIfPresent(FPSCoordinateMapping.self, forKey: .touchMapping) ?? FPSCoordinateMapping()
        wheelSwitchWeapons = try values.decode(Bool.self, forKey: .wheelSwitchWeapons)
        orientation = try values.decode(FPSOrientation.self, forKey: .orientation)
        bindings = try values.decode([FPSBinding].self, forKey: .bindings)
        customButtons = try values.decodeIfPresent([FPSCustomButton].self, forKey: .customButtons) ?? []
        keyLinks = try values.decodeIfPresent([FPSKeyLink].self, forKey: .keyLinks) ?? []
    }

    public func validate() throws {
        try touchMapping.validate()
        try validateKeyLinks()
        guard schemaVersion == 1, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name.count <= 80 else { throw ControlError("FPS 配置名称或版本无效") }
        guard joystick.isValid, look.isValid, Self.joystickRadiusRange.contains(joystickRadius),
              Self.lookWidthRange.contains(lookWidth), Self.lookHeightRange.contains(lookHeight),
              (0.10...4.0).contains(sensitivity),
              joystick.y - joystickRadius >= 0, joystick.y + joystickRadius <= 1,
              look.x - lookWidth / 2 >= 0, look.x + lookWidth / 2 <= 1,
              look.y - lookHeight / 2 >= 0, look.y + lookHeight / 2 <= 1 else {
            throw ControlError("FPS 触控位置、转向范围或灵敏度超出支持范围")
        }
        guard bindings.count <= FPSAction.allCases.count,
              Set(bindings.map(\.action)).count == bindings.count else {
            throw ControlError("FPS 按键配置有重复动作")
        }
        guard customButtons.count <= Self.maximumCustomButtons,
              Set(customButtons.map(\.id)).count == customButtons.count,
              customButtons.allSatisfy({ $0.id.hasPrefix("custom.") && UUID(uuidString: String($0.id.dropFirst(7))) != nil
                  && !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.name.count <= 40 }) else {
            throw ControlError("自定义按钮的名称、编号或数量无效；名称需要 1–40 个字符")
        }
        var used = Set<String>()
        guard keyboardTurnDuration.isFinite, Self.keyboardTurnDurationRange.contains(keyboardTurnDuration) else {
            throw ControlError("WASD 换向时间超出支持范围")
        }
        guard FPSKey.cursorChoices.contains(cursorToggleKey) else { throw ControlError("呼出鼠标快捷键无效") }
        for binding in buttons {
            guard binding.point.isValid, FPSKey.choices.contains(binding.trigger), Self.validMarkerSize(binding.size),
                  !binding.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, binding.title.count <= 40 else {
                throw ControlError("\(binding.title)的按键或触控位置无效")
            }
            if binding.behavior == .swipe { try binding.swipe.validate(from: binding.point) }
            if binding.enabled, !used.insert(binding.trigger).inserted {
                throw ControlError("按键 \(FPSKey.title(binding.trigger)) 已绑定，请为每个动作选择独立按键")
            }
        }
    }

    private static func validMarkerSize(_ size: Double) -> Bool { size.isFinite && FPSBinding.sizeRange.contains(size) }

    public mutating func setPoint(_ point: FPSPoint, target: String, aspect: Double = 4.0 / 3.0) {
        guard point.isValid else { return }
        if target == "joystick" {
            let horizontalRadius = min(0.5, joystickRadius / (aspect.isFinite && aspect > 0 ? aspect : 4.0 / 3.0))
            joystick = FPSPoint(x: min(1 - horizontalRadius, max(horizontalRadius, point.x)),
                                y: min(1 - joystickRadius, max(joystickRadius, point.y)))
        } else if target == "look" {
            look = FPSPoint(x: min(1 - lookWidth / 2, max(lookWidth / 2, point.x)),
                            y: min(1 - lookHeight / 2, max(lookHeight / 2, point.y)))
        } else if let index = bindings.firstIndex(where: { $0.action.rawValue == target }) {
            bindings[index].point = point
        } else if let index = customButtons.firstIndex(where: { $0.id == target }) {
            customButtons[index].point = point
        }
    }

    public func viewerJSON(calibrating: String? = nil, editing: Bool = false, selection: String? = nil,
                           session: String = "", sequence: Int = 0) throws -> String {
        var values: [String: Any] = ["radius": joystickRadius,
                                   "bindings": buttons.filter { editing || $0.enabled }.map {
            var button: [String: Any] = ["id": $0.id, "label": FPSKey.title($0.trigger), "title": $0.title,
             "x": $0.point.x, "y": $0.point.y, "size": $0.size, "enabled": $0.enabled]
            if $0.behavior == .swipe { button["endX"] = $0.swipe.end.x; button["endY"] = $0.swipe.end.y }
            return button
        }]
        if joystickEnabled { values["joystick"] = ["x": joystick.x, "y": joystick.y] }
        if lookEnabled { values["look"] = ["x": look.x, "y": look.y, "width": lookWidth, "height": lookHeight] }
        if let calibrating { values["calibrating"] = calibrating }
        if editing { values["editor"] = ["selected": selection ?? "", "session": session, "sequence": sequence] }
        return String(decoding: try JSONSerialization.data(withJSONObject: values), as: UTF8.self)
    }
}

public struct FPSProfileLibrary: Codable, Sendable {
    public var schemaVersion = 1
    public var profiles: [FPSProfile]
    public var selectionByDevice: [String: UUID]
    public init(profiles: [FPSProfile] = [FPSProfile()], selectionByDevice: [String: UUID] = [:]) {
        self.profiles = profiles; self.selectionByDevice = selectionByDevice
    }
    public func validate() throws {
        guard schemaVersion == 1, !profiles.isEmpty, profiles.count <= 32,
              Set(profiles.map(\.id)).count == profiles.count else { throw ControlError("FPS 配置库无效") }
        for profile in profiles { try profile.validate() }
    }
    public static func load(from url: URL) throws -> FPSProfileLibrary {
        let bytes = try Data(contentsOf: url)
        guard bytes.count < 1024 * 1024 else { throw ControlError("FPS 配置文件过大") }
        let library = try JSONDecoder().decode(Self.self, from: bytes)
        try library.validate(); return library
    }
    public func save(to url: URL) throws {
        try validate()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
