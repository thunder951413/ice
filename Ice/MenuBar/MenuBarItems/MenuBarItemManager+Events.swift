//
//  MenuBarItemManager+Events.swift
//  Ice
//

import Cocoa

// MARK: - Menu Bar Item Events

extension MenuBarItemManager {
    /// An error that can occur during menu bar item activation operations.
    struct EventError: Error, CustomStringConvertible, LocalizedError {
        enum ErrorCode: Int, CustomStringConvertible {
            case eventCreationFailure
            case invalidItem

            var description: String {
                switch self {
                case .eventCreationFailure: "eventCreationFailure"
                case .invalidItem: "invalidItem"
                }
            }
        }

        let code: ErrorCode
        let item: MenuBarItem

        var description: String {
            "EventError(code: \(code), item: \(item.logString))"
        }

        var errorDescription: String? {
            switch code {
            case .eventCreationFailure:
                "无法为“\(item.displayName)”创建点击事件。"
            case .invalidItem:
                "“\(item.displayName)”当前不在菜单栏可见区域内。"
            }
        }

        var recoverySuggestion: String? {
            "请重试；若问题持续，请确认该应用仍在后台运行。"
        }
    }

    /// Returns the current screen frame for the given hosted item.
    func getCurrentFrame(for item: MenuBarItem) -> CGRect? {
        item.hostedHandle?.currentFrame
    }

    /// Clicks the given menu bar item with the specified mouse button.
    func click(
        item: MenuBarItem,
        with mouseButton: CGMouseButton,
        preferPhysicalClick: Bool = false
    ) async throws {
        guard await HostedMenuBarBackend.refreshRenderedSnapshot() else {
            throw EventError(code: .invalidItem, item: item)
        }
        try Task.checkCancellation()
        if mouseButton == .left, !preferPhysicalClick, item.hostedHandle?.performPress() == true {
            Logger.itemManager.debug("Pressed hosted \(item.logString) through Accessibility")
            return
        }
        try await clickHostedItem(item, with: mouseButton)
    }

    /// Clicks a hosted item by screen coordinate when AXPress is unavailable or right-clicking.
    func clickHostedItem(_ item: MenuBarItem, with mouseButton: CGMouseButton) async throws {
        guard
            let source = CGEventSource(stateID: .hidSystemState),
            let cursorLocation = MouseCursor.locationCoreGraphics,
            let frame = getCurrentFrame(for: item)
        else {
            throw EventError(code: .eventCreationFailure, item: item)
        }
        let eventTypes: (down: CGEventType, up: CGEventType) = switch mouseButton {
        case .left: (.leftMouseDown, .leftMouseUp)
        case .right: (.rightMouseDown, .rightMouseUp)
        default: (.otherMouseDown, .otherMouseUp)
        }
        let point = CGPoint(x: frame.midX, y: frame.midY)
        guard
            let down = CGEvent(
                mouseEventSource: source,
                mouseType: eventTypes.down,
                mouseCursorPosition: point,
                mouseButton: mouseButton
            ),
            let up = CGEvent(
                mouseEventSource: source,
                mouseType: eventTypes.up,
                mouseCursorPosition: point,
                mouseButton: mouseButton
            )
        else {
            throw EventError(code: .eventCreationFailure, item: item)
        }
        MouseCursor.hide()
        defer {
            MouseCursor.warp(to: cursorLocation)
            MouseCursor.show()
        }
        CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?
            .post(tap: .cghidEventTap)
        try await Task.sleep(for: .milliseconds(20))
        try Task.checkCancellation()
        down.post(tap: .cghidEventTap)
        try? await Task.sleep(for: .milliseconds(20))
        up.post(tap: .cghidEventTap)
        try Task.checkCancellation()
    }

    /// Temporarily reveals a hidden hosted item in the menu bar and optionally clicks it.
    func tempShowItem(_ item: MenuBarItem, clickWhenFinished: Bool, mouseButton: CGMouseButton) {
        guard item.hostedHandle != nil, let appState else {
            return
        }
        Task {
            do {
                try await appState.menuBarManager.hostedItemVisibilityManager.withTemporarilyRevealedItem(item) { validate in
                    guard clickWhenFinished else {
                        return
                    }
                    let deadline = ContinuousClock.now.advanced(by: .seconds(4))
                    var attempt = 0
                    repeat {
                        try validate()
                        let descriptors = await HostedMenuBarBackend.refreshEnumeration(force: attempt > 0)
                        attempt += 1
                        let hasRenderedSnapshot = await HostedMenuBarBackend.refreshRenderedSnapshot()
                        let latest = descriptors
                            .map(MenuBarItem.init(hostedHandle:))
                            .first { hasRenderedSnapshot && $0.stableID == item.stableID && $0.isOnScreen }
                        try validate()
                        if let latest {
                            try await self.click(item: latest, with: mouseButton, preferPhysicalClick: true)
                            return
                        }
                        try await Task.sleep(for: .milliseconds(150))
                    } while ContinuousClock.now < deadline
                    throw HostedItemVisibilityManager.RevealError.unavailable
                }
            } catch is CancellationError {
                // Superseded by a newer click, pause, or app shutdown.
            } catch {
                self.presentHostedActivationFailure(item, error: error, mouseButton: mouseButton)
            }
        }
    }

    private func presentHostedActivationFailure(
        _ item: MenuBarItem,
        error: Error,
        mouseButton: CGMouseButton
    ) {
        Logger.itemManager.error("Could not open hosted item: \(error.localizedDescription)")
        let alert = NSAlert()
        alert.messageText = "无法打开“\(item.displayName)”"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "重试")
        if item.owningApplication?.bundleURL != nil {
            alert.addButton(withTitle: "打开应用")
        }
        alert.addButton(withTitle: "取消")
        NSApp.activate()
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            tempShowItem(item, clickWhenFinished: true, mouseButton: mouseButton)
        } else if response == .alertSecondButtonReturn, let url = item.owningApplication?.bundleURL {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
    }
}
