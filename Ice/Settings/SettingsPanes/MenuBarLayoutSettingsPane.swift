//
//  MenuBarLayoutSettingsPane.swift
//  Ice
//

import SwiftUI

struct MenuBarLayoutSettingsPane: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        if !HostedItemVisibilityManager.isSupported && !ScreenCapture.cachedCheckPermissions() {
            missingScreenRecordingPermission
        } else if appState.menuBarManager.isMenuBarHiddenBySystemUserDefaults {
            cannotArrange
        } else {
            IceForm(alignment: .leading, spacing: 20) {
                header
                if HostedItemVisibilityManager.isSupported {
                    HostedVisibilityNotice(manager: appState.menuBarManager.hostedItemVisibilityManager)
                }
                layoutBars
            }
        }
    }

    @ViewBuilder
    private var header: some View {
        Text(HostedItemVisibilityManager.isSupported ? "Choose menu bar item sections" : "Drag to arrange your menu bar items")
            .font(.title2)

        IceGroupBox {
            AnnotationView(
                alignment: .center,
                font: .callout.bold()
            ) {
                Label {
                    if HostedItemVisibilityManager.isSupported {
                        Text("On macOS 27, click a menu bar icon to choose its section. System icons cannot be assigned to hidden sections. Reorder icons directly in the menu bar with Command-drag.")
                    } else {
                        Text("Tip: you can also arrange menu bar items by Command + dragging them in the menu bar")
                    }
                } icon: {
                    Image(systemName: "lightbulb")
                }
            }
        }
    }

    @ViewBuilder
    private var layoutBars: some View {
        VStack(spacing: 25) {
            ForEach(MenuBarSection.Name.allCases, id: \.self) { section in
                layoutBar(for: section)
            }
        }
    }

    @ViewBuilder
    private var cannotArrange: some View {
        Text("Ice cannot arrange menu bar items in automatically hidden menu bars")
            .font(.title3)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    @ViewBuilder
    private var missingScreenRecordingPermission: some View {
        VStack {
            Text("Menu bar layout requires screen recording permissions")
                .font(.title2)

            Button {
                appState.navigationState.settingsNavigationIdentifier = .advanced
            } label: {
                Text("Go to Advanced Settings")
            }
            .buttonStyle(.link)
        }
    }

    @ViewBuilder
    private func layoutBar(for section: MenuBarSection.Name) -> some View {
        if
            let section = appState.menuBarManager.section(withName: section),
            section.isEnabled
        {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(section.name.displayString) Section")
                    .font(.system(size: 14))
                    .padding(.leading, 2)

                LayoutBar(section: section)
                    .environmentObject(appState.imageCache)
            }
        }
    }
}

private struct HostedVisibilityNotice: View {
    @ObservedObject var manager: HostedItemVisibilityManager

    var body: some View {
        if let message = manager.failureDescription {
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        }
        Text("Click the Ice icon or empty menu bar space to show hidden items. Right-click for Ice settings. Some Apple menu extras may be unavailable while items are hidden; Pause Hiding restores them without changing your layout. App icons are used for previews; Screen Recording is optional.")
            .font(.callout)
            .foregroundStyle(.secondary)
    }
}
