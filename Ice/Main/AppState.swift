//
//  AppState.swift
//  Ice
//

import Combine
import SwiftUI

/// The model for app-wide state.
@MainActor
final class AppState: ObservableObject {
    /// A Boolean value that indicates whether the active space is fullscreen.
    @Published private(set) var isActiveSpaceFullscreen = Bridging.isSpaceFullscreen(Bridging.activeSpaceID)

    /// Manager for events received by the app.
    private(set) lazy var eventManager = EventManager(appState: self)

    /// Manager for menu bar items.
    private(set) lazy var itemManager = MenuBarItemManager(appState: self)

    /// Manager for the state of the menu bar.
    private(set) lazy var menuBarManager = MenuBarManager(appState: self)

    /// Manager for app permissions.
    private(set) lazy var permissionsManager = PermissionsManager(appState: self)

    /// Manager for the app's settings.
    private(set) lazy var settingsManager = SettingsManager(appState: self)

    /// Manager for app updates.
    private(set) lazy var updatesManager = UpdatesManager(appState: self)

    /// Manager for user notifications.
    private(set) lazy var userNotificationManager = UserNotificationManager(appState: self)

    /// Manager for menu bar item spacing.
    let spacingManager = MenuBarItemSpacingManager()

    /// Model for app-wide navigation.
    let navigationState = AppNavigationState()

    /// The app's delegate.
    private(set) weak var appDelegate: AppDelegate?

    /// The window that contains the settings interface.
    private(set) weak var settingsWindow: NSWindow?

    /// The window that contains the permissions interface.
    private(set) weak var permissionsWindow: NSWindow?

    /// Storage for internal observers.
    private var cancellables = Set<AnyCancellable>()

    /// Observation tied specifically to the lazily-created settings window.
    private var settingsWindowCancellable: AnyCancellable?

    /// Prevents managers from being configured more than once.
    private(set) var hasPerformedSetup = false

    /// A Boolean value that indicates whether the app is running as a SwiftUI preview.
    let isPreview: Bool = {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        return environment["XCODE_RUNNING_FOR_PREVIEWS"] != nil
        #else
        return false
        #endif
    }()

    var setsCursorInBackground: Bool {
        get { Bridging.getConnectionProperty(forKey: "SetsCursorInBackground") as? Bool ?? false }
        set { Bridging.setConnectionProperty(newValue, forKey: "SetsCursorInBackground") }
    }

    private func configureCancellables() {
        var c = Set<AnyCancellable>()

        Publishers.Merge3(
            NSWorkspace.shared.notificationCenter
                .publisher(for: NSWorkspace.activeSpaceDidChangeNotification)
                .mapToVoid(),
            NSWorkspace.shared
                .publisher(for: \.frontmostApplication)
                .mapToVoid(),
            UniversalEventMonitor
                .publisher(for: .leftMouseDown)
                .delay(for: 0.1, scheduler: DispatchQueue.main)
                .mapToVoid()
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in
            guard let self else {
                return
            }
            let isFullscreen = Bridging.isSpaceFullscreen(Bridging.activeSpaceID)
            if isActiveSpaceFullscreen != isFullscreen {
                isActiveSpaceFullscreen = isFullscreen
            }
        }
        .store(in: &c)

        NSWorkspace.shared.publisher(for: \.frontmostApplication)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] frontmostApplication in
                guard let self else {
                    return
                }
                navigationState.isAppFrontmost = frontmostApplication == .current
            }
            .store(in: &c)

        menuBarManager.objectWillChange
            .sink { [weak self] in
                self?.objectWillChange.send()
            }
            .store(in: &c)
        permissionsManager.objectWillChange
            .sink { [weak self] in
                self?.objectWillChange.send()
            }
            .store(in: &c)
        settingsManager.objectWillChange
            .sink { [weak self] in
                self?.objectWillChange.send()
            }
            .store(in: &c)
        updatesManager.objectWillChange
            .sink { [weak self] in
                self?.objectWillChange.send()
            }
            .store(in: &c)

        cancellables = c
    }

    func performSetup() {
        guard !hasPerformedSetup else {
            return
        }
        hasPerformedSetup = true
        configureCancellables()
        permissionsManager.stopAllChecks()
        settingsManager.performSetup()
        menuBarManager.performSetup()
        eventManager.performSetup()
        itemManager.performSetup()
        updatesManager.performSetup()
        userNotificationManager.performSetup()
    }

    func assignAppDelegate(_ appDelegate: AppDelegate) {
        guard self.appDelegate == nil else {
            Logger.appState.warning("Multiple attempts made to assign app delegate")
            return
        }
        self.appDelegate = appDelegate
    }

    func assignSettingsWindow(_ window: NSWindow) {
        guard window.identifier?.rawValue == Constants.settingsWindowID else {
            Logger.appState.warning("Window \(window.identifier?.rawValue ?? "<NIL>") is not the settings window!")
            return
        }
        settingsWindow = window
        settingsWindowCancellable = window.publisher(for: \.isVisible)
            .debounce(for: 0.05, scheduler: DispatchQueue.main)
            .sink { [weak self] isVisible in
                self?.navigationState.isSettingsPresented = isVisible
            }
    }

    func assignPermissionsWindow(_ window: NSWindow) {
        guard window.identifier?.rawValue == Constants.permissionsWindowID else {
            Logger.appState.warning("Window \(window.identifier?.rawValue ?? "<NIL>") is not the permissions window!")
            return
        }
        permissionsWindow = window
    }

    func openSettingsWindow() {
        with(EnvironmentValues()) { environment in
            environment.openWindow(id: Constants.settingsWindowID)
        }
    }

    func dismissSettingsWindow() {
        with(EnvironmentValues()) { environment in
            environment.dismissWindow(id: Constants.settingsWindowID)
        }
    }

    func openPermissionsWindow() {
        with(EnvironmentValues()) { environment in
            environment.openWindow(id: Constants.permissionsWindowID)
        }
    }

    func dismissPermissionsWindow() {
        with(EnvironmentValues()) { environment in
            environment.dismissWindow(id: Constants.permissionsWindowID)
        }
    }

    func activate(withPolicy policy: NSApplication.ActivationPolicy) {
        enum Context {
            static let hasActivated = ObjectStorage<Bool>()
        }

        func activate() {
            if let frontApp = NSWorkspace.shared.frontmostApplication {
                NSRunningApplication.current.activate(from: frontApp)
            } else {
                NSApp.activate()
            }
            NSApp.setActivationPolicy(policy)
        }

        if Context.hasActivated.value(for: self) == true {
            activate()
        } else {
            Context.hasActivated.set(true, for: self)
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.activate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                activate()
            }
        }
    }
}

// MARK: AppState: BindingExposable
extension AppState: BindingExposable { }

// MARK: - Logger
private extension Logger {
    static let appState = Logger(category: "AppState")
}
