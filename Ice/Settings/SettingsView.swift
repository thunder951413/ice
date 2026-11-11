//
//  SettingsView.swift
//  Ice
//

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var navigationState: AppNavigationState
    @Environment(\.sidebarRowSize) var sidebarRowSize

    private var sidebarWidth: CGFloat {
        switch sidebarRowSize {
        case .small: 180
        case .medium: 200
        case .large: 220
        @unknown default: 200
        }
    }

    private var sidebarItemHeight: CGFloat {
        switch sidebarRowSize {
        case .small: 28
        case .medium: 32
        case .large: 36
        @unknown default: 32
        }
    }

    private var sidebarItemFontSize: CGFloat {
        switch sidebarRowSize {
        case .small: 13
        case .medium: 14
        case .large: 15
        @unknown default: 14
        }
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detailView
        }
        .navigationTitle(navigationState.settingsNavigationIdentifier.localized)
    }

    @ViewBuilder
    private var sidebar: some View {
        List(selection: $navigationState.settingsNavigationIdentifier) {
            Section {
                ForEach(SettingsNavigationIdentifier.allCases, id: \.self) { identifier in
                    sidebarItem(for: identifier)
                }
            } header: {
                Text("Ice")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(.primary)
                    .padding(.vertical, 6)
            }
            .collapsible(false)
        }
        .scrollDisabled(true)
        .removeSidebarToggle()
        .navigationSplitViewColumnWidth(sidebarWidth)
    }

    @ViewBuilder
    private var detailView: some View {
        switch navigationState.settingsNavigationIdentifier {
        case .general:
            GeneralSettingsPane()
        case .menuBarLayout:
            MenuBarLayoutSettingsPane()
        case .about:
            AboutSettingsPane()
        }
    }

    @ViewBuilder
    private func sidebarItem(for identifier: SettingsNavigationIdentifier) -> some View {
        Label {
            Text(identifier.localized)
                .font(.system(size: sidebarItemFontSize, weight: .medium))
                .padding(.leading, 2)
        } icon: {
            icon(for: identifier).view
        }
        .frame(height: sidebarItemHeight)
    }

    private func icon(for identifier: SettingsNavigationIdentifier) -> IconResource {
        switch identifier {
        case .general: .systemSymbol("gearshape")
        case .menuBarLayout: .systemSymbol("square.grid.2x2")
        case .about: .assetCatalog(.iceCubeStroke)
        }
    }
}
