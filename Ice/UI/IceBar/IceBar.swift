//
//  IceBar.swift
//  Ice
//

import Combine
import SwiftUI

// MARK: - IceBarPanel

final class IceBarPanel: NSPanel {
    private weak var appState: AppState?

    private(set) var currentSection: MenuBarSection.Name?
    private(set) var presentationGeneration = 0

    private var cancellables = Set<AnyCancellable>()
    private lazy var escapeMonitor = UniversalEventMonitor(mask: .keyDown) { [weak self] event in
        guard let self, self.isVisible, event.keyCode == KeyCode.escape.rawValue else { return event }
        self.close()
        return nil
    }

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

        // Close the panel when the active space changes, or when the screen parameters change.
        Publishers.Merge(
            NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.activeSpaceDidChangeNotification),
            NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
        )
        .sink { [weak self] _ in
            self?.close()
        }
        .store(in: &c)

        if
            let section = appState?.menuBarManager.section(withName: .hidden),
            let window = section.controlItem.window
        {
            window.publisher(for: \.frame)
                .debounce(for: 0.1, scheduler: DispatchQueue.main)
                .sink { [weak self, weak window] _ in
                    guard
                        let self,
                        let appState,
                        // Only continue if the menu bar is automatically hidden, as Ice
                        // can't currently display its menu bar items.
                        appState.menuBarManager.isMenuBarHiddenBySystemUserDefaults,
                        let info = window.flatMap({ window -> WindowInfo? in
                            guard
                                window.windowNumber > 0,
                                let windowID = CGWindowID(exactly: window.windowNumber)
                            else {
                                return nil
                            }
                            return WindowInfo(windowID: windowID)
                        }),
                        // Window being offscreen means the menu bar is currently hidden.
                        // Close the bar, as things will start to look weird if we don't.
                        !info.isOnScreen
                    else {
                        return
                    }
                    close()
                }
                .store(in: &c)
        }

        // Update the panel's origin whenever its size changes.
        publisher(for: \.frame)
            .map(\.size)
            .removeDuplicates()
            .sink { [weak self] _ in
                guard
                    let self,
                    let screen
                else {
                    return
                }
                updateOrigin(for: screen)
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
                if appState.eventManager.isMouseInsideEmptyMenuBarSpace {
                    return getOrigin(for: .mousePointer)
                }
                return getOrigin(for: .iceIcon)
            case .mousePointer:
                guard let location = MouseCursor.locationAppKit else {
                    return originForRightOfScreen
                }

                let lowerBound = screen.frame.minX
                let upperBound = screen.frame.maxX - frame.width

                guard lowerBound <= upperBound else {
                    return originForRightOfScreen
                }

                return CGPoint(x: (location.x - frame.width / 2).clamped(to: lowerBound...upperBound), y: originY)
            case .iceIcon:
                // Anchor to the actual hosted icon when it exists. Its source
                // window is shared or stale; fall back to the click location.
                if ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 {
                    let displayBounds = CGDisplayBounds(screen.displayID)
                    if let icon = HostedMenuBarBackend.renderedItemFrames(for: ProcessInfo.processInfo.processIdentifier)
                        .first(where: { $0.intersects(displayBounds) }), frame.width <= screen.frame.width {
                        return CGPoint(x: (icon.midX - frame.width / 2)
                            .clamped(to: screen.frame.minX...(screen.frame.maxX - frame.width)), y: originY)
                    }
                    return getOrigin(for: .mousePointer)
                }

                let lowerBound = screen.frame.minX
                let upperBound = screen.frame.maxX - frame.width

                guard
                    lowerBound <= upperBound,
                    let section = appState.menuBarManager.section(withName: .visible)
                else {
                    return originForRightOfScreen
                }

                let itemFrame = section.controlItem.windowID
                    .flatMap(Bridging.getWindowFrame)
                    ?? section.controlItem.windowFrame
                guard let itemFrame else {
                    return originForRightOfScreen
                }

                return CGPoint(x: (itemFrame.midX - frame.width / 2).clamped(to: lowerBound...upperBound), y: originY)
            }
        }

        setFrameOrigin(getOrigin(for: appState.settingsManager.generalSettingsManager.iceBarLocation))
    }

    func show(section: MenuBarSection.Name, on screen: NSScreen) async {
        guard let appState else {
            return
        }
        presentationGeneration += 1
        // Important that we set the navigation state and current section before updating the cache.
        appState.navigationState.isIceBarPresented = true
        currentSection = section

        contentView = IceBarHostingView(appState: appState, screen: screen, section: section) { [weak self] in
            self?.close()
        }

        updateOrigin(for: screen)

        orderFrontRegardless()
        escapeMonitor.start()

        // Do not block presentation on AX enumeration and shared-window screen
        // capture. The current logical cache is immediately usable, and the
        // panel updates reactively when the background refresh completes.
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
        appState?.navigationState.isIceBarPresented = false
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
                .environmentObject(appState.imageCache)
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
        return true
    }
}

// MARK: - IceBarContentView

private struct IceBarContentView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var settings: GeneralSettingsManager
    @EnvironmentObject var itemManager: MenuBarItemManager
    @EnvironmentObject var imageCache: MenuBarItemImageCache
    @EnvironmentObject var menuBarManager: MenuBarManager
    @State private var frame = CGRect.zero
    @State private var scrollIndicatorsFlashTrigger = 0

    let screen: NSScreen
    let section: MenuBarSection.Name
    let closePanel: () -> Void

    private var items: [MenuBarItem] {
        itemManager.itemCache.managedItems(for: section)
    }

    private var availableWidth: CGFloat { max(160, screen.frame.width - 32) }

    var body: some View {
        content
            .frame(minHeight: settings.iceBarIconSize + 4)
            .padding(.horizontal, settings.iceBarPadding + 2)
            .padding(.vertical, settings.iceBarPadding)
            .foregroundStyle(.primary)
            .background { IceBarSurface(style: settings.iceBarStyle) }
            .contentShape(Rectangle())
            .contextMenu {
                Button("Search menu bar items…", action: openSearch)
                Button("Arrange hidden items…") { openSettings(.menuBarLayout) }
                Button("Ice Bar settings…") { openSettings(.general) }
                Divider()
                Button("Show All Hidden Items") {
                    closePanel()
                    menuBarManager.resetModifications()
                }
                Divider()
                Button("Close Ice Bar", action: closePanel)
            }
            .padding(8) // Transparent space for the compact shadow.
            .frame(maxWidth: availableWidth)
            .fixedSize()
            .onFrameChange(update: $frame)
    }

    private func openSearch() {
        closePanel()
        Task { await menuBarManager.searchPanel.show(on: screen) }
    }

    private func openSettings(_ pane: SettingsNavigationIdentifier) {
        closePanel()
        appState.navigationState.settingsNavigationIdentifier = pane
        appState.appDelegate?.openSettingsWindow()
    }

    @ViewBuilder
    private var content: some View {
        if menuBarManager.isMenuBarHiddenBySystemUserDefaults {
            Text("Ice cannot display menu bar items for automatically hidden menu bars")
                .padding(.horizontal, 10)
        } else if items.isEmpty {
            Text("No items in \(section.displayString)")
                .font(.callout)
                .padding(.horizontal, 12)
                .accessibilityLabel("No items in \(section.displayString)")
        } else {
            ScrollView(.horizontal) {
                HStack(spacing: settings.iceBarItemSpacing) {
                    ForEach(items, id: \.stableID) { item in
                        IceBarItemView(item: item, closePanel: closePanel)
                    }
                }
            }
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
    @EnvironmentObject var imageCache: MenuBarItemImageCache
    @EnvironmentObject var itemManager: MenuBarItemManager
    @EnvironmentObject var settings: GeneralSettingsManager

    let item: MenuBarItem
    let closePanel: () -> Void

    private var iconSide: CGFloat { settings.iceBarIconSize }
    private var hitTarget: CGFloat { iconSide + 4 }

    @State private var isHovered = false

    private var usesHostedAppIcon: Bool {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 &&
            item.hostedHandle != nil && item.owningApplication?.icon != nil
    }

    private var leftClickAction: () -> Void {
        return { [weak itemManager] in
            guard let itemManager else {
                return
            }
            closePanel()
            Task {
                try await Task.sleep(for: .milliseconds(25))
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
                try await Task.sleep(for: .milliseconds(25))
                itemManager.tempShowItem(item, clickWhenFinished: true, mouseButton: .right)
            }
        }
    }

    private var image: NSImage? {
        if usesHostedAppIcon, let icon = item.owningApplication?.icon?.copy() as? NSImage {
            icon.size = CGSize(width: iconSide, height: iconSide)
            return icon
        }

        guard
            let image = imageCache.images[item.stableID],
            let screen = imageCache.screen
        else {
            return nil
        }
        let size = CGSize(
            width: CGFloat(image.width) / screen.backingScaleFactor,
            height: CGFloat(image.height) / screen.backingScaleFactor
        )
        return NSImage(cgImage: image, size: size)
    }

    private func scaledImageSize(_ image: NSImage) -> CGSize {
        let scale = iconSide / max(image.size.height, 1)
        return CGSize(width: image.size.width * scale, height: iconSide)
    }

    var body: some View {
        Group {
            if let image {
                if usesHostedAppIcon {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: iconSide, height: iconSide)
                } else {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: scaledImageSize(image).width, height: scaledImageSize(image).height)
                }
            } else {
                Text(item.displayName)
                    .font(.caption)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .frame(height: NSStatusBar.system.thickness)
            }
        }
        .frame(
            width: usesHostedAppIcon ? hitTarget : nil,
            height: hitTarget
        )
        .contentShape(Rectangle())
        .background {
            if usesHostedAppIcon && isHovered {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.primary.opacity(0.12))
                    .padding(2)
            }
        }
        .overlay {
            IceBarItemClickView(item: item, leftClickAction: leftClickAction, rightClickAction: rightClickAction)
        }
        .onHover { isHovered = $0 }
        .focusable()
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(item.displayName)
        .accessibilityHint("Press to open. Secondary click for more options.")
        .accessibilityAction(.default) { leftClickAction() }
        .accessibilityAction(named: "left click", leftClickAction)
        .accessibilityAction(named: "right click", rightClickAction)
    }
}

// MARK: - IceBarItemClickView

private struct IceBarItemClickView: NSViewRepresentable {
    private final class Represented: NSView {
        let item: MenuBarItem

        let leftClickAction: () -> Void
        let rightClickAction: () -> Void

        private var lastLeftMouseDownDate = Date.now
        private var lastRightMouseDownDate = Date.now

        private var lastLeftMouseDownLocation = CGPoint.zero
        private var lastRightMouseDownLocation = CGPoint.zero

        init(item: MenuBarItem, leftClickAction: @escaping () -> Void, rightClickAction: @escaping () -> Void) {
            self.item = item
            self.leftClickAction = leftClickAction
            self.rightClickAction = rightClickAction
            super.init(frame: .zero)
            self.toolTip = item.displayName
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
            lastLeftMouseDownDate = .now
            lastLeftMouseDownLocation = NSEvent.mouseLocation
        }

        override var acceptsFirstResponder: Bool {
            true
        }

        override func keyDown(with event: NSEvent) {
            if event.keyCode == 36 || event.keyCode == 49 {
                leftClickAction()
            } else {
                super.keyDown(with: event)
            }
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
            "Press to open. Secondary click for more options."
        }

        override func accessibilityPerformPress() -> Bool {
            leftClickAction()
            return true
        }

        override func rightMouseDown(with event: NSEvent) {
            super.rightMouseDown(with: event)
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
            super.rightMouseUp(with: event)
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

    func updateNSView(_ nsView: NSView, context: Context) { }
}
