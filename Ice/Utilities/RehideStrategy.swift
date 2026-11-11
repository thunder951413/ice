//
//  RehideStrategy.swift
//  Ice
//

import SwiftUI

/// A type that determines how the auto-rehide feature works.
enum RehideStrategy: Int, CaseIterable, Identifiable {
    /// Menu bar items are rehidden using a smart algorithm.
    case smart = 0
    /// Menu bar items are rehidden after a given time interval.
    case timed = 1
    /// Menu bar items are rehidden when the focused app changes.
    case focusedApp = 2

    var id: Int { rawValue }

    var localized: LocalizedStringKey {
        switch self {
        case .smart: "智能收起"
        case .timed: "定时收起"
        case .focusedApp: "切换应用时"
        }
    }
}
