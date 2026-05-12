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

    private lazy var colorManager = IceBarColorManager(iceBarPanel: self)

    private var cancellables = Set<AnyCancellable>()

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
                        let info = window?.cgWindowID.flatMap({ WindowInfo(windowID: $0) }),
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
                    return getOrigin(for: .iceIcon)
                }

                let lowerBound = screen.frame.minX
                let upperBound = screen.frame.maxX - frame.width

                guard lowerBound <= upperBound else {
                    return originForRightOfScreen
                }

                return CGPoint(x: (location.x - frame.width / 2).clamped(to: lowerBound...upperBound), y: originY)
            case .iceIcon:
                let lowerBound = screen.frame.minX
                let upperBound = screen.frame.maxX - frame.width

                guard
                    lowerBound <= upperBound,
                    let section = appState.menuBarManager.section(withName: .visible),
                    let itemFrame = visibleControlItemFrame(for: section)
                else {
                    return originForRightOfScreen
                }

                return CGPoint(x: (itemFrame.midX - frame.width / 2).clamped(to: lowerBound...upperBound), y: originY)
            }
        }

        setFrameOrigin(getOrigin(for: appState.settingsManager.generalSettingsManager.iceBarLocation))
    }

    private func visibleControlItemFrame(for section: MenuBarSection) -> CGRect? {
        if let frame = section.controlItem.windowFrame ?? section.controlItem.window?.frame {
            return frame
        }

        if
            let windowID = section.controlItem.windowID,
            let frame = Bridging.getWindowFrame(for: windowID)
        {
            return frame
        }

        return nil
    }

    private func debugItemList(_ items: [MenuBarItem]) -> String {
        items.map { item in
            "\(item.info)[id=\(item.windowID), frame=\(NSStringFromRect(item.frame)), onScreen=\(item.isOnScreen), movable=\(item.isMovable)]"
        }
        .joined(separator: " | ")
    }

    func show(section: MenuBarSection.Name, on screen: NSScreen) async {
        guard let appState else {
            return
        }

        Logger.iceBar.info(
            """
            IceBarRenderDebug show requested: \
            section=\(section.logString), \
            screen=\(screen.localizedName), \
            frame=\(NSStringFromRect(frame)), \
            cachedImages=\(appState.imageCache.images.count)
            """
        )

        // Important that we set the navigation state and current section before updating the cache.
        appState.navigationState.isIceBarPresented = true
        currentSection = section

        Logger.iceBar.info(
            """
            IceBarDebug panel will cache items: \
            section=\(section.logString), \
            tempContextCount=\(appState.itemManager.tempShownItemCount)
            """
        )

        await appState.itemManager.cacheItemsIfNeeded(force: true)

        let visibleItems = appState.itemManager.itemCache.managedItems(for: .visible)
        let hiddenItems = appState.itemManager.itemCache.managedItems(for: .hidden)
        let alwaysHiddenItems = appState.itemManager.itemCache.managedItems(for: .alwaysHidden)
        let sectionItems = appState.itemManager.itemCache.managedItems(for: section)

        Logger.iceBar.info(
            """
            IceBarDebug panel cache result: \
            section=\(section.logString), \
            visible=\(visibleItems.map(\.info)), \
            hidden=\(hiddenItems.map(\.info)), \
            alwaysHidden=\(alwaysHiddenItems.map(\.info)), \
            sectionItems=\(sectionItems.map(\.info)), \
            cacheState=\(appState.itemManager.itemCache.sectionStatesDescription)
            """
        )
        Logger.iceBar.info(
            """
            IceBarRenderDebug cache after force refresh: \
            visible=\(visibleItems.count), \
            hidden=\(hiddenItems.count), \
            alwaysHidden=\(alwaysHiddenItems.count), \
            requestedSectionCount=\(sectionItems.count), \
            requestedSectionItems=\(debugItemList(sectionItems))
            """
        )

        if ScreenCapture.cachedCheckPermissions() {
            Logger.iceBar.info(
                """
                IceBarRenderDebug image cache update starting: \
                beforeImageCount=\(appState.imageCache.images.count), \
                requestedSectionIDs=\(sectionItems.map(\.windowID))
                """
            )
            await appState.imageCache.updateCache()
            Logger.iceBar.info(
                """
                IceBarRenderDebug image cache update finished: \
                afterImageCount=\(appState.imageCache.images.count), \
                requestedSectionCachedIDs=\(sectionItems.map(\.windowID).filter { appState.imageCache.images[$0] != nil }), \
                requestedSectionMissingIDs=\(sectionItems.map(\.windowID).filter { appState.imageCache.images[$0] == nil })
                """
            )
        } else {
            Logger.iceBar.warning("IceBarRenderDebug image cache update skipped because screen capture permission is missing")
        }

        Logger.iceBar.info(
            """
            IceBarDebug creating hosting view: \
            section=\(section.logString), \
            visibleItems=\(visibleItems.map(\.info)), \
            hiddenItems=\(hiddenItems.map(\.info)), \
            alwaysHiddenItems=\(alwaysHiddenItems.map(\.info))
            """
        )

        contentView = IceBarHostingView(appState: appState, colorManager: colorManager, screen: screen, section: section) { [weak self] in
            self?.close()
        }

        updateOrigin(for: screen)

        // Color manager must be updated after updating the panel's origin, but before it is shown.
        //
        // Color manager handles frame changes automatically, but does so on the main queue, so we
        // need to update manually once before showing the panel to prevent the color from flashing.
        colorManager.updateAllProperties(with: frame, screen: screen)

        orderFrontRegardless()
    }

    override func close() {
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
        colorManager: IceBarColorManager,
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
                .environmentObject(colorManager)
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
    @EnvironmentObject var colorManager: IceBarColorManager
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

    private var debugItemsDescription: String {
        items.map { item in
            "\(item.info)[id=\(item.windowID), image=\(imageCache.images[item.windowID] != nil), frame=\(NSStringFromRect(item.frame)), onScreen=\(item.isOnScreen)]"
        }
        .joined(separator: " | ")
    }

    private var configuration: MenuBarAppearanceConfigurationV2 {
        appState.appearanceManager.configuration
    }

    private var horizontalPadding: CGFloat {
        configuration.hasRoundedShape ? 7 : 5
    }

    private var verticalPadding: CGFloat {
        screen.hasNotch ? 0 : 2
    }

    private var contentHeight: CGFloat? {
        guard let menuBarHeight = imageCache.menuBarHeight ?? screen.getMenuBarHeight() else {
            return nil
        }
        if configuration.shapeKind != .none && configuration.isInset && screen.hasNotch {
            return menuBarHeight - appState.appearanceManager.menuBarInsetAmount * 2
        }
        return menuBarHeight
    }

    private var clipShape: AnyInsettableShape {
        if configuration.hasRoundedShape {
            AnyInsettableShape(Capsule())
        } else {
            AnyInsettableShape(RoundedRectangle(cornerRadius: frame.height / 5, style: .continuous))
        }
    }

    private var shadowOpacity: CGFloat {
        configuration.current.hasShadow ? 0.5 : 0.33
    }

    var body: some View {
        ZStack {
            content
                .frame(height: contentHeight)
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, verticalPadding)
                .layoutBarStyle(appState: appState, averageColorInfo: colorManager.colorInfo)
                .foregroundStyle(colorManager.colorInfo?.color.brightness ?? 0 > 0.67 ? .black : .white)
                .clipShape(clipShape)
                .shadow(color: .black.opacity(shadowOpacity), radius: 2.5)

            if configuration.current.hasBorder {
                clipShape
                    .inset(by: configuration.current.borderWidth / 2)
                    .stroke(lineWidth: configuration.current.borderWidth)
                    .foregroundStyle(Color(cgColor: configuration.current.borderColor))
            }
        }
        .padding(5)
        .frame(maxWidth: imageCache.screen?.frame.width)
        .fixedSize()
        .onFrameChange(update: $frame)
    }

    @ViewBuilder
    private var content: some View {
        if !ScreenCapture.cachedCheckPermissions() {
            HStack {
                Text("The Ice Bar requires screen recording permissions.")

                Button {
                    closePanel()
                    appState.navigationState.settingsNavigationIdentifier = .advanced
                    appState.appDelegate?.openSettingsWindow()
                } label: {
                    Text("Open Ice Settings")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.link)
            }
            .padding(.horizontal, 10)
        } else if menuBarManager.isMenuBarHiddenBySystemUserDefaults {
            Text("Ice cannot display menu bar items for automatically hidden menu bars")
                .padding(.horizontal, 10)
        } else if imageCache.cacheFailed(for: section) {
            let _ = Logger.iceBar.warning(
                """
                IceBarRenderDebug cacheFailed branch: \
                section=\(section.logString), \
                itemCount=\(items.count), \
                imageCount=\(imageCache.images.count), \
                items=\(debugItemsDescription)
                """
            )
            Text("Unable to display menu bar items")
                .padding(.horizontal, 10)
        } else {
            let _ = Logger.iceBar.info(
                """
                IceBarRenderDebug rendering scroll view: \
                section=\(section.logString), \
                itemCount=\(items.count), \
                imageCount=\(imageCache.images.count), \
                panelFrame=\(NSStringFromRect(frame)), \
                contentHeight=\(String(describing: contentHeight)), \
                items=\(debugItemsDescription)
                """
            )
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(items, id: \.windowID) { item in
                        IceBarItemView(item: item, closePanel: closePanel)
                    }
                }
            }
            .environment(\.isScrollEnabled, frame.width == imageCache.screen?.frame.width)
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

    let item: MenuBarItem
    let closePanel: () -> Void

    private var leftClickAction: () -> Void {
        return { [weak itemManager] in
            Logger.iceBar.info(
                """
                IceBarClickDebug left click received: \
                item=\(item.logString), \
                info=\(item.info), \
                windowID=\(item.windowID), \
                ownerPID=\(item.ownerPID), \
                frame=\(NSStringFromRect(item.frame)), \
                isOnScreen=\(item.isOnScreen), \
                isMovable=\(item.isMovable), \
                imageCached=\(imageCache.images[item.windowID] != nil)
                """
            )
            guard let itemManager else {
                Logger.iceBar.warning("IceBarClickDebug left click ignored because itemManager is nil")
                return
            }
            closePanel()
            Task {
                try await Task.sleep(for: .milliseconds(25))
                Logger.iceBar.info("IceBarClickDebug left click dispatching tempShowItem for \(item.logString), windowID=\(item.windowID), info=\(item.info)")
                itemManager.tempShowItem(item, clickWhenFinished: true, mouseButton: .left)
            }
        }
    }

    private var rightClickAction: () -> Void {
        return { [weak itemManager] in
            Logger.iceBar.info(
                """
                IceBarClickDebug right click received: \
                item=\(item.logString), \
                info=\(item.info), \
                windowID=\(item.windowID), \
                ownerPID=\(item.ownerPID), \
                frame=\(NSStringFromRect(item.frame)), \
                isOnScreen=\(item.isOnScreen), \
                isMovable=\(item.isMovable), \
                imageCached=\(imageCache.images[item.windowID] != nil)
                """
            )
            guard let itemManager else {
                Logger.iceBar.warning("IceBarClickDebug right click ignored because itemManager is nil")
                return
            }
            closePanel()
            Task {
                try await Task.sleep(for: .milliseconds(25))
                Logger.iceBar.info("IceBarClickDebug right click dispatching tempShowItem for \(item.logString), windowID=\(item.windowID), info=\(item.info)")
                itemManager.tempShowItem(item, clickWhenFinished: true, mouseButton: .right)
            }
        }
    }

    private var image: NSImage? {
        guard
            let image = imageCache.images[item.windowID],
            let screen = imageCache.screen
        else {
            Logger.iceBar.warning(
                """
                IceBarRenderDebug item image missing: \
                item=\(item.logString), \
                windowID=\(item.windowID), \
                imageCached=\(imageCache.images[item.windowID] != nil), \
                hasScreen=\(imageCache.screen != nil), \
                knownImageIDs=\(Array(imageCache.images.keys).sorted())
                """
            )
            return nil
        }
        let size = CGSize(
            width: CGFloat(image.width) / screen.backingScaleFactor,
            height: CGFloat(image.height) / screen.backingScaleFactor
        )
        return NSImage(cgImage: image, size: size)
    }

    var body: some View {
        if let image {
            let _ = Logger.iceBar.info(
                """
                IceBarRenderDebug rendering item image: \
                item=\(item.logString), \
                windowID=\(item.windowID), \
                size=\(NSStringFromSize(image.size))
                """
            )
            Image(nsImage: image)
                .contentShape(Rectangle())
                .overlay {
                    IceBarItemClickView(item: item, leftClickAction: leftClickAction, rightClickAction: rightClickAction)
                }
                .accessibilityLabel(item.displayName)
                .accessibilityAction(named: "left click", leftClickAction)
                .accessibilityAction(named: "right click", rightClickAction)
        }
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

// MARK: - Logger

private extension Logger {
    static let iceBar = Logger(category: "IceBar")
}
