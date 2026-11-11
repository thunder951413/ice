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
                item.canBeHidden
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

    /// The manager's menu bar item cache.
    @Published private(set) var itemCache = ItemCache()

    /// A Boolean value that indicates whether at least one scan has produced a cache.
    @Published private(set) var hasCompletedInitialScan = false

    /// A Boolean value that indicates whether an explicit refresh is currently running.
    @Published private(set) var isRefreshing = false

    /// The shared app state.
    private(set) weak var appState: AppState?

    /// Storage for internal observers.
    private var cancellables = Set<AnyCancellable>()

    /// Logical section assignments for hosted items.
    private var hostedSectionAssignments = [String: MenuBarSection.Name]()

    /// Last known descriptors for hosted items, including currently hidden ones.
    private var hostedItemSnapshots = [String: MenuBarItem]()

    /// Incremented per hosted refresh request; only the latest may publish.
    private var hostedRefreshGeneration = 0

    /// Creates a manager with the given app state.
    init(appState: AppState) {
        self.appState = appState
        loadPersistedHostedSectionAssignments()
    }

    /// Sets up the manager.
    func performSetup() {
        configureCancellables()
    }

    private func configureCancellables() {
        var c = Set<AnyCancellable>()

        Timer.publish(every: 30, on: .main, in: .default)
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

        cancellables = c
    }

    /// Forces a fresh Accessibility scan and updates the item cache.
    func refreshItems() async {
        isRefreshing = true
        defer {
            isRefreshing = false
        }
        HostedMenuBarBackend.invalidateEnumerationCache()
        await cacheItemsIfNeeded()
    }

    /// Caches the current menu bar items.
    func cacheItemsIfNeeded() async {
        hostedRefreshGeneration &+= 1
        let generation = hostedRefreshGeneration
        let snapshot = await HostedMenuBarBackend.refreshDescriptorSnapshot()
        guard generation == hostedRefreshGeneration else {
            return
        }
        let discovered = snapshot.items.map(MenuBarItem.init(hostedHandle:))
            .filter { $0.ownerPID != ProcessInfo.processInfo.processIdentifier }
        cacheHostedItems(
            discovered: discovered,
            scannedPIDs: snapshot.scannedPIDs,
            concealedBundles: snapshot.concealedBundles
        )
        hasCompletedInitialScan = true
    }

    /// Preserve concealed descriptors while their owner is alive: the native
    /// assertion removes them from AX, so absence is not an uninstall signal.
    func cacheHostedItems(
        discovered: [MenuBarItem]? = nil,
        scannedPIDs: Set<pid_t> = [],
        concealedBundles: Set<String> = []
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
        let alwaysEnabled = appState?.settingsManager.generalSettingsManager.enableAlwaysHiddenSection == true
        for item in hostedItemSnapshots.values {
            let ownerKey = item.hostedHandle?.sourceBundleIdentifier.map { "bundle:" + $0 }
            let legacyID = item.stableID.replacingOccurrences(
                of: "|unidentified|",
                with: "|\(item.title ?? "")|"
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
                ?? legacyKeys.lazy.compactMap { self.hostedSectionAssignments[$0] }.first
                ?? .visible
            if !item.canBeHidden {
                section = .visible
            }
            if section == .alwaysHidden && !alwaysEnabled {
                section = .visible
            }
            cache[section].append(item)
        }
        for section in MenuBarSection.Name.allCases {
            cache[section] = cache[section].sorted { lhs, rhs in
                let cmp = lhs.displayName.localizedStandardCompare(rhs.displayName)
                if cmp != .orderedSame {
                    return cmp == .orderedAscending
                }
                return lhs.stableID < rhs.stableID
            }
        }
        if cache != itemCache {
            itemCache = cache
        }
    }

    /// macOS 27 hides by owner bundle, so move all sibling icons together.
    func assignHostedItem(_ item: MenuBarItem, to section: MenuBarSection.Name) {
        guard let handle = item.hostedHandle, item.canBeHidden else {
            return
        }
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
        cacheHostedItems()
    }

    /// Clears all saved section assignments and returns every item to the visible section.
    func resetHostedSectionAssignments() {
        hostedSectionAssignments.removeAll()
        Defaults.removeObject(forKey: .hostedSectionAssignments)
        var cache = ItemCache()
        cache[.visible] = itemCache.allItems.sorted { lhs, rhs in
            let cmp = lhs.displayName.localizedStandardCompare(rhs.displayName)
            if cmp != .orderedSame {
                return cmp == .orderedAscending
            }
            return lhs.stableID < rhs.stableID
        }
        itemCache = cache
        Logger.itemManager.info("Reset hosted section assignments")
    }

    private func loadPersistedHostedSectionAssignments() {
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

    private func persistHostedSectionAssignments() {
        var stored = [String: String]()
        for (stableID, section) in hostedSectionAssignments {
            stored[stableID] = section.persistenceString
        }
        Defaults.set(stored, forKey: .hostedSectionAssignments)
    }
}

// MARK: - Logger

extension Logger {
    static let itemManager = Logger(category: "MenuBarItemManager")
}
