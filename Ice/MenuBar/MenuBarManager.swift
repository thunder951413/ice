//
//  MenuBarManager.swift
//  Ice
//

import AXSwift
import Combine
import SwiftUI

/// Manager for the state of the menu bar.
@MainActor
final class MenuBarManager: ObservableObject {
    /// A Boolean value that indicates whether the menu bar is either always hidden
    /// by the system, or automatically hidden and shown by the system based on the
    /// location of the mouse.
    @Published private(set) var isMenuBarHiddenBySystem = false

    /// A Boolean value that indicates whether the menu bar is hidden by the system
    /// according to a value stored in UserDefaults.
    @Published private(set) var isMenuBarHiddenBySystemUserDefaults = false

    /// Session-only pause: assignments and spacing remain untouched.
    @Published private(set) var isHidingPaused = false

    /// The shared app state.
    private weak var appState: AppState?

    /// Storage for internal observers.
    private var cancellables = Set<AnyCancellable>()

    /// The managed sections in the menu bar.
    private(set) var sections = [MenuBarSection]()

    /// The panel that contains the Ice Bar interface.
    let iceBarPanel: IceBarPanel

    /// Native visibility backend for status items hosted by MenuBarAgent.
    let hostedItemVisibilityManager: HostedItemVisibilityManager

    /// Initializes a new menu bar manager instance.
    init(appState: AppState) {
        self.iceBarPanel = IceBarPanel(appState: appState)
        self.hostedItemVisibilityManager = HostedItemVisibilityManager(appState: appState)
        self.appState = appState
    }

    /// Performs the initial setup of the menu bar manager.
    func performSetup() {
        refreshSystemMenuBarHiddenDefaults()
        initializeSections()
        configureCancellables()
        iceBarPanel.performSetup()
        hostedItemVisibilityManager.performSetup()
    }

    private func refreshSystemMenuBarHiddenDefaults() {
        let isHidden = (Defaults.globalDomain["_HIHideMenuBar"] as? Bool) ?? false
        if isMenuBarHiddenBySystemUserDefaults != isHidden {
            isMenuBarHiddenBySystemUserDefaults = isHidden
        }
    }

    /// Performs the initial setup of the menu bar manager's sections.
    private func initializeSections() {
        guard sections.isEmpty else {
            Logger.menuBarManager.warning("Sections already initialized")
            return
        }
        guard let appState else {
            Logger.menuBarManager.error("Error initializing menu bar sections: Missing app state")
            return
        }
        sections = [
            MenuBarSection(name: .visible, appState: appState),
            MenuBarSection(name: .hidden, appState: appState),
            MenuBarSection(name: .alwaysHidden, appState: appState),
        ]
    }

    /// Configures the internal observers for the manager.
    private func configureCancellables() {
        var c = Set<AnyCancellable>()

        NSApp.publisher(for: \.currentSystemPresentationOptions)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] options in
                guard let self else {
                    return
                }
                let hidden = options.contains(.hideMenuBar) || options.contains(.autoHideMenuBar)
                isMenuBarHiddenBySystem = hidden
                refreshSystemMenuBarHiddenDefaults()
            }
            .store(in: &c)

        Publishers.Merge(
            NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification),
            NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.activeSpaceDidChangeNotification)
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in
            self?.refreshSystemMenuBarHiddenDefaults()
        }
        .store(in: &c)

        if
            let visibleSection = section(withName: .visible),
            let window = visibleSection.controlItem.window
        {
            window.publisher(for: \.frame)
                .map { $0.origin.y }
                .removeDuplicates()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    self?.refreshSystemMenuBarHiddenDefaults()
                }
                .store(in: &c)
        }

        // Handle the `focusedApp` rehide strategy.
        NSWorkspace.shared.publisher(for: \.frontmostApplication)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                if
                    let self,
                    let appState,
                    appState.settingsManager.generalSettingsManager.autoRehide,
                    case .focusedApp = appState.settingsManager.generalSettingsManager.rehideStrategy,
                    sections.contains(where: { !$0.isHidden }),
                    !appState.eventManager.isMouseInsideMenuBar,
                    !appState.eventManager.isMouseInsideIceBar
                {
                    Task { @MainActor [weak self] in
                        do { try await Task.sleep(for: .seconds(0.1)) } catch { return }
                        guard
                            let self,
                            let appState = self.appState,
                            appState.settingsManager.generalSettingsManager.autoRehide,
                            !appState.eventManager.isMouseInsideMenuBar,
                            !appState.eventManager.isMouseInsideIceBar
                        else {
                            return
                        }
                        self.iceBarPanel.close()
                    }
                }
            }
            .store(in: &c)

        cancellables = c
    }

    private struct ApplicationMenuFrameKey: Hashable {
        let ownerPID: pid_t
        let displayID: CGDirectDisplayID
    }

    /// Short-lived cache of application menu frames.
    private var applicationMenuFrameCache = [ApplicationMenuFrameKey: (date: ContinuousClock.Instant, frame: CGRect?)]()

    /// Default freshness for ``getApplicationMenuFrame(for:maxAge:)``.
    nonisolated static let applicationMenuFrameCacheLifetime: Duration = .milliseconds(500)

    /// Returns the frame of the application menu for the given display.
    func getApplicationMenuFrame(
        for displayID: CGDirectDisplayID,
        maxAge: Duration = MenuBarManager.applicationMenuFrameCacheLifetime
    ) -> CGRect? {
        let key = ApplicationMenuFrameKey(
            ownerPID: NSWorkspace.shared.menuBarOwningApplication?.processIdentifier ?? 0,
            displayID: displayID
        )
        let now = ContinuousClock.now
        if maxAge > .zero, let cached = applicationMenuFrameCache[key], cached.date.duration(to: now) < maxAge {
            return cached.frame
        }
        let frame = readApplicationMenuFrame(for: displayID)
        if applicationMenuFrameCache.count > 16 {
            applicationMenuFrameCache.removeAll()
        }
        applicationMenuFrameCache[key] = (now, frame)
        return frame
    }

    private func readApplicationMenuFrame(for displayID: CGDirectDisplayID) -> CGRect? {
        let displayBounds = CGDisplayBounds(displayID)

        if let owner = NSWorkspace.shared.menuBarOwningApplication,
           let application = Application(forProcessID: owner.processIdentifier) {
            application.messagingTimeout = 0.05
            if let menuBar: UIElement = try? application.attribute(.menuBar),
               let frame = applicationMenuFrame(from: menuBar, displayBounds: displayBounds) {
                return frame
            }
        }

        guard
            let menuBar = try? systemWideElement.elementAtPosition(Float(displayBounds.minX + 1), Float(displayBounds.minY + 12)),
            let role = try? menuBar.role(),
            role == .menuBar
        else {
            return nil
        }
        return applicationMenuFrame(from: menuBar, displayBounds: displayBounds)
    }

    private func applicationMenuFrame(from menuBar: UIElement, displayBounds: CGRect) -> CGRect? {
        menuBar.messagingTimeout = 0.05
        guard let items: [UIElement] = try? menuBar.arrayAttribute(.children), !items.isEmpty else {
            return nil
        }
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(200))
        var frames = [CGRect]()
        for item in items {
            guard ContinuousClock.now < deadline else {
                return nil
            }
            item.messagingTimeout = 0.05
            guard let frame: CGRect = try? item.attribute(.frame) else {
                return nil
            }
            frames.append(frame)
        }
        return ApplicationMenuGeometry.frame(itemFrames: frames, displayBounds: displayBounds)
    }

    func pauseHiding() {
        guard !isHidingPaused else {
            return
        }
        isHidingPaused = true
        iceBarPanel.close()
        hostedItemVisibilityManager.restoreAll()
    }

    func resumeHiding() {
        guard isHidingPaused else {
            return
        }
        isHidingPaused = false
        hostedItemVisibilityManager.refreshNow()
    }

    func toggleHidingPaused() {
        if isHidingPaused {
            resumeHiding()
        } else {
            pauseHiding()
        }
    }

    /// Resets Ice's runtime menu bar modifications so that every managed item becomes visible again.
    func resetModifications() {
        Logger.menuBarManager.info("Resetting Ice menu bar modifications")
        isHidingPaused = false
        iceBarPanel.close()
        guard let appState else {
            return
        }
        let knownPIDs = Set(appState.itemManager.itemCache.allItems.map(\.ownerPID))
        appState.itemManager.resetHostedSectionAssignments()
        hostedItemVisibilityManager.restoreAll()
        if appState.settingsManager.generalSettingsManager.itemSpacingOffset != 0 {
            appState.settingsManager.generalSettingsManager.itemSpacingOffset = 0
            Task {
                do {
                    try await appState.spacingManager.applyOffset(additionalPIDs: knownPIDs)
                } catch {
                    Logger.menuBarManager.error("Error resetting item spacing: \(error)")
                    NSAlert(error: error).runModal()
                }
            }
        }
    }

    /// Shows the right-click menu when clicking empty space in the menu bar.
    func showRightClickMenu(at point: CGPoint) {
        let menu = NSMenu(title: "Ice")

        if let hiddenSection = section(withName: .hidden) {
            let toggleHiddenItem = NSMenuItem(
                title: hiddenSection.isHidden ? "展开隐藏图标" : "收起隐藏图标",
                action: #selector(toggleHiddenSectionAction),
                keyEquivalent: ""
            )
            toggleHiddenItem.target = self
            menu.addItem(toggleHiddenItem)
        }

        if let alwaysHiddenSection = section(withName: .alwaysHidden), alwaysHiddenSection.isEnabled {
            let toggleAlwaysItem = NSMenuItem(
                title: alwaysHiddenSection.isHidden ? "展开始终隐藏图标" : "收起始终隐藏图标",
                action: #selector(toggleAlwaysHiddenSectionAction),
                keyEquivalent: ""
            )
            toggleAlwaysItem.target = self
            menu.addItem(toggleAlwaysItem)
        }

        let pauseItem = NSMenuItem(
            title: isHidingPaused ? "恢复隐藏菜单栏图标" : "暂停隐藏菜单栏图标",
            action: #selector(togglePauseAction),
            keyEquivalent: ""
        )
        pauseItem.target = self
        menu.addItem(pauseItem)

        menu.addItem(.separator())

        let layoutItem = NSMenuItem(
            title: "图标管理…",
            action: #selector(openLayoutSettingsAction),
            keyEquivalent: ""
        )
        layoutItem.target = self
        menu.addItem(layoutItem)

        let settingsItem = NSMenuItem(
            title: "Ice 设置…",
            action: #selector(AppDelegate.openSettingsWindow),
            keyEquivalent: ","
        )
        settingsItem.keyEquivalentModifierMask = .command
        menu.addItem(settingsItem)

        menu.popUp(positioning: nil, at: point, in: nil)
    }

    @objc private func toggleHiddenSectionAction() {
        section(withName: .hidden)?.toggle()
    }

    @objc private func toggleAlwaysHiddenSectionAction() {
        section(withName: .alwaysHidden)?.toggle()
    }

    @objc private func togglePauseAction() {
        toggleHidingPaused()
    }

    @objc private func openLayoutSettingsAction() {
        guard let appState else {
            return
        }
        appState.navigationState.settingsNavigationIdentifier = .menuBarLayout
        appState.appDelegate?.openSettingsWindow()
    }

    /// Returns the menu bar section with the given name.
    func section(withName name: MenuBarSection.Name) -> MenuBarSection? {
        sections.first { $0.name == name }
    }
}

// MARK: MenuBarManager: BindingExposable
extension MenuBarManager: BindingExposable { }

// MARK: - Logger
private extension Logger {
    static let menuBarManager = Logger(category: "MenuBarManager")
}
