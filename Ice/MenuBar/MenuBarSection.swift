//
//  MenuBarSection.swift
//  Ice
//

import Cocoa

/// A representation of a section in a menu bar.
@MainActor
final class MenuBarSection {
    /// The name of a menu bar section.
    enum Name: CaseIterable {
        case visible
        case hidden
        case alwaysHidden

        /// Localized title shown in the user interface.
        var displayString: String {
            switch self {
            case .visible: "常驻显示"
            case .hidden: "隐藏"
            case .alwaysHidden: "始终隐藏"
            }
        }

        /// Subtitle explaining the section's behavior.
        var subtitle: String {
            switch self {
            case .visible: "始终直接显示在系统菜单栏中"
            case .hidden: "平时从菜单栏隐藏，点击 Ice 图标或菜单栏空白处通过 Ice Bar 查看"
            case .alwaysHidden: "深层收纳极少使用的图标，按住 Option 点击或通过右键菜单打开"
            }
        }

        /// A string to use for logging purposes.
        var logString: String {
            switch self {
            case .visible: "visible section"
            case .hidden: "hidden section"
            case .alwaysHidden: "always-hidden section"
            }
        }

        /// The canonical string used to persist hosted section assignments.
        var persistenceString: String {
            switch self {
            case .visible: "visible"
            case .hidden: "hidden"
            case .alwaysHidden: "alwaysHidden"
            }
        }

        /// Creates a name from its persisted string representation.
        init?(persistenceString: String) {
            switch persistenceString {
            case "visible": self = .visible
            case "hidden": self = .hidden
            case "alwaysHidden": self = .alwaysHidden
            default: return nil
            }
        }
    }

    /// The name of the section.
    let name: Name

    /// The control item that manages the section.
    let controlItem: ControlItem

    /// The shared app state.
    private weak var appState: AppState?

    /// A timer that manages rehiding the section.
    private var rehideTimer: Timer?

    /// An event monitor that handles starting the rehide timer when the mouse is outside the bar.
    private var rehideMonitor: UniversalEventMonitor?

    /// A weak reference to the menu bar manager's Ice Bar panel.
    private weak var iceBarPanel: IceBarPanel? {
        appState?.menuBarManager.iceBarPanel
    }

    /// A Boolean value that indicates whether the section's Ice Bar presentation is currently closed.
    var isHidden: Bool {
        switch name {
        case .visible, .hidden:
            return iceBarPanel?.currentSection != .hidden
        case .alwaysHidden:
            return iceBarPanel?.currentSection != .alwaysHidden
        }
    }

    /// A Boolean value that indicates whether the section is enabled.
    var isEnabled: Bool {
        switch name {
        case .visible, .hidden:
            return true
        case .alwaysHidden:
            return appState?.settingsManager.generalSettingsManager.enableAlwaysHiddenSection == true
        }
    }

    /// Creates a section with the given name, control item, and app state.
    init(name: Name, controlItem: ControlItem, appState: AppState) {
        self.name = name
        self.controlItem = controlItem
        self.appState = appState
        controlItem.attach(to: self)
    }

    /// Creates a section with the given name and app state.
    convenience init(name: Name, appState: AppState) {
        let controlItem = switch name {
        case .visible:
            ControlItem(identifier: .iceIcon, appState: appState)
        case .hidden:
            ControlItem(identifier: .hidden, appState: appState)
        case .alwaysHidden:
            ControlItem(identifier: .alwaysHidden, appState: appState)
        }
        self.init(name: name, controlItem: controlItem, appState: appState)
    }

    /// Shows the section in the Ice Bar.
    func show(on screen: NSScreen? = nil, menuBarClickX: CGFloat? = nil) {
        guard isEnabled, isHidden, let screen = screen ?? NSScreen.screenWithMouse ?? NSScreen.main else {
            return
        }
        let targetSection: Name = name == .alwaysHidden ? .alwaysHidden : .hidden
        Logger.menuBarSection.info("Showing \(targetSection.logString) in Ice Bar")
        Task {
            await iceBarPanel?.show(section: targetSection, on: screen, menuBarClickX: menuBarClickX)
        }
        startRehideChecks()
    }

    /// Hides the section by closing the Ice Bar.
    func hide() {
        stopRehideChecks()
        guard !isHidden else {
            return
        }
        Logger.menuBarSection.info("Closing Ice Bar for \(name.logString)")
        iceBarPanel?.close()
    }

    /// Toggles the visibility of the section.
    func toggle(on screen: NSScreen? = nil, menuBarClickX: CGFloat? = nil) {
        if isHidden {
            show(on: screen, menuBarClickX: menuBarClickX)
        } else {
            hide()
        }
    }

    /// Starts running checks to determine when to rehide the section.
    private func startRehideChecks() {
        stopRehideChecks()

        guard
            let appState,
            appState.settingsManager.generalSettingsManager.autoRehide,
            case .timed = appState.settingsManager.generalSettingsManager.rehideStrategy
        else {
            return
        }

        let armTimerIfNeeded: @MainActor () -> Void = { [weak self] in
            guard
                let self,
                let appState = self.appState
            else {
                return
            }
            let isInside = Self.isMouseInsideMenuBar || appState.eventManager.isMouseInsideIceBar
            if !isInside {
                if self.rehideTimer == nil {
                    self.rehideTimer = .scheduledTimer(
                        withTimeInterval: appState.settingsManager.generalSettingsManager.rehideInterval,
                        repeats: false
                    ) { [weak self] _ in
                        Task { @MainActor [weak self] in
                            guard
                                let self,
                                let appState = self.appState
                            else {
                                return
                            }
                            self.rehideTimer = nil
                            let stillInside = Self.isMouseInsideMenuBar || appState.eventManager.isMouseInsideIceBar
                            if !stillInside {
                                self.hide()
                            } else {
                                self.startRehideChecks()
                            }
                        }
                    }
                }
            } else {
                self.rehideTimer?.invalidate()
                self.rehideTimer = nil
            }
        }

        armTimerIfNeeded()

        rehideMonitor = UniversalEventMonitor(mask: .mouseMoved) { event in
            armTimerIfNeeded()
            return event
        }

        rehideMonitor?.start()
    }

    /// Whether the pointer is in the menu bar of the screen it is on.
    private nonisolated static var isMouseInsideMenuBar: Bool {
        guard let screen = NSScreen.screenWithMouse ?? NSScreen.main else {
            return false
        }
        return screen.menuBarContains(NSEvent.mouseLocation)
    }

    /// Stops running checks to determine when to rehide the section.
    func stopRehideChecks() {
        rehideTimer?.invalidate()
        rehideMonitor?.stop()
        rehideTimer = nil
        rehideMonitor = nil
    }
}

// MARK: MenuBarSection: BindingExposable
extension MenuBarSection: BindingExposable { }

// MARK: - Logger
private extension Logger {
    static let menuBarSection = Logger(category: "MenuBarSection")
}
