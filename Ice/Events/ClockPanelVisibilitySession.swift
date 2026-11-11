//
//  ClockPanelVisibilitySession.swift
//  Ice
//

import CoreGraphics
import Foundation

/// Tracks Notification Center or Calendar popover visibility while the clock
/// activation bridge is active on macOS 27+.
struct ClockPanelVisibilitySession {
    struct SystemWindowSnapshot {
        let id: CGWindowID
        let bundleIdentifier: String?
        let title: String?
        let frame: CGRect
        let layer: Int
        let alpha: Double
    }

    enum Decision: Equatable {
        case wait(Duration)
        case restore
    }

    private static let clockHostBundles: Set<String> = [
        "com.apple.notificationcenterui",
        "com.apple.MenuBarAgent",
        "com.apple.controlcenter",
    ]

    private var appeared = false
    private var missingSince: Duration?

    /// `MBAssessmentModeAssertion` suppresses Notification Center and Calendar
    /// from opening on macOS 27.x (including 27.2), so clicking Date/Clock
    /// requires releasing the assertion until the panel closes.
    static func requiresActivationBridge(operatingSystemVersion version: OperatingSystemVersion) -> Bool {
        version.majorVersion >= 27
    }

    mutating func observe(isOpen: Bool, elapsed: Duration) -> Decision {
        if isOpen {
            appeared = true
            missingSince = nil
        } else if appeared {
            if let missingSince, elapsed - missingSince >= .milliseconds(300) {
                return .restore
            }
            if missingSince == nil {
                missingSince = elapsed
            }
        } else if elapsed >= .seconds(3) {
            return .restore
        }
        return .wait(elapsed >= .seconds(30) ? .seconds(1) : .milliseconds(100))
    }

    /// Matches Notification Center or Calendar popover windows with or without
    /// Screen Recording permission, while ignoring compact notification banners.
    static func isNotificationCenterWindow(
        title: String?,
        frame: CGRect,
        displayBounds: [CGRect]
    ) -> Bool {
        if title == "Notification Center" || title == "Calendar" {
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
            // Match top-right Notification Center and Calendar popovers (>= 180pt)
            // while excluding compact notification banners (~60–120pt tall).
            let isTrailingPanel = abs(frame.maxX - bounds.maxX) <= 32 &&
                frame.minY <= bounds.minY + 60 &&
                frame.width >= 240 &&
                frame.height >= 180
            return isTrailingPanel
        }
    }

    /// Detects whether Notification Center or the Date/Calendar popover is open,
    /// including newly ordered-in popover windows from `MenuBarAgent` or `ControlCenter`.
    static func isClockPanelOpen(
        windows: [SystemWindowSnapshot],
        baselineWindowIDs: Set<CGWindowID> = [],
        floatingLayerMinimum: Int,
        displayBounds: [CGRect]
    ) -> Bool {
        windows.contains { window in
            guard window.alpha > 0,
                  let bundle = window.bundleIdentifier,
                  clockHostBundles.contains(bundle)
            else {
                return false
            }
            if bundle == "com.apple.notificationcenterui",
               isNotificationCenterWindow(
                   title: window.title,
                   frame: window.frame,
                   displayBounds: displayBounds
               ) {
                return true
            }
            guard !baselineWindowIDs.contains(window.id),
                  window.layer >= floatingLayerMinimum,
                  window.frame.width >= 200,
                  window.frame.height >= 180
            else {
                return false
            }
            return displayBounds.contains { $0.intersects(window.frame) }
        }
    }
}
