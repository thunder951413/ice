//
//  HostedMenuBarBackend+Enumeration.swift
//  Ice
//

import ApplicationServices
import Cocoa

extension HostedMenuBarBackend {
    /// How long a cached enumeration result is considered fresh.
    private static let enumerationTTL: TimeInterval = 2
    private static let perApplicationTimeout: Float = 0.15
    private static let perApplicationBudget: TimeInterval = 0.35
    private static let scanBudget: TimeInterval = 1.5
    /// Bounded so a stream of invalidations cannot keep waiters forever.
    private static let maxEnumerationRestarts = 2

    private struct EnumerationScan {
        let items: [HostedMenuBarItemHandle]
        let scannedPIDs: Set<pid_t>
        let livePIDs: Set<pid_t>
        let nextCursor: Int
    }

    /// Returns the last complete descriptor snapshot immediately and schedules
    /// a background refresh when the cache is stale.
    static func enumerate(forceRefresh: Bool = false) -> [HostedMenuBarItemHandle] {
        requestEnumerationRefresh(force: forceRefresh)
        return enumerationState.withLock { $0.cache?.snapshot.items ?? [] }
    }

    /// Refreshes the hosted descriptor snapshot. Intended for explicit actions
    /// that need to await a fresh scan (e.g. retrying a click after revealing an item).
    /// Concurrent requests join the same scan.
    @MainActor
    static func refreshEnumeration(force: Bool = false) async -> [HostedMenuBarItemHandle] {
        await refreshDescriptorSnapshot(force: force).items
    }

    @MainActor
    static func refreshDescriptorSnapshot(force: Bool = false) async -> DescriptorSnapshot {
        guard AXIsProcessTrusted() else {
            return .empty
        }
        let cachedSnapshot = enumerationState.withLock { state -> DescriptorSnapshot? in
            guard
                !force,
                let cached = state.cache,
                Date.now.timeIntervalSince(cached.date) < enumerationTTL
            else {
                return nil
            }
            return cached.snapshot
        }
        if let cachedSnapshot {
            return cachedSnapshot
        }
        return await refreshEnumeration(snapshot: makeEnumerationSnapshot(), force: force)
    }

    /// Requests a background refresh without making a UI path wait for it.
    static func requestEnumerationRefresh(force: Bool = false) {
        let shouldRequest = enumerationState.withLock { state -> Bool in
            let cacheIsFresh = state.cache.map {
                Date.now.timeIntervalSince($0.date) < enumerationTTL
            } ?? false
            return HostedEnumerationScanPolicy.shouldRequestRefresh(
                cacheIsFresh: cacheIsFresh,
                scanInFlight: state.isEnumerating,
                force: force
            )
        }
        guard shouldRequest else {
            return
        }
        Task { @MainActor in
            _ = await refreshEnumeration(force: force)
        }
    }

    @MainActor
    private static func makeEnumerationSnapshot() -> EnumerationSnapshot {
        let applications = NSWorkspace.shared.runningApplications.compactMap { app -> ApplicationSnapshot? in
            guard app.isFinishedLaunching, !app.isTerminated else {
                return nil
            }
            return ApplicationSnapshot(
                pid: app.processIdentifier,
                bundleIdentifier: app.bundleIdentifier,
                isResponsive: Bridging.responsivity(for: app.processIdentifier) != .unresponsive
            )
        }
        // NSWorkspace and NSScreen are AppKit snapshots and must stay on main.
        return EnumerationSnapshot(
            applications: applications,
            displayBounds: NSScreen.screens.map { CGDisplayBounds($0.displayID) }
        )
    }

    private static func refreshEnumeration(snapshot: EnumerationSnapshot, force: Bool) async -> DescriptorSnapshot {
        await withCheckedContinuation { continuation in
            let startInfo = enumerationState.withLock { state -> (generation: Int, cursor: Int)? in
                if
                    !force,
                    let cached = state.cache,
                    Date.now.timeIntervalSince(cached.date) < enumerationTTL
                {
                    continuation.resume(returning: cached.snapshot)
                    return nil
                }
                state.waiters.append(continuation)
                if state.isEnumerating {
                    // Keep the newest main-thread view of processes and displays;
                    // it is used if the in-flight scan is invalidated.
                    state.pendingSnapshot = snapshot
                    return nil
                }
                state.isEnumerating = true
                return (state.cacheGeneration, state.cursor)
            }
            if let startInfo {
                startEnumeration(
                    snapshot: snapshot,
                    generation: startInfo.generation,
                    cursor: startInfo.cursor
                )
            }
        }
    }

    private static func startEnumeration(
        snapshot: EnumerationSnapshot,
        generation: Int,
        cursor: Int,
        restarts: Int = 0
    ) {
        enumerationQueue.async {
            let result = enumerateUncached(snapshot: snapshot, cursor: cursor)

            enum CompletionAction {
                case restart(EnumerationSnapshot, Int, Int)
                case refreshSnapshotAndRestart
                case finish(DescriptorSnapshot, [CheckedContinuation<DescriptorSnapshot, Never>])
            }

            let action: CompletionAction = enumerationState.withLock { state in
                if generation == state.cacheGeneration {
                    state.cursor = result.nextCursor
                    // A budgeted scan only replaces descriptors for owners it
                    // actually queried. Existing descriptors for later owners stay
                    // available until their turn, while exited owners are removed.
                    let existingItems = state.cache?.snapshot.items ?? []
                    let retainedOwners = HostedEnumerationScanPolicy.retainedOwners(
                        existing: Set(existingItems.map(\.sourcePID)),
                        live: result.livePIDs,
                        scanned: result.scannedPIDs
                    )
                    let retained = existingItems.filter { retainedOwners.contains($0.sourcePID) }
                    state.cache = (
                        .now,
                        DescriptorSnapshot(
                            items: retained + result.items,
                            scannedPIDs: result.scannedPIDs,
                            concealedBundles: state.concealedBundleIdentifiers
                        ),
                    )
                } else if restarts < maxEnumerationRestarts, let newerSnapshot = state.pendingSnapshot {
                    // A launch/quit/display event arrived while AX was blocked. Do
                    // not publish its old result; immediately coalesce waiters onto
                    // one replacement scan using the newer main-thread snapshot.
                    state.pendingSnapshot = nil
                    return .restart(newerSnapshot, state.cacheGeneration, state.cursor)
                } else if restarts < maxEnumerationRestarts {
                    // Invalidated by a launch/quit/visibility change with no newer
                    // request queued. Waiters asked for a fresh scan, so do not hand
                    // them the expired cache: rescan with a current process list.
                    return .refreshSnapshotAndRestart
                }

                // An invalidation while AX was blocked makes the result stale.
                // Return the newer cache (or nothing), never the stale result.
                let reply = state.cache?.snapshot ?? .empty
                let waiters = state.waiters
                state.waiters.removeAll()
                state.isEnumerating = false
                state.pendingSnapshot = nil
                return .finish(reply, waiters)
            }

            switch action {
            case let .restart(newerSnapshot, newerGeneration, newerCursor):
                startEnumeration(
                    snapshot: newerSnapshot,
                    generation: newerGeneration,
                    cursor: newerCursor,
                    restarts: restarts + 1
                )
            case .refreshSnapshotAndRestart:
                Task { @MainActor in
                    let newerSnapshot = makeEnumerationSnapshot()
                    let (newerGeneration, newerCursor) = enumerationState.withLock {
                        ($0.cacheGeneration, $0.cursor)
                    }
                    startEnumeration(
                        snapshot: newerSnapshot,
                        generation: newerGeneration,
                        cursor: newerCursor,
                        restarts: restarts + 1
                    )
                }
            case let .finish(reply, waiters):
                waiters.forEach { $0.resume(returning: reply) }
            }
        }
    }

    private static func enumerateUncached(snapshot: EnumerationSnapshot, cursor: Int) -> EnumerationScan {
        var result = [HostedMenuBarItemHandle]()
        var stableIDOccurrences = [String: Int]()
        let deadline = Date.now.addingTimeInterval(scanBudget)
        let applications = snapshot.applications
        let displayBounds = snapshot.displayBounds

        let scannableApplications = applications.filter(\.isResponsive)
        let start = scannableApplications.isEmpty ? 0 : cursor % scannableApplications.count
        let orderedApplications = HostedEnumerationScanPolicy
            .orderedIndices(count: scannableApplications.count, cursor: cursor)
            .map { scannableApplications[$0] }
        var scannedPIDs = Set<pid_t>()
        var nextCursor = start

        applicationLoop: for (offset, app) in orderedApplications.enumerated() {
            guard Date.now < deadline else {
                logger.warning("Hosted menu bar enumeration exceeded its scan budget")
                break
            }
            if !scannableApplications.isEmpty {
                nextCursor = HostedEnumerationScanPolicy.nextCursor(
                    count: scannableApplications.count,
                    cursor: start,
                    scannedCount: offset + 1
                )
            }
            let applicationDeadline = min(deadline, Date.now.addingTimeInterval(perApplicationBudget))
            let itemStartIndex = result.endIndex

            let appElement = AXUIElementCreateApplication(app.pid)
            AXUIElementSetMessagingTimeout(appElement, perApplicationTimeout)
            let menuBar: AXUIElement
            switch attributeRead(kAXExtrasMenuBarAttribute, of: appElement) as AttributeRead<AXUIElement> {
            case let .value(value):
                menuBar = value
                // Messaging timeouts are per element reference; children do not
                // inherit the application's timeout and would otherwise use the
                // ~6s system default, defeating the scan budgets below.
                AXUIElementSetMessagingTimeout(menuBar, perApplicationTimeout)
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
                AXUIElementSetMessagingTimeout(element, perApplicationTimeout)
                guard Date.now < applicationDeadline else {
                    // Do not replace this owner's prior complete descriptors
                    // with a prefix gathered before its individual budget ran
                    // out. It will be retried after the cursor completes a lap.
                    result.removeSubrange(itemStartIndex..<result.endIndex)
                    logger.debug("Hosted menu bar enumeration timed out for pid \(app.pid)")
                    continue applicationLoop
                }
                let frame: CGRect
                switch frameRead(of: element) {
                case .value(let value): frame = value
                case .absent: continue
                case .failed:
                    result.removeSubrange(itemStartIndex..<result.endIndex)
                    continue applicationLoop
                }
                guard frame.width > 0, frame.height > 0 else {
                    continue
                }
                guard Date.now < applicationDeadline else {
                    result.removeSubrange(itemStartIndex..<result.endIndex)
                    logger.debug("Hosted menu bar enumeration timed out for pid \(app.pid)")
                    continue applicationLoop
                }

                // Identity failures must not turn an existing icon into a new
                // unidentified descriptor and prune the owner's prior snapshot.
                var metadata = [String?]()
                for name in [
                    kAXIdentifierAttribute,
                    kAXTitleAttribute,
                    kAXHelpAttribute,
                    kAXDescriptionAttribute,
                    kAXRoleAttribute,
                    kAXSubroleAttribute,
                ] {
                    guard Date.now < applicationDeadline else {
                        result.removeSubrange(itemStartIndex..<result.endIndex)
                        continue applicationLoop
                    }
                    switch attributeRead(name, of: element) as AttributeRead<String> {
                    case .value(let value): metadata.append(value)
                    case .absent: metadata.append(nil)
                    case .failed:
                        result.removeSubrange(itemStartIndex..<result.endIndex)
                        continue applicationLoop
                    }
                }
                let identifier = metadata[0]
                let identityStrings = metadata.prefix(4).compactMap { (value: String?) -> String? in
                    guard let value, !value.isEmpty else {
                        return nil
                    }
                    return value
                }
                let title = identityStrings.first
                guard Date.now < applicationDeadline else {
                    result.removeSubrange(itemStartIndex..<result.endIndex)
                    logger.debug("Hosted menu bar enumeration timed out for pid \(app.pid)")
                    continue applicationLoop
                }
                let role = metadata[4]
                let subrole = metadata[5]
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
                    frame.minY <= bounds.minY + 80 && frame.intersects(bounds)
                }

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
                        usesLocalInitialFrame: !isGlobalFrame
                    )
                )
            }
            scannedPIDs.insert(app.pid)
        }

        // AX can expose system-created clones at identical positions. Prefer one
        // descriptor per source application and global frame, while keeping
        // distinct sibling descriptors that report window-local coordinates.
        var seen = Set<String>()
        let deduplicated = result.filter { item in
            let key = if item.usesLocalInitialFrame {
                item.stableID
            } else {
                "\(item.sourcePID)|\(NSStringFromRect(item.initialFrame))|\(item.title ?? "")"
            }
            return seen.insert(key).inserted
        }
        logger.debug("Discovered \(deduplicated.count) hosted menu bar items")
        return EnumerationScan(
            items: deduplicated,
            scannedPIDs: scannedPIDs,
            livePIDs: Set(applications.map(\.pid)),
            nextCursor: nextCursor
        )
    }
}
