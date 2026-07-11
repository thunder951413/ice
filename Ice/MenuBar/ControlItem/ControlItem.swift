//
//  ControlItem.swift
//  Ice
//

import Cocoa
import Combine

/// A status item that controls a section in the menu bar.
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
        case hideItems, showItems
    }

    /// Possible lengths for control items.
    enum Lengths {
        static let standard: CGFloat = NSStatusItem.variableLength
        static let expanded: CGFloat = 10_000
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

    /// A horizontal constraint for the control item's content view.
    private let constraint: NSLayoutConstraint?

    /// The control item's identifier.
    private let identifier: Identifier

    /// Hosted menu bars use logical delimiters instead of registering extra
    /// system status items in the shared scene.
    private let isVirtualHostedDivider: Bool

    /// Storage for internal observers.
    private var cancellables = Set<AnyCancellable>()

    /// Content rendered directly in the hosted button view hierarchy.
    private var hostedContentView: NSView?

    /// Global monitor used because MenuBarAgent does not forward hosted status
    /// item mouse events to the owning process on newer systems.
    private var hostedClickMonitor: Any?

    /// Newer systems host all status items in a shared menu bar scene. Expanding
    /// a divider there resizes the shared host instead of an isolated item.
    private var usesHostedMenuBar: Bool {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26
    }

    /// The menu bar section associated with the control item.
    private weak var section: MenuBarSection?

    /// Completes the initial status-item update after its section exists.
    func attach(to section: MenuBarSection) {
        self.section = section
        updateStatusItem(with: state)
        isVisible = isVisible
        guard usesHostedMenuBar, !isVirtualHostedDivider else {
            return
        }
        configureHostedClickMonitor()
        // AppKit realizes hosted status item scenes asynchronously and can
        // replace the initial button after this object has been configured.
        // Rebind appearance and actions once the hosted scene is ready.
        for delay in [0.5, 1.5, 3.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, let button = statusItem.button else {
                    return
                }
                button.setAccessibilityIdentifier(identifier.rawValue)
                button.setAccessibilityRole(.button)
                button.target = self
                button.action = #selector(performAction)
                let useIceBar = appState?.settingsManager.generalSettingsManager.useIceBar ?? false
                button.sendAction(on: useIceBar ? [.leftMouseDown, .rightMouseUp] : [.leftMouseUp, .rightMouseUp])
                button.isEnabled = true
                updateStatusItem(with: state)
                isVisible = isVisible
                guard hostedContentView?.superview !== button else {
                    return
                }
                hostedContentView?.removeFromSuperview()
                let label = HostedControlLabel(labelWithString: "❄︎")
                label.translatesAutoresizingMaskIntoConstraints = false
                label.font = .systemFont(ofSize: 14, weight: .semibold)
                label.textColor = .white
                label.alignment = .center
                label.setAccessibilityElement(false)
                label.onLeftClick = { [weak self] in
                    self?.section?.toggle()
                }
                label.onRightClick = { [weak self] in
                    guard let self, let appState else {
                        return
                    }
                    statusItem.showMenu(createMenu(with: appState))
                }
                button.addSubview(label)
                NSLayoutConstraint.activate([
                    label.centerXAnchor.constraint(equalTo: button.centerXAnchor),
                    label.centerYAnchor.constraint(equalTo: button.centerYAnchor),
                ])
                hostedContentView = label
            }
        }
    }

    /// The control item's window.
    var window: NSWindow? {
        statusItem.button?.window
    }

    /// The identifier of the control item's window.
    var windowID: CGWindowID? {
        guard
            let window,
            window.windowNumber > 0,
            let windowID = CGWindowID(exactly: window.windowNumber)
        else {
            return nil
        }
        return windowID
    }

    /// A Boolean value that indicates whether the control item serves as
    /// a divider between sections.
    var isSectionDivider: Bool {
        identifier != .iceIcon
    }

    /// A Boolean value that indicates whether the control item is currently
    /// displayed in the menu bar.
    var isAddedToMenuBar: Bool {
        if isVirtualHostedDivider {
            return true
        }
        return statusItem.isVisible
    }

    /// Creates a control item with the given identifier and app state.
    init(identifier: Identifier, appState: AppState) {
        let hosted = ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26
        let isVirtualHostedDivider = hosted && identifier != .iceIcon
        let autosaveName = hosted && identifier == .iceIcon
            ? "\(identifier.rawValue)-HostedV6"
            : identifier.rawValue

        // If the status item doesn't have a preferred position, set it
        // according to the identifier.
        if hosted, identifier == .iceIcon,
           StatusItemDefaults[.preferredPosition, autosaveName] == nil {
            StatusItemDefaults[.preferredPosition, autosaveName] = 193
        } else if !hosted, StatusItemDefaults[.preferredPosition, autosaveName] == nil {
            switch identifier {
            case .iceIcon:
                StatusItemDefaults[.preferredPosition, autosaveName] = 0
            case .hidden:
                StatusItemDefaults[.preferredPosition, autosaveName] = 1
            case .alwaysHidden:
                break
            }
        }

        self.statusItem = isVirtualHostedDivider
            ? NSStatusItem()
            : NSStatusBar.system.statusItem(withLength: hosted ? 33 : 0)
        if !isVirtualHostedDivider {
            self.statusItem.autosaveName = autosaveName
        }
        self.identifier = identifier
        self.isVirtualHostedDivider = isVirtualHostedDivider
        self.appState = appState

        // This could break in a new macOS release, but we need this constraint in order to be
        // able to hide the control item when the `ShowSectionDividers` setting is disabled. A
        // previous implementation used the status item's `isVisible` property, which was more
        // robust, but would completely remove the control item. With the current set of
        // features, we need to be able to accurately retrieve the items for each section, so
        // we need the control item to always be present to act as a delimiter. The new solution
        // is to remove the constraint that prevents status items from having a length of zero,
        // then resize the content view. FIXME: Find a replacement for this.
        if
            let button = statusItem.button,
            let constraints = button.window?.contentView?.constraintsAffectingLayout(for: .horizontal),
            let constraint = constraints.first(where: Predicates.controlItemConstraint(button: button))
        {
            assert(constraints.filter(Predicates.controlItemConstraint(button: button)).count == 1)
            self.constraint = hosted ? nil : constraint
        } else {
            self.constraint = nil
        }

        configureStatusItem()
    }

    /// Removes the status item without clearing its stored position.
    deinit {
        if let hostedClickMonitor {
            NSEvent.removeMonitor(hostedClickMonitor)
        }
        guard !isVirtualHostedDivider else {
            return
        }
        // Removing the status item has the unwanted side effect of deleting
        // the preferredPosition. Cache and restore it.
        let autosaveName = statusItem.autosaveName as String
        let cached = StatusItemDefaults[.preferredPosition, autosaveName]
        NSStatusBar.system.removeStatusItem(statusItem)
        if !autosaveName.isEmpty {
            StatusItemDefaults[.preferredPosition, autosaveName] = cached
        }
    }

    /// Handles physical clicks on Ice's hosted menu bar element even when
    /// MenuBarAgent declines to forward them through NSStatusBarButton.
    private func configureHostedClickMonitor() {
        guard hostedClickMonitor == nil else {
            return
        }
        hostedClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard
                let self,
                let point = CGEvent(source: nil)?.location
            else {
                return
            }
            let systemWide = AXUIElementCreateSystemWide()
            var element: AXUIElement?
            guard
                AXUIElementCopyElementAtPosition(
                    systemWide,
                    Float(point.x),
                    Float(point.y),
                    &element
                ) == .success,
                let element
            else {
                return
            }
            var pid: pid_t = 0
            AXUIElementGetPid(element, &pid)
            var identifierValue: CFTypeRef?
            AXUIElementCopyAttributeValue(
                element,
                kAXIdentifierAttribute as CFString,
                &identifierValue
            )
            let hitIdentifier = identifierValue as? String
            if point.y <= NSStatusBar.system.thickness + 4 {
                Logger.controlItem.info(
                    "Hosted menu click: type=\(String(describing: event.type)), " +
                    "pid=\(pid), identifier=\(hitIdentifier ?? "nil"), " +
                    "point=\(NSStringFromPoint(point))"
                )
            }
            guard
                pid == ProcessInfo.processInfo.processIdentifier
                    || hitIdentifier == Identifier.iceIcon.rawValue
            else {
                return
            }
            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }
                switch event.type {
                case .leftMouseDown:
                    section?.toggle()
                case .rightMouseDown:
                    guard let appState else {
                        return
                    }
                    statusItem.showMenu(createMenu(with: appState))
                default:
                    break
                }
            }
        }
    }

    /// Configures the internal observers for the control item.
    private func configureCancellables() {
        var c = Set<AnyCancellable>()

        $state
            .sink { [weak self] state in
                self?.updateStatusItem(with: state)
            }
            .store(in: &c)

        Publishers.CombineLatest($isVisible, $state)
            .sink { [weak self] (isVisible, state) in
                guard
                    let self,
                    let section
                else {
                    return
                }
                if usesHostedMenuBar {
                    if isVirtualHostedDivider {
                        return
                    }
                    // Never resize or remove the real member of the shared
                    // hosted scene. Dividers are virtual on this path.
                    statusItem.isVisible = true
                    statusItem.length = switch section.name {
                    case .visible: isVisible ? 33 : 1
                    case .hidden, .alwaysHidden: isVisible ? Lengths.standard : 1
                    }
                    return
                }
                if isVisible {
                    statusItem.length = switch section.name {
                    case .visible: Lengths.standard
                    case .hidden, .alwaysHidden:
                        switch state {
                        case .hideItems: Lengths.expanded
                        case .showItems: Lengths.standard
                        }
                    }
                    constraint?.isActive = true
                } else {
                    statusItem.length = 0
                    constraint?.isActive = false
                    if let window {
                        var size = window.frame.size
                        size.width = 1
                        window.setContentSize(size)
                    }
                }
            }
            .store(in: &c)

        constraint?.publisher(for: \.isActive)
            .removeDuplicates()
            .sink { [weak self] isActive in
                self?.isVisible = isActive
            }
            .store(in: &c)

        statusItem.publisher(for: \.isVisible)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isVisible in
                guard
                    let self,
                    let appState,
                    let section
                else {
                    return
                }

                let manager = appState.settingsManager.hotkeySettingsManager

                let hotkey: Hotkey? = switch section.name {
                case .visible: nil
                case .hidden: manager.hotkey(withAction: .toggleHiddenSection)
                case .alwaysHidden: manager.hotkey(withAction: .toggleAlwaysHiddenSection)
                }

                guard let hotkey else {
                    return
                }

                if isVisible {
                    hotkey.enable()
                } else {
                    hotkey.disable()
                }
            }
            .store(in: &c)

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
            appState.settingsManager.generalSettingsManager.$showIceIcon
                .receive(on: DispatchQueue.main)
                .sink { [weak self] showIceIcon in
                    guard
                        let self,
                        !isSectionDivider
                    else {
                        return
                    }
                    if showIceIcon {
                        addToMenuBar()
                    } else {
                        removeFromMenuBar()
                    }
                }
                .store(in: &c)

            appState.settingsManager.generalSettingsManager.$iceIcon
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    guard let self else {
                        return
                    }
                    updateStatusItem(with: state)
                }
                .store(in: &c)

            appState.settingsManager.generalSettingsManager.$customIceIconIsTemplate
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    guard let self else {
                        return
                    }
                    updateStatusItem(with: state)
                }
                .store(in: &c)

            appState.settingsManager.generalSettingsManager.$useIceBar
                .receive(on: DispatchQueue.main)
                .sink { [weak self] useIceBar in
                    guard
                        let self,
                        let button = statusItem.button
                    else {
                        return
                    }
                    if useIceBar {
                        button.sendAction(on: [.leftMouseDown, .rightMouseUp])
                    } else {
                        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
                    }
                }
                .store(in: &c)

            appState.settingsManager.advancedSettingsManager.$showSectionDividers
                .receive(on: DispatchQueue.main)
                .sink { [weak self] shouldShow in
                    guard
                        let self,
                        isSectionDivider,
                        state == .showItems
                    else {
                        return
                    }
                    isVisible = shouldShow
                }
                .store(in: &c)

            appState.settingsManager.advancedSettingsManager.$enableAlwaysHiddenSection
                .receive(on: DispatchQueue.main)
                .sink { [weak self] enable in
                    guard
                        let self,
                        identifier == .alwaysHidden
                    else {
                        return
                    }
                    if enable {
                        addToMenuBar()
                    } else {
                        removeFromMenuBar()
                    }
                }
                .store(in: &c)
        }

        cancellables = c
    }

    /// Sets the initial configuration for the status item.
    private func configureStatusItem() {
        defer {
            configureCancellables()
            updateStatusItem(with: state)
        }
        guard let button = statusItem.button else {
            return
        }
        button.setAccessibilityIdentifier(identifier.rawValue)
        button.setAccessibilityRole(.button)
        button.target = self
        button.action = #selector(performAction)
    }

    /// Updates the appearance of the status item using the given hiding state.
    private func updateStatusItem(with state: HidingState) {
        guard
            let appState,
            let section,
            let button = statusItem.button
        else {
            return
        }

        switch section.name {
        case .visible:
            isVisible = true
            // Enable the cell, as it may have been previously disabled.
            button.cell?.isEnabled = true
            if ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26 {
                button.contentTintColor = .white
            }
            let icon = appState.settingsManager.generalSettingsManager.iceIcon
            // We can usually just set the image directly from the icon.
            button.image = switch state {
            case .hideItems: icon.hidden.nsImage(for: appState)
            case .showItems: icon.visible.nsImage(for: appState)
            }
            if
                case .custom = icon.name,
                let originalImage = button.image
            {
                // Custom icons need to be resized to fit inside the button.
                let originalWidth = originalImage.size.width
                let originalHeight = originalImage.size.height
                let ratio = max(originalWidth / 25, originalHeight / 17)
                let newSize = CGSize(width: originalWidth / ratio, height: originalHeight / ratio)
                button.image = originalImage.resized(to: newSize)
            }
        case .hidden, .alwaysHidden:
            switch state {
            case .hideItems:
                isVisible = !usesHostedMenuBar
                // Prevent the cell from highlighting while expanded.
                button.cell?.isEnabled = false
                // Cell still sometimes briefly flashes on expansion unless manually unhighlighted.
                button.isHighlighted = false
                button.image = nil
            case .showItems:
                isVisible = appState.settingsManager.advancedSettingsManager.showSectionDividers
                // Enable the cell, as it may have been previously disabled.
                button.cell?.isEnabled = true
                // Set the image based on the section name and the hiding state.
                switch section.name {
                case .hidden:
                    button.image = ControlItemImage.builtin(.chevronLarge).nsImage(for: appState)
                case .alwaysHidden:
                    button.image = ControlItemImage.builtin(.chevronSmall).nsImage(for: appState)
                case .visible: break
                }
            }
        }
    }

    /// Performs the control item's action.
    @objc private func performAction() {
        guard let appState else {
            return
        }
        guard let event = NSApp.currentEvent else {
            // Hosted menu bar accessibility presses do not install an AppKit
            // event, but they still invoke this button action.
            section?.toggle()
            return
        }
        switch event.type {
        case .leftMouseDown, .leftMouseUp:
            if NSEvent.modifierFlags == .control {
                statusItem.showMenu(createMenu(with: appState))
            } else if
                NSEvent.modifierFlags == .option,
                appState.settingsManager.advancedSettingsManager.canToggleAlwaysHiddenSection
            {
                if let alwaysHiddenSection = appState.menuBarManager.section(withName: .alwaysHidden) {
                    alwaysHiddenSection.toggle()
                }
            } else {
                section?.toggle()
            }
        case .rightMouseUp:
            statusItem.showMenu(createMenu(with: appState))
        default:
            // MenuBarAgent forwards AXPress as an application-defined event.
            section?.toggle()
        }
    }

    /// Creates a menu to show under the control item.
    private func createMenu(with appState: AppState) -> NSMenu {
        func hotkey(withAction action: HotkeyAction) -> Hotkey? {
            let hotkeySettingsManager = appState.settingsManager.hotkeySettingsManager
            return hotkeySettingsManager.hotkey(withAction: action)
        }

        let menu = NSMenu(title: "Ice")

        let settingsItem = NSMenuItem(
            title: "Ice Settings…",
            action: #selector(AppDelegate.openSettingsWindow),
            keyEquivalent: ","
        )
        settingsItem.keyEquivalentModifierMask = .command
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let searchItem = NSMenuItem(
            title: "Search Menu Bar Items",
            action: #selector(showSearchPanel),
            keyEquivalent: ""
        )
        searchItem.target = self
        if
            let hotkey = hotkey(withAction: .searchMenuBarItems),
            let keyCombination = hotkey.keyCombination
        {
            searchItem.keyEquivalent = keyCombination.key.keyEquivalent
            searchItem.keyEquivalentModifierMask = keyCombination.modifiers.nsEventFlags
        }
        menu.addItem(searchItem)

        menu.addItem(.separator())

        // Add menu items to toggle the hidden and always-hidden sections.
        let sectionNames: [MenuBarSection.Name] = [.hidden, .alwaysHidden]
        for name in sectionNames {
            guard
                let section = appState.menuBarManager.section(withName: name),
                section.controlItem.isAddedToMenuBar
            else {
                // Section doesn't exist, or is disabled.
                continue
            }
            let item = NSMenuItem(
                title: "\(section.isHidden ? "Show" : "Hide") the \(name.displayString) Section",
                action: #selector(toggleMenuBarSection),
                keyEquivalent: ""
            )
            item.target = self
            Self.sectionStorage.weakSet(section, for: item)
            switch name {
            case .visible:
                break
            case .hidden:
                if
                    let hotkey = hotkey(withAction: .toggleHiddenSection),
                    let keyCombination = hotkey.keyCombination
                {
                    item.keyEquivalent = keyCombination.key.keyEquivalent
                    item.keyEquivalentModifierMask = keyCombination.modifiers.nsEventFlags
                }
            case .alwaysHidden:
                if
                    let hotkey = hotkey(withAction: .toggleAlwaysHiddenSection),
                    let keyCombination = hotkey.keyCombination
                {
                    item.keyEquivalent = keyCombination.key.keyEquivalent
                    item.keyEquivalentModifierMask = keyCombination.modifiers.nsEventFlags
                }
            }
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let checkForUpdatesItem = NSMenuItem(
            title: "Check for Updates…",
            action: #selector(checkForUpdates),
            keyEquivalent: ""
        )
        checkForUpdatesItem.target = self
        menu.addItem(checkForUpdatesItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit Ice",
            action: #selector(NSApp.terminate),
            keyEquivalent: "q"
        )
        quitItem.keyEquivalentModifierMask = .command
        menu.addItem(quitItem)

        return menu
    }

    /// Toggles the menu bar section associated with the given menu item.
    @objc private func toggleMenuBarSection(for menuItem: NSMenuItem) {
        Self.sectionStorage.value(for: menuItem)?.toggle()
    }

    /// Opens the menu bar search panel.
    @objc private func showSearchPanel() {
        guard
            let appState,
            let screen = MenuBarSearchPanel.defaultScreen
        else {
            return
        }
        Task {
            await appState.menuBarManager.searchPanel.show(on: screen)
        }
    }

    /// Opens the settings window and checks for app updates.
    @objc private func checkForUpdates() {
        guard let appState else {
            return
        }
        appState.updatesManager.checkForUpdates()
    }

    /// Adds the control item to the menu bar.
    func addToMenuBar() {
        guard !isVirtualHostedDivider else {
            return
        }
        guard !isAddedToMenuBar else {
            return
        }
        statusItem.isVisible = true
    }

    /// Removes the control item from the menu bar.
    func removeFromMenuBar() {
        guard !isVirtualHostedDivider else {
            return
        }
        guard isAddedToMenuBar else {
            return
        }
        // Setting `statusItem.isVisible` to `false` has the unwanted side
        // effect of deleting the preferredPosition. Cache and restore it.
        let autosaveName = statusItem.autosaveName as String
        let cached = StatusItemDefaults[.preferredPosition, autosaveName]
        statusItem.isVisible = false
        StatusItemDefaults[.preferredPosition, autosaveName] = cached
    }
}

/// Visual content for a hosted status button that leaves all mouse and
/// accessibility hit testing to the underlying `NSStatusBarButton`.
private final class HostedControlLabel: NSTextField {
    var onLeftClick: (() -> Void)?
    var onRightClick: (() -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        self
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        onLeftClick?()
    }

    override func rightMouseDown(with event: NSEvent) {
        onRightClick?()
    }
}

private extension ControlItem {
    /// Storage for menu items that toggle a menu bar section.
    ///
    /// When one of these menu items is created, its section is stored here.
    /// When its action is invoked, the section is retrieved from storage.
    static let sectionStorage = ObjectStorage<MenuBarSection>()
}

// MARK: - Logger
private extension Logger {
    /// The logger to use for control items.
    static let controlItem = Logger(category: "ControlItem")
}
