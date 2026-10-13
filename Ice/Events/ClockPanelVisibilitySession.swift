//
//  ClockPanelVisibilitySession.swift
//  Ice
//

import Foundation

/// A long reading session in Notification Center must never be cut short by
/// the hiding bridge's recovery timeout. Only confirmed absence restores it.
struct ClockPanelVisibilitySession {
    enum Decision: Equatable {
        case wait(Duration)
        case restore
    }

    private var appeared = false
    private var missingSince: Duration?

    mutating func observe(isOpen: Bool, elapsed: Duration) -> Decision {
        if isOpen {
            appeared = true
            missingSince = nil
        } else if appeared {
            if let missingSince, elapsed - missingSince >= .milliseconds(300) { return .restore }
            if missingSince == nil { missingSince = elapsed }
        } else if elapsed >= .seconds(3) {
            return .restore
        }
        return .wait(elapsed >= .seconds(30) ? .seconds(1) : .milliseconds(100))
    }
}
