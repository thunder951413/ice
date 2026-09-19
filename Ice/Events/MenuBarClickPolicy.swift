//
//  MenuBarClickPolicy.swift
//  Ice
//

import Foundation

/// Resolves menu bar clicks without depending on AppKit's mutable global
/// modifier state, so callers can snapshot flags at event-delivery time.
enum MenuBarClickPolicy {
    enum Button {
        case primary
        case secondary
    }

    struct ModifierSnapshot: OptionSet {
        let rawValue: UInt8

        static let option = ModifierSnapshot(rawValue: 1 << 0)
        static let control = ModifierSnapshot(rawValue: 1 << 1)

        init(rawValue: UInt8) {
            self.rawValue = rawValue
        }

        init(option: Bool, control: Bool) {
            var value: ModifierSnapshot = []
            if option { value.insert(.option) }
            if control { value.insert(.control) }
            self = value
        }
    }

    enum Action: Equatable {
        case toggleHidden
        case toggleAlwaysHidden
        case showMenu
    }

    static func resolve(
        button: Button,
        modifiers: ModifierSnapshot,
        allowsAlwaysHidden: Bool
    ) -> Action {
        if button == .secondary || modifiers.contains(.control) {
            return .showMenu
        }
        if allowsAlwaysHidden, modifiers.contains(.option) {
            return .toggleAlwaysHidden
        }
        return .toggleHidden
    }
}
