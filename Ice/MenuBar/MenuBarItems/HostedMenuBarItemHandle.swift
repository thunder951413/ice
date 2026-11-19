//
//  HostedMenuBarItemHandle.swift
//  Ice
//

import ApplicationServices
import Cocoa

/// A menu bar item discovered through Accessibility on macOS 27+, where
/// MenuBarAgent hosts status items instead of publishing one window per item.
final class HostedMenuBarItemHandle: @unchecked Sendable {
    let element: AXUIElement
    let sourcePID: pid_t
    let sourceBundleIdentifier: String?
    let stableID: String
    let title: String?
    let identityStrings: [String]
    let role: String?
    let subrole: String?
    let windowID: CGWindowID?
    let initialFrame: CGRect
    let usesLocalInitialFrame: Bool

    init(
        element: AXUIElement,
        sourcePID: pid_t,
        sourceBundleIdentifier: String?,
        stableID: String,
        title: String?,
        identityStrings: [String],
        role: String?,
        subrole: String?,
        windowID: CGWindowID?,
        initialFrame: CGRect,
        usesLocalInitialFrame: Bool
    ) {
        self.element = element
        self.sourcePID = sourcePID
        self.sourceBundleIdentifier = sourceBundleIdentifier
        self.stableID = stableID
        self.title = title
        self.identityStrings = identityStrings
        self.role = role
        self.subrole = subrole
        self.windowID = windowID
        self.initialFrame = initialFrame
        self.usesLocalInitialFrame = usesLocalInitialFrame
    }

    var currentFrame: CGRect? {
        // MenuBarAgent may leave the source app's AX proxy and its last frame
        // alive after concealment. That rectangle can now belong to a neighbor.
        guard !HostedMenuBarBackend.isConcealed(sourceBundleIdentifier) else {
            return nil
        }
        return HostedMenuBarBackend.renderedFrame(for: self)
    }

    var isOnScreen: Bool {
        if usesLocalInitialFrame {
            return currentFrame != nil
        }
        guard let frame = currentFrame else {
            return false
        }
        return NSScreen.screens.contains { CGDisplayBounds($0.displayID).intersects(frame) }
    }

    func performPress() -> Bool {
        guard
            !HostedMenuBarBackend.isConcealed(sourceBundleIdentifier),
            let rendered = HostedMenuBarBackend.renderedElement(for: self)
        else {
            return false
        }
        return HostedMenuBarBackend.press(rendered)
    }
}
