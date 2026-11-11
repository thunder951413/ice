//
//  Extensions.swift
//  Ice
//

import Combine
import SwiftUI

// MARK: - Bundle

extension Bundle {
    var copyrightString: String? {
        object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String
    }

    var versionString: String? {
        object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    var buildString: String? {
        object(forInfoDictionaryKey: "CFBundleVersion") as? String
    }
}

// MARK: - CGError

extension CGError {
    var logString: String {
        switch self {
        case .success: "\(rawValue): success"
        case .failure: "\(rawValue): failure"
        case .illegalArgument: "\(rawValue): illegalArgument"
        case .invalidConnection: "\(rawValue): invalidConnection"
        case .invalidContext: "\(rawValue): invalidContext"
        case .cannotComplete: "\(rawValue): cannotComplete"
        case .notImplemented: "\(rawValue): notImplemented"
        case .rangeCheck: "\(rawValue): rangeCheck"
        case .typeCheck: "\(rawValue): typeCheck"
        case .invalidOperation: "\(rawValue): invalidOperation"
        case .noneAvailable: "\(rawValue): noneAvailable"
        @unknown default: "\(rawValue): unknown"
        }
    }
}

// MARK: - Collection where Element == MenuBarItem

extension Collection where Element == MenuBarItem {
    func firstIndex(matching info: MenuBarItemInfo) -> Index? {
        firstIndex { $0.info == info }
    }
}

// MARK: - Comparable

extension Comparable {
    func clamped(to limits: ClosedRange<Self>) -> Self {
        min(max(self, limits.lowerBound), limits.upperBound)
    }
}

// MARK: - EdgeInsets

extension EdgeInsets {
    init(all: CGFloat) {
        self.init(top: all, leading: all, bottom: all, trailing: all)
    }
}

// MARK: - NSApplication

extension NSApplication {
    func window(withIdentifier identifier: String) -> NSWindow? {
        windows.first { $0.identifier?.rawValue == identifier }
    }
}

// MARK: - NSImage

extension NSImage {
    func resized(to size: CGSize) -> NSImage {
        let resizedImage = NSImage(size: size, flipped: false) { bounds in
            self.draw(in: bounds)
            return true
        }
        resizedImage.isTemplate = isTemplate
        return resizedImage
    }
}

// MARK: - NSScreen

extension NSScreen {
    static var screenWithMouse: NSScreen? {
        let location = NSEvent.mouseLocation
        if let screen = screens.first(where: { $0.frame.contains(location) }) {
            return screen
        }
        return screens.first { screen in
            let frame = screen.frame
            return location.x >= frame.minX && location.x < frame.maxX && location.y == frame.maxY
        }
    }

    var menuBarMinY: CGFloat {
        if visibleFrame.maxY < frame.maxY {
            return visibleFrame.maxY
        }
        return frame.maxY - max(NSStatusBar.system.thickness, safeAreaInsets.top)
    }

    func menuBarContains(_ point: CGPoint) -> Bool {
        point.x >= frame.minX && point.x < frame.maxX &&
            point.y >= menuBarMinY && point.y <= frame.maxY
    }

    var displayID: CGDirectDisplayID {
        // swiftlint:disable:next force_cast
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! CGDirectDisplayID
    }

    var hasNotch: Bool {
        safeAreaInsets.top != 0
    }

    var frameOfNotch: CGRect? {
        guard
            let auxiliaryTopLeftArea,
            let auxiliaryTopRightArea
        else {
            return nil
        }
        return CGRect(
            x: auxiliaryTopLeftArea.maxX,
            y: frame.maxY - safeAreaInsets.top,
            width: auxiliaryTopRightArea.minX - auxiliaryTopLeftArea.maxX,
            height: safeAreaInsets.top
        )
    }

    func getMenuBarHeight() -> CGFloat? {
        if visibleFrame.maxY < frame.maxY {
            return frame.maxY - visibleFrame.maxY
        }
        if let menuBarWindow = WindowInfo.getMenuBarWindow(for: displayID) {
            return menuBarWindow.frame.height
        }
        return max(NSStatusBar.system.thickness, safeAreaInsets.top)
    }
}

// MARK: - NSStatusItem

extension NSStatusItem {
    func showMenu(_ menu: NSMenu) {
        let originalMenu = self.menu
        defer {
            self.menu = originalMenu
        }
        self.menu = menu
        button?.performClick(nil)
    }
}

// MARK: - Publisher

extension Publisher {
    func mapToVoid() -> some Publisher<Void, Failure> {
        map { _ in () }
    }
}

// MARK: - Sequence where Element == MenuBarItem

extension Sequence where Element == MenuBarItem {
    func sortedByOrderInMenuBar() -> [MenuBarItem] {
        sorted { lhs, rhs in
            lhs.frame.maxX < rhs.frame.maxX
        }
    }
}
