//
//  Defaults.swift
//  Ice
//

import Foundation

enum Defaults {
    /// Returns a dictionary containing the keys and values for
    /// the defaults meant to be seen by all applications.
    static var globalDomain: [String: Any] {
        UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain) ?? [:]
    }

    static func object(forKey key: Key) -> Any? {
        UserDefaults.standard.object(forKey: key.rawValue)
    }

    static func string(forKey key: Key) -> String? {
        UserDefaults.standard.string(forKey: key.rawValue)
    }

    static func array(forKey key: Key) -> [Any]? {
        UserDefaults.standard.array(forKey: key.rawValue)
    }

    static func dictionary(forKey key: Key) -> [String: Any]? {
        UserDefaults.standard.dictionary(forKey: key.rawValue)
    }

    static func data(forKey key: Key) -> Data? {
        UserDefaults.standard.data(forKey: key.rawValue)
    }

    static func stringArray(forKey key: Key) -> [String]? {
        UserDefaults.standard.stringArray(forKey: key.rawValue)
    }

    static func integer(forKey key: Key) -> Int {
        UserDefaults.standard.integer(forKey: key.rawValue)
    }

    static func float(forKey key: Key) -> Float {
        UserDefaults.standard.float(forKey: key.rawValue)
    }

    static func double(forKey key: Key) -> Double {
        UserDefaults.standard.double(forKey: key.rawValue)
    }

    static func bool(forKey key: Key) -> Bool {
        UserDefaults.standard.bool(forKey: key.rawValue)
    }

    static func url(forKey key: Key) -> URL? {
        UserDefaults.standard.url(forKey: key.rawValue)
    }

    static func set(_ value: Any?, forKey key: Key) {
        UserDefaults.standard.set(value, forKey: key.rawValue)
    }

    static func removeObject(forKey key: Key) {
        UserDefaults.standard.removeObject(forKey: key.rawValue)
    }

    static func ifPresent<Value>(key: Key, assign value: inout Value) {
        if let found = object(forKey: key) as? Value {
            value = found
        }
    }

    static func ifPresent<Value>(key: Key, body: (Value) throws -> Void) rethrows {
        if let found = object(forKey: key) as? Value {
            try body(found)
        }
    }
}

extension Defaults {
    enum Key: String {
        // MARK: General & Trigger Settings
        case showIceIcon = "ShowIceIcon"
        case iceIcon = "IceIcon"
        case customIceIconIsTemplate = "CustomIceIconIsTemplate"
        case showOnClick = "ShowOnClick"
        case showContextMenuOnRightClick = "ShowContextMenuOnRightClick"
        case itemSpacingOffset = "ItemSpacingOffset"
        case autoRehide = "AutoRehide"
        case rehideStrategy = "RehideStrategy"
        case rehideInterval = "RehideInterval"
        case tempShowInterval = "TempShowInterval"
        case enableAlwaysHiddenSection = "EnableAlwaysHiddenSection"
        case canToggleAlwaysHiddenSection = "CanToggleAlwaysHiddenSection"

        // MARK: Ice Bar & Section Persistence
        case iceBarLocation = "IceBarLocation"
        case iceBarStyle = "IceBarStyle"
        case iceBarIconSize = "IceBarIconSize"
        case iceBarItemSpacing = "IceBarItemSpacing"
        case iceBarPadding = "IceBarPadding"
        case hostedSectionAssignments = "HostedSectionAssignments"
    }
}
