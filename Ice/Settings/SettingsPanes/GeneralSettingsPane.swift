//
//  GeneralSettingsPane.swift
//  Ice
//

import SwiftUI

@MainActor
struct GeneralSettingsPane: View {
    private enum CustomIconImportError: LocalizedError {
        case invalidImageData

        var errorDescription: String? {
            switch self {
            case .invalidImageData:
                "所选文件无法识别为有效图片。"
            }
        }
    }

    @EnvironmentObject var appState: AppState
    @StateObject private var loginItemManager = LoginItemManager()
    @State private var isImportingCustomIceIcon = false
    @State private var isPresentingError = false
    @State private var presentedError: LocalizedErrorWrapper?
    @State private var isApplyingOffset = false
    @State private var tempItemSpacingOffset: CGFloat = 0
    @State private var isConfirmingSpacingApply = false

    private var manager: GeneralSettingsManager {
        appState.settingsManager.generalSettingsManager
    }

    private var accessibilityPermission: AccessibilityPermission {
        appState.permissionsManager.accessibilityPermission
    }

    private var hasSpacingSliderValueChanged: Bool {
        tempItemSpacingOffset != manager.itemSpacingOffset
    }

    private var isActualOffsetDifferentFromDefault: Bool {
        manager.itemSpacingOffset != 0
    }

    private func localizedOffsetString(for offset: CGFloat) -> LocalizedStringKey {
        switch offset {
        case -16:
            return LocalizedStringKey("最紧凑 (-16)")
        case 0:
            return LocalizedStringKey("系统默认 (0)")
        case 16:
            return LocalizedStringKey("最宽松 (+16)")
        default:
            let sign = offset > 0 ? "+" : ""
            return LocalizedStringKey("\(sign)\(Int(offset))")
        }
    }

    private func secondsLabel(_ seconds: TimeInterval) -> LocalizedStringKey {
        if seconds == 0 {
            return LocalizedStringKey("关闭菜单后立即回隐")
        }
        return LocalizedStringKey("\(Int(seconds)) 秒")
    }

    var body: some View {
        IceForm {
            IceSection("启动与权限") {
                launchAtLoginRow
                accessibilityPermissionRow
            }
            IceSection("菜单栏入口与点击操作") {
                iceIconOptions
                Toggle("左键点击菜单栏空白处展开隐藏图标", isOn: manager.bindings.showOnClick)
                    .annotation("点击应用菜单与右侧状态图标之间的空白区域即可呼出或收起 Ice Bar")
                Toggle("右键点击菜单栏空白处打开快捷菜单", isOn: manager.bindings.showContextMenuOnRightClick)
                    .annotation("即使隐藏了菜单栏上的 Ice 图标，也能随时右键空白处打开设置")
            }
            IceSection("Ice Bar 悬浮面板") {
                iceBarStylePicker
                iceBarLocationPicker
                iceBarSizingOptions
            }
            IceSection("自动收起与回隐") {
                autoRehideOptions
                tempShowIntervalRow
            }
            IceSection("系统菜单栏间距") {
                spacingOptions
            }
        }
        .alert(isPresented: $isPresentingError, error: presentedError) {
            Button("好") {
                presentedError = nil
                isPresentingError = false
            }
        }
        .confirmationDialog(
            "应用新的系统菜单栏图标间距？",
            isPresented: $isConfirmingSpacingApply,
            titleVisibility: .visible
        ) {
            Button("应用并重启菜单栏应用") {
                applyOffset()
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text("包含菜单栏图标的应用将收到正常退出并重开的请求；若有未保存内容，对应应用会保持运行。")
        }
    }

    @ViewBuilder
    private var launchAtLoginRow: some View {
        Toggle(
            "登录时自动启动 Ice",
            isOn: Binding(
                get: { loginItemManager.isEnabled },
                set: { loginItemManager.setEnabled($0) }
            )
        )
        .annotation {
            VStack(alignment: .leading, spacing: 6) {
                switch loginItemManager.status {
                case .requiresApproval:
                    Text("请在“系统设置 > 通用 > 登录项”中允许 Ice 在后台运行。")
                    Button("打开登录项设置…") {
                        loginItemManager.openSystemSettings()
                    }
                case .notFound:
                    Text("未找到登录项注册信息，请将 Ice 移入“应用程序”文件夹后重试。")
                case .enabled, .notRegistered:
                    EmptyView()
                }

                if let errorMessage = loginItemManager.errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.orange)
                }
            }
        }
        .onAppear {
            loginItemManager.refresh()
            appState.permissionsManager.refreshPermissions()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginItemManager.refresh()
            appState.permissionsManager.refreshPermissions()
        }
    }

    @ViewBuilder
    private var accessibilityPermissionRow: some View {
        IceLabeledContent {
            HStack(spacing: 10) {
                if accessibilityPermission.hasPermission {
                    Label("已授权", systemImage: "checkmark.circle.fill")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.green)
                } else {
                    Label("未授权", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.orange)
                }
                Button(accessibilityPermission.hasPermission ? "系统设置…" : "前往授权…") {
                    if accessibilityPermission.hasPermission {
                        accessibilityPermission.openSystemSettings()
                    } else {
                        accessibilityPermission.performRequest()
                    }
                }
            }
        } label: {
            Text("辅助功能权限")
        }
        .annotation("用于读取菜单栏图标列表及点击唤醒隐藏图标，无需屏幕录制权限")
    }

    @ViewBuilder
    private func menuItem(for imageSet: ControlItemImageSet) -> some View {
        Label {
            Text(imageSet.name.localizedTitle)
        } icon: {
            if let nsImage = imageSet.hidden.nsImage(for: appState) {
                switch imageSet.name {
                case .custom:
                    Image(size: CGSize(width: 18, height: 18)) { context in
                        context.draw(
                            Image(nsImage: nsImage),
                            in: context.clipBoundingRect
                        )
                    }
                default:
                    Image(nsImage: nsImage)
                }
            }
        }
    }

    @ViewBuilder
    private var iceIconOptions: some View {
        Toggle("在菜单栏显示 Ice 图标", isOn: manager.bindings.showIceIcon)
            .annotation {
                if !manager.showIceIcon {
                    Text("已隐藏 Ice 图标；可点击菜单栏空白处呼出面板，或右键空白处打开设置")
                }
            }
        if manager.showIceIcon {
            IceMenu("Ice 图标样式") {
                Picker("Ice 图标样式", selection: manager.bindings.iceIcon) {
                    ForEach(ControlItemImageSet.userSelectableIceIcons) { imageSet in
                        Button {
                            manager.iceIcon = imageSet
                        } label: {
                            menuItem(for: imageSet)
                        }
                        .tag(imageSet)
                    }
                    if let lastCustomIceIcon = manager.lastCustomIceIcon {
                        Button {
                            manager.iceIcon = lastCustomIceIcon
                        } label: {
                            menuItem(for: lastCustomIceIcon)
                        }
                        .tag(lastCustomIceIcon)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()

                Divider()

                Button("选择自定义图片…") {
                    isImportingCustomIceIcon = true
                }
            } title: {
                menuItem(for: manager.iceIcon)
            }
            .fileImporter(
                isPresented: $isImportingCustomIceIcon,
                allowedContentTypes: [.image]
            ) { result in
                do {
                    let url = try result.get()
                    let accessed = url.startAccessingSecurityScopedResource()
                    defer {
                        if accessed {
                            url.stopAccessingSecurityScopedResource()
                        }
                    }
                    let data = try Data(contentsOf: url)
                    guard NSImage(data: data) != nil else {
                        throw CustomIconImportError.invalidImageData
                    }
                    manager.iceIcon = ControlItemImageSet(name: .custom, image: .data(data))
                } catch {
                    presentedError = LocalizedErrorWrapper(error)
                    isPresentingError = true
                }
            }

            if case .custom = manager.iceIcon.name {
                Toggle("将自定义图标设为系统单色模板", isOn: manager.bindings.customIceIconIsTemplate)
                    .annotation("自动跟随浅色 / 深色菜单栏切换黑白单色效果")
            }
        }
    }

    @ViewBuilder
    private var iceBarStylePicker: some View {
        IcePicker("面板外观", selection: manager.bindings.iceBarStyle) {
            ForEach(IceBarStyle.allCases) { style in
                Text(style.localized).tag(style)
            }
        }
    }

    @ViewBuilder
    private var iceBarLocationPicker: some View {
        IcePicker("弹出位置", selection: manager.bindings.iceBarLocation) {
            ForEach(IceBarLocation.allCases) { location in
                Text(location.localized).tag(location)
            }
        }
        .annotation {
            switch manager.iceBarLocation {
            case .dynamic:
                Text("点击 Ice 图标时在其正下方展开，点击空白菜单栏时在鼠标下方展开")
            case .mousePointer:
                Text("始终在当前鼠标指针正下方居中展开")
            case .iceIcon:
                Text("始终对齐菜单栏上的 Ice 图标正下方展开")
            }
        }
    }

    @ViewBuilder
    private var iceBarSizingOptions: some View {
        IceLabeledContent {
            HStack(spacing: 10) {
                SwiftUI.Slider(value: manager.bindings.iceBarIconSize, in: 16...36, step: 1)
                    .labelsHidden()
                    .accessibilityLabel("图标大小")
                Text("\(manager.iceBarIconSize.formatted()) pt")
                    .monospacedDigit()
                    .frame(width: 46, alignment: .trailing)
            }
            .frame(width: 240)
        } label: {
            Text("图标大小")
        }

        IceLabeledContent {
            HStack(spacing: 10) {
                SwiftUI.Slider(value: manager.bindings.iceBarItemSpacing, in: 0...12, step: 1)
                    .labelsHidden()
                    .accessibilityLabel("图标间距")
                Text("\(manager.iceBarItemSpacing.formatted()) pt")
                    .monospacedDigit()
                    .frame(width: 46, alignment: .trailing)
            }
            .frame(width: 240)
        } label: {
            Text("图标间距")
        }

        IceLabeledContent {
            HStack(spacing: 10) {
                SwiftUI.Slider(value: manager.bindings.iceBarPadding, in: 2...12, step: 1)
                    .labelsHidden()
                    .accessibilityLabel("面板内边距")
                Text("\(manager.iceBarPadding.formatted()) pt")
                    .monospacedDigit()
                    .frame(width: 46, alignment: .trailing)
            }
            .frame(width: 240)
        } label: {
            Text("面板内边距")
        }

        HStack(spacing: 10) {
            Button("恢复默认尺寸") {
                manager.iceBarIconSize = GeneralSettingsManager.defaultIceBarIconSize
                manager.iceBarItemSpacing = GeneralSettingsManager.defaultIceBarItemSpacing
                manager.iceBarPadding = GeneralSettingsManager.defaultIceBarPadding
            }
            Button("预览 Ice Bar") {
                appState.menuBarManager.section(withName: .hidden)?.show()
            }
        }
    }

    @ViewBuilder
    private var autoRehideOptions: some View {
        Toggle("自动收起 Ice Bar", isOn: manager.bindings.autoRehide)
        if manager.autoRehide {
            IcePicker("收起策略", selection: manager.bindings.rehideStrategy) {
                ForEach(RehideStrategy.allCases) { strategy in
                    Text(strategy.localized).tag(strategy)
                }
            }
            .annotation {
                switch manager.rehideStrategy {
                case .smart:
                    Text("点击桌面或其他应用窗口时自动关闭 Ice Bar")
                case .timed:
                    Text("鼠标移出菜单栏与 Ice Bar 指定时间后自动关闭")
                case .focusedApp:
                    Text("当前前台焦点应用切换时自动关闭")
                }
            }

            if case .timed = manager.rehideStrategy {
                IceLabeledContent {
                    IceSlider(
                        LocalizedStringKey("\(Int(manager.rehideInterval)) 秒"),
                        value: manager.bindings.rehideInterval,
                        in: 1...30,
                        step: 1
                    )
                    .frame(width: 240)
                } label: {
                    Text("定时收起等待")
                }
            }
        }
    }

    @ViewBuilder
    private var tempShowIntervalRow: some View {
        IceLabeledContent {
            IceSlider(
                secondsLabel(manager.tempShowInterval),
                value: manager.bindings.tempShowInterval,
                in: 0...30,
                step: 1
            )
            .frame(width: 240)
        } label: {
            Text("临时唤醒保留时长")
        }
        .annotation("在 Ice Bar 中点击某个隐藏图标后，该图标会在系统菜单栏临时显现直至其弹出菜单关闭，并额外保留所设时长")
    }

    @ViewBuilder
    private var spacingOptions: some View {
        IceLabeledContent {
            IceSlider(
                localizedOffsetString(for: tempItemSpacingOffset),
                value: $tempItemSpacingOffset,
                in: -16...16,
                step: 2
            )
            .disabled(isApplyingOffset)
            .frame(width: 240)
        } label: {
            IceLabeledContent {
                Button("应用") {
                    isConfirmingSpacingApply = true
                }
                .disabled(isApplyingOffset || !hasSpacingSliderValueChanged)

                if isApplyingOffset {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .scaleEffect(0.5)
                        .frame(width: 15, height: 15)
                } else {
                    Button {
                        resetOffsetToDefault()
                    } label: {
                        Image(systemName: "arrow.counterclockwise.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .help("恢复系统默认间距")
                    .accessibilityLabel("恢复系统默认间距")
                    .disabled(isApplyingOffset || !isActualOffsetDifferentFromDefault)
                }
            } label: {
                Text("系统菜单栏图标间距")
            }
        }
        .annotation("调整全局菜单栏状态图标紧凑度；部分系统图标可能需要注销并重新登录才完全生效")
        .onAppear {
            tempItemSpacingOffset = manager.itemSpacingOffset
        }
        .onChange(of: manager.itemSpacingOffset) { _, newValue in
            if !isApplyingOffset {
                tempItemSpacingOffset = newValue
            }
        }
    }

    private func applyOffset() {
        isApplyingOffset = true
        manager.itemSpacingOffset = tempItemSpacingOffset
        let knownPIDs = Set(appState.itemManager.itemCache.allItems.map(\.ownerPID))
        Task {
            do {
                try await appState.spacingManager.applyOffset(additionalPIDs: knownPIDs)
            } catch {
                NSAlert(error: error).runModal()
            }
            isApplyingOffset = false
        }
    }

    private func resetOffsetToDefault() {
        tempItemSpacingOffset = 0
        isConfirmingSpacingApply = true
    }
}
