//
//  ControlItem.swift
//  Ice
//

import Cocoa
import Combine

/// A status item that controls Ice's menu bar entry point and logical sections.
@MainActor
final class ControlItem {
    /// Possible identifiers for control items.
    enum Identifier: String, CaseIterable {
        case iceIcon = "SItem"
        case hidden = "HItem"
        case alwaysHidden = "AHItem"
    }

    /// Possible hiding states for control items.
    enum HidingState {
        case hideItems
        case showItems
    }

    /// The control item's hiding state (`@Published`).
    @Published var state = HidingState.hideItems

    /// A Boolean value that indicates whether the control item is visible (`@Published`).
    @Published var isVisible = true

    /// The frame of the control item's window (`@Published`).
    @Published private(set) var windowFrame: CGRect?

    /// The shared app state.
    private weak var appState: AppState?

    /// The control item's underlying status item.
    private let statusItem: NSStatusItem

    /// The control item's identifier.
    private let identifier: Identifier

    /// Logical hidden sections do not register extra system status items in the shared hosted scene.
    private let isVirtualSection: Bool

    /// Storage for internal observers.
    private var cancellables = Set<AnyCancellable>()

    /// Global monitor used when MenuBarAgent does not forward hosted status item mouse events.
    private var hostedClickMonitor: Any?

    /// The last routed click, used to coalesce button and hosted monitor callbacks.
    private var lastClickDate = Date.distantPast

    /// The menu bar section associated with the control item.
    private weak var section: MenuBarSection?

    /// The control item's window.
    var window: NSWindow? {
        statusItem.button?.window
    }

    /// A Boolean value that indicates whether the control item is currently active.
    var isAddedToMenuBar: Bool {
        if isVirtualSection {
            return identifier != .alwaysHidden
                || appState?.settingsManager.generalSettingsManager.enableAlwaysHiddenSection == true
        }
        return statusItem.isVisible
    }

    /// Creates a control item with the given identifier and app state.
    init(identifier: Identifier, appState: AppState) {
        let isVirtualSection = identifier != .iceIcon
        let autosaveName = identifier.rawValue

        if identifier == .iceIcon, StatusItemDefaults[.preferredPosition, autosaveName] == nil {
            StatusItemDefaults[.preferredPosition, autosaveName] = 193
        }

        self.statusItem = isVirtualSection
            ? NSStatusItem()
            : NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if !isVirtualSection {
            self.statusItem.autosaveName = autosaveName
        }
        self.identifier = identifier
        self.isVirtualSection = isVirtualSection
        self.appState = appState

        configureStatusItem()
    }

    /// Removes the status item without clearing its stored position.
    deinit {
        if let hostedClickMonitor {
            NSEvent.removeMonitor(hostedClickMonitor)
        }
        guard !isVirtualSection else {
            return
        }
        let autosaveName = statusItem.autosaveName as String
        let cached = StatusItemDefaults[.preferredPosition, autosaveName]
        NSStatusBar.system.removeStatusItem(statusItem)
        if !autosaveName.isEmpty {
            StatusItemDefaults[.preferredPosition, autosaveName] = cached
        }
    }

    /// Completes the initial status-item update after its section exists.
    func attach(to section: MenuBarSection) {
        self.section = section
        updateStatusItem()
        guard !isVirtualSection else {
            return
        }
        configureHostedClickMonitor()
        // AppKit realizes hosted status item scenes asynchronously and can
        // replace the initial button after this object has been configured.
        for delay in [0.5, 1.5, 3.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, let button = statusItem.button else {
                    return
                }
                bindButton(button)
                updateStatusItem()
            }
        }
    }

    private func bindButton(_ button: NSStatusBarButton) {
        button.setAccessibilityIdentifier(identifier.rawValue)
        button.target = self
        button.action = #selector(performAction)
        #if compiler(>=6.4)
        button.addTarget(self, action: #selector(performHostedPrimaryAction), for: .primaryActionTriggered)
        #endif
        button.sendAction(on: [.leftMouseDown, .rightMouseUp])
        button.isEnabled = true
    }

    private func configureHostedClickMonitor() {
        guard hostedClickMonitor == nil else {
            return
        }
        hostedClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard
                let self,
                let point = event.cgEvent?.location ?? MouseCursor.locationCoreGraphics
            else {
                return
            }

            guard NSScreen.screens.contains(where: { screen in
                let bounds = CGDisplayBounds(screen.displayID)
                return point.x >= bounds.minX && point.x <= bounds.maxX
                    && point.y >= bounds.minY
                    && point.y <= bounds.minY + max(NSStatusBar.system.thickness, screen.safeAreaInsets.top) + 4
            }) else {
                return
            }

            let eventType = event.type
            let modifiers = event.modifierFlags
            let lastHandledClick = lastClickDate

            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }
                if HostedMenuBarBackend.renderedItemFrameSnapshot(for: ProcessInfo.processInfo.processIdentifier) == nil {
                    guard await HostedMenuBarBackend.refreshRenderedSnapshot() else {
                        return
                    }
                }
                guard
                    lastClickDate == lastHandledClick,
                    HostedMenuBarBackend.renderedItemFrames(for: ProcessInfo.processInfo.processIdentifier)
                        .contains(where: { $0.insetBy(dx: -2, dy: -4).contains(point) })
                else {
                    return
                }
                switch eventType {
                case .leftMouseDown:
                    routeClick(.primary, modifiers: modifiers, menuAtMouseLocation: true)
                case .rightMouseDown:
                    routeClick(.secondary, modifiers: modifiers, menuAtMouseLocation: true)
                default:
                    break
                }
            }
        }
    }

    private enum ClickKind: Equatable {
        case primary
        case secondary
    }

    private func routeClick(
        _ kind: ClickKind,
        modifiers: NSEvent.ModifierFlags = [],
        menuAtMouseLocation: Bool = false
    ) {
        let now = Date.now
        guard now.timeIntervalSince(lastClickDate) > 0.3 else {
            Logger.controlItem.debug("Ignoring duplicate Ice icon click within debounce window")
            return
        }
        lastClickDate = now
        guard let appState else {
            return
        }
        let general = appState.settingsManager.generalSettingsManager
        let action = MenuBarClickPolicy.resolve(
            button: kind == .primary ? .primary : .secondary,
            modifiers: .init(
                option: modifiers.contains(.option),
                control: modifiers.contains(.control)
            ),
            allowsAlwaysHidden: general.enableAlwaysHiddenSection && general.canToggleAlwaysHiddenSection
        )

        switch action {
        case .showMenu:
            let menu = createMenu(with: appState)
            if menuAtMouseLocation {
                menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
            } else {
                statusItem.showMenu(menu)
            }
        case .toggleAlwaysHidden:
            appState.menuBarManager.section(withName: .alwaysHidden)?.toggle()
        case .toggleHidden:
            appState.menuBarManager.section(withName: .hidden)?.toggle()
        }
    }

    private func configureCancellables() {
        var c = Set<AnyCancellable>()

        guard !isVirtualSection else {
            cancellables = c
            return
        }

        window?.publisher(for: \.frame)
            .sink { [weak self] frame in
                guard
                    let self,
                    let screen = window?.screen,
                    screen.frame.intersects(frame)
                else {
                    return
                }
                windowFrame = frame
            }
            .store(in: &c)

        if let appState {
            let general = appState.settingsManager.generalSettingsManager

            general.$showIceIcon
                .receive(on: DispatchQueue.main)
                .sink { [weak self] showIceIcon in
                    guard let self else {
                        return
                    }
                    isVisible = showIceIcon
                    if showIceIcon {
                        addToMenuBar()
                        updateStatusItem()
                    } else {
                        removeFromMenuBar()
                    }
                }
                .store(in: &c)

            general.$iceIcon
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    self?.updateStatusItem()
                }
                .store(in: &c)

            general.$customIceIconIsTemplate
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    self?.updateStatusItem()
                }
                .store(in: &c)

            appState.navigationState.$isIceBarPresented
                .receive(on: DispatchQueue.main)
                .sink { [weak self] isPresented in
                    guard let self else {
                        return
                    }
                    state = isPresented ? .showItems : .hideItems
                    updateStatusItem()
                }
                .store(in: &c)
        }

        cancellables = c
    }

    private func configureStatusItem() {
        defer {
            configureCancellables()
            updateStatusItem()
        }
        guard !isVirtualSection, let button = statusItem.button else {
            return
        }
        bindButton(button)
    }

    private func updateStatusItem() {
        guard
            !isVirtualSection,
            let appState,
            let button = statusItem.button
        else {
            return
        }

        let general = appState.settingsManager.generalSettingsManager
        isVisible = general.showIceIcon
        guard general.showIceIcon else {
            removeFromMenuBar()
            return
        }
        if !statusItem.isVisible {
            statusItem.isVisible = true
        }
        statusItem.length = NSStatusItem.variableLength
        button.cell?.isEnabled = true

        let icon = general.iceIcon
        let isExpanded = appState.navigationState.isIceBarPresented
        button.image = isExpanded ? icon.visible.nsImage(for: appState) : icon.hidden.nsImage(for: appState)

        if case .custom = icon.name, let originalImage = button.image {
            let originalWidth = originalImage.size.width
            let originalHeight = originalImage.size.height
            if originalWidth > 0, originalHeight > 0 {
                let ratio = max(originalWidth / 25, originalHeight / 17)
                let newSize = CGSize(width: originalWidth / ratio, height: originalHeight / ratio)
                button.image = originalImage.resized(to: newSize)
            }
        }
    }

    @objc private func performAction() {
        guard let event = NSApp.currentEvent else {
            routeClick(.primary)
            return
        }
        switch event.type {
        case .leftMouseDown, .leftMouseUp:
            routeClick(.primary, modifiers: event.modifierFlags, menuAtMouseLocation: true)
        case .rightMouseUp:
            routeClick(.secondary, modifiers: event.modifierFlags, menuAtMouseLocation: true)
        default:
            routeClick(.primary, modifiers: event.modifierFlags)
        }
    }

    @objc private func performHostedPrimaryAction() {
        routeClick(
            .primary,
            modifiers: NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags,
            menuAtMouseLocation: true
        )
    }

    private func createMenu(with appState: AppState) -> NSMenu {
        let menu = NSMenu(title: "Ice")

        let sectionNames: [MenuBarSection.Name] = [.hidden, .alwaysHidden]
        for name in sectionNames {
            guard
                let section = appState.menuBarManager.section(withName: name),
                section.isEnabled
            else {
                continue
            }
            let title = switch name {
            case .visible:
                ""
            case .hidden:
                section.isHidden ? "展开隐藏图标" : "收起隐藏图标"
            case .alwaysHidden:
                section.isHidden ? "展开始终隐藏图标" : "收起始终隐藏图标"
            }
            let item = NSMenuItem(
                title: title,
                action: #selector(toggleMenuBarSection),
                keyEquivalent: ""
            )
            item.target = self
            Self.sectionStorage.weakSet(section, for: item)
            menu.addItem(item)
        }

        let pauseItem = NSMenuItem(
            title: appState.menuBarManager.isHidingPaused ? "恢复隐藏菜单栏图标" : "暂停隐藏菜单栏图标",
            action: #selector(toggleHidingPaused),
            keyEquivalent: ""
        )
        pauseItem.target = self
        menu.addItem(pauseItem)

        menu.addItem(.separator())

        let layoutItem = NSMenuItem(
            title: "图标管理…",
            action: #selector(openLayoutSettings),
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

        let checkForUpdatesItem = NSMenuItem(
            title: "检查更新…",
            action: #selector(checkForUpdates),
            keyEquivalent: ""
        )
        checkForUpdatesItem.target = self
        menu.addItem(checkForUpdatesItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "退出 Ice",
            action: #selector(NSApp.terminate),
            keyEquivalent: "q"
        )
        quitItem.keyEquivalentModifierMask = .command
        menu.addItem(quitItem)

        return menu
    }

    @objc private func toggleMenuBarSection(for menuItem: NSMenuItem) {
        Self.sectionStorage.value(for: menuItem)?.toggle()
    }

    @objc private func toggleHidingPaused() {
        appState?.menuBarManager.toggleHidingPaused()
    }

    @objc private func openLayoutSettings() {
        guard let appState else {
            return
        }
        appState.navigationState.settingsNavigationIdentifier = .menuBarLayout
        appState.appDelegate?.openSettingsWindow()
    }

    @objc private func checkForUpdates() {
        appState?.updatesManager.checkForUpdates()
    }

    func addToMenuBar() {
        guard !isVirtualSection, !isAddedToMenuBar else {
            return
        }
        statusItem.isVisible = true
    }

    func removeFromMenuBar() {
        guard !isVirtualSection, isAddedToMenuBar else {
            return
        }
        let autosaveName = statusItem.autosaveName as String
        let cached = StatusItemDefaults[.preferredPosition, autosaveName]
        statusItem.isVisible = false
        StatusItemDefaults[.preferredPosition, autosaveName] = cached
    }
}

private extension ControlItem {
    static let sectionStorage = ObjectStorage<MenuBarSection>()
}

// MARK: - Logger
private extension Logger {
    static let controlItem = Logger(category: "ControlItem")
}
