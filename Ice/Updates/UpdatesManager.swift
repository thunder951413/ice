//
//  UpdatesManager.swift
//  Ice
//

import Sparkle
import SwiftUI

/// Manager for app updates.
@MainActor
final class UpdatesManager: NSObject, ObservableObject {
    /// A Boolean value that indicates whether the user can check for updates.
    @Published var canCheckForUpdates = false

    /// The date of the last update check.
    @Published var lastUpdateCheckDate: Date?

    /// A Boolean value that indicates whether a GitHub token is configured for updates.
    @Published private(set) var hasGitHubUpdateToken = false

    /// An error encountered while accessing the GitHub update token.
    @Published private(set) var githubUpdateTokenError: String?

    /// The shared app state.
    private(set) weak var appState: AppState?

    /// The underlying updater controller.
    private(set) lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: false,
        updaterDelegate: self,
        userDriverDelegate: self
    )

    /// The underlying updater.
    var updater: SPUUpdater {
        updaterController.updater
    }

    /// A Boolean value that indicates whether to automatically check for updates.
    var automaticallyChecksForUpdates: Bool {
        get {
            updater.automaticallyChecksForUpdates
        }
        set {
            objectWillChange.send()
            updater.automaticallyChecksForUpdates = newValue
        }
    }

    /// A Boolean value that indicates whether to automatically download updates.
    var automaticallyDownloadsUpdates: Bool {
        get {
            updater.automaticallyDownloadsUpdates
        }
        set {
            objectWillChange.send()
            updater.automaticallyDownloadsUpdates = newValue
        }
    }

    /// Creates an updates manager with the given app state.
    init(appState: AppState) {
        self.appState = appState
        super.init()
    }

    /// Sets up the manager.
    func performSetup() {
        let updaterController = updaterController
        configureUpdateRequestHeaders()
        updaterController.updater.clearFeedURLFromUserDefaults()
        updaterController.startUpdater()
        configureCancellables()
    }

    /// Stores a GitHub token in the Keychain and applies it to future update requests.
    func saveGitHubUpdateToken(_ token: String) {
        do {
            try GitHubUpdateCredentials.saveToken(token)
            configureUpdateRequestHeaders()
        } catch {
            githubUpdateTokenError = error.localizedDescription
        }
    }

    /// Removes the GitHub update token from the Keychain.
    func removeGitHubUpdateToken() {
        do {
            try GitHubUpdateCredentials.removeToken()
            configureUpdateRequestHeaders()
        } catch {
            githubUpdateTokenError = error.localizedDescription
        }
    }

    /// Clears the most recent Keychain error shown in settings.
    func clearGitHubUpdateTokenError() {
        githubUpdateTokenError = nil
    }

    /// Configures headers for GitHub's repository contents API.
    private func configureUpdateRequestHeaders() {
        do {
            let token = try GitHubUpdateCredentials.loadToken()
            var headers = ["Accept": "application/vnd.github.raw+json"]
            if let token {
                headers["Authorization"] = "Bearer \(token)"
            }
            updater.httpHeaders = headers
            hasGitHubUpdateToken = token != nil
            githubUpdateTokenError = nil
        } catch {
            updater.httpHeaders = ["Accept": "application/vnd.github.raw+json"]
            hasGitHubUpdateToken = false
            githubUpdateTokenError = error.localizedDescription
        }
    }

    /// Configures the internal observers for the manager.
    private func configureCancellables() {
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
        updater.publisher(for: \.lastUpdateCheckDate)
            .assign(to: &$lastUpdateCheckDate)
    }

    /// Checks for app updates.
    @objc func checkForUpdates() {
        #if DEBUG
        // Checking for updates hangs in debug mode.
        let alert = NSAlert()
        alert.messageText = "Checking for updates is not supported in debug mode."
        alert.runModal()
        #else
        guard let appState else {
            return
        }
        // Activate the app in case an alert needs to be displayed.
        appState.activate(withPolicy: .regular)
        appState.openSettingsWindow()
        updater.checkForUpdates()
        #endif
    }
}

// MARK: UpdatesManager: SPUUpdaterDelegate
extension UpdatesManager: @preconcurrency SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater, willScheduleUpdateCheckAfterDelay delay: TimeInterval) {
        guard let appState else {
            return
        }
        appState.userNotificationManager.requestAuthorization()
    }

    func updater(
        _ updater: SPUUpdater,
        willDownloadUpdate item: SUAppcastItem,
        with request: NSMutableURLRequest
    ) {
        guard let url = request.url,
              url.scheme == "https",
              url.host == "api.github.com",
              url.path.hasPrefix("/repos/thunder951413/ice/releases/assets/")
        else {
            request.setValue(nil, forHTTPHeaderField: "Authorization")
            return
        }

        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        do {
            if let token = try GitHubUpdateCredentials.loadToken() {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            } else {
                request.setValue(nil, forHTTPHeaderField: "Authorization")
            }
        } catch {
            request.setValue(nil, forHTTPHeaderField: "Authorization")
            githubUpdateTokenError = error.localizedDescription
        }
    }
}

// MARK: UpdatesManager: SPUStandardUserDriverDelegate
extension UpdatesManager: @preconcurrency SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        if NSApp.isActive {
            return immediateFocus
        } else {
            return false
        }
    }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        guard let appState else {
            return
        }
        if !state.userInitiated {
            appState.userNotificationManager.addRequest(
                with: .updateCheck,
                title: "A new update is available",
                body: "Version \(update.displayVersionString) is now available"
            )
        }
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        guard let appState else {
            return
        }
        appState.userNotificationManager.removeDeliveredNotifications(with: [.updateCheck])
    }
}

// MARK: UpdatesManager: BindingExposable
extension UpdatesManager: BindingExposable { }
