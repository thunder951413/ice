//
//  SettingsWindow.swift
//  Ice
//

import SwiftUI

struct SettingsWindow: Scene {
    @ObservedObject var appState: AppState

    var body: some Scene {
        Window(Constants.settingsWindowTitle, id: Constants.settingsWindowID) {
            SettingsView()
                .readWindow { window in
                    guard let window else {
                        return
                    }
                    appState.assignSettingsWindow(window)
                }
                .frame(minWidth: 760, minHeight: 500)
        }
        .commandsRemoved()
        .windowResizability(.contentSize)
        .defaultSize(width: 840, height: 600)
        .environmentObject(appState)
        .environmentObject(appState.navigationState)
    }
}
