//
//  MenuBarItem.swift
//  Ice
//

import Cocoa

// MARK: - MenuBarItem

/// A representation of an item in the macOS 27 hosted menu bar.
struct MenuBarItem {
    /// The item's window descriptor.
    let window: WindowInfo

    /// The menu bar item info associated with this item.
    let info: MenuBarItemInfo

    /// Accessibility handle for the hosted menu bar item.
    let hostedHandle: HostedMenuBarItemHandle?

    /// Stable identity used across cache refreshes.
    let stableID: String

    /// The identifier of the item's window.
    var windowID: CGWindowID {
        window.windowID
    }

    /// The frame of the item's window.
    var frame: CGRect {
        hostedHandle?.currentFrame ?? window.frame
    }

    /// The title of the item's window.
    var title: String? {
        window.title
    }

    /// A Boolean value that indicates whether the item is on screen.
    var isOnScreen: Bool {
        hostedHandle?.isOnScreen ?? window.isOnScreen
    }

    /// A Boolean value that indicates whether the item can be hidden by Ice.
    var canBeHidden: Bool {
        guard let bundle = hostedHandle?.sourceBundleIdentifier else {
            return false
        }
        return !bundle.hasPrefix("com.apple.") && bundle != Bundle.main.bundleIdentifier
    }

    /// The process identifier of the application that owns the item.
    var ownerPID: pid_t {
        window.ownerPID
    }

    /// The name of the application that owns the item.
    var ownerName: String? {
        window.ownerName
    }

    /// The application that owns the item.
    var owningApplication: NSRunningApplication? {
        window.owningApplication
    }

    /// The bundle identifier of the owning application, if available.
    var bundleIdentifier: String? {
        hostedHandle?.sourceBundleIdentifier ?? owningApplication?.bundleIdentifier
    }

    /// A name associated with the item that is suited for display to the user.
    var displayName: String {
        let fallback = "未知应用"
        guard let owningApplication else {
            return ownerName ?? title ?? fallback
        }
        let bestName = owningApplication.localizedName
            ?? ownerName
            ?? owningApplication.bundleIdentifier
            ?? fallback
        guard let title, !title.isEmpty else {
            return bestName
        }
        return switch MenuBarItemInfo.Namespace(owningApplication.bundleIdentifier) {
        case .controlCenter:
            switch title {
            case "AccessibilityShortcuts": "辅助功能快捷键"
            case "BentoBox": bestName
            case "FocusModes": "专注模式"
            case "KeyboardBrightness": "键盘亮度"
            case "MusicRecognition": "音乐识别"
            case "NowPlaying": "正在播放"
            case "ScreenMirroring": "屏幕镜像"
            case "StageManager": "台前调度"
            case "UserSwitcher": "快速用户切换"
            case "WiFi": "Wi-Fi"
            default: title
            }
        case .systemUIServer:
            switch title {
            case "TimeMachine.TMMenuExtraHost", "TimeMachineMenuExtra.TMMenuExtraHost": "时间机器"
            default: title
            }
        case MenuBarItemInfo.Namespace("com.apple.Passwords.MenuBarExtra"):
            "密码"
        default:
            bestName
        }
    }

    /// A Boolean value that indicates whether the item is currently rendered in the menu bar.
    var isCurrentlyInMenuBar: Bool {
        hostedHandle?.currentFrame != nil
    }

    /// A string to use for logging purposes.
    var logString: String {
        String(describing: info)
    }

    /// Creates an item backed by an Accessibility element.
    init(hostedHandle: HostedMenuBarItemHandle) {
        self.window = WindowInfo(hostedItem: hostedHandle)
        self.info = MenuBarItemInfo(
            namespace: MenuBarItemInfo.Namespace(hostedHandle.sourceBundleIdentifier),
            title: hostedHandle.title ?? ""
        )
        self.hostedHandle = hostedHandle
        self.stableID = "hosted:\(hostedHandle.stableID)"
    }
}

// MARK: MenuBarItem Getters
extension MenuBarItem {
    /// Returns an array of the current menu bar items in the hosted menu bar.
    static func getMenuBarItems(
        on display: CGDirectDisplayID? = nil,
        onScreenOnly: Bool,
        activeSpaceOnly: Bool = true,
        forceRefresh: Bool = false
    ) -> [MenuBarItem] {
        _ = activeSpaceOnly
        return HostedMenuBarBackend.enumerate(forceRefresh: forceRefresh).lazy
            .map(MenuBarItem.init(hostedHandle:))
            .filter { item in
                guard let display else {
                    return true
                }
                return CGDisplayBounds(display).intersects(item.frame)
            }
            .filter { item in
                !onScreenOnly || item.isOnScreen
            }
            .sortedByOrderInMenuBar()
    }
}

// MARK: MenuBarItem: Equatable
extension MenuBarItem: Equatable {
    static func == (lhs: MenuBarItem, rhs: MenuBarItem) -> Bool {
        lhs.stableID == rhs.stableID
            && lhs.ownerPID == rhs.ownerPID
            && lhs.info == rhs.info
            && lhs.window.frame == rhs.window.frame
            && lhs.window.isOnScreen == rhs.window.isOnScreen
    }
}

// MARK: MenuBarItem: Hashable
extension MenuBarItem: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(stableID)
        hasher.combine(ownerPID)
        hasher.combine(info)
        hasher.combine(NSStringFromRect(window.frame))
        hasher.combine(window.isOnScreen)
    }
}
