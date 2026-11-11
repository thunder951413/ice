//
//  MenuBarItemSpacingManager.swift
//  Ice
//

import Cocoa

/// Manager for menu bar item spacing.
@MainActor
final class MenuBarItemSpacingManager {
    /// UserDefaults keys.
    private enum Key: String, CaseIterable {
        case spacing = "NSStatusItemSpacing"
        case padding = "NSStatusItemSelectionPadding"

        var defaultValue: Int {
            switch self {
            case .spacing: 16
            case .padding: 16
            }
        }
    }

    /// An error that groups multiple failed app relaunches.
    private struct GroupedRelaunchError: LocalizedError {
        let failedApps: [String]

        var errorDescription: String? {
            "以下应用未能自动重启以应用新间距：\n" + failedApps.sorted().joined(separator: "\n")
        }

        var recoverySuggestion: String? {
            "未退出的应用保持原状运行；请在保存未完成的工作后手动退出并重开这些应用。"
        }
    }

    /// The offset to apply to the default spacing and padding.
    var offset = 0

    private func writePreferences() throws {
        struct WriteError: LocalizedError {
            var errorDescription: String? {
                "无法写入系统菜单栏间距配置，所有应用保持原状运行。"
            }
        }
        for key in Key.allCases {
            let value = offset == 0 ? nil : NSNumber(value: key.defaultValue + offset)
            CFPreferencesSetValue(
                key.rawValue as CFString,
                value,
                kCFPreferencesAnyApplication,
                kCFPreferencesCurrentUser,
                kCFPreferencesCurrentHost
            )
        }
        guard CFPreferencesSynchronize(
            kCFPreferencesAnyApplication,
            kCFPreferencesCurrentUser,
            kCFPreferencesCurrentHost
        ) else {
            throw WriteError()
        }
    }

    private nonisolated func logString(for app: NSRunningApplication) -> String {
        app.localizedName ?? app.bundleIdentifier ?? "<NIL>"
    }

    private func signalAppToQuit(_ app: NSRunningApplication) async throws {
        if app.isTerminated {
            Logger.spacing.debug("Application \"\(logString(for: app))\" is already terminated")
            return
        }
        Logger.spacing.debug("Signaling application \"\(logString(for: app))\" to quit")
        try await GracefulApplicationTermination.terminate(
            isTerminated: { app.isTerminated },
            requestTermination: { app.terminate() }
        )
    }

    private func launchApp(at applicationURL: URL, bundleIdentifier: String) async throws {
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleIdentifier }) {
            Logger.spacing.debug("Application \"\(logString(for: app))\" is already open, so skipping launch")
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        configuration.createsNewApplicationInstance = false
        configuration.promptsUserIfNeeded = false
        try await NSWorkspace.shared.openApplication(at: applicationURL, configuration: configuration)
    }

    private func relaunchApp(_ app: NSRunningApplication) async throws {
        struct RelaunchError: Error { }
        guard
            let url = app.bundleURL,
            let bundleIdentifier = app.bundleIdentifier
        else {
            throw RelaunchError()
        }
        try await signalAppToQuit(app)
        if app.isTerminated {
            try await launchApp(at: url, bundleIdentifier: bundleIdentifier)
        } else {
            throw RelaunchError()
        }
    }

    /// Applies the current ``offset`` and cooperatively restarts menu bar apps.
    func applyOffset(additionalPIDs: Set<pid_t> = []) async throws {
        try writePreferences()

        try? await Task.sleep(for: .milliseconds(100))

        let items = MenuBarItem.getMenuBarItems(onScreenOnly: false, activeSpaceOnly: true)
        let pids = Set(items.map(\.ownerPID)).union(additionalPIDs)

        var failedApps = [String]()

        let excludedBundles: Set<String> = [
            "com.apple.controlcenter",
            "com.apple.MenuBarAgent",
            "com.apple.systemuiserver",
        ]

        await withTaskGroup(of: Void.self) { group in
            for pid in pids {
                guard
                    let app = NSRunningApplication(processIdentifier: pid),
                    app.bundleIdentifier.map({ !excludedBundles.contains($0) }) ?? true,
                    app != .current
                else {
                    continue
                }
                group.addTask { @MainActor in
                    do {
                        try await self.relaunchApp(app)
                    } catch {
                        guard let name = app.localizedName else {
                            return
                        }
                        if app.bundleIdentifier == "com.apple.Spotlight" {
                            if
                                let latestSpotlightInstance = NSRunningApplication
                                    .runningApplications(withBundleIdentifier: "com.apple.Spotlight").first,
                                latestSpotlightInstance.processIdentifier == app.processIdentifier
                            {
                                failedApps.append(name)
                            }
                        } else {
                            failedApps.append(name)
                        }
                    }
                }
            }
        }

        try? await Task.sleep(for: .milliseconds(100))

        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.controlcenter").first {
            do {
                try await signalAppToQuit(app)
            } catch {
                if let name = app.localizedName {
                    failedApps.append(name)
                }
            }
        }

        if !failedApps.isEmpty {
            throw GroupedRelaunchError(failedApps: failedApps)
        }
    }
}

// MARK: - Logger
private extension Logger {
    static let spacing = Logger(category: "Spacing")
}
