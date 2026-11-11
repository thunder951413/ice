//
//  MenuBarLayoutSettingsPane.swift
//  Ice
//

import SwiftUI

@MainActor
struct MenuBarLayoutSettingsPane: View {
    @EnvironmentObject var appState: AppState
    @State private var isConfirmingReset = false

    private var general: GeneralSettingsManager {
        appState.settingsManager.generalSettingsManager
    }

    private var menuBarManager: MenuBarManager {
        appState.menuBarManager
    }

    private var itemManager: MenuBarItemManager {
        appState.itemManager
    }

    private var visibilityManager: HostedItemVisibilityManager {
        menuBarManager.hostedItemVisibilityManager
    }

    private var activeSections: [MenuBarSection.Name] {
        if general.enableAlwaysHiddenSection {
            return [.visible, .hidden, .alwaysHidden]
        }
        return [.visible, .hidden]
    }

    var body: some View {
        if menuBarManager.isMenuBarHiddenBySystemUserDefaults {
            autoHiddenNotice
        } else {
            IceForm(alignment: .leading, spacing: 18) {
                controlSection
                ForEach(activeSections, id: \.self) { sectionName in
                    sectionCard(for: sectionName)
                }
            }
            .confirmationDialog(
                "重置所有图标分区与菜单栏设置？",
                isPresented: $isConfirmingReset,
                titleVisibility: .visible
            ) {
                Button("重置为全部常驻显示", role: .destructive) {
                    menuBarManager.resetModifications()
                }
                Button("取消", role: .cancel) { }
            } message: {
                Text("所有已隐藏的第三方图标将恢复常驻显示，菜单栏图标间距也将重置为系统默认值。")
            }
        }
    }

    @ViewBuilder
    private var autoHiddenNotice: some View {
        VStack(spacing: 12) {
            Image(systemName: "menubar.arrow.up.rectangle")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("系统当前开启了“自动隐藏和显示菜单栏”")
                .font(.title3.weight(.semibold))
            Text("请前往“系统设置 > 控制中心”将自动隐藏菜单栏设为“仅全屏幕”或“永不”以管理图标。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var controlSection: some View {
        IceSection("运行状态与分区设置") {
            HStack(spacing: 10) {
                statusBadge
                Spacer()
                Button {
                    Task {
                        await itemManager.refreshItems()
                    }
                } label: {
                    Label("刷新列表", systemImage: "arrow.clockwise")
                }
                .disabled(itemManager.isRefreshing)

                Button {
                    menuBarManager.toggleHidingPaused()
                } label: {
                    Label(
                        menuBarManager.isHidingPaused ? "恢复隐藏" : "暂停隐藏",
                        systemImage: menuBarManager.isHidingPaused ? "play.fill" : "pause.fill"
                    )
                }

                Button("重置布局…", role: .destructive) {
                    isConfirmingReset = true
                }
            }
            .annotation(
                general.enableAlwaysHiddenSection
                    ? "点击下方任意应用卡片即可切换所属分区；菜单栏内的排列顺序可按住 ⌘ Command 直接拖动图标调整"
                    : "点击下方任意应用卡片即可在“常驻显示”与“隐藏”之间一键切换；按住 ⌘ Command 可在菜单栏内直接拖动排序"
            )

            if let failure = visibilityManager.failureDescription {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }

            Toggle("启用“始终隐藏”第三分区", isOn: general.bindings.enableAlwaysHiddenSection)
                .annotation("提供更深一层的收纳空间，适合放置常年后台运行但几乎无需点击的应用图标")

            if general.enableAlwaysHiddenSection {
                Toggle("按住 Option 点击切换“始终隐藏”分区", isOn: general.bindings.canToggleAlwaysHiddenSection)
                    .annotation("按住 ⌥ Option 左键点击 Ice 图标或菜单栏空白处时，直接打开“始终隐藏”面板")
            }
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        if menuBarManager.isHidingPaused {
            Label("已暂停隐藏（所有图标临时显示）", systemImage: "pause.circle.fill")
                .font(.callout.weight(.medium))
                .foregroundStyle(.orange)
        } else {
            let hiddenCount = itemManager.itemCache.managedItems(for: .hidden).count
                + (general.enableAlwaysHiddenSection ? itemManager.itemCache.managedItems(for: .alwaysHidden).count : 0)
            Label("隐藏生效中 · 已收纳 \(hiddenCount) 个图标", systemImage: "checkmark.circle.fill")
                .font(.callout.weight(.medium))
                .foregroundStyle(.green)
        }
    }

    private func sectionSymbol(for section: MenuBarSection.Name) -> String {
        switch section {
        case .visible: "eye"
        case .hidden: "eye.slash"
        case .alwaysHidden: "archivebox"
        }
    }

    @ViewBuilder
    private func sectionCard(for sectionName: MenuBarSection.Name) -> some View {
        let items = itemManager.itemCache.managedItems(for: sectionName)

        IceSection(options: [.isBordered]) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label(sectionName.displayString, systemImage: sectionSymbol(for: sectionName))
                    .font(.headline)
                Text("\(items.count)")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
                Spacer()
                Text(sectionName.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } content: {
            if items.isEmpty {
                emptySectionPlaceholder(for: sectionName)
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 155, maximum: 220), spacing: 10)],
                    alignment: .leading,
                    spacing: 10
                ) {
                    ForEach(items, id: \.stableID) { item in
                        ManagedItemCard(
                            item: item,
                            currentSection: sectionName,
                            enableAlwaysHidden: general.enableAlwaysHiddenSection,
                            assignSection: { target in
                                itemManager.assignHostedItem(item, to: target)
                            },
                            openTemporarily: {
                                itemManager.tempShowItem(item, clickWhenFinished: true, mouseButton: .left)
                            }
                        )
                    }
                }
                .padding(.top, 4)
            }
        }
    }

    @ViewBuilder
    private func emptySectionPlaceholder(for sectionName: MenuBarSection.Name) -> some View {
        HStack {
            Spacer()
            if !itemManager.hasCompletedInitialScan {
                ProgressView()
                    .controlSize(.small)
                Text("正在扫描菜单栏图标…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text("“\(sectionName.displayString)”分区暂无图标，点击其他分区中的应用卡片可移入此处")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 18)
    }
}

// MARK: - ManagedItemCard

private struct ManagedItemCard: View {
    let item: MenuBarItem
    let currentSection: MenuBarSection.Name
    let enableAlwaysHidden: Bool
    let assignSection: (MenuBarSection.Name) -> Void
    let openTemporarily: () -> Void

    @State private var isHovered = false

    private var availableSections: [MenuBarSection.Name] {
        enableAlwaysHidden ? [.visible, .hidden, .alwaysHidden] : [.visible, .hidden]
    }

    private var quickToggleTarget: MenuBarSection.Name {
        currentSection == .visible ? .hidden : .visible
    }

    var body: some View {
        Group {
            if enableAlwaysHidden {
                Menu {
                    sectionMenuItems
                } label: {
                    cardContent
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    assignSection(quickToggleTarget)
                } label: {
                    cardContent
                }
                .buttonStyle(.plain)
                .help(currentSection == .visible ? "点击移至“隐藏”分区" : "点击移回“常驻显示”分区")
            }
        }
        .contextMenu {
            sectionMenuItems
            Divider()
            Button("在菜单栏唤醒并打开") {
                openTemporarily()
            }
        }
        .onHover { isHovered = $0 }
    }

    @ViewBuilder
    private var sectionMenuItems: some View {
        ForEach(availableSections, id: \.self) { target in
            Button {
                assignSection(target)
            } label: {
                if target == currentSection {
                    Label("当前位于“\(target.displayString)”", systemImage: "checkmark")
                } else {
                    Text("移至“\(target.displayString)”")
                }
            }
            .disabled(target == currentSection)
        }
    }

    @ViewBuilder
    private var cardContent: some View {
        HStack(spacing: 10) {
            appIcon
            Text(item.displayName)
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            Image(systemName: enableAlwaysHidden ? "chevron.up.chevron.down" : (currentSection == .visible ? "eye.slash" : "eye"))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(isHovered ? .primary : .tertiary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isHovered ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.quinary))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder
    private var appIcon: some View {
        if let icon = item.owningApplication?.icon {
            Image(nsImage: icon)
                .resizable()
                .scaledToFit()
                .frame(width: 24, height: 24)
        } else {
            Image(systemName: "app.dashed")
                .font(.system(size: 18))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
        }
    }
}
