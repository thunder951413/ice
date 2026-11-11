//
//  IceBar.swift
//  Ice
//

import Combine
import SwiftUI

// MARK: - IceBarPanel

final class IceBarPanel: NSPanel {
    private static let escapeKeyCode: UInt16 = 53

    private weak var appState: AppState?

    private(set) var currentSection: MenuBarSection.Name?
    private(set) var presentationGeneration = 0
    private weak var targetScreen: NSScreen?
    private var resolvedAnchor: (location: IceBarLocation, mouseX: CGFloat?)?

    private var cancellables = Set<AnyCancellable>()
    private lazy var escapeMonitor = LocalEventMonitor(mask: .keyDown) { [weak self] event in
        guard let self, self.isKeyWindow, event.keyCode == Self.escapeKeyCode else {
            return event
        }
        self.close()
        return nil
    }

    override var canBecomeKey: Bool { true }

    init(appState: AppState) {
        super.init(
            contentRect: .zero,
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: false
        )
        self.appState = appState
        self.title = "Ice Bar"
        self.titlebarAppearsTransparent = true
        self.isMovableByWindowBackground = true
        self.allowsToolTipsWhenApplicationIsInactive = true
        self.isFloatingPanel = true
        self.animationBehavior = .none
        self.backgroundColor = .clear
        self.isOpaque = false
        self.hasShadow = false
        self.level = .mainMenu + 1
        self.collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle, .moveToActiveSpace]
    }

    func performSetup() {
        configureCancellables()
    }

    private func configureCancellables() {
        var c = Set<AnyCancellable>()

        Publishers.Merge(
            NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.activeSpaceDidChangeNotification),
            NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
        )
        .sink { [weak self] _ in
            self?.close()
        }
        .store(in: &c)

        publisher(for: \.frame)
            .map(\.size)
            .removeDuplicates()
            .sink { [weak self] _ in
                guard
                    let self,
                    let screen = targetScreen ?? self.screen
                else {
                    return
                }
                updateOrigin(for: screen)
            }
            .store(in: &c)

        NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification, object: self)
            .delay(for: .milliseconds(100), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, isVisible, !isKeyWindow else {
                    return
                }
                close()
            }
            .store(in: &c)

        cancellables = c
    }

    private func updateOrigin(for screen: NSScreen) {
        guard let appState else {
            return
        }

        func getOrigin(for iceBarLocation: IceBarLocation) -> CGPoint {
            let menuBarHeight = screen.getMenuBarHeight() ?? 0
            let originY = ((screen.frame.maxY - 1) - menuBarHeight) - frame.height

            var originForRightOfScreen: CGPoint {
                CGPoint(x: screen.frame.maxX - frame.width, y: originY)
            }

            switch iceBarLocation {
            case .dynamic:
                if let resolved = resolvedAnchor?.location, resolved != .dynamic {
                    return getOrigin(for: resolved)
                }
                if appState.eventManager.isMouseInsideEmptyMenuBarSpace {
                    return getOrigin(for: .mousePointer)
                }
                return getOrigin(for: .iceIcon)
            case .mousePointer:
                guard let locationX = resolvedAnchor?.mouseX ?? MouseCursor.locationAppKit?.x else {
                    return originForRightOfScreen
                }
                let lowerBound = screen.frame.minX
                let upperBound = screen.frame.maxX - frame.width
                guard lowerBound <= upperBound else {
                    return originForRightOfScreen
                }
                return CGPoint(x: (locationX - frame.width / 2).clamped(to: lowerBound...upperBound), y: originY)
            case .iceIcon:
                let displayBounds = CGDisplayBounds(screen.displayID)
                if
                    let icon = HostedMenuBarBackend.renderedItemFrames(for: ProcessInfo.processInfo.processIdentifier)
                        .first(where: { $0.intersects(displayBounds) }),
                    frame.width <= screen.frame.width
                {
                    let originX = (icon.midX - frame.width / 2)
                        .clamped(to: screen.frame.minX...(screen.frame.maxX - frame.width))
                    return CGPoint(x: originX, y: originY)
                }
                return getOrigin(for: .mousePointer)
            }
        }

        setFrameOrigin(getOrigin(for: appState.settingsManager.generalSettingsManager.iceBarLocation))
    }

    func show(section: MenuBarSection.Name, on screen: NSScreen) async {
        guard let appState else {
            return
        }
        presentationGeneration += 1
        targetScreen = screen
        let configuredLocation = appState.settingsManager.generalSettingsManager.iceBarLocation
        let effectiveLocation: IceBarLocation = if configuredLocation == .dynamic {
            appState.eventManager.isMouseInsideEmptyMenuBarSpace ? .mousePointer : .iceIcon
        } else {
            configuredLocation
        }
        resolvedAnchor = (effectiveLocation, MouseCursor.locationAppKit?.x)
        appState.navigationState.isIceBarPresented = true
        currentSection = section

        let hostingView = IceBarHostingView(appState: appState, screen: screen, section: section) { [weak self] in
            self?.close()
        }
        contentView = hostingView

        updateOrigin(for: screen)

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        alphaValue = reduceMotion ? 1 : 0
        makeKeyAndOrderFront(nil)
        if !reduceMotion {
            NSAnimationContext.beginGrouping()
            NSAnimationContext.current.duration = 0.12
            animator().alphaValue = 1
            NSAnimationContext.endGrouping()
        }
        escapeMonitor.start()
        DispatchQueue.main.async { [weak self, weak hostingView] in
            guard self?.isKeyWindow == true else {
                return
            }
            hostingView?.focusFirstItem()
        }

        Task {
            try? await Task.sleep(for: .milliseconds(250))
            await appState.itemManager.cacheItemsIfNeeded()
        }
    }

    override func close() {
        presentationGeneration += 1
        escapeMonitor.stop()
        super.close()
        contentView = nil
        currentSection = nil
        targetScreen = nil
        resolvedAnchor = nil
        if let appState {
            appState.navigationState.isIceBarPresented = false
            for section in appState.menuBarManager.sections {
                section.stopRehideChecks()
            }
        }
    }
}

// MARK: - IceBarHostingView

private final class IceBarHostingView: NSHostingView<AnyView> {
    override var safeAreaInsets: NSEdgeInsets {
        NSEdgeInsets()
    }

    init(
        appState: AppState,
        screen: NSScreen,
        section: MenuBarSection.Name,
        closePanel: @escaping () -> Void
    ) {
        super.init(
            rootView: IceBarContentView(screen: screen, section: section, closePanel: closePanel)
                .environmentObject(appState)
                .environmentObject(appState.itemManager)
                .environmentObject(appState.menuBarManager)
                .environmentObject(appState.settingsManager.generalSettingsManager)
                .erasedToAnyView()
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @available(*, unavailable)
    required init(rootView: AnyView) {
        fatalError("init(rootView:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    func focusFirstItem() {
        func focusableButtons(in view: NSView) -> [NSView] {
            view.subviews.flatMap { subview in
                let current = subview.acceptsFirstResponder
                    && subview.isAccessibilityElement()
                    && subview.accessibilityRole() == .button ? [subview] : []
                return current + focusableButtons(in: subview)
            }
        }
        guard let first = focusableButtons(in: self).min(by: {
            $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX
        }) else {
            return
        }
        window?.makeFirstResponder(first)
        first.scrollToVisible(first.bounds)
    }
}

// MARK: - IceBarContentView

private struct IceBarContentView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var settings: GeneralSettingsManager
    @EnvironmentObject var itemManager: MenuBarItemManager
    @EnvironmentObject var menuBarManager: MenuBarManager
    @State private var scrollIndicatorsFlashTrigger = 0
    @State private var loadingTimedOut = false

    let screen: NSScreen
    let section: MenuBarSection.Name
    let closePanel: () -> Void

    private var items: [MenuBarItem] {
        itemManager.itemCache.managedItems(for: section)
    }

    private var availableWidth: CGFloat {
        max(160, screen.frame.width - 32)
    }

    private var maxScrollWidth: CGFloat {
        max(64, availableWidth - 16 - (settings.iceBarPadding + 2) * 2)
    }

    private var itemsRowWidth: CGFloat {
        let count = items.count
        guard count > 0 else {
            return 0
        }
        return CGFloat(count) * (settings.iceBarIconSize + 4)
            + CGFloat(count - 1) * settings.iceBarItemSpacing
    }

    var body: some View {
        content
            .frame(minHeight: settings.iceBarIconSize + 4)
            .padding(.horizontal, settings.iceBarPadding + 2)
            .padding(.vertical, settings.iceBarPadding)
            .foregroundStyle(.primary)
            .background { IceBarSurface(style: settings.iceBarStyle) }
            .contentShape(Rectangle())
            .contextMenu {
                Button("管理隐藏图标…") { openSettings(.menuBarLayout) }
                Button("Ice 设置…") { openSettings(.general) }
                Divider()
                Button(menuBarManager.isHidingPaused ? "恢复隐藏菜单栏图标" : "暂停隐藏菜单栏图标") {
                    closePanel()
                    menuBarManager.toggleHidingPaused()
                }
                Divider()
                Button("收起面板", action: closePanel)
            }
            .padding(8)
            .frame(maxWidth: availableWidth)
            .fixedSize()
    }

    private func openSettings(_ pane: SettingsNavigationIdentifier) {
        closePanel()
        appState.navigationState.settingsNavigationIdentifier = pane
        appState.appDelegate?.openSettingsWindow()
    }

    @ViewBuilder
    private var content: some View {
        if menuBarManager.isMenuBarHiddenBySystemUserDefaults {
            Text("系统开启“自动隐藏和显示菜单栏”时无法展示图标")
                .font(.callout)
                .padding(.horizontal, 12)
        } else if items.isEmpty, !itemManager.hasCompletedInitialScan, !loadingTimedOut {
            ProgressView()
                .controlSize(.small)
                .padding(.horizontal, 12)
                .accessibilityLabel("正在扫描菜单栏图标")
                .task {
                    try? await Task.sleep(for: .seconds(3))
                    loadingTimedOut = true
                }
        } else if items.isEmpty {
            Text("“\(section.displayString)”分区暂无图标")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .accessibilityLabel("“\(section.displayString)”分区暂无图标")
        } else {
            ScrollView(.horizontal) {
                HStack(spacing: settings.iceBarItemSpacing) {
                    ForEach(items, id: \.stableID) { item in
                        IceBarItemView(item: item, closePanel: closePanel)
                    }
                }
            }
            .frame(width: min(itemsRowWidth, maxScrollWidth))
            .environment(\.isScrollEnabled, true)
            .defaultScrollAnchor(.trailing)
            .scrollIndicatorsFlash(trigger: scrollIndicatorsFlashTrigger)
            .task {
                scrollIndicatorsFlashTrigger += 1
            }
        }
    }
}

// MARK: - IceBarItemView

private struct IceBarItemView: View {
    @EnvironmentObject var itemManager: MenuBarItemManager
    @EnvironmentObject var settings: GeneralSettingsManager

    let item: MenuBarItem
    let closePanel: () -> Void

    private var iconSide: CGFloat { settings.iceBarIconSize }
    private var hitTarget: CGFloat { iconSide + 4 }

    @State private var isHovered = false

    private var leftClickAction: () -> Void {
        return { [weak itemManager] in
            guard let itemManager else {
                return
            }
            closePanel()
            Task {
                await Task.yield()
                itemManager.tempShowItem(item, clickWhenFinished: true, mouseButton: .left)
            }
        }
    }

    private var rightClickAction: () -> Void {
        return { [weak itemManager] in
            guard let itemManager else {
                return
            }
            closePanel()
            Task {
                await Task.yield()
                itemManager.tempShowItem(item, clickWhenFinished: true, mouseButton: .right)
            }
        }
    }

    var body: some View {
        Group {
            if let icon = item.owningApplication?.icon {
                Image(nsImage: icon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: iconSide, height: iconSide)
            } else {
                Text(item.displayName)
                    .font(.caption)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .frame(height: iconSide)
            }
        }
        .frame(
            width: item.owningApplication?.icon != nil ? hitTarget : nil,
            height: hitTarget
        )
        .contentShape(Rectangle())
        .background {
            if isHovered {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.primary.opacity(0.12))
                    .padding(2)
            }
        }
        .accessibilityHidden(true)
        .overlay {
            IceBarItemClickView(
                item: item,
                leftClickAction: leftClickAction,
                rightClickAction: rightClickAction
            )
        }
        .onHover { isHovered = $0 }
    }
}

// MARK: - IceBarItemClickView

private func iceBarTooltip(for item: MenuBarItem) -> String {
    "\(item.displayName)\n左键打开菜单 · 右键打开快捷菜单"
}

private struct IceBarItemClickView: NSViewRepresentable {
    private final class Represented: NSView {
        var item: MenuBarItem

        var leftClickAction: () -> Void
        var rightClickAction: () -> Void

        private var lastLeftMouseDownDate = Date.now
        private var lastRightMouseDownDate = Date.now

        private var lastLeftMouseDownLocation = CGPoint.zero
        private var lastRightMouseDownLocation = CGPoint.zero

        init(
            item: MenuBarItem,
            leftClickAction: @escaping () -> Void,
            rightClickAction: @escaping () -> Void
        ) {
            self.item = item
            self.leftClickAction = leftClickAction
            self.rightClickAction = rightClickAction
            super.init(frame: .zero)
            self.toolTip = iceBarTooltip(for: item)
            self.focusRingType = .default
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        private func absoluteDistance(_ p1: CGPoint, _ p2: CGPoint) -> CGFloat {
            hypot(p1.x - p2.x, p1.y - p2.y).magnitude
        }

        override func mouseDown(with event: NSEvent) {
            super.mouseDown(with: event)
            window?.makeFirstResponder(self)
            lastLeftMouseDownDate = .now
            lastLeftMouseDownLocation = NSEvent.mouseLocation
        }

        override var acceptsFirstResponder: Bool {
            true
        }

        override func becomeFirstResponder() -> Bool {
            let became = super.becomeFirstResponder()
            if became {
                setKeyboardFocusRingNeedsDisplay(bounds)
            }
            return became
        }

        override func resignFirstResponder() -> Bool {
            let resigned = super.resignFirstResponder()
            if resigned {
                setKeyboardFocusRingNeedsDisplay(bounds)
            }
            return resigned
        }

        override var focusRingMaskBounds: NSRect { bounds }

        override func drawFocusRingMask() {
            NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 6, yRadius: 6).fill()
        }

        override func keyDown(with event: NSEvent) {
            switch event.keyCode {
            case 36, 49: // Return and Space
                leftClickAction()
            case 123: // Left arrow
                moveKeyboardFocus(by: -1)
            case 124: // Right arrow
                moveKeyboardFocus(by: 1)
            default:
                super.keyDown(with: event)
            }
        }

        private func moveKeyboardFocus(by offset: Int) {
            guard let root = window?.contentView else {
                return
            }
            func representedViews(in view: NSView) -> [Represented] {
                view.subviews.flatMap { subview in
                    (subview as? Represented).map { [$0] } ?? representedViews(in: subview)
                }
            }
            let views = representedViews(in: root).sorted {
                $0.convert($0.bounds, to: nil).midX < $1.convert($1.bounds, to: nil).midX
            }
            guard let index = views.firstIndex(where: { $0 === self }), !views.isEmpty else {
                return
            }
            let nextIndex = (index + offset + views.count) % views.count
            let next = views[nextIndex]
            window?.makeFirstResponder(next)
            next.scrollToVisible(next.bounds)
        }

        override func isAccessibilityElement() -> Bool {
            true
        }

        override func accessibilityRole() -> NSAccessibility.Role? {
            .button
        }

        override func accessibilityLabel() -> String? {
            item.displayName
        }

        override func accessibilityHelp() -> String? {
            "左键点击打开菜单，右键点击呼出该应用的快捷菜单。"
        }

        override func accessibilityPerformPress() -> Bool {
            leftClickAction()
            return true
        }

        override func menu(for event: NSEvent) -> NSMenu? {
            nil
        }

        override func rightMouseDown(with event: NSEvent) {
            lastRightMouseDownDate = .now
            lastRightMouseDownLocation = NSEvent.mouseLocation
        }

        override func mouseUp(with event: NSEvent) {
            super.mouseUp(with: event)
            guard
                Date.now.timeIntervalSince(lastLeftMouseDownDate) < 0.5,
                absoluteDistance(lastLeftMouseDownLocation, NSEvent.mouseLocation) < 5
            else {
                return
            }
            leftClickAction()
        }

        override func rightMouseUp(with event: NSEvent) {
            guard
                Date.now.timeIntervalSince(lastRightMouseDownDate) < 0.5,
                absoluteDistance(lastRightMouseDownLocation, NSEvent.mouseLocation) < 5
            else {
                return
            }
            rightClickAction()
        }
    }

    let item: MenuBarItem
    let leftClickAction: () -> Void
    let rightClickAction: () -> Void

    func makeNSView(context: Context) -> NSView {
        Represented(item: item, leftClickAction: leftClickAction, rightClickAction: rightClickAction)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? Represented else {
            return
        }
        view.item = item
        view.leftClickAction = leftClickAction
        view.rightClickAction = rightClickAction
        view.toolTip = iceBarTooltip(for: item)
    }
}
