import Foundation

/// A layout stays in a draft until saved. One drag or slider gesture is one undo step.
public struct FPSLayoutEditor: Equatable, Sendable {
    public private(set) var draft: FPSProfile
    public private(set) var selection: String
    private let original: FPSProfile
    private var undoStack: [FPSProfile] = []
    private var redoStack: [FPSProfile] = []
    private var interactionStart: FPSProfile?

    public init(profile: FPSProfile, selection: String = "joystick") {
        original = profile; draft = profile
        self.selection = Self.contains(selection, in: profile) ? selection : profile.mappingTargets.first?.id ?? ""
    }
    public var hasChanges: Bool { draft != original }
    public var isInteracting: Bool { interactionStart != nil }
    public var canUndo: Bool { !undoStack.isEmpty || interactionStart.map { $0 != draft } == true }
    public var canRedo: Bool { !redoStack.isEmpty && !isInteracting }

    private static func contains(_ target: String, in profile: FPSProfile) -> Bool {
        profile.mappingTargets.contains { $0.id == target }
    }
    public mutating func select(_ target: String) {
        guard Self.contains(target, in: draft) else { return }
        selection = target
    }
    public mutating func beginInteraction() {
        if interactionStart == nil { interactionStart = draft }
    }
    public mutating func endInteraction(cancelled: Bool = false) {
        guard let start = interactionStart else { return }
        interactionStart = nil
        if cancelled { draft = start }
        else if draft != start { remember(start) }
    }
    public mutating func edit(_ update: (inout FPSProfile) -> Void) throws {
        var next = draft; update(&next); try next.validate()
        guard next != draft else { return }
        if interactionStart == nil { remember(draft) }
        draft = next
        normalizeSelection()
    }
    private mutating func remember(_ previous: FPSProfile) {
        undoStack.append(previous)
        if undoStack.count > 100 { undoStack.removeFirst() }
        redoStack.removeAll()
    }
    public mutating func undo() {
        endInteraction()
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(draft); draft = previous
        normalizeSelection()
    }
    public mutating func redo() {
        guard !isInteracting, let next = redoStack.popLast() else { return }
        undoStack.append(draft); draft = next
        normalizeSelection()
    }
    public mutating func reset() throws {
        endInteraction()
        try edit { profile in
            var reset = FPSProfile(); reset.id = profile.id; reset.name = profile.name; profile = reset
        }
    }

    public mutating func addCustomButton(swipe: Bool = false) throws {
        endInteraction()
        var target = ""
        var next = draft; target = try next.addCustomButton(swipe: swipe); try next.validate()
        remember(draft); draft = next; selection = target
    }

    public mutating func removeCustomButton(_ target: String) throws {
        guard draft.customButtons.contains(where: { $0.id == target }) else { return }
        endInteraction()
        try edit { $0.customButtons.removeAll(where: { $0.id == target }) }
    }

    public mutating func addMapping(_ target: String) throws {
        endInteraction()
        var next = draft
        if target == "joystick" { next.joystickEnabled = true }
        else if target == "look" { next.lookEnabled = true }
        else if let action = FPSAction(rawValue: target) { try next.addPreset(action) }
        else { return }
        try next.validate(); if next != draft { remember(draft); draft = next }; selection = target
    }

    public mutating func removeMapping(_ target: String) throws {
        endInteraction(); try edit { $0.removeMapping(target) }
    }

    private mutating func normalizeSelection() {
        if !Self.contains(selection, in: draft) { selection = draft.mappingTargets.first?.id ?? "" }
    }

    public mutating func geometry(target: String, point: FPSPoint? = nil, radius: Double? = nil,
                                  width: Double? = nil, height: Double? = nil, size: Double? = nil,
                                  end: FPSPoint? = nil, aspect: Double = 4.0 / 3.0) throws {
        guard Self.contains(target, in: draft) else { return }
        guard [radius, width, height, size].compactMap({ $0 }).allSatisfy(\.isFinite),
              point?.isValid != false, end?.isValid != false, aspect.isFinite, aspect > 0 else {
            throw ControlError("布局位置和大小必须是有效数值")
        }
        select(target)
        try edit { profile in
            if target == "joystick" {
                if let radius { profile.joystickRadius = Self.clamp(radius, to: FPSProfile.joystickRadiusRange) }
                profile.setPoint(point ?? profile.joystick, target: target, aspect: aspect)
            } else if target == "look" {
                if let width { profile.lookWidth = Self.clamp(width, to: FPSProfile.lookWidthRange) }
                if let height { profile.lookHeight = Self.clamp(height, to: FPSProfile.lookHeightRange) }
                profile.setPoint(point ?? profile.look, target: target, aspect: aspect)
            } else if let index = profile.bindings.firstIndex(where: { $0.id == target }) {
                if let size { profile.bindings[index].size = Self.clamp(size, to: FPSBinding.sizeRange) }
                if let point { profile.bindings[index].point = point }
                if let end { profile.bindings[index].swipe.end = end }
            } else if let index = profile.customButtons.firstIndex(where: { $0.id == target }) {
                if let size { profile.customButtons[index].size = Self.clamp(size, to: FPSBinding.sizeRange) }
                if let point { profile.customButtons[index].point = point }
                if let end { profile.customButtons[index].swipe.end = end }
            }
        }
    }
    private static func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
        min(range.upperBound, max(range.lowerBound, value))
    }
}
