//
//  SettingsManager.swift
//  Ice
//

import Combine
import Foundation

@MainActor
final class SettingsManager: ObservableObject {
    /// The manager for general settings.
    let generalSettingsManager: GeneralSettingsManager

    /// The manager for advanced settings.
    let advancedSettingsManager: AdvancedSettingsManager

    /// The manager for hotkey settings.
    let hotkeySettingsManager: HotkeySettingsManager

    /// Storage for internal observers.
    private var cancellables = Set<AnyCancellable>()

    /// Whether a forwarded objectWillChange notification has already been queued.
    private var isObjectWillChangeScheduled = false

    /// The shared app state.
    private(set) weak var appState: AppState?

    init(appState: AppState) {
        self.generalSettingsManager = GeneralSettingsManager(appState: appState)
        self.advancedSettingsManager = AdvancedSettingsManager(appState: appState)
        self.hotkeySettingsManager = HotkeySettingsManager(appState: appState)
        self.appState = appState
    }

    func performSetup() {
        configureCancellables()
        generalSettingsManager.performSetup()
        advancedSettingsManager.performSetup()
        hotkeySettingsManager.performSetup()
    }

    private func configureCancellables() {
        var c = Set<AnyCancellable>()

        generalSettingsManager.objectWillChange
            .sink { [weak self] in
                self?.scheduleObjectWillChange()
            }
            .store(in: &c)
        advancedSettingsManager.objectWillChange
            .sink { [weak self] in
                self?.scheduleObjectWillChange()
            }
            .store(in: &c)
        hotkeySettingsManager.objectWillChange
            .sink { [weak self] in
                self?.scheduleObjectWillChange()
            }
            .store(in: &c)

        cancellables = c
    }

    private func scheduleObjectWillChange() {
        guard !isObjectWillChangeScheduled else {
            return
        }
        isObjectWillChangeScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }
            self.isObjectWillChangeScheduled = false
            self.objectWillChange.send()
        }
    }
}

// MARK: SettingsManager: BindingExposable
extension SettingsManager: BindingExposable { }
