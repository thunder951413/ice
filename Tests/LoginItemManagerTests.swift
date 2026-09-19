import Foundation

@main
@MainActor
enum LoginItemManagerTests {
    private enum TestError: LocalizedError {
        case registerFailed

        var errorDescription: String? { "Registration failed for testing" }
    }

    private final class ServiceDouble {
        var status: LoginItemManager.Status = .notRegistered
        var registerCalls = 0
        var unregisterCalls = 0
        var settingsCalls = 0
        var registerError: Error?

        var service: LoginItemManager.Service {
            .init(
                status: { self.status },
                register: {
                    self.registerCalls += 1
                    if let registerError = self.registerError { throw registerError }
                    self.status = .enabled
                },
                unregister: {
                    self.unregisterCalls += 1
                    self.status = .notRegistered
                },
                openSystemSettings: { self.settingsCalls += 1 }
            )
        }
    }

    static func main() {
        testEnableAndDisableFollowServiceStatus()
        testApprovalOpensSettingsWithoutRegisteringAgain()
        testRegistrationCanBecomePendingApproval()
        testErrorIsShownWithoutInventingEnabledState()
        testRefreshTracksExternalChanges()
        testNotFoundStatusIsPreserved()
        print("LoginItemManagerTests passed")
    }

    private static func testEnableAndDisableFollowServiceStatus() {
        let double = ServiceDouble()
        let manager = LoginItemManager(service: double.service)
        manager.setEnabled(true)
        expect(manager.status == .enabled, "successful registration must publish the service status")
        manager.setEnabled(false)
        expect(manager.status == .notRegistered, "successful unregistration must publish the service status")
        expect(double.registerCalls == 1 && double.unregisterCalls == 1, "each transition must perform one operation")
    }

    private static func testApprovalOpensSettingsWithoutRegisteringAgain() {
        let double = ServiceDouble()
        double.status = .requiresApproval
        let manager = LoginItemManager(service: double.service)
        manager.setEnabled(true)
        expect(double.registerCalls == 0, "pending approval must not retry registration")
        expect(double.settingsCalls == 1, "enabling a pending item must direct the user to System Settings")
        expect(manager.status == .requiresApproval, "the pending OS status must remain visible")
    }

    private static func testRegistrationCanBecomePendingApproval() {
        let double = ServiceDouble()
        var service = double.service
        service.register = {
            double.registerCalls += 1
            double.status = .requiresApproval
        }
        let manager = LoginItemManager(service: service)
        manager.setEnabled(true)
        expect(manager.status == .requiresApproval, "registration requiring approval must not appear enabled")
        expect(double.registerCalls == 1, "initial registration must run once")
    }

    private static func testErrorIsShownWithoutInventingEnabledState() {
        let double = ServiceDouble()
        double.registerError = TestError.registerFailed
        let manager = LoginItemManager(service: double.service)
        manager.setEnabled(true)
        expect(manager.status == .notRegistered, "a failed registration must preserve the actual status")
        expect(manager.errorMessage == "Registration failed for testing", "the operation error must be exposed")
    }

    private static func testRefreshTracksExternalChanges() {
        let double = ServiceDouble()
        let manager = LoginItemManager(service: double.service)
        double.status = .enabled
        manager.refresh()
        expect(manager.isEnabled, "refresh must observe approval completed outside Ice")
    }

    private static func testNotFoundStatusIsPreserved() {
        let double = ServiceDouble()
        double.status = .notFound
        let manager = LoginItemManager(service: double.service)
        expect(manager.status == .notFound, "a missing registration must remain distinguishable")
        expect(!manager.isEnabled, "a missing registration must not appear enabled")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
    }
}
