import Foundation

/// A keyboard key can trigger additional mapped keys or the game cursor action.
public struct FPSKeyLink: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var source: String
    public var target: String
    public var enabled: Bool

    public init(source: String = "KeyB", target: String = "Escape", enabled: Bool = true) {
        self.source = source; self.target = target; self.enabled = enabled
    }
}

extension FPSProfile {
    public static let maximumKeyLinks = 64

    public func validateKeyLinks() throws {
        guard keyLinks.count <= Self.maximumKeyLinks, Set(keyLinks.map(\.id)).count == keyLinks.count else {
            throw ControlError("每个配置最多添加 \(Self.maximumKeyLinks) 条按键联动，编号不能重复")
        }
        var pairs = Set<String>()
        for link in keyLinks {
            guard FPSKey.linkSources.contains(link.source), FPSKey.linkTargets.contains(link.target),
                  link.source != link.target else { throw ControlError("联动需要选择不同的按键；F8 和 WASD 保留原有功能") }
            guard pairs.insert(link.source + ":" + link.target).inserted else {
                throw ControlError("\(FPSKey.title(link.source)) → \(FPSKey.title(link.target)) 的联动已存在")
            }
        }
    }

    /// Breadth-first expansion preserves row order and fires each target once,
    /// including when multiple paths or a cycle reach the same key.
    public func linkedKeys(from source: String) -> [String] {
        var result = [source], visited: Set<String> = [source], index = 0
        while index < result.count {
            let key = result[index]; index += 1
            for link in keyLinks where link.enabled && link.source == key {
                if visited.insert(link.target).inserted { result.append(link.target) }
            }
        }
        return result
    }

    @discardableResult public mutating func addKeyLink() throws -> UUID {
        guard keyLinks.count < Self.maximumKeyLinks else {
            throw ControlError("每个配置最多添加 \(Self.maximumKeyLinks) 条按键联动")
        }
        for source in ["KeyB"] + FPSKey.linkSources.filter({ $0 != "KeyB" }) {
            for target in ["Escape", FPSKey.cursorAction] + FPSKey.linkTargets.filter({ $0 != "Escape" && $0 != FPSKey.cursorAction }) {
                if source != target, !keyLinks.contains(where: { $0.source == source && $0.target == target }) {
                    let link = FPSKeyLink(source: source, target: target)
                    keyLinks.append(link); return link.id
                }
            }
        }
        throw ControlError("没有可添加的按键联动")
    }
}
