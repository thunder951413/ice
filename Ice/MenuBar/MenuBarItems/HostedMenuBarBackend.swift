//
//  HostedMenuBarBackend.swift
//  Ice
//

import ApplicationServices
import Cocoa

/// A menu bar item discovered through Accessibility on systems where the
/// WindowServer no longer publishes one window per item.
final class HostedMenuBarItemHandle: @unchecked Sendable {
    let element: AXUIElement
    let sourcePID: pid_t
    let sourceBundleIdentifier: String?
    let stableID: String
    let title: String?
    let identityStrings: [String]
    let role: String?
    let subrole: String?
    let windowID: CGWindowID?
    let initialFrame: CGRect
    let requiresGlobalHitTesting: Bool

    init(
        element: AXUIElement,
        sourcePID: pid_t,
        sourceBundleIdentifier: String?,
        stableID: String,
        title: String?,
        identityStrings: [String],
        role: String?,
        subrole: String?,
        windowID: CGWindowID?,
        initialFrame: CGRect,
        requiresGlobalHitTesting: Bool
    ) {
        self.element = element
        self.sourcePID = sourcePID
        self.sourceBundleIdentifier = sourceBundleIdentifier
        self.stableID = stableID
        self.title = title
        self.identityStrings = identityStrings
        self.role = role
        self.subrole = subrole
        self.windowID = windowID
        self.initialFrame = initialFrame
        self.requiresGlobalHitTesting = requiresGlobalHitTesting
    }

    var currentFrame: CGRect? {
        // MenuBarAgent may leave the source app's AX proxy and its last frame
        // alive after concealment. That rectangle can now belong to a neighbor.
        guard !HostedMenuBarBackend.isConcealed(sourceBundleIdentifier) else { return nil }
        if ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 {
            return HostedMenuBarBackend.renderedFrame(for: self)
        }
        if requiresGlobalHitTesting {
            return HostedMenuBarBackend.globalHitFrame(for: sourcePID, matching: title)
        }
        return HostedMenuBarBackend.frame(of: element)
    }

    var isOnScreen: Bool {
        if requiresGlobalHitTesting {
            return currentFrame != nil
        }
        guard let frame = currentFrame else {
            return false
        }
        return NSScreen.screens.contains { CGDisplayBounds($0.displayID).intersects(frame) }
    }

    func performPress() -> Bool {
        if ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 {
            guard !HostedMenuBarBackend.isConcealed(sourceBundleIdentifier),
                  let rendered = HostedMenuBarBackend.renderedElement(for: self) else { return false }
            return AXUIElementPerformAction(rendered, kAXPressAction as CFString) == .success
        }
        return AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
    }
}

/// Accessibility-backed discovery used when the legacy CGS menu bar list only
/// contains the menu bar background window.
enum HostedMenuBarBackend {
    enum Mode: String {
        case legacyWindows
        case hostedAccessibility
        case unavailable
    }

    private static let logger = Logger(category: "HostedMenuBarBackend")
    private static var hitFrameCache = [String: (date: Date, frame: CGRect)]()
    private struct RenderedItem {
        let element: AXUIElement
        let pid: pid_t
        let frame: CGRect
        let identityStrings: Set<String>
    }
    private static var renderedSnapshot: (date: Date, items: [RenderedItem])?
    private static var isReadingRenderedSnapshot = false
    private static let renderedFrameCacheTTL: TimeInterval = 0.25

    /// Cached result of ``enumerate()``. AX enumeration walks every running
    /// application and is synchronous; without caching it stalls the main
    /// thread on every menu bar click and on the 5-second cache refresh timer.
    private static var enumerationCache: (date: Date, items: [HostedMenuBarItemHandle])?
    /// How long a cached enumeration result is considered fresh.
    private static let enumerationTTL: TimeInterval = 2
    /// Guards against concurrent re-enumeration when multiple call sites hit
    /// ``enumerate()`` simultaneously (e.g. the 5s timer fires while the user
    /// clicks the Ice icon).
    private static let enumerationLock = NSLock()
    /// Accessibility queries can block in another process. Keep the complete
    /// walk off the main actor, and serialize it so a burst of layout events
    /// becomes one bounded scan instead of several competing scans.
    private static let enumerationQueue = DispatchQueue(label: "com.jordansamuel.ice.hosted-menu-bar-enumeration")
    /// Set while an enumeration is in progress so callers can short-circuit
    /// instead of piling up behind the lock and then all re-running the scan.
    private static var isEnumerating = false
    private static var cacheGeneration = 0
    /// Circular cursor used by bounded macOS 27 scans. A slow app cannot keep
    /// later owners permanently beyond the total scan budget.
    private static var enumerationCursor = 0
    private static var enumerationWaiters = [CheckedContinuation<[HostedMenuBarItemHandle], Never>]()
    private static var pendingEnumerationSnapshot: EnumerationSnapshot?
    private static var concealedBundleIdentifiers = Set<String>()
    private static let perApplicationTimeout: Float = 0.15
    private static let perApplicationBudget: TimeInterval = 0.35
    private static let scanBudget: TimeInterval = 1.5

    private struct ApplicationSnapshot: Sendable {
        let pid: pid_t
        let bundleIdentifier: String?
        let isResponsive: Bool
    }

    private struct EnumerationSnapshot: Sendable {
        let applications: [ApplicationSnapshot]
        let displayBounds: [CGRect]
    }

    private struct EnumerationScan {
        let items: [HostedMenuBarItemHandle]
        let scannedPIDs: Set<pid_t>
        let livePIDs: Set<pid_t>
        let nextCursor: Int
    }

    private enum AttributeRead<Value> {
        case value(Value)
        /// The owner answered, but does not expose this attribute. This is a
        /// genuine absence and may clear descriptors for that owner.
        case absent
        /// AX could not answer reliably (including cannotComplete/timeout).
        /// Preserve the prior owner snapshot and retry on a later cursor lap.
        case failed(AXError)
    }

    static func isConcealed(_ bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        enumerationLock.lock()
        defer { enumerationLock.unlock() }
        return concealedBundleIdentifiers.contains(bundleIdentifier)
    }

    static func setConcealedBundleIdentifiers(_ identifiers: Set<String>) {
        enumerationLock.lock()
        concealedBundleIdentifiers = identifiers
        cacheGeneration += 1
        expireEnumerationCacheLocked()
        hitFrameCache.removeAll()
        renderedSnapshot = nil
        enumerationLock.unlock()
    }

    /// Whether a legacy result contains actual item windows rather than only the
    /// full-width menu bar background.
    static func legacyListContainsItems(_ windowIDs: [CGWindowID]) -> Bool {
        let frames = windowIDs.compactMap(Bridging.getWindowFrame)
        guard !frames.isEmpty else {
            return false
        }
        // Presence of a full-width host is the capability signal on newer
        // systems. It can coexist with a small number of legacy-looking windows,
        // so prefer AX for the whole set rather than producing a partial cache.
        return !frames.contains { frame in
            let isFullWidthMenuBar = NSScreen.screens.contains { screen in
                abs(frame.width - screen.frame.width) <= 2 && frame.height <= 80
            }
            return isFullWidthMenuBar
        }
    }

    /// Selects the discovery backend from observed system capabilities instead
    /// of relying on an OS-version check.
    static func preferredMode(for legacyWindowIDs: [CGWindowID]) -> Mode {
        if ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 {
            return AXIsProcessTrusted() ? .hostedAccessibility : .unavailable
        }
        if legacyListContainsItems(legacyWindowIDs) {
            return .legacyWindows
        }
        return AXIsProcessTrusted() ? .hostedAccessibility : .unavailable
    }

    /// Enumerates extras menu bar children for each responsive application.
    ///
    /// Results are cached for ``enumerationTTL`` seconds. Callers that need a
    /// definitely-fresh snapshot can pass `forceRefresh: true`, but this should
    /// be reserved for explicit user actions (never for periodic timers).
    static func enumerate(forceRefresh: Bool = false) -> [HostedMenuBarItemHandle] {
        // On hosted menu bars this method is called from paint, event, and
        // timer paths. It must only return the last complete snapshot; schedule
        // a refresh rather than allowing a synchronous AX walk on the main
        // thread. Pre-27 keeps the existing synchronous behavior.
        if ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 {
            requestEnumerationRefresh(force: forceRefresh)
            enumerationLock.lock()
            let cached = enumerationCache?.items ?? []
            enumerationLock.unlock()
            return cached
        }
        guard AXIsProcessTrusted() else {
            logger.warning("Accessibility permission is unavailable")
            return []
        }

        enumerationLock.lock()
        if !forceRefresh, let cached = enumerationCache, Date.now.timeIntervalSince(cached.date) < enumerationTTL {
            enumerationLock.unlock()
            return cached.items
        }
        if isEnumerating {
            let cached = enumerationCache?.items ?? []
            enumerationLock.unlock()
            return cached
        }
        isEnumerating = true
        let generation = cacheGeneration
        enumerationLock.unlock()

        let result = enumerateUncached().items
        enumerationLock.lock()
        if generation == cacheGeneration { enumerationCache = (.now, result) }
        isEnumerating = false
        enumerationLock.unlock()
        return result
    }

    /// Refreshes the hosted descriptor snapshot. This is intended for an
    /// explicit action which needs to await a new scan (for example, retrying a
    /// click after revealing an item). Concurrent requests join the same scan.
    @MainActor
    static func refreshEnumeration(force: Bool = false) async -> [HostedMenuBarItemHandle] {
        guard AXIsProcessTrusted() else { return [] }
        let cachedItems = enumerationLock.withLock { () -> [HostedMenuBarItemHandle]? in
            guard !force, let cached = enumerationCache,
                  Date.now.timeIntervalSince(cached.date) < enumerationTTL else { return nil }
            return cached.items
        }
        if let cachedItems { return cachedItems }
        return await refreshEnumeration(snapshot: makeEnumerationSnapshot(), force: force)
    }

    /// Requests a refresh without making a UI path wait for it.
    static func requestEnumerationRefresh(force: Bool = false) {
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 else { return }
        enumerationLock.lock()
        let cacheIsFresh = enumerationCache.map {
            Date.now.timeIntervalSince($0.date) < enumerationTTL
        } ?? false
        let shouldRequest = HostedEnumerationScanPolicy.shouldRequestRefresh(
            cacheIsFresh: cacheIsFresh, scanInFlight: isEnumerating, force: force
        )
        enumerationLock.unlock()
        guard shouldRequest else { return }
        Task { @MainActor in
            _ = await refreshEnumeration(force: force)
        }
    }

    @MainActor
    private static func makeEnumerationSnapshot() -> EnumerationSnapshot {
        let applications = NSWorkspace.shared.runningApplications.compactMap { app -> ApplicationSnapshot? in
            guard app.isFinishedLaunching, !app.isTerminated else { return nil }
            return ApplicationSnapshot(
                pid: app.processIdentifier,
                bundleIdentifier: app.bundleIdentifier,
                isResponsive: Bridging.responsivity(for: app.processIdentifier) != .unresponsive
            )
        }
        // NSWorkspace and NSScreen are AppKit snapshots and must stay on main.
        return EnumerationSnapshot(applications: applications,
                                   displayBounds: NSScreen.screens.map { CGDisplayBounds($0.displayID) })
    }

    private static func refreshEnumeration(snapshot: EnumerationSnapshot, force: Bool) async -> [HostedMenuBarItemHandle] {
        await withCheckedContinuation { continuation in
            enumerationLock.lock()
            if !force, let cached = enumerationCache,
               Date.now.timeIntervalSince(cached.date) < enumerationTTL {
                enumerationLock.unlock()
                continuation.resume(returning: cached.items)
                return
            }
            enumerationWaiters.append(continuation)
            if isEnumerating {
                // Keep the newest main-thread view of processes and displays;
                // it is used if the in-flight scan is invalidated.
                pendingEnumerationSnapshot = snapshot
                enumerationLock.unlock()
                return
            }
            isEnumerating = true
            let generation = cacheGeneration
            let cursor = enumerationCursor
            enumerationLock.unlock()
            startEnumeration(snapshot: snapshot, generation: generation, cursor: cursor)
        }
    }

    private static func startEnumeration(snapshot: EnumerationSnapshot, generation: Int, cursor: Int) {
        enumerationQueue.async {
            let result = enumerateUncached(snapshot: snapshot, cursor: cursor)
            enumerationLock.lock()
            if generation == cacheGeneration {
                enumerationCursor = result.nextCursor
                // A budgeted scan only replaces descriptors for owners it
                // actually queried. Existing descriptors for later owners stay
                // available until their turn, while exited owners are removed.
                let retainedOwners = HostedEnumerationScanPolicy.retainedOwners(
                    existing: Set((enumerationCache?.items ?? []).map(\.sourcePID)),
                    live: result.livePIDs,
                    scanned: result.scannedPIDs
                )
                let retained = (enumerationCache?.items ?? []).filter {
                    retainedOwners.contains($0.sourcePID)
                }
                enumerationCache = (.now, retained + result.items)
            } else if let newerSnapshot = pendingEnumerationSnapshot {
                // A launch/quit/display event arrived while AX was blocked. Do
                // not publish its old result; immediately coalesce waiters onto
                // one replacement scan using the newer main-thread snapshot.
                pendingEnumerationSnapshot = nil
                let newerGeneration = cacheGeneration
                let newerCursor = enumerationCursor
                enumerationLock.unlock()
                startEnumeration(snapshot: newerSnapshot, generation: newerGeneration, cursor: newerCursor)
                return
            }
            // An invalidation while AX was blocked makes the result stale.
            // Return the newer cache (or nothing), never the stale result.
            let reply = enumerationCache?.items ?? []
            let waiters = enumerationWaiters
            enumerationWaiters.removeAll()
            isEnumerating = false
            pendingEnumerationSnapshot = nil
            enumerationLock.unlock()
            waiters.forEach { $0.resume(returning: reply) }
        }
    }

    private static func enumerateUncached(snapshot: EnumerationSnapshot? = nil, cursor: Int = 0) -> EnumerationScan {
        var result = [HostedMenuBarItemHandle]()
        var stableIDOccurrences = [String: Int]()
        // The bounded scan is specific to the macOS 27 hosted path. Keep the
        // established 14–26 fallback behavior unchanged.
        let deadline = snapshot.map { _ in Date.now.addingTimeInterval(scanBudget) }

        let applications: [ApplicationSnapshot]
        let displayBounds: [CGRect]
        if let snapshot {
            applications = snapshot.applications
            displayBounds = snapshot.displayBounds
        } else {
            // Legacy callers retain their previous behavior.
            applications = NSWorkspace.shared.runningApplications.compactMap { app in
                guard app.isFinishedLaunching, !app.isTerminated,
                      Bridging.responsivity(for: app.processIdentifier) != .unresponsive else { return nil }
                return ApplicationSnapshot(pid: app.processIdentifier, bundleIdentifier: app.bundleIdentifier, isResponsive: true)
            }
            displayBounds = NSScreen.screens.map { CGDisplayBounds($0.displayID) }
        }

        let scannableApplications = snapshot == nil
            ? applications
            : applications.filter(\.isResponsive)
        let start = scannableApplications.isEmpty ? 0 : cursor % scannableApplications.count
        let orderedApplications = snapshot != nil
            ? HostedEnumerationScanPolicy.orderedIndices(count: scannableApplications.count, cursor: cursor).map { scannableApplications[$0] }
            : scannableApplications
        var scannedPIDs = Set<pid_t>()
        var nextCursor = start

        applicationLoop: for (offset, app) in orderedApplications.enumerated() {
            guard deadline.map({ Date.now < $0 }) ?? true else {
                logger.warning("Hosted menu bar enumeration exceeded its scan budget")
                break
            }
            if !scannableApplications.isEmpty {
                nextCursor = HostedEnumerationScanPolicy.nextCursor(
                    count: scannableApplications.count, cursor: start, scannedCount: offset + 1
                )
            }
            let applicationDeadline = deadline.map {
                min($0, Date.now.addingTimeInterval(perApplicationBudget))
            } ?? .distantFuture
            let itemStartIndex = result.endIndex

            let appElement = AXUIElementCreateApplication(app.pid)
            AXUIElementSetMessagingTimeout(appElement, perApplicationTimeout)
            let menuBar: AXUIElement
            switch attributeRead(kAXExtrasMenuBarAttribute, of: appElement) as AttributeRead<AXUIElement> {
            case let .value(value):
                menuBar = value
            case .absent:
                scannedPIDs.insert(app.pid)
                continue
            case let .failed(error):
                logger.debug("Could not read hosted menu bar for pid \(app.pid): \(String(describing: error))")
                continue
            }
            let children: [AXUIElement]
            switch attributeRead(kAXChildrenAttribute, of: menuBar) as AttributeRead<[AXUIElement]> {
            case let .value(value):
                children = value
            case .absent:
                scannedPIDs.insert(app.pid)
                continue
            case let .failed(error):
                logger.debug("Could not read hosted menu bar children for pid \(app.pid): \(String(describing: error))")
                continue
            }

            for element in children {
                guard Date.now < applicationDeadline else {
                    // Do not replace this owner's prior complete descriptors
                    // with a prefix gathered before its individual budget ran
                    // out. It will be retried after the cursor completes a lap.
                    result.removeSubrange(itemStartIndex..<result.endIndex)
                    logger.debug("Hosted menu bar enumeration timed out for pid \(app.pid)")
                    continue applicationLoop
                }
                guard let frame = frame(of: element), frame.width > 0, frame.height > 0 else {
                    continue
                }
                guard Date.now < applicationDeadline else {
                    result.removeSubrange(itemStartIndex..<result.endIndex)
                    logger.debug("Hosted menu bar enumeration timed out for pid \(app.pid)")
                    continue applicationLoop
                }

                let identifier: String? = attribute(kAXIdentifierAttribute, of: element)
                let identityStrings = [
                    identifier,
                    attribute(kAXTitleAttribute, of: element),
                    attribute(kAXHelpAttribute, of: element),
                    attribute(kAXDescriptionAttribute, of: element),
                ]
                .compactMap { (value: String?) -> String? in
                    guard let value, !value.isEmpty else { return nil }
                    return value
                }
                let title = identityStrings.first
                guard Date.now < applicationDeadline else {
                    result.removeSubrange(itemStartIndex..<result.endIndex)
                    logger.debug("Hosted menu bar enumeration timed out for pid \(app.pid)")
                    continue applicationLoop
                }
                let role: String? = attribute(kAXRoleAttribute, of: element)
                let subrole: String? = attribute(kAXSubroleAttribute, of: element)
                let baseStableID = [
                    app.bundleIdentifier ?? "pid:\(app.pid)",
                    role ?? "",
                    subrole ?? "",
                    identifier.flatMap { $0.isEmpty ? nil : $0 } ?? "unidentified",
                ].joined(separator: "|")
                let occurrence = stableIDOccurrences[baseStableID, default: 0]
                stableIDOccurrences[baseStableID] = occurrence + 1
                let stableID = "\(baseStableID)|\(occurrence)"

                var resolvedWindowID: CGWindowID = 0
                let windowResult = _AXUIElementGetWindow(element, &resolvedWindowID)
                let windowID = windowResult == .success && resolvedWindowID != 0
                    ? resolvedWindowID
                    : nil
                guard Date.now < applicationDeadline else {
                    result.removeSubrange(itemStartIndex..<result.endIndex)
                    logger.debug("Hosted menu bar enumeration timed out for pid \(app.pid)")
                    continue applicationLoop
                }
                let isGlobalFrame = displayBounds.contains { bounds in
                    return frame.minY <= bounds.minY + 80 && frame.intersects(bounds)
                }
                // globalHitFrame is extremely expensive (hundreds of synchronous
                // cross-process AX hit-tests). Defer it: mark the item as
                // requiring global hit testing, but only resolve the frame on
                // demand from ``currentFrame``. Never run it during enumeration.
                let requiresGlobalHitTesting = !isGlobalFrame

                result.append(
                    HostedMenuBarItemHandle(
                        element: element,
                        sourcePID: app.pid,
                        sourceBundleIdentifier: app.bundleIdentifier,
                        stableID: stableID,
                        title: title,
                        identityStrings: identityStrings,
                        role: role,
                        subrole: subrole,
                        windowID: windowID,
                        initialFrame: frame,
                        requiresGlobalHitTesting: requiresGlobalHitTesting
                    )
                )
            }
            scannedPIDs.insert(app.pid)
        }

        // AX can expose system-created clones at identical positions. Prefer one
        // descriptor per source application and frame.
        var seen = Set<String>()
        let deduplicated = result.filter { item in
            let key = "\(item.sourcePID)|\(NSStringFromRect(item.initialFrame))|\(item.title ?? "")"
            return seen.insert(key).inserted
        }
        logger.debug("Discovered \(deduplicated.count) hosted menu bar items")
        return EnumerationScan(items: deduplicated,
                               scannedPIDs: scannedPIDs,
                               livePIDs: Set(applications.map(\.pid)),
                               nextCursor: nextCursor)
    }

    static func frame(of element: AXUIElement) -> CGRect? {
        guard
            let positionValue: AXValue = attribute(kAXPositionAttribute, of: element),
            let sizeValue: AXValue = attribute(kAXSizeAttribute, of: element),
            AXValueGetType(positionValue) == .cgPoint,
            AXValueGetType(sizeValue) == .cgSize
        else {
            return nil
        }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard
            AXValueGetValue(positionValue, .cgPoint, &position),
            AXValueGetValue(sizeValue, .cgSize, &size)
        else {
            return nil
        }
        return CGRect(origin: position, size: size)
    }

    /// Resolves an item's rendered frame from MenuBarAgent's accessibility
    /// tree. On macOS 27 an app's `AXExtrasMenuBar` proxy can retain its old
    /// frame after the item is removed, while a system-wide hit test can return
    /// a neighbouring application's element. The host tree is authoritative:
    /// only a descendant that still identifies as the source item is accepted.
    static func renderedFrame(for item: HostedMenuBarItemHandle) -> CGRect? {
        matchingRenderedItem(for: item, forceRefresh: false)?.frame
    }

    /// The actual occupied rectangles, including system items that have no
    /// corresponding source-app extra. Empty-space clicks need only this tree.
    static func renderedItemFrames(for sourcePID: pid_t? = nil) -> [CGRect] {
        renderedItems().filter { sourcePID == nil || $0.pid == sourcePID }.map(\.frame)
    }

    static func renderedElement(for item: HostedMenuBarItemHandle) -> AXUIElement? {
        // A click must reacquire after any reflow rather than trusting a hover
        // snapshot. Ordinary layout reads share the short-lived snapshot below.
        matchingRenderedItem(for: item, forceRefresh: true)?.element
    }

    private static func matchingRenderedItem(for source: HostedMenuBarItemHandle, forceRefresh: Bool) -> RenderedItem? {
        let sourceStrings = Set(source.identityStrings)
        let matches = renderedItems(forceRefresh: forceRefresh).filter { candidate in
            guard candidate.pid == source.sourcePID else { return false }
            if CFEqual(candidate.element, source.element) { return true }
            if source.sourceBundleIdentifier == "com.apple.MenuBarAgent" {
                return !sourceStrings.isEmpty && !sourceStrings.isDisjoint(with: candidate.identityStrings)
            }
            return sourceStrings.isEmpty || candidate.identityStrings.isEmpty ||
                !sourceStrings.isDisjoint(with: candidate.identityStrings)
        }
        // Multiple same-owner icons without identifiers cannot safely be picked
        // by index: refuse ambiguity instead of activating a neighboring item.
        guard let first = matches.first,
              matches.dropFirst().allSatisfy({ $0.frame == first.frame }) else { return nil }
        return first
    }

    private static func renderedItems(forceRefresh: Bool = false) -> [RenderedItem] {
        enumerationLock.lock()
        if !forceRefresh, let cached = renderedSnapshot,
           Date.now.timeIntervalSince(cached.date) < renderedFrameCacheTTL {
            enumerationLock.unlock()
            return cached.items
        }
        if isReadingRenderedSnapshot {
            let items = renderedSnapshot?.items ?? []
            enumerationLock.unlock()
            return items
        }
        isReadingRenderedSnapshot = true
        let generation = cacheGeneration
        enumerationLock.unlock()

        let items = readRenderedItems()
        enumerationLock.lock()
        let isCurrent = generation == cacheGeneration
        if isCurrent { renderedSnapshot = (.now, items) }
        isReadingRenderedSnapshot = false
        enumerationLock.unlock()
        return isCurrent ? items : []
    }

    /// Walk MenuBarAgent once for every item in a layout/hit-test batch. Read
    /// each leaf's AX metadata once; matching individual owners is then in-memory.
    private static func readRenderedItems() -> [RenderedItem] {
        guard let host = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.MenuBarAgent").first else { return [] }
        let application = AXUIElementCreateApplication(host.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.15)
        guard let windows: [AXUIElement] = attribute(kAXWindowsAttribute, of: application) else { return [] }
        var remainingNodes = 512
        var visited = Set<AXUIElement>()
        var result = [RenderedItem]()
        func visit(_ element: AXUIElement, depth: Int) {
            guard depth > 0, remainingNodes > 0, visited.insert(element).inserted else { return }
            remainingNodes -= 1
            let role: String? = attribute(kAXRoleAttribute, of: element)
            if role == kAXButtonRole as String || role == kAXMenuBarItemRole as String {
                var pid: pid_t = 0
                if AXUIElementGetPid(element, &pid) == .success,
                   let frame = frame(of: element), isMenuBarFrame(frame) {
                    let strings: [String?] = [
                        attribute(kAXIdentifierAttribute, of: element),
                        attribute(kAXTitleAttribute, of: element),
                        attribute(kAXHelpAttribute, of: element),
                        attribute(kAXDescriptionAttribute, of: element),
                    ]
                    result.append(RenderedItem(element: element, pid: pid, frame: frame,
                        identityStrings: Set(strings.compactMap { $0 }.filter { !$0.isEmpty })))
                }
                // Descending into a status button's open menu confuses its menu
                // contents with the status item and adds synchronous AX traffic.
                return
            }
            if let children: [AXUIElement] = attribute(kAXChildrenAttribute, of: element) {
                for child in children { visit(child, depth: depth - 1) }
            }
        }
        for window in windows { visit(window, depth: 12) }
        return result
    }

    private static func isMenuBarFrame(_ frame: CGRect) -> Bool {
        frame.width > 0 && frame.height > 0 && NSScreen.screens.contains { screen in
            let bounds = CGDisplayBounds(screen.displayID)
            return frame.intersects(bounds) && frame.minY <= bounds.minY + 80
        }
    }

    /// Resolves the global frame of a hosted item by hit-testing the real menu
    /// bar. Some applications expose only window-local AX coordinates.
    ///
    /// This is expensive: each probe is a synchronous cross-process AX call. To
    /// keep menu bar interactions responsive we (1) cache results for 2 seconds,
    /// (2) use an 8pt stride instead of 2pt, and (3) bail out as soon as a
    /// single contiguous run is found rather than scanning the whole screen.
    static func globalHitFrame(for pid: pid_t, matching title: String?) -> CGRect? {
        let cacheKey = "\(pid)|\(title ?? "")"
        enumerationLock.lock()
        let cached = hitFrameCache[cacheKey]
        let generation = cacheGeneration
        enumerationLock.unlock()
        if let cached, Date.now.timeIntervalSince(cached.date) < 2 {
            return cached.frame.isNull ? nil : cached.frame
        }

        let systemWide = AXUIElementCreateSystemWide()
        var bestFrame: CGRect?
        for screen in NSScreen.screens {
            guard bestFrame == nil else { break }
            let bounds = CGDisplayBounds(screen.displayID)
            let y = Float(bounds.minY + min(NSStatusBar.system.thickness / 2, 15))
            var runStart: CGFloat?
            var runEnd: CGFloat?

            func finishRun() {
                guard let start = runStart, let end = runEnd else { return }
                let candidate = CGRect(x: start, y: bounds.minY, width: max(2, end - start + 2), height: NSStatusBar.system.thickness)
                if candidate.width <= 300, bestFrame == nil || candidate.maxX > bestFrame!.maxX {
                    bestFrame = candidate
                }
                runStart = nil
                runEnd = nil
            }

            for x in stride(from: bounds.midX, through: bounds.maxX - 1, by: 8) {
                var element: AXUIElement?
                var hitPID: pid_t = 0
                if
                    AXUIElementCopyElementAtPosition(systemWide, Float(x), y, &element) == .success,
                    let element
                {
                    AXUIElementGetPid(element, &hitPID)
                }
                let hitTitle = element.flatMap {
                    firstNonemptyString([
                        attribute(kAXIdentifierAttribute, of: $0),
                        attribute(kAXTitleAttribute, of: $0),
                        attribute(kAXHelpAttribute, of: $0),
                        attribute(kAXDescriptionAttribute, of: $0),
                    ])
                }
                if hitPID == pid && (title == nil || hitTitle == title) {
                    runStart = runStart ?? x
                    runEnd = x
                } else {
                    finishRun()
                }
            }
            finishRun()
        }

        enumerationLock.lock()
        if generation == cacheGeneration { hitFrameCache[cacheKey] = (.now, bestFrame ?? .null) }
        enumerationLock.unlock()
        return bestFrame
    }

    /// Invalidates the enumeration cache. Call this when the set of running
    /// applications is known to have changed (e.g. an app launched or quit).
    static func invalidateEnumerationCache() {
        enumerationLock.lock()
        cacheGeneration += 1
        expireEnumerationCacheLocked()
        hitFrameCache.removeAll()
        renderedSnapshot = nil
        enumerationLock.unlock()
    }

    /// Keep descriptors across an invalidation so a budgeted replacement pass
    /// can retain owners it has not yet reached. Generation checks still stop
    /// the pre-invalidation AX result from ever being published.
    private static func expireEnumerationCacheLocked() {
        enumerationCache = enumerationCache.map { (date: .distantPast, items: $0.items) }
    }

    /// Invalidates the cached global hit-test frame for the given item.
    ///
    /// ``globalHitFrame(for:matching:)`` caches its result for 2 seconds. A
    /// synthetic Command-drag verifies its effect by comparing the item's frame
    /// before and after the drag, but the stale cache makes the post-drag read
    /// return the pre-drag position, so a successful move is reported as failed.
    /// Call this between the drag and the verification read to force a fresh probe.
    static func invalidateGlobalHitFrameCache(for pid: pid_t, title: String?) {
        let key = "\(pid)|\(title ?? "")"
        enumerationLock.lock()
        hitFrameCache.removeValue(forKey: key)
        renderedSnapshot = nil
        enumerationLock.unlock()
    }

    private static func attributeRead<T>(_ name: String, of element: AXUIElement) -> AttributeRead<T> {
        var value: CFTypeRef?
        switch AXUIElementCopyAttributeValue(element, name as CFString, &value) {
        case .success:
            guard let typedValue = value as? T else { return .failed(.failure) }
            return .value(typedValue)
        case .noValue, .attributeUnsupported:
            return .absent
        case let error:
            return .failed(error)
        }
    }

    private static func attribute<T>(_ name: String, of element: AXUIElement) -> T? {
        guard case let .value(value) = attributeRead(name, of: element) as AttributeRead<T> else { return nil }
        return value
    }

    private static func firstNonemptyString(_ values: [String?]) -> String? {
        values.compactMap { (value: String?) -> String? in
            guard let value, !value.isEmpty else { return nil }
            return value
        }.first
    }
}
