//
//  PermissionsManager.swift
//  Ice
//

import Combine
import Foundation

/// A type that manages the permissions of the app.
@MainActor
final class PermissionsManager: ObservableObject {
    /// The state of the granted permissions for the app.
    enum PermissionsState {
        case missingPermissions
        case hasPermissions
    }

    /// The state of the granted permissions for the app.
    @Published var permissionsState = PermissionsState.missingPermissions

    let accessibilityPermission: AccessibilityPermission

    let allPermissions: [Permission]

    private(set) weak var appState: AppState?

    private var cancellables = Set<AnyCancellable>()

    init(appState: AppState) {
        self.appState = appState
        self.accessibilityPermission = AccessibilityPermission()
        self.allPermissions = [
            accessibilityPermission,
        ]
        configureCancellables()
    }

    private func configureCancellables() {
        var c = Set<AnyCancellable>()

        accessibilityPermission.$hasPermission
            .receive(on: DispatchQueue.main)
            .sink { [weak self] hasPermission in
                guard let self else {
                    return
                }
                permissionsState = hasPermission ? .hasPermissions : .missingPermissions
            }
            .store(in: &c)

        cancellables = c
    }

    /// Low-frequency runtime revalidation after onboarding has stopped polling.
    func refreshPermissions() {
        for permission in allPermissions {
            permission.refresh()
        }
    }

    /// Stops running all permissions checks.
    func stopAllChecks() {
        for permission in allPermissions {
            permission.stopCheck()
        }
    }
}
