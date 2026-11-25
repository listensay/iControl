import SwiftUI
import Combine
import IControlCore

struct FPSSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    let controller: FPSController
    @State private var draft: FPSProfile
    @State private var error: String?
    @State private var search = ""
    @State private var selectedTab = SettingsTab.mouseAndMovement
    @State private var videoReady: Bool
    @State private var profileNames: [FPSProfile]
    @State private var orientationDescription: String

    private enum SettingsTab: Hashable { case mouseAndMovement, actionsAndLinks }

    init(controller: FPSController) {
        self.controller = controller
        _draft = State(initialValue: controller.profile)
        _videoReady = State(initialValue: controller.videoReady)
        _profileNames = State(initialValue: controller.profileNames)
        _orientationDescription = State(initialValue: controller.orientationDescription)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "gamecontroller").font(.system(size: 28)).foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 4) {
                    Text("FPS 按键与灵敏度").font(.title2.weight(.semibold))
                    Text("位置和大小可在游戏画面中直接拖动调整。")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") { if save() { dismiss() } }
                    .buttonStyle(PrimaryActionButtonStyle()).keyboardShortcut(.defaultAction)
            }
            Divider()
            HStack(spacing: 12) {
                Picker("配置", selection: Binding(get: { draft.id }, set: { id in
                    guard id != draft.id else { return }
                    controller.selectProfile(id); draft = controller.profile; error = nil
                })) {
                    ForEach(profileNames) { Text($0.name).tag($0.id) }
                }.frame(width: 250)
                TextField("配置名称", text: $draft.name).textFieldStyle(.roundedBorder)
                Button("复制配置") {
                    if save() { controller.duplicateProfile(); draft = controller.profile }
                }.disabled(profileNames.count >= 32)
                Button("重置布局") {
                    var reset = FPSProfile(); reset.id = draft.id; reset.name = draft.name
                    draft = reset; error = nil
                }
            }.font(.system(size: 11))
            HStack {
                Spacer()
                Picker("设置分类", selection: $selectedTab) {
                    Text("鼠标与移动").tag(SettingsTab.mouseAndMovement)
                    Text("动作与联动").tag(SettingsTab.actionsAndLinks)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 260)
                Spacer()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if selectedTab == .mouseAndMovement {
                        aimSettings
                        Divider()
                        movementSettings
                    } else {
                        addMappingControls
                        bindingsSettings
                        Divider()
                        FPSKeyLinkControls(profile: $draft)
                    }
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            }.id(selectedTab)
                .background(Color.secondary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            Divider()
            HStack {
                Text("位置、尺寸、滑动路径与换向参数统一在拖拽布局中调整。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("拖拽布局…") {
                    if save() { controller.beginLayoutEditing(); dismiss() }
                }.disabled(!videoReady)
            }
        }
        .padding(24).frame(width: 840, height: 730)
        // Input ACKs arrive at the game refresh rate. Only subscribe to state
        // used by this sheet so they do not rebuild every action row.
        .onReceive(controller.$videoReady.removeDuplicates()) { videoReady = $0 }
        .onReceive(controller.$library.map(\.profiles).removeDuplicates()) { profileNames = $0 }
        .onReceive(controller.$remoteOrientation.combineLatest(controller.$hasRemoteOrientation, controller.$viewportAspect)
            .receive(on: RunLoop.main)
            .map { _ in controller.orientationDescription }.removeDuplicates()) { orientationDescription = $0 }
    }

    private var addMappingControls: some View {
        HStack {
                FPSAddMappingMenu(profile: draft, custom: { addCustomButton() }, swipe: { addCustomButton(swipe: true) }, preset: addPreset)
                Button("添加滑动按钮") { addCustomButton(swipe: true) }
                    .disabled(draft.customButtons.count >= FPSProfile.maximumCustomButtons)
                Text(videoReady ? "添加后直接进入画面拖拽布局。" : "先添加并绑定按键，连接画面后可拖动位置。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Text("\(draft.customButtons.count) / \(FPSProfile.maximumCustomButtons)").font(.system(size: 11)).monospacedDigit()
            }
    }

    private var aimSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("鼠标转向").font(.system(size: 14, weight: .semibold))
            Toggle("启用鼠标转向映射", isOn: $draft.lookEnabled).toggleStyle(.checkbox)
            if draft.lookEnabled { Button("删除转向映射", role: .destructive) { draft.removeMapping("look") } }
            HStack(spacing: 14) {
                Text("灵敏度").frame(width: 72, alignment: .leading)
                Slider(value: $draft.sensitivity, in: 0.10...4.0)
                Text("\(draft.sensitivity, specifier: "%.2f")×").monospacedDigit().frame(width: 52)
            }
            Picker("呼出 / 收回鼠标", selection: $draft.cursorToggleKey) {
                ForEach(FPSKey.cursorChoices, id: \.self) { Text(FPSKey.title($0)).tag($0) }
            }.frame(width: 320)
            Text("捕获后按此键显示鼠标，左键点击或拖动游戏界面；再按一次恢复转视角。WASD 可继续使用。")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 18) {
                Picker("画面方向", selection: $draft.orientation) {
                    ForEach(FPSOrientation.allCases, id: \.rawValue) { Text($0.title).tag($0) }
                }.frame(width: 320)
                Toggle("滚轮切换武器", isOn: $draft.wheelSwitchWeapons).toggleStyle(.checkbox)
            }
            Text(orientationDescription).foregroundStyle(.orange)
        }.font(.system(size: 11))
    }

    private var movementSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("WASD 移动").font(.system(size: 14, weight: .semibold))
            Toggle("启用 WASD 移动映射", isOn: $draft.joystickEnabled).toggleStyle(.checkbox)
            if draft.joystickEnabled { Button("删除移动映射", role: .destructive) { draft.removeMapping("joystick") } }
            Text("WASD 控制移动，鼠标控制视角。换向过渡与松键归位选项在拖拽布局中选中 WASD 后调整。")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.font(.system(size: 11))
    }

    private var bindingsSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("动作按键").font(.system(size: 14, weight: .semibold))
            TextField("搜索按钮名称或 Mac 按键", text: $search).textFieldStyle(.roundedBorder)
            Text("共 \(draft.buttons.count) 个按钮 · \(draft.buttons.filter(\.enabled).count) 个启用")
                .foregroundStyle(.secondary)
            ForEach(draft.buttons.filter { search.isEmpty || ($0.title + FPSKey.title($0.trigger)).localizedCaseInsensitiveContains(search) }) { button in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Toggle("启用", isOn: buttonValue(button, \.enabled)).toggleStyle(.checkbox)
                        TextField("按钮名称", text: buttonValue(button, \.title)).textFieldStyle(.roundedBorder).frame(width: 240)
                        Spacer()
                        Button("删除", role: .destructive) { draft.removeMapping(button.id) }
                    }
                    HStack(spacing: 16) {
                        Picker(button.title + "按键", selection: buttonValue(button, \.trigger)) {
                            ForEach(FPSKey.choices, id: \.self) { key in Text(FPSKey.title(key)).tag(key) }
                        }.labelsHidden().frame(width: 136)
                        Picker(button.title + "触屏方式", selection: buttonValue(button, \.behavior)) {
                            ForEach(FPSPressBehavior.allCases, id: \.rawValue) { Text($0.title).tag($0) }
                        }.labelsHidden().frame(width: 90)
                    }
                }.padding(10).background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            }
            Text("预设、自定义和滑动按钮均可改名、改键、改位置、停用或删除。删除的预设可从“添加映射”恢复。")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.font(.system(size: 11))
    }

    private func buttonValue<Value>(_ button: FPSButton, _ keyPath: WritableKeyPath<FPSButton, Value>) -> Binding<Value> {
        Binding(get: { (draft.buttons.first { $0.id == button.id } ?? button)[keyPath: keyPath] }, set: { value in
            guard var next = draft.buttons.first(where: { $0.id == button.id }) else { return }
            next[keyPath: keyPath] = value; draft.updateButton(next)
        })
    }
    private func addPreset(_ target: String) {
        do {
            if target == "joystick" { draft.joystickEnabled = true }
            else if target == "look" { draft.lookEnabled = true }
            else if let action = FPSAction(rawValue: target) { try draft.addPreset(action) }
            error = nil
        } catch { self.error = error.localizedDescription }
    }
    private func addCustomButton(swipe: Bool = false) {
        do {
            let target = try draft.addCustomButton(swipe: swipe); error = nil
            if controller.videoReady, save() { controller.beginLayoutEditing(target); dismiss() }
        } catch { self.error = error.localizedDescription }
    }
    private func save() -> Bool {
        do { try draft.validate(); controller.profile = draft; error = nil; return true }
        catch { self.error = error.localizedDescription; return false }
    }
}
