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
    /// Information for the menu bar's average color.
    @Published private(set) var averageColorInfo: MenuBarAverageColorInfo?

    /// A Boolean value that indicates whether the menu bar is either always hidden
    /// by the system, or automatically hidden and shown by the system based on the
    /// location of the mouse.
    @Published private(set) var isMenuBarHiddenBySystem = false

    /// A Boolean value that indicates whether the menu bar is hidden by the system
    /// according to a value stored in UserDefaults.
    @Published private(set) var isMenuBarHiddenBySystemUserDefaults = false

    /// The shared app state.
    private weak var appState: AppState?

    /// Storage for internal observers.
    private var cancellables = Set<AnyCancellable>()

    /// A Boolean value that indicates whether the application menus are hidden.
    private var isHidingApplicationMenus = false

    /// Session-only pause: assignments, ordering and spacing remain untouched.
    @Published private(set) var isHidingPaused = false
    private var statesBeforePause = [MenuBarSection.Name: ControlItem.HidingState]()

    /// The managed sections in the menu bar.
    private(set) var sections = [MenuBarSection]()

    /// The panel that contains the Ice Bar interface.
    let iceBarPanel: IceBarPanel

    /// The panel that contains the menu bar search interface.
    let searchPanel: MenuBarSearchPanel

    /// Native visibility backend for status items hosted by MenuBarAgent.
    let hostedItemVisibilityManager: HostedItemVisibilityManager

    /// A Boolean value that indicates whether the manager can update its stored
    /// information for the menu bar's average color.
    private var canUpdateAverageColorInfo: Bool {
        appState?.settingsWindow?.isVisible == true
    }

    /// Initializes a new menu bar manager instance.
    init(appState: AppState) {
        self.iceBarPanel = IceBarPanel(appState: appState)
        self.searchPanel = MenuBarSearchPanel(appState: appState)
        self.hostedItemVisibilityManager = HostedItemVisibilityManager(appState: appState)
        self.appState = appState
    }

    /// Performs the initial setup of the menu bar manager.
    func performSetup() {
        initializeSections()
        configureCancellables()
        iceBarPanel.performSetup()
        hostedItemVisibilityManager.performSetup()
    }

    /// Performs the initial setup of the menu bar manager's sections.
    private func initializeSections() {
        // Make sure initialization can only happen once.
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
            }
            .store(in: &c)

        if
            let hiddenSection = section(withName: .alwaysHidden),
            let window = hiddenSection.controlItem.window
        {
            window.publisher(for: \.frame)
                .map { $0.origin.y }
                .removeDuplicates()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    guard
                        let self,
                        let isMenuBarHidden = Defaults.globalDomain["_HIHideMenuBar"] as? Bool
                    else {
                        return
                    }
                    isMenuBarHiddenBySystemUserDefaults = isMenuBarHidden
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
                    case .focusedApp = appState.settingsManager.generalSettingsManager.rehideStrategy,
                    let hiddenSection = section(withName: .hidden),
                    !appState.eventManager.isMouseInsideMenuBar
                {
                    Task {
                        try await Task.sleep(for: .seconds(0.1))
                        hiddenSection.hide()
                    }
                }
            }
            .store(in: &c)

        appState?.settingsWindow?.publisher(for: \.isVisible)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateAverageColorInfo()
            }
            .store(in: &c)

        Timer.publish(every: 5, on: .main, in: .default)
            .autoconnect()
            .sink { [weak self] _ in
                self?.updateAverageColorInfo()
            }
            .store(in: &c)

        // Hide application menus when a section is shown (if applicable).
        Publishers.MergeMany(sections.map { $0.controlItem.$state })
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard
                    let self,
                    let appState
                else {
                    return
                }

                // Don't continue if:
                //   * The "HideApplicationMenus" setting isn't enabled.
                //   * The menu bar is hidden by the system.
                //   * The active space is fullscreen.
                //   * The settings window is visible.
                guard
                    appState.settingsManager.advancedSettingsManager.hideApplicationMenus,
                    !isMenuBarHiddenBySystem,
                    !appState.isActiveSpaceFullscreen,
                    appState.settingsWindow?.isVisible == false
                else {
                    return
                }

                if sections.contains(where: { $0.controlItem.state == .showItems }) {
                    guard let screen = NSScreen.main else {
                        return
                    }

                    let displayID = screen.displayID

                    // Get the application menu frame for the display.
                    guard let applicationMenuFrame = getApplicationMenuFrame(for: displayID) else {
                        return
                    }

                    // Get all items.
                    var items = MenuBarItem.getMenuBarItems(on: displayID, onScreenOnly: false, activeSpaceOnly: true)

                    // Filter the items down according to the currently enabled/shown sections.
                    if
                        let alwaysHiddenSection = section(withName: .alwaysHidden),
                        alwaysHiddenSection.isEnabled
                    {
                        if alwaysHiddenSection.controlItem.state == .hideItems {
                            if let alwaysHiddenControlItem = items.firstIndex(matching: .alwaysHiddenControlItem).map({ items.remove(at: $0) }) {
                                items.trimPrefix { $0.frame.maxX <= alwaysHiddenControlItem.frame.minX }
                            }
                        }
                    } else {
                        if let hiddenControlItem = items.firstIndex(matching: .hiddenControlItem).map({ items.remove(at: $0) }) {
                            items.trimPrefix { $0.frame.maxX <= hiddenControlItem.frame.minX }
                        }
                    }

                    // Get the leftmost item on the screen.
                    guard let leftmostItem = items.min(by: { $0.frame.minX < $1.frame.minX }) else {
                        return
                    }

                    // If the minX of the item is less than or equal to the maxX of the
                    // application menu frame, activate the app to hide the menu.
                    if leftmostItem.frame.minX <= applicationMenuFrame.maxX {
                        hideApplicationMenus()
                    }
                } else if isHidingApplicationMenus {
                    showApplicationMenus()
                }
            }
            .store(in: &c)

        cancellables = c
    }

    /// Updates the ``averageColorInfo`` property with the current average color
    /// of the menu bar.
    func updateAverageColorInfo() {
        guard
            canUpdateAverageColorInfo,
            let screen = appState?.settingsWindow?.screen
        else {
            return
        }

        let image: CGImage?
        let source: MenuBarAverageColorInfo.Source

        let windows = WindowInfo.getOnScreenWindows(excludeDesktopWindows: false)
        let displayID = screen.displayID

        if let window = WindowInfo.getMenuBarWindow(from: windows, for: displayID) {
            var bounds = window.frame
            bounds.size.height = 1
            bounds.origin.x = bounds.maxX - (bounds.width / 4)
            bounds.size.width /= 4

            image = ScreenCapture.captureWindow(window.windowID, screenBounds: bounds, option: .nominalResolution)
            source = .menuBarWindow
        } else if let window = WindowInfo.getWallpaperWindow(from: windows, for: displayID) {
            var bounds = window.frame
            bounds.size.height = 1
            bounds.origin.x = bounds.midX
            bounds.size.width /= 2

            image = ScreenCapture.captureWindow(window.windowID, screenBounds: bounds, option: .nominalResolution)
            source = .desktopWallpaper
        } else {
            return
        }

        guard
            let image,
            let color = image.averageColor(makeOpaque: true)
        else {
            return
        }

        let info = MenuBarAverageColorInfo(color: color, source: source)

        if averageColorInfo != info {
            averageColorInfo = info
        }
    }

    /// Returns a Boolean value that indicates whether the given display
    /// has a valid menu bar.
    func hasValidMenuBar(in windows: [WindowInfo], for display: CGDirectDisplayID) -> Bool {
        guard let menuBarWindow = WindowInfo.getMenuBarWindow(from: windows, for: display) else {
            return false
        }
        let position = menuBarWindow.frame.origin
        do {
            let uiElement = try systemWideElement.elementAtPosition(Float(position.x), Float(position.y))
            return try uiElement?.role() == .menuBar
        } catch {
            return false
        }
    }

    /// Returns the frame of the application menu for the given display.
    func getApplicationMenuFrame(for displayID: CGDirectDisplayID) -> CGRect? {
        let displayBounds = CGDisplayBounds(displayID)

        // On hosted menu bars, hit-testing the exact display corner can return
        // MenuBarAgent's window instead of AXMenuBar. Ask the app that owns the
        // visible application menu, including disabled menu titles.
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
        guard let items: [UIElement] = try? menuBar.arrayAttribute(.children), !items.isEmpty else { return nil }
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(200))
        var frames = [CGRect]()
        for item in items {
            guard ContinuousClock.now < deadline else { return nil }
            item.messagingTimeout = 0.05
            // A partial result could omit File/Edit or the last menu title.
            // Fail closed instead of shortening the protected menu region.
            guard let frame: CGRect = try? item.attribute(.frame) else { return nil }
            frames.append(frame)
        }
        return ApplicationMenuGeometry.frame(itemFrames: frames, displayBounds: displayBounds)
    }

    /// Reveals every menu bar item that Ice is currently hiding.
    ///
    /// Ice hides items by moving its control-item dividers so the real items
    /// end up in a hidden or always-hidden region of the menu bar. When items
    /// get stranded there (and stay hidden across relaunches), forcing every
    /// control item into the ``ControlItem/State/showItems`` state pushes all of
    /// them back into view without requiring a synthetic drag.
    func showAllSections() {
        Logger.menuBarManager.info("Showing all sections to reveal hidden items")
        iceBarPanel.close()
        for section in sections {
            section.controlItem.state = .showItems
        }
    }

    func pauseHiding() {
        guard !isHidingPaused else { return }
        statesBeforePause = Dictionary(uniqueKeysWithValues: sections.map { ($0.name, $0.controlItem.state) })
        isHidingPaused = true
        hostedItemVisibilityManager.restoreAll()
        showAllSections()
    }

    func resumeHiding() {
        guard isHidingPaused else { return }
        isHidingPaused = false
        for section in sections {
            section.controlItem.state = statesBeforePause[section.name] ?? .hideItems
        }
        statesBeforePause.removeAll()
        hostedItemVisibilityManager.refreshNow()
    }

    func toggleHidingPaused() {
        if isHidingPaused { resumeHiding() } else { pauseHiding() }
    }

    /// Resets Ice's runtime menu bar modifications so that every managed item
    /// becomes visible again.
    ///
    /// This reveals all sections and restores the menu bar item spacing to the
    /// system default (a negative spacing offset can make items overlap and
    /// appear invisible). It does not touch the user's other preferences.
    func resetModifications() {
        Logger.menuBarManager.info("Resetting Ice menu bar modifications")
        isHidingPaused = false
        statesBeforePause.removeAll()
        showAllSections()
        guard let appState else {
            return
        }
        appState.itemManager.resetHostedSectionAssignments()
        hostedItemVisibilityManager.restoreAll()
        if appState.settingsManager.generalSettingsManager.itemSpacingOffset != 0 {
            appState.settingsManager.generalSettingsManager.itemSpacingOffset = 0
            Task {
                do {
                    try await appState.spacingManager.applyOffset()
                } catch {
                    Logger.menuBarManager.error("Error resetting item spacing: \(error)")
                }
            }
        }
    }


    /// Shows the right-click menu.
    func showRightClickMenu(at point: CGPoint) {
        let menu = NSMenu(title: "Ice")

        let editItem = NSMenuItem(
            title: "Edit Menu Bar Appearance…",
            action: #selector(showAppearanceEditorPopover),
            keyEquivalent: ""
        )
        editItem.target = self
        menu.addItem(editItem)

        let showAllItem = NSMenuItem(
            title: isHidingPaused ? "Resume Hiding" : "Pause Hiding",
            action: #selector(showAllSectionsAction),
            keyEquivalent: ""
        )
        showAllItem.target = self
        menu.addItem(showAllItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(
            title: "Ice Settings…",
            action: #selector(AppDelegate.openSettingsWindow),
            keyEquivalent: ","
        )
        menu.addItem(settingsItem)

        menu.popUp(positioning: nil, at: point, in: nil)
    }

    /// Hides the application menus.
    func hideApplicationMenus() {
        guard let appState else {
            Logger.menuBarManager.error("Error hiding application menus: Missing app state")
            return
        }
        Logger.menuBarManager.info("Hiding application menus")
        appState.activate(withPolicy: .regular)
        isHidingApplicationMenus = true
    }

    /// Shows the application menus.
    func showApplicationMenus() {
        guard let appState else {
            Logger.menuBarManager.error("Error showing application menus: Missing app state")
            return
        }
        Logger.menuBarManager.info("Showing application menus")
        appState.deactivate(withPolicy: .accessory)
        isHidingApplicationMenus = false
    }

    /// Toggles the visibility of the application menus.
    func toggleApplicationMenus() {
        if isHidingApplicationMenus {
            showApplicationMenus()
        } else {
            hideApplicationMenus()
        }
    }

    /// Reveals all hidden items. Wraps ``showAllSections()`` for use as a menu
    /// item action.
    @objc private func showAllSectionsAction() {
        toggleHidingPaused()
    }

    /// Shows the appearance editor popover, centered under the menu bar.
    @objc private func showAppearanceEditorPopover() {
        guard let appState else {
            Logger.menuBarManager.error("Error showing appearance editor popover: Missing app state")
            return
        }
        let panel = MenuBarAppearanceEditorPanel(appState: appState)
        panel.orderFrontRegardless()
        panel.showAppearanceEditorPopover()
    }

    /// Returns the menu bar section with the given name.
    func section(withName name: MenuBarSection.Name) -> MenuBarSection? {
        sections.first { $0.name == name }
    }
}

// MARK: MenuBarManager: BindingExposable
extension MenuBarManager: BindingExposable { }

// MARK: - MenuBarAverageColorInfo

/// Information for the menu bar's average color.
struct MenuBarAverageColorInfo: Hashable {
    enum Source: Hashable {
        case menuBarWindow
        case desktopWallpaper
    }

    var color: CGColor
    var source: Source
}

// MARK: - Logger
private extension Logger {
    /// Logger to use for the menu bar manager.
    static let menuBarManager = Logger(category: "MenuBarManager")
}
