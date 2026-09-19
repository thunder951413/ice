//
//  LoginItemManager.swift
//  Ice
//

import Combine
import ServiceManagement

@MainActor
final class LoginItemManager: ObservableObject {
    enum Status: Equatable {
        case enabled
        case notRegistered
        case requiresApproval
        case notFound
    }

    struct Service {
        var status: () -> Status
        var register: () throws -> Void
        var unregister: () throws -> Void
        var openSystemSettings: () -> Void

        static let mainApp = Service(
            status: {
                switch SMAppService.mainApp.status {
                case .enabled:
                    return .enabled
                case .notRegistered:
                    return .notRegistered
                case .requiresApproval:
                    return .requiresApproval
                case .notFound:
                    return .notFound
                @unknown default:
                    return .notFound
                }
            },
            register: { try SMAppService.mainApp.register() },
            unregister: { try SMAppService.mainApp.unregister() },
            openSystemSettings: { SMAppService.openSystemSettingsLoginItems() }
        )
    }

    @Published private(set) var status: Status
    @Published private(set) var errorMessage: String?

    private let service: Service

    init(service: Service = .mainApp) {
        self.service = service
        status = service.status()
    }

    var isEnabled: Bool {
        status == .enabled
    }

    func refresh() {
        status = service.status()
    }

    func setEnabled(_ shouldEnable: Bool) {
        errorMessage = nil
        refresh()

        if shouldEnable, status == .requiresApproval {
            service.openSystemSettings()
            refresh()
            return
        }

        guard shouldEnable != isEnabled else {
            return
        }

        do {
            if shouldEnable {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            errorMessage = error.localizedDescription
        }

        // Service Management is authoritative even when an operation throws or
        // leaves registration waiting for approval.
        refresh()
    }

    func openSystemSettings() {
        errorMessage = nil
        service.openSystemSettings()
        refresh()
    }
}
