//
//  MenuBarItemManager.swift
//  Ice
//

import Cocoa
import Combine

/// Manager for menu bar items.
@MainActor
final class MenuBarItemManager: ObservableObject {
    /// Cache for menu bar items.
    struct ItemCache: Hashable {
        /// All cached menu bar items, keyed by section.
        var items = [MenuBarSection.Name: [MenuBarItem]]()

        /// All cached menu bar items.
        var allItems: [MenuBarItem] {
            MenuBarSection.Name.allCases.reduce(into: []) { result, section in
                result.append(contentsOf: self[section])
            }
        }

        /// The cached menu bar items managed by Ice.
        var managedItems: [MenuBarItem] {
            MenuBarSection.Name.allCases.reduce(into: []) { result, section in
                result.append(contentsOf: managedItems(for: section))
            }
        }

        /// Clears the cache.
        mutating func clear() {
            items.removeAll()
        }

        /// Returns the cached menu bar items managed by Ice for the given section.
        func managedItems(for section: MenuBarSection.Name) -> [MenuBarItem] {
            self[section].filter { item in
                // Filter out items that can't be hidden.
                guard item.canBeHidden else {
                    return false
                }

                if item.owningApplication == .current {
                    // Ice icon is the only item owned by Ice that should be included.
                    guard item.title == ControlItem.Identifier.iceIcon.rawValue else {
                        return false
                    }
                }

                return true
            }
        }

        /// Returns the name of the section for the given menu bar item.
        func section(for item: MenuBarItem) -> MenuBarSection.Name? {
            for (section, items) in self.items where items.contains(where: { $0.stableID == item.stableID }) {
                return section
            }
            return nil
        }

        /// Accesses the items in the given section.
        subscript(section: MenuBarSection.Name) -> [MenuBarItem] {
            get { items[section, default: []] }
            set { items[section] = newValue }
        }
    }

    /// Context for a temporarily shown menu bar item.
    struct TempShownItemContext {
        /// Stable identity of the item.
        let stableID: String

        /// The information associated with the item.
        let info: MenuBarItemInfo

        /// The destination to return the item to.
        let returnDestination: MoveDestination

        /// The window of the item's shown interface.
        let shownInterfaceWindow: WindowInfo?

        /// A Boolean value that indicates whether the menu bar item's interface is showing.
        var isShowingInterface: Bool {
            guard let currentWindow = shownInterfaceWindow.flatMap({ WindowInfo(windowID: $0.windowID) }) else {
                return false
            }
            return if
                currentWindow.layer != CGWindowLevelForKey(.popUpMenuWindow),
                let owningApplication = currentWindow.owningApplication
            {
                owningApplication.isActive && currentWindow.isOnScreen
            } else {
                currentWindow.isOnScreen
            }
        }
    }

    /// The manager's menu bar item cache.
    @Published private(set) var itemCache = ItemCache()

    /// A Boolean value that indicates whether at least one scan has produced a
    /// cache. Lets the UI tell "still scanning" apart from "really empty".
    @Published private(set) var hasCompletedInitialScan = false

    /// The shared app state.
    private(set) weak var appState: AppState?

    /// Storage for internal observers.
    var cancellables = Set<AnyCancellable>()

    /// Stable identities and geometry for the most recent successful cache.
    var cachedItemSignatures = [String]()

    /// Logical section assignments for hosted items. Hidden hosted items can
    /// disappear from AX entirely, so their section cannot be reconstructed
    /// from each enumeration alone.
    var hostedSectionAssignments = [String: MenuBarSection.Name]()

    /// Last known descriptors for hosted items, including currently hidden ones.
    var hostedItemSnapshots = [String: MenuBarItem]()

    /// Whether the initial hosted layout has been captured with sections shown.
    var hasWarmedHostedCache = false

    /// Prevents timer-driven cache refreshes during the hosted warmup.
    var isWarmingHostedCache = false

    /// Incremented per hosted refresh request; only the latest may publish.
    var hostedRefreshGeneration = 0

    /// Number of in-flight operations that need every section shown.
    var sectionRevealLeases = 0

    /// Control states captured by the first reveal lease, restored by the last.
    var sectionStatesBeforeReveal = [(ControlItem, ControlItem.HidingState)]()

    /// Context values for the current temporarily shown items.
    var tempShownItemContexts = [TempShownItemContext]()

    /// A timer that determines when to rehide the temporarily shown items.
    var tempShownItemsTimer: Timer?

    /// The last time a menu bar item was moved.
    var lastItemMoveStartDate: Date?

    /// The last time the mouse was moved.
    var lastMouseMoveStartDate: Date?

    /// Counter to determine if a menu bar item, or group of menu bar
    /// items is being moved.
    var itemMoveCount = 0

    /// A Boolean value that indicates whether a mouse button is down.
    var isMouseButtonDown = false

    /// Event type mask for tracking mouse events.
    let mouseTrackingMask: NSEvent.EventTypeMask = [
        .mouseMoved,
        .leftMouseDown,
        .rightMouseDown,
        .otherMouseDown,
        .leftMouseUp,
        .rightMouseUp,
        .otherMouseUp,
    ]

    /// A Boolean value that indicates whether a menu bar item, or
    /// group of menu bar items is being moved.
    var isMovingItem: Bool {
        itemMoveCount > 0
    }

    /// A Boolean value that indicates whether a menu bar item has
    /// recently moved.
    var itemHasRecentlyMoved: Bool {
        guard let lastItemMoveStartDate else {
            return false
        }
        return Date.now.timeIntervalSince(lastItemMoveStartDate) <= 1
    }

    /// A Boolean value that indicates whether the mouse has recently moved.
    var mouseHasRecentlyMoved: Bool {
        guard let lastMouseMoveStartDate else {
            return false
        }
        return Date.now.timeIntervalSince(lastMouseMoveStartDate) <= 1
    }

    /// Creates a manager with the given app state.
    init(appState: AppState) {
        self.appState = appState
        loadPersistedHostedSectionAssignments()
    }

    /// Sets up the manager.
    func performSetup() {
        configureCancellables()
    }

    /// Configures the internal observers for the manager.
    func configureCancellables() {
        var c = Set<AnyCancellable>()

        // Workspace and screen notifications below normally request a refresh.
        // The timer is only a conservative recovery path on hosted menu bars.
        Timer.publish(every: HostedItemVisibilityManager.isSupported ? 30 : 5, on: .main, in: .default)
            .autoconnect()
            .merge(with: Just(.now))
            .sink { [weak self] _ in
                guard let self else {
                    return
                }
                Task {
                    await self.cacheItemsIfNeeded()
                }
            }
            .store(in: &c)

        NSWorkspace.shared.publisher(for: \.runningApplications)
            .delay(for: 0.25, scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else {
                    return
                }
                Task {
                    await self.cacheItemsIfNeeded()
                }
            }
            .store(in: &c)

        // On hosted menu bars we no longer synthesize physical divider drags.
        // Draining/reposting AppKit's tracking queue can swallow the mouse-up
        // that finishes a settings click or an NSDraggingSession on macOS 27.
        let mouseEvents: AnyPublisher<NSEvent, Never>
        if HostedItemVisibilityManager.isSupported {
            // Mouse-move timing only gates the synthetic drag paths, which are
            // not used on hosted menu bars. Do not wake for every pointer move.
            mouseEvents = UniversalEventMonitor.publisher(for: mouseTrackingMask.subtracting(.mouseMoved))
                .eraseToAnyPublisher()
        } else {
            mouseEvents = Publishers.Merge(
                UniversalEventMonitor.publisher(for: mouseTrackingMask),
                RunLoopLocalEventMonitor.publisher(for: mouseTrackingMask, mode: .eventTracking)
            ).eraseToAnyPublisher()
        }
        mouseEvents
            .sink { [weak self] event in
                guard let self else {
                    return
                }
                switch event.type {
                case .mouseMoved:
                    lastMouseMoveStartDate = .now
                case .leftMouseDown, .rightMouseDown, .otherMouseDown:
                    isMouseButtonDown = true
                case .leftMouseUp, .rightMouseUp, .otherMouseUp:
                    isMouseButtonDown = false
                default:
                    break
                }
            }
            .store(in: &c)

        cancellables = c
    }
}

// MARK: - Cache Items

extension MenuBarItemManager {
    /// Logs a warning that the given menu bar item was not added to the cache.
    func logNotCachedWarning(for item: MenuBarItem) {
        Logger.itemManager.warning("\(item.logString) at \(NSStringFromRect(item.frame)) was not cached")
    }

    /// Logs a reason for skipping the cache.
    func logSkippingCache(reason: String) {
        Logger.itemManager.debug("Skipping menu bar item cache as \(reason)")
    }

    /// Caches the given menu bar items, without checking whether the control
    /// items are in the correct order.
    func uncheckedCacheItems(
        hiddenControlItem: MenuBarItem,
        alwaysHiddenControlItem: MenuBarItem?,
        otherItems: [MenuBarItem]
    ) {
        Logger.itemManager.debug("Caching menu bar items")

        let predicates = Predicates.sectionPredicates(
            hiddenControlItem: hiddenControlItem,
            alwaysHiddenControlItem: alwaysHiddenControlItem
        )
        Logger.itemManager.debug(
            "Section delimiters: hidden=\(NSStringFromRect(hiddenControlItem.frame)), " +
                "alwaysHidden=\(alwaysHiddenControlItem.map { NSStringFromRect($0.frame) } ?? "<disabled>")"
        )

        var cache = ItemCache()
        var tempShownItems = [(MenuBarItem, MoveDestination)]()

        let screenWidth = NSScreen.screens.map(\.frame.width).max() ?? 0
        let hiddenFrame = hiddenControlItem.frame
        let hasUsableDelimiterGeometry = hiddenFrame.width <= screenWidth
            && NSScreen.screens.contains { $0.frame.insetBy(dx: -100, dy: -100).intersects(hiddenFrame) }
        if !hasUsableDelimiterGeometry {
            // Hosted status items can report the expanded divider as a wrapped,
            // multi-screen-width rectangle. Geometry comparisons against that
            // rectangle classify every real item outside all sections. Preserve
            // useful layout data by separating visible and offscreen items.
            Logger.itemManager.warning("Hosted control-item geometry is invalid; using visibility-based sections")
            for item in otherItems where item.hostedHandle != nil {
                hostedItemSnapshots[item.stableID] = item
                if hostedSectionAssignments[item.stableID] == nil {
                    hostedSectionAssignments[item.stableID] = item.isOnScreen ? .visible : .hidden
                }
            }
            hostedItemSnapshots = hostedItemSnapshots.filter { _, item in
                item.owningApplication != nil
            }
            for (stableID, item) in hostedItemSnapshots {
                let section = hostedSectionAssignments[stableID] ?? (item.isOnScreen ? .visible : .hidden)
                cache[section].append(item)
            }
            for section in MenuBarSection.Name.allCases {
                cache[section] = cache[section].sortedByOrderInMenuBar()
            }
            itemCache = cache
            return
        }

        for item in otherItems {
            if
                item.hostedHandle != nil,
                let assigned = hostedSectionAssignments[item.stableID]
            {
                // Logical assignments are authoritative for hosted items: an
                // item Ice is hiding may be absent from AX or keep a stale
                // frame, so geometry cannot determine its section.
                cache[assigned].append(item)
            } else if item.hostedHandle != nil, !item.isOnScreen {
                let section = hostedSectionAssignments[item.stableID] ?? .hidden
                cache[section].append(item)
            } else if let context = tempShownItemContexts.first(where: { $0.stableID == item.stableID }) {
                // Keep track of temporarily shown items and their return destinations separately.
                // We want to cache them as if they were in their original locations. Once all other
                // items are cached, use the return destinations to insert the items into the cache
                // at the correct position.
                tempShownItems.append((item, context.returnDestination))
            } else if predicates.isInVisibleSection(item) {
                cache[.visible].append(item)
            } else if predicates.isInHiddenSection(item) {
                cache[.hidden].append(item)
            } else if predicates.isInAlwaysHiddenSection(item) {
                cache[.alwaysHidden].append(item)
            } else {
                logNotCachedWarning(for: item)
            }
        }

        for (item, destination) in tempShownItems {
            switch destination {
            case .leftOfItem(let targetItem):
                switch targetItem.info {
                case .hiddenControlItem:
                    cache[.hidden].append(item)
                case .alwaysHiddenControlItem:
                    cache[.alwaysHidden].append(item)
                default:
                    if
                        let section = cache.section(for: targetItem),
                        let index = cache[section].firstIndex(where: { $0.stableID == targetItem.stableID })
                    {
                        let clampedIndex = index.clamped(to: cache[section].startIndex...cache[section].endIndex)
                        cache[section].insert(item, at: clampedIndex)
                    }
                }
            case .rightOfItem(let targetItem):
                switch targetItem.info {
                case .hiddenControlItem:
                    cache[.visible].insert(item, at: 0)
                case .alwaysHiddenControlItem:
                    cache[.hidden].insert(item, at: 0)
                default:
                    if
                        let section = cache.section(for: targetItem),
                        let index = cache[section].firstIndex(where: { $0.stableID == targetItem.stableID })
                    {
                        let clampedIndex = (index - 1).clamped(to: cache[section].startIndex...cache[section].endIndex)
                        cache[section].insert(item, at: clampedIndex)
                    }
                }
            }
        }

        for section in MenuBarSection.Name.allCases {
            for item in cache[section] where item.hostedHandle != nil {
                hostedSectionAssignments[item.stableID] = section
                hostedItemSnapshots[item.stableID] = item
            }
        }
        itemCache = cache
    }

    /// Caches the current menu bar items if needed, ensuring that the control
    /// items are in the correct order.
    func cacheItemsIfNeeded() async {
        guard !isWarmingHostedCache else {
            return
        }
        if HostedItemVisibilityManager.isSupported {
            // Items are never dragged on hosted menu bars, so there is no move
            // to wait for. Several observers request refreshes concurrently;
            // only the most recent request may publish, so a slow earlier
            // await cannot overwrite a newer result.
            hostedRefreshGeneration &+= 1
            let generation = hostedRefreshGeneration
            let snapshot = await HostedMenuBarBackend.refreshDescriptorSnapshot()
            guard generation == hostedRefreshGeneration else { return }
            let discovered = snapshot.items.map(MenuBarItem.init(hostedHandle:))
                .filter { $0.ownerPID != ProcessInfo.processInfo.processIdentifier }
            cacheHostedItems(
                discovered: discovered,
                scannedPIDs: snapshot.scannedPIDs,
                concealedBundles: snapshot.concealedBundles
            )
            return
        }
        do {
            try await waitForItemsToStopMoving(timeout: .seconds(1))
        } catch is TaskTimeoutError {
            logSkippingCache(reason: "an item is currently being moved")
            return
        } catch {
            guard !itemHasRecentlyMoved else {
                logSkippingCache(reason: "an item was recently moved")
                return
            }
        }

        var didRevealSections = false
        var items = MenuBarItem.getMenuBarItems(onScreenOnly: false, activeSpaceOnly: true)
        if
            !hasWarmedHostedCache,
            items.contains(where: { $0.hostedHandle != nil }),
            let appState
        {
            hasWarmedHostedCache = true
            isWarmingHostedCache = true
            beginSectionReveal(appState)
            didRevealSections = true
            try? await Task.sleep(for: .milliseconds(150))
            items = MenuBarItem.getMenuBarItems(onScreenOnly: false, activeSpaceOnly: true)
            isWarmingHostedCache = false
        }
        defer {
            if didRevealSections { endSectionReveal() }
        }
        guard !items.isEmpty else {
            logSkippingCache(reason: AXIsProcessTrusted() ? "no menu bar items were discovered" : "Accessibility permission is unavailable")
            return
        }

        let itemSignatures = items.map {
            "\($0.stableID)|\(NSStringFromRect($0.frame))|\($0.isOnScreen)"
        }
        if !cachedItemSignatures.isEmpty, cachedItemSignatures == itemSignatures {
            hasCompletedInitialScan = true
            logSkippingCache(reason: "menu bar items have not changed")
            return
        }

        let hiddenControlItem = removeControlItem(for: .hidden, from: &items)
        let alwaysHiddenControlItem = removeControlItem(for: .alwaysHidden, from: &items)

        guard let hiddenControlItem else {
            Logger.itemManager.warning("Missing control item for hidden section")
            Logger.itemManager.debug("Clearing menu bar item cache")
            itemCache.clear()
            return
        }

        do {
            if let alwaysHiddenControlItem {
                try await enforceControlItemOrder(
                    hiddenControlItem: hiddenControlItem,
                    alwaysHiddenControlItem: alwaysHiddenControlItem
                )
            }
            uncheckedCacheItems(
                hiddenControlItem: hiddenControlItem,
                alwaysHiddenControlItem: alwaysHiddenControlItem,
                otherItems: items
            )
            cachedItemSignatures = itemSignatures
            hasCompletedInitialScan = true
        } catch {
            Logger.itemManager.error("Error enforcing control item order: \(error)")
            Logger.itemManager.debug("Clearing menu bar item cache")
            itemCache.clear()
        }
    }

    /// Preserve concealed descriptors while their owner is alive: the native
    /// assertion removes them from AX, so absence is not an uninstall signal.
    func cacheHostedItems(
        discovered: [MenuBarItem]? = nil, scannedPIDs: Set<pid_t> = [], concealedBundles: Set<String> = []
    ) {
        let discovered = (discovered ?? itemCache.allItems)
            .filter { $0.hostedHandle != nil && $0.ownerPID != ProcessInfo.processInfo.processIdentifier }
        let livePIDs = Set(NSWorkspace.shared.runningApplications.filter { !$0.isTerminated }.map(\.processIdentifier))
        hostedItemSnapshots = HostedItemSnapshotPolicy.merge(
            existing: hostedItemSnapshots,
            discovered: discovered,
            liveOwners: livePIDs,
            scannedOwners: scannedPIDs,
            id: { $0.stableID },
            owner: { $0.ownerPID },
            preserveMissing: { item in
                item.hostedHandle?.sourceBundleIdentifier.map { concealedBundles.contains($0) } ?? false
            }
        )
        var cache = ItemCache()
        let alwaysEnabled = appState?.settingsManager.advancedSettingsManager.enableAlwaysHiddenSection == true
        for item in hostedItemSnapshots.values {
            let ownerKey = item.hostedHandle?.sourceBundleIdentifier.map { "bundle:" + $0 }
            // Migrate the old title-derived identity when a status item has
            // no AXIdentifier. New identities do not change with a timer/title.
            let legacyID = item.stableID.replacingOccurrences(
                of: "|unidentified|", with: "|\(item.title ?? "")|"
            )
            let rawID = item.hostedHandle?.stableID ?? item.stableID
            let legacyKeys = [
                item.stableID,
                legacyID,
                rawID,
                rawID.replacingOccurrences(of: "|unidentified|", with: "||"),
                rawID.replacingOccurrences(of: "|unidentified|", with: "|\(item.title ?? "")|"),
            ]
            var section = ownerKey.flatMap { hostedSectionAssignments[$0] }
                ?? legacyKeys.lazy.compactMap { self.hostedSectionAssignments[$0] }.first ?? .visible
            if !item.canBeHidden { section = .visible }
            if section == .alwaysHidden && !alwaysEnabled { section = .visible }
            cache[section].append(item)
        }
        for section in MenuBarSection.Name.allCases {
            cache[section] = cache[section].sorted { $0.stableID < $1.stableID }
        }
        if cache != itemCache { itemCache = cache }
    }

    /// macOS 27 hides by owner bundle, so move all sibling icons together.
    func assignHostedItem(_ item: MenuBarItem, to section: MenuBarSection.Name) {
        guard let handle = item.hostedHandle, item.canBeHidden else { return }
        hostedItemSnapshots[item.stableID] = item
        if let bundle = handle.sourceBundleIdentifier {
            hostedSectionAssignments["bundle:" + bundle] = section
            for sibling in hostedItemSnapshots.values where sibling.hostedHandle?.sourceBundleIdentifier == bundle {
                hostedSectionAssignments[sibling.stableID] = section
            }
        } else {
            hostedSectionAssignments[item.stableID] = section
        }
        persistHostedSectionAssignments()
        // This synchronous assignment path must never start a new AX walk.
        // The observer-driven refresh will merge a fresh descriptor snapshot.
        cacheHostedItems()
        cachedItemSignatures.removeAll()
    }

    /// Recovery also clears the live cache's sections so a pending observer
    /// cannot immediately recreate the restriction after Show All.
    func resetHostedSectionAssignments() {
        hostedSectionAssignments.removeAll()
        cachedItemSignatures.removeAll()
        Defaults.removeObject(forKey: .hostedSectionAssignments)
        if HostedItemVisibilityManager.isSupported {
            var cache = ItemCache()
            cache[.visible] = itemCache.allItems
            itemCache = cache
        }
        Logger.itemManager.info("Reset hosted section assignments")
    }

    // MARK: Hosted Section Assignment Persistence

    /// Restores logical section assignments recorded by previous sessions.
    ///
    /// Hosted items that Ice is hiding are removed from the menu bar by the
    /// system, so visibility alone cannot reconstruct the assignment after a
    /// relaunch.
    func loadPersistedHostedSectionAssignments() {
        guard let stored = Defaults.dictionary(forKey: .hostedSectionAssignments) as? [String: String] else {
            return
        }
        for (stableID, rawName) in stored {
            guard let section = MenuBarSection.Name(persistenceString: rawName) else {
                continue
            }
            hostedSectionAssignments[stableID] = section
        }
        if !stored.isEmpty {
            Logger.itemManager.info("Restored \(hostedSectionAssignments.count) hosted section assignments")
        }
    }

    func persistHostedSectionAssignments() {
        var stored = [String: String]()
        for (stableID, section) in hostedSectionAssignments {
            stored[stableID] = section.persistenceString
        }
        Defaults.set(stored, forKey: .hostedSectionAssignments)
    }

    /// Removes Ice's control item using semantic metadata when available and
    /// its live status-item frame as a fallback on hosted menu bars.
    func removeControlItem(
        for sectionName: MenuBarSection.Name,
        from items: inout [MenuBarItem]
    ) -> MenuBarItem? {
        guard let index = controlItemIndex(for: sectionName, in: items) else {
            return nil
        }
        return items.remove(at: index)
    }

    /// Locates a control item semantically, with its live frame as a fallback.
    func controlItemIndex(
        for sectionName: MenuBarSection.Name,
        in items: [MenuBarItem]
    ) -> Int? {
        let expectedInfo: MenuBarItemInfo = switch sectionName {
        case .hidden: .hiddenControlItem
        case .alwaysHidden: .alwaysHiddenControlItem
        case .visible: .iceIcon
        }
        if let index = items.firstIndex(matching: expectedInfo) {
            return index
        }
        guard
            let controlItem = appState?.menuBarManager.sections.first(where: { $0.name == sectionName })?.controlItem,
            let controlFrame = controlItem.windowFrame
        else {
            return nil
        }
        let candidates = items.indices.filter { index in
            items[index].ownerPID == ProcessInfo.processInfo.processIdentifier
        }
        guard let index = candidates.min(by: { lhs, rhs in
            abs(items[lhs].frame.midX - controlFrame.midX) < abs(items[rhs].frame.midX - controlFrame.midX)
        }), abs(items[index].frame.midX - controlFrame.midX) <= max(controlFrame.width, 12) else {
            return nil
        }
        return index
    }
}

// MARK: - Logger

extension Logger {
    /// The logger to use for the menu bar item manager.
    static let itemManager = Logger(category: "MenuBarItemManager")
}
