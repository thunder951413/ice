//
//  AboutSettingsPane.swift
//  Ice
//

import SwiftUI

struct AboutSettingsPane: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.openURL) private var openURL

    private var updatesManager: UpdatesManager {
        appState.updatesManager
    }

    private var acknowledgementsURL: URL? {
        Bundle.main.url(forResource: "Acknowledgements", withExtension: "pdf")
    }

    private var repositoryURL: URL? {
        URL(string: "https://github.com/thunder951413/ice")
    }

    private var issuesURL: URL? {
        URL(string: "https://github.com/thunder951413/ice/issues")
    }

    private var lastUpdateCheckString: String {
        if let date = updatesManager.lastUpdateCheckDate {
            date.formatted(date: .abbreviated, time: .shortened)
        } else {
            "从未检查"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            mainForm
            Spacer(minLength: 16)
            bottomBar
        }
        .padding(28)
    }

    @ViewBuilder
    private var mainForm: some View {
        IceForm(padding: EdgeInsets(top: 16, leading: 28, bottom: 24, trailing: 28), spacing: 0) {
            appIconAndCopyrightSection
                .layoutPriority(1)

            Spacer(minLength: 0)
                .frame(maxHeight: 20)

            updatesSection
                .layoutPriority(1)
        }
        .scrollDisabled(false)
        .frame(maxHeight: 480)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    @ViewBuilder
    private var appIconAndCopyrightSection: some View {
        IceSection(options: .plain) {
            HStack(spacing: 20) {
                if let nsImage = NSImage(named: NSImage.applicationIconName) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 140, height: 140)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Ice")
                        .font(.system(size: 52, weight: .semibold))
                        .foregroundStyle(.primary)

                    Text("版本 \(Constants.versionString) (Build \(Constants.buildString))")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.secondary)

                    Text("专为 macOS 27+ 打造的原生菜单栏图标管理工具")
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    Text(Constants.copyrightString)
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 2)
                }
            }
        }
    }

    @ViewBuilder
    private var updatesSection: some View {
        IceSection(options: .hasDividers) {
            Toggle(
                "自动检查更新",
                isOn: updatesManager.bindings.automaticallyChecksForUpdates
            )
            Toggle(
                "自动在后台下载更新",
                isOn: updatesManager.bindings.automaticallyDownloadsUpdates
            )
            if updatesManager.canCheckForUpdates {
                HStack {
                    Button("检查更新…") {
                        updatesManager.checkForUpdates()
                    }
                    Spacer()
                    Text("上次检查：\(lastUpdateCheckString)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: 560)
    }

    @ViewBuilder
    private var bottomBar: some View {
        HStack {
            Button("退出 Ice") {
                NSApp.terminate(nil)
            }
            Spacer()
            if let acknowledgementsURL {
                Button("开源致谢") {
                    NSWorkspace.shared.open(acknowledgementsURL)
                }
            }
            if let repositoryURL {
                Button("GitHub 仓库") {
                    openURL(repositoryURL)
                }
            }
            if let issuesURL {
                Button("问题反馈") {
                    openURL(issuesURL)
                }
            }
        }
        .padding(8)
        .buttonStyle(BottomBarButtonStyle())
        .background(.quinary, in: Capsule(style: .circular))
        .frame(height: 40)
    }
}

private struct BottomBarButtonStyle: ButtonStyle {
    @State private var isHovering = false

    private var borderShape: some InsettableShape {
        Capsule(style: .circular)
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background {
                borderShape
                    .fill(configuration.isPressed ? .tertiary : .quaternary)
                    .opacity(isHovering ? 1 : 0)
            }
            .contentShape([.focusEffect, .interaction], borderShape)
            .onHover { hovering in
                isHovering = hovering
            }
    }
}
