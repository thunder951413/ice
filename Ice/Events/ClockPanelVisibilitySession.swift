//
//  ClockPanelVisibilitySession.swift
//  Ice
//

import CoreGraphics
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

    /// Matches Notification Center's panel window with or without Screen
    /// Recording permission, while ignoring compact notification banners.
    static func isNotificationCenterWindow(
        title: String?,
        frame: CGRect,
        displayBounds: [CGRect]
    ) -> Bool {
        if title == "Notification Center" {
            return true
        }
        guard frame.width > 0, frame.height > 0 else {
            return false
        }
        return displayBounds.contains { bounds in
            guard bounds.width > 0, bounds.height > 0, frame.intersects(bounds) else {
                return false
            }
            let coversDisplay = abs(frame.minX - bounds.minX) < 2 &&
                abs(frame.minY - bounds.minY) < 2 &&
                frame.width >= bounds.width * 0.8 &&
                frame.height >= bounds.height * 0.8
            if coversDisplay {
                return true
            }
            // Without Screen Recording permission, window titles are redacted and
            // Notification Center may appear as a tall trailing-edge panel rather
            // than a full-display backdrop window.
            let isTrailingPanel = abs(frame.maxX - bounds.maxX) <= 24 &&
                frame.minY <= bounds.minY + 60 &&
                frame.width >= 280 &&
                frame.height >= bounds.height * 0.5
            return isTrailingPanel
        }
    }
}
