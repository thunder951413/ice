//
//  IceBarStyle.swift
//  Ice
//

import SwiftUI

/// Appearance styles for the Ice Bar.
enum IceBarStyle: Int, CaseIterable, Identifiable {
    case frosted = 0
    case solid = 1

    var id: Int { rawValue }

    /// Localized string key representation.
    var localized: LocalizedStringKey {
        switch self {
        case .frosted: "Frosted"
        case .solid: "Solid"
        }
    }
}
