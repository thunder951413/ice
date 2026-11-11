//
//  AppDelegate.swift
//  Ice
//

import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private weak var appState: AppState?
    private var isSecondaryInstance = false

    // MARK: NSApplicationDelegate Methods

    func applicationWillFinishLaunching(_ notification: Notification) {
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let hasOlderInstance = NSRunningApplication
            .runningApplications(withBundleIdentifier: Constants.bundleIdentifier)
            .contains { $0.processIdentifier < currentPID }
        if hasOlderInstance {
            isSecondaryInstance = true
            Logger.appDelegate.warning("Terminating duplicate Ice instance")
            NSApp.terminate(nil)
            return
        }

        guard let appState else {
            Logger.appDelegate.warning("Missing app state in applicationWillFinishLaunching")
            return
        }

        appState.assignAppDelegate(self)
        appState.setsCursorInBackground = true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !isSecondaryInstance else {
            return
        }
        guard let appState else {
            Logger.appDelegate.warning("Missing app state in applicationDidFinishLaunching")
            return
        }

        appState.dismissSettingsWindow()
        appState.dismissPermissionsWindow()

        if let mainMenu = NSApp.mainMenu {
            for item in mainMenu.items {
                item.isHidden = true
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            guard !appState.isPreview else {
                return
            }
            switch appState.permissionsManager.permissionsState {
            case .hasPermissions:
                appState.performSetup()
            case .missingPermissions:
                appState.activate(withPolicy: .regular)
                appState.openPermissionsWindow()
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        NSApp.setActivationPolicy(.accessory)
        return false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !isSecondaryInstance, appState?.isPreview == false else {
            return true
        }
        if !flag {
            openSettingsWindow()
        }
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        appState?.menuBarManager.hostedItemVisibilityManager.restoreAll(stop: true)
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }

    // MARK: Other Methods

    func assignAppState(_ appState: AppState) {
        guard self.appState == nil else {
            Logger.appDelegate.warning("Multiple attempts made to assign app state")
            return
        }
        self.appState = appState
    }

    @objc func openSettingsWindow() {
        guard let appState else {
            Logger.appDelegate.error("Failed to open settings window")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            appState.activate(withPolicy: .regular)
            appState.openSettingsWindow()
        }
    }
}

// MARK: - Logger
private extension Logger {
    static let appDelegate = Logger(category: "AppDelegate")
}
