//
//  HostedItemMaskManager.swift
//  Ice
//

import Cocoa
import Combine

/// Visually hides accessibility-hosted status items without changing another
/// application's preferences or MenuBarAgent's persistent layout.
///
/// Newer macOS releases render third-party status items in a shared host. Those
/// items cannot be moved safely and the system visibility switch is backed by a
/// protected Control Center service. A mask is intentionally less invasive: the
/// real item remains alive and actionable, and every item becomes visible again
/// automatically if Ice exits.
@MainActor
final class HostedItemMaskManager {
    private final class MaskPanel: NSPanel {
        let stableID: String
        private let imageView = NSImageView()

        init(stableID: String) {
            self.stableID = stableID
            super.init(
                contentRect: .zero,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
            backgroundColor = .clear
            isOpaque = false
            hasShadow = false
            ignoresMouseEvents = false
            collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
            isReleasedWhenClosed = false
            animationBehavior = .none

            imageView.imageAlignment = .alignCenter
            imageView.imageScaling = .scaleAxesIndependently
            imageView.wantsLayer = true
            imageView.layer?.masksToBounds = true
            contentView = imageView
        }

        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }

        func update(frame: CGRect, background: CGImage?) {
            setFrame(frame, display: false)
            if let background {
                imageView.image = NSImage(cgImage: background, size: frame.size)
                imageView.layer?.backgroundColor = nil
            } else {
                // Screen capture can be transiently unavailable during a space
                // change. Use the system menu material as a non-black fallback.
                imageView.image = nil
                imageView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            }
            orderFrontRegardless()
        }
    }

    private weak var appState: AppState?
    private var panels = [String: MaskPanel]()
    private var temporarilyRevealedIDs = Set<String>()
    private var cancellables = Set<AnyCancellable>()
    private var refreshTask: Task<Void, Never>?

    private var isSupported: Bool {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26
    }

    init(appState: AppState) {
        self.appState = appState
    }

    deinit {
        refreshTask?.cancel()
    }

    func performSetup() {
        guard isSupported, let appState else {
            return
        }

        var c = Set<AnyCancellable>()
        appState.itemManager.$itemCache
            .mapToVoid()
            .sink { [weak self] in self?.scheduleRefresh() }
            .store(in: &c)

        appState.settingsManager.generalSettingsManager.$useIceBar
            .mapToVoid()
            .sink { [weak self] in self?.scheduleRefresh() }
            .store(in: &c)

        Publishers.MergeMany(appState.menuBarManager.sections.map { $0.controlItem.$state.mapToVoid() })
            .sink { [weak self] in self?.scheduleRefresh() }
            .store(in: &c)

        Publishers.Merge4(
            NSWorkspace.shared.notificationCenter
                .publisher(for: NSWorkspace.activeSpaceDidChangeNotification)
                .mapToVoid(),
            NotificationCenter.default
                .publisher(for: NSApplication.didChangeScreenParametersNotification)
                .mapToVoid(),
            DistributedNotificationCenter.default()
                .publisher(for: DistributedNotificationCenter.interfaceThemeChangedNotification)
                .mapToVoid(),
            Timer.publish(every: 5, on: .main, in: .common)
                .autoconnect()
                .mapToVoid()
        )
        .sink { [weak self] in self?.scheduleRefresh(delay: .milliseconds(100)) }
        .store(in: &c)

        cancellables = c
        scheduleRefresh()
    }

    /// Removes every mask. This is also naturally guaranteed by process exit,
    /// but doing it explicitly makes clean termination and reset immediate.
    func removeAllMasks() {
        refreshTask?.cancel()
        refreshTask = nil
        panels.values.forEach { $0.orderOut(nil) }
        panels.removeAll()
        temporarilyRevealedIDs.removeAll()
    }

    /// Makes one real status item hittable for the duration of a coordinate
    /// event. AXPress does not require this path.
    func withItemTemporarilyUnmasked<T>(
        stableID: String,
        operation: () async throws -> T
    ) async rethrows -> T {
        temporarilyRevealedIDs.insert(stableID)
        panels[stableID]?.orderOut(nil)
        // Give WindowServer one display transaction before posting the click.
        try? await Task.sleep(for: .milliseconds(20))
        defer {
            temporarilyRevealedIDs.remove(stableID)
            scheduleRefresh(delay: .milliseconds(80))
        }
        return try await operation()
    }

    func refreshNow() {
        refreshTask?.cancel()
        refreshTask = nil
        refresh()
    }

    private func scheduleRefresh(delay: Duration = .milliseconds(25)) {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else {
                return
            }
            self?.refreshTask = nil
            self?.refresh()
        }
    }

    private func refresh() {
        guard
            isSupported,
            let appState,
            !appState.isActiveSpaceFullscreen,
            !appState.menuBarManager.isMenuBarHiddenBySystem
        else {
            panels.values.forEach { $0.orderOut(nil) }
            return
        }

        let useIceBar = appState.settingsManager.generalSettingsManager.useIceBar
        var desired = [String: MenuBarItem]()
        for sectionName in [MenuBarSection.Name.hidden, .alwaysHidden] {
            guard let section = appState.menuBarManager.section(withName: sectionName) else {
                continue
            }
            let shouldMask = useIceBar || section.isHidden
            guard shouldMask else {
                continue
            }
            for item in appState.itemManager.itemCache.managedItems(for: sectionName) where item.hostedHandle != nil {
                guard
                    item.ownerPID != ProcessInfo.processInfo.processIdentifier,
                    !temporarilyRevealedIDs.contains(item.stableID),
                    let frame = item.hostedHandle?.currentFrame,
                    isValidStatusItemFrame(frame)
                else {
                    continue
                }
                desired[item.stableID] = item
            }
        }

        for (stableID, panel) in panels where desired[stableID] == nil {
            panel.orderOut(nil)
            panels.removeValue(forKey: stableID)
        }

        for (stableID, item) in desired {
            guard
                let frame = item.hostedHandle?.currentFrame,
                let screen = screen(containingCoreGraphicsFrame: frame)
            else {
                continue
            }
            let panel = panels[stableID] ?? MaskPanel(stableID: stableID)
            panels[stableID] = panel

            // Capture only the WindowServer's menu bar background window. It
            // excludes status-item content, producing a seamless, non-black mask.
            let background = WindowInfo.getMenuBarWindow(for: screen.displayID).flatMap {
                ScreenCapture.captureWindow($0.windowID, screenBounds: frame, option: .nominalResolution)
            }
            panel.update(frame: appKitFrame(fromCoreGraphicsFrame: frame), background: background)
        }
    }

    private func isValidStatusItemFrame(_ frame: CGRect) -> Bool {
        guard frame.width > 0, frame.width <= 500, frame.height > 0, frame.height <= 80 else {
            return false
        }
        return NSScreen.screens.contains { screen in
            let bounds = CGDisplayBounds(screen.displayID)
            return frame.minY <= bounds.minY + 80 && frame.intersects(bounds)
        }
    }

    private func screen(containingCoreGraphicsFrame frame: CGRect) -> NSScreen? {
        NSScreen.screens.first { CGDisplayBounds($0.displayID).intersects(frame) }
    }

    private func appKitFrame(fromCoreGraphicsFrame frame: CGRect) -> CGRect {
        let mainDisplayHeight = CGDisplayBounds(CGMainDisplayID()).height
        return CGRect(
            x: frame.minX,
            y: mainDisplayHeight - frame.maxY,
            width: frame.width,
            height: frame.height
        )
    }
}
