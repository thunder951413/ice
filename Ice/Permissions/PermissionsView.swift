//
//  PermissionsView.swift
//  Ice
//

import SwiftUI

struct PermissionsView: View {
    @EnvironmentObject var permissionsManager: PermissionsManager
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 16) {
            headerView
                .padding(.top, 8)

            explanationView
            permissionsGroupStack

            footerView
                .padding(.bottom, 8)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .frame(width: 460)
        .fixedSize()
        .readWindow { window in
            guard let window else {
                return
            }
            window.styleMask.remove([.closable, .miniaturizable])
            if let contentView = window.contentView {
                with(contentView.safeAreaInsets) { insets in
                    insets.bottom = -insets.bottom
                    insets.left = -insets.left
                    insets.right = -insets.right
                    insets.top = -insets.top
                    contentView.additionalSafeAreaInsets = insets
                }
            }
        }
    }

    @ViewBuilder
    private var headerView: some View {
        HStack(spacing: 14) {
            if let nsImage = NSImage(named: NSImage.applicationIconName) {
                Image(nsImage: nsImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 64, height: 64)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("欢迎使用 Ice")
                    .font(.system(size: 26, weight: .semibold))
                Text("开始前请完成必要的系统权限授权")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var explanationView: some View {
        IceSection {
            VStack(alignment: .leading, spacing: 6) {
                Text("Ice 需要辅助功能权限以管理 macOS 27 菜单栏图标。")
                    .font(.callout)
                Label("应用仅在本地运行，绝不会收集、存储或上传任何个人数据。", systemImage: "lock.shield.fill")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(4)
        }
    }

    @ViewBuilder
    private var permissionsGroupStack: some View {
        VStack(spacing: 10) {
            ForEach(permissionsManager.allPermissions) { permission in
                permissionBox(permission)
            }
        }
    }

    @ViewBuilder
    private var footerView: some View {
        HStack(spacing: 12) {
            quitButton
            continueButton
        }
        .controlSize(.large)
    }

    @ViewBuilder
    private var quitButton: some View {
        Button {
            NSApp.terminate(nil)
        } label: {
            Text("退出")
                .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private var continueButton: some View {
        Button {
            guard let appState = permissionsManager.appState else {
                return
            }
            appState.performSetup()
            appState.permissionsWindow?.close()
            appState.appDelegate?.openSettingsWindow()
        } label: {
            Text("进入设置")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .disabled(permissionsManager.permissionsState == .missingPermissions)
    }

    @ViewBuilder
    private func permissionBox(_ permission: Permission) -> some View {
        IceSection {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(permission.title)
                        .font(.headline)
                    Spacer()
                    if permission.hasPermission {
                        Label("已授权", systemImage: "checkmark.circle.fill")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.green)
                    } else {
                        Label("未授权", systemImage: "exclamationmark.circle.fill")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.orange)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    ForEach(permission.details, id: \.self) { detail in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("•")
                                .foregroundStyle(.secondary)
                            Text(detail)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                HStack {
                    Spacer()
                    Button {
                        guard let appState = permissionsManager.appState else {
                            return
                        }
                        permission.performRequest()
                        Task {
                            await permission.waitForPermission()
                            guard
                                permission.hasPermission,
                                !appState.hasPerformedSetup
                            else {
                                return
                            }
                            appState.activate(withPolicy: .regular)
                            openWindow(id: Constants.permissionsWindowID)
                        }
                    } label: {
                        Text(permission.hasPermission ? "已完成授权" : "前往系统设置授权…")
                    }
                    .disabled(permission.hasPermission)
                }
            }
            .padding(4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
