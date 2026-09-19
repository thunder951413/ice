//
//  GeneralSettingsManager.swift
//  Ice
//

import Combine
import Foundation

@MainActor
final class GeneralSettingsManager: ObservableObject {
    /// A Boolean value that indicates whether the Ice icon
    /// should be shown.
    @Published var showIceIcon = true

    /// An icon to show in the menu bar, with a different image
    /// for when items are visible or hidden.
    @Published var iceIcon: ControlItemImageSet = .defaultIceIcon

    /// The last user-selected custom Ice icon.
    @Published var lastCustomIceIcon: ControlItemImageSet?

    /// A Boolean value that indicates whether custom Ice icons
    /// should be rendered as template images.
    @Published var customIceIconIsTemplate = false

    /// A Boolean value that indicates whether to show hidden items
    /// in a separate bar below the menu bar.
    @Published var useIceBar = false

    /// Enables the menu bar item search panel and its shortcut.
    @Published var enableMenuBarSearch = true

    /// The location where the Ice Bar appears.
    @Published var iceBarLocation: IceBarLocation = .dynamic

    /// The appearance of the Ice Bar.
    @Published var iceBarStyle: IceBarStyle = .frosted

    /// The size of icons in the Ice Bar.
    @Published var iceBarIconSize: Double = 28

    /// The spacing between icons in the Ice Bar.
    @Published var iceBarItemSpacing: Double = 2

    /// The padding around the Ice Bar background.
    @Published var iceBarPadding: Double = 4

    /// A Boolean value that indicates whether the hidden section
    /// should be shown when the mouse pointer clicks in an empty
    /// area of the menu bar.
    @Published var showOnClick = true

    /// A Boolean value that indicates whether the hidden section
    /// should be shown when the mouse pointer hovers over an
    /// empty area of the menu bar.
    @Published var showOnHover = false

    /// A Boolean value that indicates whether the hidden section
    /// should be shown or hidden when the user scrolls in the
    /// menu bar.
    @Published var showOnScroll = true

    /// The offset to apply to the menu bar item spacing and padding.
    @Published var itemSpacingOffset: Double = 0

    /// A Boolean value that indicates whether the hidden section
    /// should automatically rehide.
    @Published var autoRehide = true

    /// A strategy that determines how the auto-rehide feature works.
    @Published var rehideStrategy: RehideStrategy = .smart

    /// A time interval for the auto-rehide feature when its rule
    /// is ``RehideStrategy/timed``.
    @Published var rehideInterval: TimeInterval = 15

    /// Encoder for properties.
    private let encoder = JSONEncoder()

    /// Decoder for properties.
    private let decoder = JSONDecoder()

    /// Storage for internal observers.
    private var cancellables = Set<AnyCancellable>()

    /// The shared app state.
    private(set) weak var appState: AppState?

    init(appState: AppState) {
        self.appState = appState
    }

    func performSetup() {
        loadInitialState()
        configureCancellables()
    }

    private func loadInitialState() {
        Defaults.ifPresent(key: .showIceIcon, assign: &showIceIcon)
        Defaults.ifPresent(key: .customIceIconIsTemplate, assign: &customIceIconIsTemplate)
        Defaults.ifPresent(key: .useIceBar, assign: &useIceBar)
        Defaults.ifPresent(key: .enableMenuBarSearch, assign: &enableMenuBarSearch)
        Defaults.ifPresent(key: .showOnClick, assign: &showOnClick)
        Defaults.ifPresent(key: .showOnHover, assign: &showOnHover)
        Defaults.ifPresent(key: .showOnScroll, assign: &showOnScroll)
        Defaults.ifPresent(key: .itemSpacingOffset, assign: &itemSpacingOffset)
        loadIceBarSizingPreferences()
        Defaults.ifPresent(key: .autoRehide, assign: &autoRehide)
        Defaults.ifPresent(key: .rehideInterval, assign: &rehideInterval)

        Defaults.ifPresent(key: .iceBarLocation) { rawValue in
            if let location = IceBarLocation(rawValue: rawValue) {
                iceBarLocation = location
            }
        }
        Defaults.ifPresent(key: .iceBarStyle) { rawValue in
            if let style = IceBarStyle(rawValue: rawValue) {
                iceBarStyle = style
            }
        }
        Defaults.ifPresent(key: .rehideStrategy) { rawValue in
            if let strategy = RehideStrategy(rawValue: rawValue) {
                rehideStrategy = strategy
            }
        }

        if let data = Defaults.data(forKey: .iceIcon) {
            do {
                iceIcon = try decoder.decode(ControlItemImageSet.self, from: data)
            } catch {
                Logger.generalSettingsManager.error("Error decoding Ice icon: \(error)")
            }
            if case .custom = iceIcon.name {
                lastCustomIceIcon = iceIcon
            }
        }
    }

    private func loadIceBarSizingPreferences() {
        Defaults.ifPresent(key: .iceBarIconSize) { (value: Double) in
            iceBarIconSize = clampedIceBarValue(value, in: 16...36, defaultValue: 28)
        }
        Defaults.ifPresent(key: .iceBarItemSpacing) { (value: Double) in
            iceBarItemSpacing = clampedIceBarValue(value, in: 0...12, defaultValue: 2)
        }
        Defaults.ifPresent(key: .iceBarPadding) { (value: Double) in
            iceBarPadding = clampedIceBarValue(value, in: 2...12, defaultValue: 4)
        }
    }

    private func clampedIceBarValue(
        _ value: Double,
        in range: ClosedRange<Double>,
        defaultValue: Double
    ) -> Double {
        guard value.isFinite else {
            return defaultValue
        }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    private func configureCancellables() {
        var c = Set<AnyCancellable>()

        $showIceIcon
            .receive(on: DispatchQueue.main)
            .sink { showIceIcon in
                Defaults.set(showIceIcon, forKey: .showIceIcon)
            }
            .store(in: &c)

        $iceIcon
            .receive(on: DispatchQueue.main)
            .sink { [weak self] iceIcon in
                guard let self else {
                    return
                }
                if case .custom = iceIcon.name {
                    lastCustomIceIcon = iceIcon
                }
                do {
                    let data = try encoder.encode(iceIcon)
                    Defaults.set(data, forKey: .iceIcon)
                } catch {
                    Logger.generalSettingsManager.error("Error encoding Ice icon: \(error)")
                }
            }
            .store(in: &c)

        $customIceIconIsTemplate
            .receive(on: DispatchQueue.main)
            .sink { isTemplate in
                Defaults.set(isTemplate, forKey: .customIceIconIsTemplate)
            }
            .store(in: &c)

        $useIceBar
            .receive(on: DispatchQueue.main)
            .sink { [weak self] useIceBar in
                Defaults.set(useIceBar, forKey: .useIceBar)
                guard let appState = self?.appState else {
                    return
                }
                appState.menuBarManager.iceBarPanel.close()
                for section in appState.menuBarManager.sections {
                    section.controlItem.state = .hideItems
                }
                Task {
                    await appState.itemManager.cacheItemsIfNeeded()
                }
            }
            .store(in: &c)

        $enableMenuBarSearch
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                Defaults.set(enabled, forKey: .enableMenuBarSearch)
                guard let appState = self?.appState else { return }
                if !enabled { appState.menuBarManager.searchPanel.close() }
                // Re-register only when enabled; retain the saved combination.
                appState.settingsManager.hotkeySettingsManager.hotkey(withAction: .searchMenuBarItems)?.setRegistrationAllowed(enabled)
            }
            .store(in: &c)

        $iceBarLocation
            .receive(on: DispatchQueue.main)
            .sink { location in
                Defaults.set(location.rawValue, forKey: .iceBarLocation)
            }
            .store(in: &c)

        $iceBarStyle
            .receive(on: DispatchQueue.main)
            .sink { style in
                Defaults.set(style.rawValue, forKey: .iceBarStyle)
            }
            .store(in: &c)

        $iceBarIconSize
            .receive(on: DispatchQueue.main)
            .sink { size in
                Defaults.set(size, forKey: .iceBarIconSize)
            }
            .store(in: &c)

        $iceBarItemSpacing
            .receive(on: DispatchQueue.main)
            .sink { spacing in
                Defaults.set(spacing, forKey: .iceBarItemSpacing)
            }
            .store(in: &c)

        $iceBarPadding
            .receive(on: DispatchQueue.main)
            .sink { padding in
                Defaults.set(padding, forKey: .iceBarPadding)
            }
            .store(in: &c)

        $showOnClick
            .receive(on: DispatchQueue.main)
            .sink { showOnClick in
                Defaults.set(showOnClick, forKey: .showOnClick)
            }
            .store(in: &c)

        $showOnHover
            .receive(on: DispatchQueue.main)
            .sink { showOnHover in
                Defaults.set(showOnHover, forKey: .showOnHover)
            }
            .store(in: &c)

        $showOnScroll
            .receive(on: DispatchQueue.main)
            .sink { showOnScroll in
                Defaults.set(showOnScroll, forKey: .showOnScroll)
            }
            .store(in: &c)

        $itemSpacingOffset
            .receive(on: DispatchQueue.main)
            .sink { [weak appState] offset in
                Defaults.set(offset, forKey: .itemSpacingOffset)
                appState?.spacingManager.offset = Int(offset)
            }
            .store(in: &c)

        $autoRehide
            .receive(on: DispatchQueue.main)
            .sink { autoRehide in
                Defaults.set(autoRehide, forKey: .autoRehide)
            }
            .store(in: &c)

        $rehideStrategy
            .receive(on: DispatchQueue.main)
            .sink { strategy in
                Defaults.set(strategy.rawValue, forKey: .rehideStrategy)
            }
            .store(in: &c)

        $rehideInterval
            .receive(on: DispatchQueue.main)
            .sink { interval in
                Defaults.set(interval, forKey: .rehideInterval)
            }
            .store(in: &c)

        cancellables = c
    }
}

// MARK: GeneralSettingsManager: BindingExposable
extension GeneralSettingsManager: BindingExposable { }

// MARK: - Logger
private extension Logger {
    static let generalSettingsManager = Logger(category: "GeneralSettingsManager")
}
