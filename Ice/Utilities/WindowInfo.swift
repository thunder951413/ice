//
//  WindowInfo.swift
//  Ice
//

import Cocoa

/// Information for a window.
struct WindowInfo {
    let windowID: CGWindowID
    let frame: CGRect
    let title: String?
    let layer: Int
    let alpha: Double
    let ownerPID: pid_t
    let ownerName: String?
    let sharingState: CGWindowSharingType
    let backingStoreType: CGWindowBackingType
    let memoryUsage: Measurement<UnitInformationStorage>
    let isOnScreen: Bool
    let isBackedByVideoMemory: Bool

    var owningApplication: NSRunningApplication? {
        NSRunningApplication(processIdentifier: ownerPID)
    }

    var isMenuBarItem: Bool {
        layer == kCGStatusWindowLevel
    }

    var isWindowServerWindow: Bool {
        ownerName == "Window Server"
    }

    var isOnActiveSpace: Bool {
        Bridging.isWindowOnActiveSpace(windowID)
    }

    init(hostedItem: HostedMenuBarItemHandle) {
        self.windowID = hostedItem.windowID ?? kCGNullWindowID
        self.frame = hostedItem.initialFrame
        self.title = hostedItem.title
        self.layer = Int(kCGStatusWindowLevel)
        self.alpha = 1
        self.ownerPID = hostedItem.sourcePID
        self.ownerName = NSRunningApplication(processIdentifier: hostedItem.sourcePID)?.localizedName
        self.sharingState = CGWindowSharingType(rawValue: 1) ?? .none
        self.backingStoreType = .backingStoreBuffered
        self.memoryUsage = Measurement(value: 0, unit: .bytes)
        self.isOnScreen = NSScreen.screens.contains { screen in
            CGDisplayBounds(screen.displayID).intersects(hostedItem.initialFrame)
        }
        self.isBackedByVideoMemory = false
    }

    private init?(dictionary: CFDictionary) {
        guard
            let info = dictionary as? [CFString: CFTypeRef],
            let windowID = info[kCGWindowNumber] as? CGWindowID,
            let boundsDict = info[kCGWindowBounds] as? NSDictionary,
            let frame = CGRect(dictionaryRepresentation: boundsDict),
            let layer = info[kCGWindowLayer] as? Int,
            let alpha = info[kCGWindowAlpha] as? Double,
            let ownerPID = info[kCGWindowOwnerPID] as? pid_t,
            let rawSharingState = info[kCGWindowSharingState] as? UInt32,
            let rawBackingStoreType = info[kCGWindowStoreType] as? UInt32,
            let sharingState = CGWindowSharingType(rawValue: rawSharingState),
            let backingStoreType = CGWindowBackingType(rawValue: rawBackingStoreType),
            let memoryUsage = info[kCGWindowMemoryUsage] as? Double
        else {
            return nil
        }
        self.windowID = windowID
        self.frame = frame
        self.title = info[kCGWindowName] as? String
        self.layer = layer
        self.alpha = alpha
        self.ownerPID = ownerPID
        self.ownerName = info[kCGWindowOwnerName] as? String
        self.sharingState = sharingState
        self.backingStoreType = backingStoreType
        self.memoryUsage = Measurement(value: memoryUsage, unit: .bytes)
        self.isOnScreen = info[kCGWindowIsOnscreen] as? Bool ?? false
        self.isBackedByVideoMemory = info[kCGWindowBackingLocationVideoMemory] as? Bool ?? false
    }
}

// MARK: - WindowList Operations

extension WindowInfo {
    static func getOnScreenWindows(excludeDesktopWindows: Bool = false) -> [WindowInfo] {
        var option: CGWindowListOption = [.optionOnScreenOnly]
        if excludeDesktopWindows {
            option.insert(.excludeDesktopElements)
        }
        guard let list = CGWindowListCopyWindowInfo(option, kCGNullWindowID) as? [CFDictionary] else {
            return []
        }
        return list.compactMap { WindowInfo(dictionary: $0) }
    }

    static func getMenuBarWindow(from windows: [WindowInfo], for display: CGDirectDisplayID) -> WindowInfo? {
        let displayBounds = CGDisplayBounds(display)
        return windows.first { window in
            window.isWindowServerWindow &&
                window.isOnScreen &&
                window.layer == kCGMainMenuWindowLevel &&
                (window.title == "Menubar" || (abs(window.frame.width - displayBounds.width) <= 2 && window.frame.height <= 80)) &&
                displayBounds.intersects(window.frame)
        }
    }

    static func getMenuBarWindow(for display: CGDirectDisplayID) -> WindowInfo? {
        getMenuBarWindow(from: getOnScreenWindows(excludeDesktopWindows: true), for: display)
    }
}

// MARK: WindowInfo: Equatable
extension WindowInfo: Equatable {
    static func == (lhs: WindowInfo, rhs: WindowInfo) -> Bool {
        lhs.windowID == rhs.windowID &&
            NSStringFromRect(lhs.frame) == NSStringFromRect(rhs.frame) &&
            lhs.title == rhs.title &&
            lhs.layer == rhs.layer &&
            lhs.alpha == rhs.alpha &&
            lhs.ownerPID == rhs.ownerPID &&
            lhs.ownerName == rhs.ownerName &&
            lhs.sharingState == rhs.sharingState &&
            lhs.backingStoreType == rhs.backingStoreType &&
            lhs.memoryUsage == rhs.memoryUsage &&
            lhs.isOnScreen == rhs.isOnScreen &&
            lhs.isBackedByVideoMemory == rhs.isBackedByVideoMemory
    }
}

// MARK: WindowInfo: Hashable
extension WindowInfo: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(windowID)
        hasher.combine(NSStringFromRect(frame))
        hasher.combine(title)
        hasher.combine(layer)
        hasher.combine(alpha)
        hasher.combine(ownerPID)
        hasher.combine(ownerName)
        hasher.combine(sharingState)
        hasher.combine(backingStoreType)
        hasher.combine(memoryUsage)
        hasher.combine(isOnScreen)
        hasher.combine(isBackedByVideoMemory)
    }
}
