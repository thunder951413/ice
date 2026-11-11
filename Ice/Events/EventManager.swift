//
//  EventManager.swift
//  Ice
//

import Cocoa
import Combine

/// Manager for the mouse event monitors maintained by the app.
@MainActor
final class EventManager {
    /// The shared app state.
    private weak var appState: AppState?

    /// A native Clock click needs an assertion-free interval while Notification Center / Calendar is open.
    private var clockMouseDownPoint: CGPoint?
    private var clockBaselineWindowIDs = Set<CGWindowID>()
    private var clockActivationTask: Task<Void, Never>?
    private var isSynthesizingClockClick = false

    private var menuBarWindowFrameCache: (displayID: CGDirectDisplayID, date: ContinuousClock.Instant, frame: CGRect?)?

    // MARK: Monitors

    /// Monitor for mouse down events.
    private(set) lazy var mouseDownMonitor = UniversalEventMonitor(
        mask: [.leftMouseDown, .rightMouseDown]
    ) { [weak self] event in
        guard let self, !isSynthesizingClockClick else {
            return event
        }
        switch event.type {
        case .leftMouseDown:
            handleClockMouseDown(with: event)
            handleShowOnClick(with: event)
            handleSmartRehide(with: event)
        case .rightMouseDown:
            handleShowRightClickMenu(with: event)
        default:
            break
        }
        return event
    }

    /// Monitor for mouse up events.
    private(set) lazy var mouseUpMonitor = UniversalEventMonitor(
        mask: .leftMouseUp
    ) { [weak self] event in
        guard let self, !isSynthesizingClockClick else {
            return event
        }
        handleClockMouseUp(with: event)
        return event
    }

    private lazy var allMonitors = [
        mouseDownMonitor,
        mouseUpMonitor,
    ]

    init(appState: AppState) {
        self.appState = appState
    }

    func performSetup() {
        startAll()
    }

    func startAll() {
        for monitor in allMonitors {
            monitor.start()
        }
    }

    func stopAll() {
        clockActivationTask?.cancel()
        clockActivationTask = nil
        clockMouseDownPoint = nil
        clockBaselineWindowIDs.removeAll()
        isSynthesizingClockClick = false
        for monitor in allMonitors {
            monitor.stop()
        }
    }
}

// MARK: - Handlers

extension EventManager {
    private func handleShowOnClick(with event: NSEvent) {
        guard
            let appState,
            appState.settingsManager.generalSettingsManager.showOnClick,
            isMouseInsideMenuBar,
            !isMouseInsideNotch
        else {
            return
        }

        let modifiers = MenuBarClickPolicy.ModifierSnapshot(
            option: event.modifierFlags.contains(.option),
            control: event.modifierFlags.contains(.control)
        )
        let menuLocation = MouseCursor.locationAppKit
        Task {
            guard
                await isEmptyMenuBarClick(event),
                appState.settingsManager.generalSettingsManager.showOnClick
            else {
                return
            }
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return }

            let general = appState.settingsManager.generalSettingsManager
            let action = MenuBarClickPolicy.resolve(
                button: .primary,
                modifiers: modifiers,
                allowsAlwaysHidden: general.enableAlwaysHiddenSection && general.canToggleAlwaysHiddenSection
            )
            switch action {
            case .showMenu:
                if let menuLocation, general.showContextMenuOnRightClick {
                    appState.menuBarManager.showRightClickMenu(at: menuLocation)
                }
            case .toggleAlwaysHidden:
                appState.menuBarManager.section(withName: .alwaysHidden)?.toggle()
            case .toggleHidden:
                appState.menuBarManager.section(withName: .hidden)?.toggle()
            }
        }
    }

    private func handleSmartRehide(with event: NSEvent) {
        guard
            let appState,
            appState.settingsManager.generalSettingsManager.autoRehide,
            case .smart = appState.settingsManager.generalSettingsManager.rehideStrategy
        else {
            return
        }

        if let visibleSection = appState.menuBarManager.section(withName: .visible) {
            guard event.window !== visibleSection.controlItem.window else {
                return
            }
        }

        guard event.window !== appState.menuBarManager.iceBarPanel else {
            return
        }

        guard appState.menuBarManager.sections.contains(where: { !$0.isHidden }) else {
            return
        }

        guard !isMouseInsideMenuBar else {
            return
        }

        let presentationGeneration = appState.menuBarManager.iceBarPanel.presentationGeneration
        Task {
            let initialSpaceID = Bridging.activeSpaceID

            try? await Task.sleep(for: .seconds(0.25))
            guard presentationGeneration == appState.menuBarManager.iceBarPanel.presentationGeneration else {
                return
            }

            if Bridging.activeSpaceID != initialSpaceID {
                appState.menuBarManager.iceBarPanel.close()
                return
            }

            guard
                let mouseLocation = MouseCursor.locationCoreGraphics,
                let windowUnderMouse = WindowInfo.getOnScreenWindows(excludeDesktopWindows: false)
                    .filter({ $0.layer < CGWindowLevelForKey(.cursorWindow) })
                    .first(where: {
                        $0.frame.contains(mouseLocation)
                            && $0.alpha > 0
                            && $0.windowID != kCGNullWindowID
                            && !$0.isWindowServerWindow
                    }),
                let owningApplication = windowUnderMouse.owningApplication
            else {
                return
            }

            if owningApplication.bundleIdentifier != "com.apple.dock" {
                guard
                    owningApplication.isActive,
                    owningApplication.activationPolicy == .regular
                else {
                    return
                }
            }

            appState.menuBarManager.iceBarPanel.close()
        }
    }

    private func handleShowRightClickMenu(with event: NSEvent) {
        guard
            let appState,
            appState.settingsManager.generalSettingsManager.showContextMenuOnRightClick,
            isMouseInsideMenuBar,
            !isMouseInsideNotch,
            let mouseLocation = MouseCursor.locationAppKit
        else {
            return
        }
        Task {
            guard
                await isEmptyMenuBarClick(event),
                appState.settingsManager.generalSettingsManager.showContextMenuOnRightClick
            else {
                return
            }
            appState.menuBarManager.showRightClickMenu(at: mouseLocation)
        }
    }

    private func isEmptyMenuBarClick(_ event: NSEvent) async -> Bool {
        guard
            let appState,
            let screen = bestScreen,
            let point = event.cgEvent?.location ?? MouseCursor.locationCoreGraphics
        else {
            return false
        }
        let displayID = screen.displayID
        let bounds = CGDisplayBounds(displayID)
        let menuOwner = NSWorkspace.shared.menuBarOwningApplication?.processIdentifier
        let menuFrame = appState.menuBarManager.getApplicationMenuFrame(for: displayID, maxAge: .zero)
        guard ApplicationMenuGeometry.isEmptySpace(at: point, applicationMenuFrame: menuFrame) else {
            return false
        }
        if HostedMenuBarBackend.renderedItemFrameSnapshot() == nil {
            guard await HostedMenuBarBackend.refreshRenderedSnapshot() else {
                return false
            }
        }
        guard
            !Task.isCancelled,
            NSWorkspace.shared.menuBarOwningApplication?.processIdentifier == menuOwner,
            NSScreen.screens.contains(where: { $0.displayID == displayID })
        else {
            return false
        }
        return ApplicationMenuGeometry.isEmptyHostedSpace(
            at: point,
            applicationMenuFrame: menuFrame,
            itemFrames: HostedMenuBarBackend.renderedItemFrameSnapshot(),
            displayBounds: bounds
        )
    }

    // MARK: Handle System Clock (macOS 27+)

    private func handleClockMouseDown(with event: NSEvent) {
        clockMouseDownPoint = nil
        clockBaselineWindowIDs.removeAll()
        guard
            let appState,
            appState.menuBarManager.hostedItemVisibilityManager.needsClockActivationBridge,
            clockActivationTask == nil,
            event.modifierFlags.isDisjoint(with: [.command, .control, .option]),
            let location = event.cgEvent?.location ?? MouseCursor.locationCoreGraphics,
            isMouseInsideMenuBar || Self.isPointInMenuBarBand(location)
        else {
            return
        }
        if HostedMenuBarBackend.renderedItemFrameSnapshot() != nil,
           HostedMenuBarBackend.systemClockFrame(at: location) == nil {
            return
        }
        guard !Self.isClockPanelOpen() else {
            return
        }
        clockBaselineWindowIDs = Set(WindowInfo.getOnScreenWindows().map(\.windowID))
        clockMouseDownPoint = location
    }

    private func handleClockMouseUp(with event: NSEvent) {
        guard let downPoint = clockMouseDownPoint else {
            return
        }
        let baselineIDs = clockBaselineWindowIDs
        clockMouseDownPoint = nil
        clockBaselineWindowIDs.removeAll()
        guard
            let appState,
            let location = event.cgEvent?.location ?? MouseCursor.locationCoreGraphics,
            hypot(location.x - downPoint.x, location.y - downPoint.y) <= 6,
            let screen = NSScreen.screens.first(where: {
                CGDisplayBounds($0.displayID).insetBy(dx: -2, dy: -2).contains(location)
            })
        else {
            return
        }

        let visibility = appState.menuBarManager.hostedItemVisibilityManager
        clockActivationTask = Task { @MainActor [weak self] in
            defer { self?.clockActivationTask = nil }
            guard
                await !Self.waitForClockPanel(baselineWindowIDs: baselineIDs, within: .milliseconds(80)),
                !Task.isCancelled
            else {
                return
            }
            if HostedMenuBarBackend.systemClockFrame(at: downPoint) == nil {
                guard await HostedMenuBarBackend.refreshRenderedSnapshot() else {
                    return
                }
            }
            guard
                let initialClockFrame = HostedMenuBarBackend.systemClockFrame(at: downPoint, allowingStale: true),
                HostedMenuBarBackend.systemClockFrame(at: location, allowingStale: true) != nil,
                visibility.beginClockActivationBridge()
            else {
                return
            }
            defer { visibility.endClockActivationBridge() }
            appState.menuBarManager.iceBarPanel.close()

            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }

            var didActivate = Self.isClockPanelOpen(baselineWindowIDs: baselineIDs)
            for attempt in 0..<3 where !didActivate {
                guard !Task.isCancelled else {
                    return
                }
                _ = await HostedMenuBarBackend.refreshRenderedSnapshot()
                if Self.isClockPanelOpen(baselineWindowIDs: baselineIDs) {
                    didActivate = true
                    break
                }
                let clockFrame = HostedMenuBarBackend.systemClockFrame(on: screen.displayID) ?? initialClockFrame
                let clickPoint = CGPoint(x: clockFrame.midX, y: clockFrame.midY)
                guard await self?.postSyntheticClockClick(at: clickPoint) == true else {
                    break
                }
                let waitBudget: Duration = attempt == 0 ? .milliseconds(160) : .milliseconds(320)
                if await Self.waitForClockPanel(baselineWindowIDs: baselineIDs, within: waitBudget) {
                    didActivate = true
                    break
                }
            }
            guard didActivate else {
                return
            }

            var session = ClockPanelVisibilitySession()
            let started = ContinuousClock.now
            while true {
                guard !Task.isCancelled else {
                    return
                }
                let isOpen = Self.isClockPanelOpen(baselineWindowIDs: baselineIDs)
                switch session.observe(isOpen: isOpen, elapsed: started.duration(to: .now)) {
                case .restore:
                    return
                case .wait(let interval):
                    do { try await Task.sleep(for: interval) } catch { return }
                }
            }
        }
    }

    /// Clicks the rendered Clock by screen coordinate rather than `AXPress`.
    /// On macOS 27.2, `AXPress` on `com.apple.menuextra.clock` fires both open
    /// and close ~80ms apart, immediately dismissing Notification Center / Calendar.
    private func postSyntheticClockClick(at point: CGPoint) async -> Bool {
        guard
            let source = CGEventSource(stateID: .hidSystemState),
            let cursorLocation = MouseCursor.locationCoreGraphics,
            let down = CGEvent(
                mouseEventSource: source,
                mouseType: .leftMouseDown,
                mouseCursorPosition: point,
                mouseButton: .left
            ),
            let up = CGEvent(
                mouseEventSource: source,
                mouseType: .leftMouseUp,
                mouseCursorPosition: point,
                mouseButton: .left
            )
        else {
            return false
        }
        down.setIntegerValueField(.mouseEventClickState, value: 1)
        up.setIntegerValueField(.mouseEventClickState, value: 1)

        isSynthesizingClockClick = true
        MouseCursor.hide()
        defer {
            MouseCursor.warp(to: cursorLocation)
            MouseCursor.show()
            isSynthesizingClockClick = false
        }
        CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?
            .post(tap: .cghidEventTap)
        do { try await Task.sleep(for: .milliseconds(15)) } catch { return false }
        down.post(tap: .cghidEventTap)
        try? await Task.sleep(for: .milliseconds(20))
        up.post(tap: .cghidEventTap)
        try? await Task.sleep(for: .milliseconds(25))
        return !Task.isCancelled
    }

    private static func isPointInMenuBarBand(_ point: CGPoint) -> Bool {
        NSScreen.screens.contains { screen in
            let bounds = CGDisplayBounds(screen.displayID).insetBy(dx: -2, dy: -2)
            return bounds.contains(point) && point.y <= bounds.minY + 52
        }
    }

    private static func waitForClockPanel(
        baselineWindowIDs: Set<CGWindowID>,
        within timeout: Duration
    ) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        repeat {
            do { try await Task.sleep(for: .milliseconds(40)) } catch { return false }
            if isClockPanelOpen(baselineWindowIDs: baselineWindowIDs) {
                return true
            }
        } while ContinuousClock.now < deadline
        return false
    }

    private static func isClockPanelOpen(baselineWindowIDs: Set<CGWindowID> = []) -> Bool {
        let displayBounds = NSScreen.screens.map { CGDisplayBounds($0.displayID) }
        let floatingLayer = Int(CGWindowLevelForKey(.floatingWindow))
        let windows = WindowInfo.getOnScreenWindows().map { window in
            ClockPanelVisibilitySession.SystemWindowSnapshot(
                id: window.windowID,
                bundleIdentifier: window.owningApplication?.bundleIdentifier,
                title: window.title,
                frame: window.frame,
                layer: window.layer,
                alpha: Double(window.alpha)
            )
        }
        return ClockPanelVisibilitySession.isClockPanelOpen(
            windows: windows,
            baselineWindowIDs: baselineWindowIDs,
            floatingLayerMinimum: floatingLayer,
            displayBounds: displayBounds
        )
    }
}

// MARK: - Helpers

extension EventManager {
    var bestScreen: NSScreen? {
        NSScreen.screenWithMouse ?? NSScreen.main
    }

    var isMouseInsideMenuBar: Bool {
        guard
            let screen = bestScreen,
            let appState
        else {
            return false
        }
        if appState.menuBarManager.isMenuBarHiddenBySystem || appState.isActiveSpaceFullscreen {
            if
                let mouseLocation = MouseCursor.locationCoreGraphics,
                let menuBarFrame = menuBarWindowFrame(for: screen.displayID)
            {
                return menuBarFrame.contains(mouseLocation)
            }
        } else if let mouseLocation = MouseCursor.locationAppKit {
            return mouseLocation.x >= screen.frame.minX
                && mouseLocation.x < screen.frame.maxX
                && mouseLocation.y > screen.visibleFrame.maxY
                && mouseLocation.y <= screen.frame.maxY
        }
        return false
    }

    private func menuBarWindowFrame(for displayID: CGDirectDisplayID) -> CGRect? {
        let now = ContinuousClock.now
        if let cached = menuBarWindowFrameCache, cached.displayID == displayID,
           cached.date.duration(to: now) < .milliseconds(100) {
            return cached.frame
        }
        let frame = WindowInfo.getMenuBarWindow(for: displayID)?.frame
        menuBarWindowFrameCache = (displayID, now, frame)
        return frame
    }

    var isMouseInsideNotch: Bool {
        guard
            let screen = bestScreen,
            let mouseLocation = MouseCursor.locationAppKit,
            let frameOfNotch = screen.frameOfNotch
        else {
            return false
        }
        return frameOfNotch.contains(mouseLocation)
    }

    var isMouseInsideEmptyMenuBarSpace: Bool {
        guard
            isMouseInsideMenuBar,
            !isMouseInsideNotch,
            let appState,
            let screen = bestScreen,
            let point = MouseCursor.locationCoreGraphics
        else {
            return false
        }
        let applicationMenuFrame = appState.menuBarManager.getApplicationMenuFrame(for: screen.displayID)
        guard ApplicationMenuGeometry.isEmptySpace(
            at: point,
            applicationMenuFrame: applicationMenuFrame
        ) else {
            return false
        }
        return ApplicationMenuGeometry.isEmptyHostedSpace(
            at: point,
            applicationMenuFrame: applicationMenuFrame,
            itemFrames: HostedMenuBarBackend.renderedItemFrameSnapshot(),
            displayBounds: CGDisplayBounds(screen.displayID)
        )
    }

    var isMouseInsideIceBar: Bool {
        guard
            let appState,
            let mouseLocation = MouseCursor.locationAppKit
        else {
            return false
        }
        let panel = appState.menuBarManager.iceBarPanel
        guard panel.isVisible else {
            return false
        }
        return panel.frame.insetBy(dx: -10, dy: -10).contains(mouseLocation)
    }
}
