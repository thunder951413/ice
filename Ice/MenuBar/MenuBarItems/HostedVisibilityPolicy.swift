//
//  HostedVisibilityPolicy.swift
//  Ice
//

import Foundation

/// The macOS 27 visibility assertion operates on owning applications, not windows.
/// Keep this policy independent from AppKit so its allowlist can be tested.
enum HostedVisibilityPolicy {
    struct Item {
        let bundleIdentifier: String?
        let shouldHide: Bool
    }

    struct Configuration: Equatable {
        let concealed: Set<String>
        let allowed: Set<String>
    }

    static func configuration(
        items: [Item], runningBundleIdentifiers: Set<String>, ownBundleIdentifier: String
    ) -> Configuration {
        let visible = Set(items.filter { !$0.shouldHide }.compactMap(\.bundleIdentifier))
        let concealed = Set(items.filter(\.shouldHide).compactMap(\.bundleIdentifier))
            .subtracting(visible)
            .filter { !$0.isEmpty && $0 != ownBundleIdentifier && !$0.hasPrefix("com.apple.") }
        // Include discovered owners too: some hosted helpers do not appear in
        // NSWorkspace's application list. Never hide an unselected owner.
        let allOwners = Set(items.compactMap(\.bundleIdentifier))
        let allowed = runningBundleIdentifiers.union(allOwners)
            .union([ownBundleIdentifier]).subtracting(concealed).filter { !$0.isEmpty }
        return Configuration(concealed: concealed, allowed: allowed)
    }
}
