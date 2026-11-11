//
//  GeneralSettingsManager.swift
//  Ice
//

import Combine
import Foundation

@MainActor
final class GeneralSettingsManager: ObservableObject {
    /// Default Ice Bar dimensions, in points.
    static let defaultIceBarIconSize: Double = 28
    static let defaultIceBarItemSpacing: Double = 2
    static let defaultIceBarPadding: Double = 4

    /// A Boolean value that indicates whether the Ice icon should be shown.
    @Published var showIceIcon = true

    /// An icon to show in the menu bar, with a different image for when items are visible or hidden.
    @Published var iceIcon: ControlItemImageSet = .defaultIceIcon

    /// The last user-selected custom Ice icon.
    @Published var lastCustomIceIcon: ControlItemImageSet?

    /// A Boolean value that indicates whether custom Ice icons should be rendered as template images.
    @Published var customIceIconIsTemplate = false

    /// The location where the Ice Bar appears.
    @Published var iceBarLocation: IceBarLocation = .dynamic

    /// The appearance of the Ice Bar.
    @Published var iceBarStyle: IceBarStyle = .frosted

    /// The size of icons in the Ice Bar.
    @Published var iceBarIconSize: Double = GeneralSettingsManager.defaultIceBarIconSize

    /// The spacing between icons in the Ice Bar.
    @Published var iceBarItemSpacing: Double = GeneralSettingsManager.defaultIceBarItemSpacing

    /// The padding around the Ice Bar background.
    @Published var iceBarPadding: Double = GeneralSettingsManager.defaultIceBarPadding

    /// A Boolean value that indicates whether the hidden section should be shown when
    /// clicking in an empty area of the menu bar.
    @Published var showOnClick = true

    /// A Boolean value that indicates whether right-clicking empty menu bar space opens Ice's menu.
    @Published var showContextMenuOnRightClick = true

    /// The offset to apply to the menu bar item spacing and padding.
    @Published var itemSpacingOffset: Double = 0

    /// A Boolean value that indicates whether the Ice Bar should automatically rehide.
    @Published var autoRehide = true

    /// A strategy that determines how the auto-rehide feature works.
    @Published var rehideStrategy: RehideStrategy = .smart

    /// A time interval for the auto-rehide feature when its rule is ``RehideStrategy/timed``.
    @Published var rehideInterval: TimeInterval = 15

    /// How long a clicked hidden item remains visible in the menu bar after its menu closes.
    @Published var tempShowInterval: TimeInterval = 15

    /// A Boolean value that indicates whether the Always-Hidden third section is enabled.
    @Published var enableAlwaysHiddenSection = false

    /// A Boolean value that indicates whether Option-clicking toggles the Always-Hidden section.
    @Published var canToggleAlwaysHiddenSection = true

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
        Defaults.ifPresent(key: .showOnClick, assign: &showOnClick)
        Defaults.ifPresent(key: .showContextMenuOnRightClick, assign: &showContextMenuOnRightClick)
        Defaults.ifPresent(key: .enableAlwaysHiddenSection, assign: &enableAlwaysHiddenSection)
        Defaults.ifPresent(key: .canToggleAlwaysHiddenSection, assign: &canToggleAlwaysHiddenSection)
        Defaults.ifPresent(key: .itemSpacingOffset) { (value: Double) in
            itemSpacingOffset = clampedValue(value, in: -16...16, defaultValue: 0)
        }
        loadIceBarSizingPreferences()
        Defaults.ifPresent(key: .autoRehide, assign: &autoRehide)
        Defaults.ifPresent(key: .rehideInterval) { (value: TimeInterval) in
            rehideInterval = clampedValue(value, in: 0...30, defaultValue: 15)
        }
        Defaults.ifPresent(key: .tempShowInterval) { (value: TimeInterval) in
            tempShowInterval = clampedValue(value, in: 0...30, defaultValue: 15)
        }

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
            iceBarIconSize = clampedValue(value, in: 16...36, defaultValue: Self.defaultIceBarIconSize)
        }
        Defaults.ifPresent(key: .iceBarItemSpacing) { (value: Double) in
            iceBarItemSpacing = clampedValue(value, in: 0...12, defaultValue: Self.defaultIceBarItemSpacing)
        }
        Defaults.ifPresent(key: .iceBarPadding) { (value: Double) in
            iceBarPadding = clampedValue(value, in: 2...12, defaultValue: Self.defaultIceBarPadding)
        }
    }

    private func clampedValue(
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

        $showContextMenuOnRightClick
            .receive(on: DispatchQueue.main)
            .sink { showContextMenu in
                Defaults.set(showContextMenu, forKey: .showContextMenuOnRightClick)
            }
            .store(in: &c)

        $itemSpacingOffset
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak appState] offset in
                let sanitized = self?.clampedValue(offset, in: -16...16, defaultValue: 0) ?? 0
                Defaults.set(sanitized, forKey: .itemSpacingOffset)
                appState?.spacingManager.offset = Int(sanitized)
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
            .sink { [weak self] interval in
                let sanitized = self?.clampedValue(interval, in: 0...30, defaultValue: 15) ?? 15
                Defaults.set(sanitized, forKey: .rehideInterval)
            }
            .store(in: &c)

        $tempShowInterval
            .receive(on: DispatchQueue.main)
            .sink { [weak self] interval in
                let sanitized = self?.clampedValue(interval, in: 0...30, defaultValue: 15) ?? 15
                Defaults.set(sanitized, forKey: .tempShowInterval)
            }
            .store(in: &c)

        $enableAlwaysHiddenSection
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { enabled in
                Defaults.set(enabled, forKey: .enableAlwaysHiddenSection)
            }
            .store(in: &c)

        $enableAlwaysHiddenSection
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                guard let appState = self?.appState else {
                    return
                }
                if !enabled, appState.menuBarManager.iceBarPanel.currentSection == .alwaysHidden {
                    appState.menuBarManager.iceBarPanel.close()
                }
                appState.itemManager.cacheHostedItems()
                appState.menuBarManager.hostedItemVisibilityManager.refreshNow()
            }
            .store(in: &c)

        $canToggleAlwaysHiddenSection
            .receive(on: DispatchQueue.main)
            .sink { canToggle in
                Defaults.set(canToggle, forKey: .canToggleAlwaysHiddenSection)
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
