import Foundation

@main
enum HostedVisibilityPolicyTests {
    private static let ownBundleIdentifier = "com.jordanbaird.Ice"

    static func main() {
        testOwnOwnerIsProtected()
        testAppleOwnerIsProtected()
        testVisibleSiblingPreventsConcealment()
        testUnknownOwnersAreIgnored()
        testRunningApplicationsAreAllowlistedExceptConcealedOwners()
        testDiscoveredOwnersAreAllowlistedWhenAbsentFromRunningApplications()
        testEmptyConfigurationKeepsOnlyIceAllowed()
        print("HostedVisibilityPolicyTests passed")
    }

    private static func testOwnOwnerIsProtected() {
        let configuration = makeConfiguration(items: [
            .init(bundleIdentifier: ownBundleIdentifier, shouldHide: true)
        ])

        expect(configuration.concealed.isEmpty, "Ice must never conceal itself")
        expect(configuration.allowed == [ownBundleIdentifier], "Ice must remain allowlisted")
    }

    private static func testAppleOwnerIsProtected() {
        let appleBundleIdentifier = "com.apple.controlcenter"
        let configuration = makeConfiguration(items: [
            .init(bundleIdentifier: appleBundleIdentifier, shouldHide: true)
        ])

        expect(configuration.concealed.isEmpty, "Apple-owned menu extras must not be concealed")
        expect(configuration.allowed == [ownBundleIdentifier, appleBundleIdentifier], "Apple-owned extras must remain allowed")
    }

    private static func testVisibleSiblingPreventsConcealment() {
        let bundleIdentifier = "com.example.menu-extra"
        let configuration = makeConfiguration(items: [
            .init(bundleIdentifier: bundleIdentifier, shouldHide: true),
            .init(bundleIdentifier: bundleIdentifier, shouldHide: false)
        ])

        expect(configuration.concealed.isEmpty, "A visible sibling must keep its shared owner visible")
        expect(configuration.allowed.contains(bundleIdentifier), "A visible sibling owner must be allowed")
    }

    private static func testUnknownOwnersAreIgnored() {
        let configuration = makeConfiguration(items: [
            .init(bundleIdentifier: nil, shouldHide: true),
            .init(bundleIdentifier: nil, shouldHide: false),
            .init(bundleIdentifier: "", shouldHide: true)
        ])

        expect(configuration.concealed.isEmpty, "Items without an owner cannot be concealed by bundle")
        expect(configuration.allowed == [ownBundleIdentifier], "Unknown owners must not create an allowlist entry")
    }

    private static func testRunningApplicationsAreAllowlistedExceptConcealedOwners() {
        let concealedBundleIdentifier = "com.example.hidden"
        let visibleBundleIdentifier = "com.example.visible"
        let runningOnlyBundleIdentifier = "com.example.running-only"
        let configuration = makeConfiguration(
            items: [
                .init(bundleIdentifier: concealedBundleIdentifier, shouldHide: true),
                .init(bundleIdentifier: visibleBundleIdentifier, shouldHide: false)
            ],
            running: [concealedBundleIdentifier, runningOnlyBundleIdentifier]
        )

        expect(configuration.concealed == [concealedBundleIdentifier], "Selected owners must be concealed")
        expect(
            configuration.allowed == [ownBundleIdentifier, visibleBundleIdentifier, runningOnlyBundleIdentifier],
            "All running and visible owners except concealed owners must be allowed"
        )
    }

    private static func testDiscoveredOwnersAreAllowlistedWhenAbsentFromRunningApplications() {
        let visibleBundleIdentifier = "com.example.discovered-visible"
        let hiddenBundleIdentifier = "com.example.discovered-hidden"
        let configuration = makeConfiguration(items: [
            .init(bundleIdentifier: visibleBundleIdentifier, shouldHide: false),
            .init(bundleIdentifier: hiddenBundleIdentifier, shouldHide: true)
        ])

        expect(configuration.allowed.contains(visibleBundleIdentifier), "Discovered visible owners must be allowed without NSWorkspace")
        expect(!configuration.allowed.contains(hiddenBundleIdentifier), "Discovered concealed owners must not be allowed")
    }

    private static func testEmptyConfigurationKeepsOnlyIceAllowed() {
        let configuration = makeConfiguration(items: [])

        expect(configuration.concealed.isEmpty, "An empty item list must conceal nothing")
        expect(configuration.allowed == [ownBundleIdentifier], "An empty item list must retain Ice's allowlist entry")
    }

    private static func makeConfiguration(
        items: [HostedVisibilityPolicy.Item], running: Set<String> = []
    ) -> HostedVisibilityPolicy.Configuration {
        HostedVisibilityPolicy.configuration(
            items: items,
            runningBundleIdentifiers: running,
            ownBundleIdentifier: ownBundleIdentifier
        )
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fatalError(message)
        }
    }
}
