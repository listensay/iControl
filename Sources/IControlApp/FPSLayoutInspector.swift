import SwiftUI
import IControlCore

struct FPSLayoutInspector: View {
    @ObservedObject var controller: FPSController
    @State private var search = ""

    var body: some View {
        if let editor = controller.layoutEditor {
            VStack(alignment: .leading, spacing: 13) {
                Label("拖拽布局", systemImage: "square.and.pencil")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(.blue)
                Text("拖动按键移动，拖动四角调整大小。圆圈中心就是触控位置。")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button(action: controller.addLayoutButton) {
                    Label("添加自定义按钮", systemImage: "plus.circle.fill").frame(maxWidth: .infinity)
                }.buttonStyle(PrimaryActionButtonStyle())
                    .disabled(editor.draft.customButtons.count >= FPSProfile.maximumCustomButtons)
                    .help("新增按钮会自动选择空闲按键；拖到游戏按钮中心后保存")
                Button("添加滑动按钮", action: controller.addLayoutSwipe)
                    .disabled(editor.draft.customButtons.count >= FPSProfile.maximumCustomButtons)
                FPSAddMappingMenu(profile: editor.draft, custom: controller.addLayoutButton,
                                  swipe: controller.addLayoutSwipe, preset: controller.addLayoutMapping)
                TextField("搜索名称或按键", text: $search).textFieldStyle(.roundedBorder)
                Picker("选中对象", selection: Binding(get: { editor.selection }, set: controller.selectLayoutTarget)) {
                    ForEach(editor.draft.mappingTargets.filter { item in
                        let key = editor.draft.buttons.first { $0.id == item.id }.map { FPSKey.title($0.trigger) } ?? ""
                        return search.isEmpty || item.id == editor.selection || (item.title + key).localizedCaseInsensitiveContains(search)
                    }, id: \.id) { item in
                        Text(item.title).tag(item.id)
                    }
                }.labelsHidden().accessibilityLabel("选中布局对象")
                Divider()
                if editor.selection == "joystick" {
                    FPSJoystickControls(profile: draftBinding)
                    dimension("推杆距离", value: layoutValue(\.joystickRadius) {
                        controller.layoutGeometry(target: "joystick", radius: $0)
                    }, range: FPSProfile.joystickRadiusRange)
                    HStack {
                        Button("测试直行 W", action: controller.testLayoutForward)
                        Button("测试八向", action: controller.testLayoutMovement)
                    }.disabled(!controller.ready || controller.layoutTesting)
                    Button("测试 W+A 加鼠标转向（10 秒）", action: controller.testLayoutDiagonalWithLook)
                        .disabled(!controller.ready || controller.layoutTesting)
                    Text("组合测试持续转动视角：先从 A 切到 W+A，再松开、按回 A。两次斜走时，游戏摇杆应指向同一个左上方向；只按 W 时应朝正上。")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Text("直行测试只发送 W 约 1 秒，八向测试约 1.5 秒。若直行仍偏，将中心十字对准游戏静止时的摇杆中心后再测。")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else if editor.selection == "look" {
                    FPSMouseAxisControls(profile: draftBinding)
                    dimension("区域宽度", value: layoutValue(\.lookWidth) {
                        controller.layoutGeometry(target: "look", width: $0)
                    }, range: FPSProfile.lookWidthRange)
                    dimension("区域高度", value: layoutValue(\.lookHeight) {
                        controller.layoutGeometry(target: "look", height: $0)
                    }, range: FPSProfile.lookHeightRange)
                    Text("转向区域应避开游戏按钮。拖动角点时按住 Shift 可等比缩放。")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("测试向右") { controller.testLayoutLook(horizontal: true) }
                        Button("测试向下") { controller.testLayoutLook(horizontal: false) }
                    }.disabled(!controller.ready || controller.layoutTesting)
                } else if let binding = editor.draft.buttons.first(where: { $0.id == editor.selection }) {
                        FPSCustomNameField(name: binding.title) { value in
                            controller.editLayout { profile in
                                guard var button = profile.buttons.first(where: { $0.id == binding.id }) else { return }
                                button.title = value; profile.updateButton(button)
                            }
                        }.id(binding.id)
                    Toggle("启用此动作", isOn: bindingValue(binding.id, \.enabled, fallback: binding.enabled))
                        .toggleStyle(.checkbox)
                    Picker("Mac 按键", selection: bindingValue(binding.id, \.trigger, fallback: binding.trigger)) {
                        ForEach(FPSKey.choices, id: \.self) { key in
                            let occupied = editor.draft.buttons.contains { $0.id != binding.id && $0.enabled && $0.trigger == key }
                            Text(FPSKey.title(key) + (occupied ? " · 已占用" : "")).tag(key).disabled(occupied)
                        }
                    }
                    Picker("触屏方式", selection: bindingValue(binding.id, \.behavior, fallback: binding.behavior)) {
                        ForEach(FPSPressBehavior.allCases, id: \.rawValue) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented)
                    if binding.behavior == .swipe {
                        FPSSwipeControls(start: binding.point, swipe: bindingValue(binding.id, \.swipe, fallback: binding.swipe))
                    }
                    dimension("按键标记大小", value: Binding(get: {
                        controller.layoutEditor?.draft.buttons.first(where: { $0.id == binding.id })?.size ?? binding.size
                    }, set: {
                        controller.layoutGeometry(target: binding.id, size: $0)
                    }), range: FPSBinding.sizeRange)
                    Button("测试\(binding.behavior == .swipe ? "滑动" : "点击") \(binding.title)") { controller.testLayoutAction() }
                        .disabled(!binding.enabled || !controller.ready || controller.layoutTesting)
                    Text(binding.enabled ? "测试会实际向 iPad 发送此映射动作。" : "此动作未启用，勾选后才能触发。")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if !editor.selection.isEmpty {
                    Button("删除此映射", role: .destructive, action: controller.removeLayoutButton)
                        .help("预设和自定义映射均可删除；撤销或添加映射可恢复")
                } else { Text("暂无映射，点击“添加映射”开始配置。") }
                if let message = controller.layoutTestMessage {
                    Text(message).foregroundStyle(.blue).fixedSize(horizontal: false, vertical: true)
                }
                Text("方向键移动 1 像素，Shift + 方向键移动 10 像素；＋ / − 调整大小。")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let error = controller.layoutError {
                    Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
                Divider()
                FPSMappingControls(profile: draftBinding, orientationDescription: controller.orientationDescription)
                Divider()
                Button("恢复默认布局") { controller.resetLayout() }
                    .help("恢复后仍可撤销；保存后才替换原布局")
                Text(editor.hasChanges ? "有未保存的修改" : "拖动后点击“保存布局”")
                    .foregroundStyle(editor.hasChanges ? Color.orange : Color.secondary)
            }.font(.system(size: 11))
        }
    }

    private var draftBinding: Binding<FPSProfile> {
        Binding(get: { controller.layoutEditor?.draft ?? controller.profile }, set: { value in
            controller.editLayout { $0 = value }
        })
    }

    private func layoutValue(_ keyPath: KeyPath<FPSProfile, Double>, update: @escaping (Double) -> Void) -> Binding<Double> {
        Binding(get: { controller.layoutEditor?.draft[keyPath: keyPath] ?? 0 }, set: update)
    }
    private func dimension(_ title: String, value binding: Binding<Double>, range: ClosedRange<Double>) -> some View {
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(title)
                Spacer(minLength: 0)
                TextField(title, value: binding, format: .percent.precision(.fractionLength(1)))
                    .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing)
                    .monospacedDigit().frame(width: 64).accessibilityLabel(title + "百分比")
                Stepper(title, value: binding, in: range, step: 0.005).labelsHidden()
            }
            Slider(value: binding, in: range, onEditingChanged: { changing in
                if changing { controller.beginLayoutInteraction() } else { controller.endLayoutInteraction() }
            }).accessibilityLabel(title)
        }
    }

    private func bindingValue<Value>(_ id: String, _ keyPath: WritableKeyPath<FPSButton, Value>, fallback: Value) -> Binding<Value> {
        Binding(get: {
            controller.layoutEditor?.draft.buttons.first(where: { $0.id == id })?[keyPath: keyPath] ?? fallback
        }, set: { value in
            controller.editLayout { profile in
                guard var button = profile.buttons.first(where: { $0.id == id }) else { return }
                button[keyPath: keyPath] = value; profile.updateButton(button)
            }
        })
    }
}

private struct FPSCustomNameField: View {
    let name: String
    let update: (String) -> Void
    @State private var text: String
    @FocusState private var focused: Bool

    init(name: String, update: @escaping (String) -> Void) {
        self.name = name; self.update = update; _text = State(initialValue: name)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("按钮名称")
            TextField("自定义按钮名称", text: $text).textFieldStyle(.roundedBorder)
                .accessibilityLabel("自定义按钮名称").focused($focused)
                .onChange(of: text) { _, value in
                    if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value.count <= 40 { update(value) }
                }
                .onChange(of: name) { _, value in if !focused { text = value } }
                .onChange(of: focused) { _, value in
                    if !value {
                        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= 40 { update(text) }
                        else { text = name }
                    }
                }
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text.count > 40 {
                Text("名称需要 1–40 个字符").foregroundStyle(.red)
            }
        }
    }
}
