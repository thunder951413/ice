//
//  HostedMenuBarBackend+RenderedSnapshot.swift
//  Ice
//

import ApplicationServices
import Cocoa

extension HostedMenuBarBackend {
    /// How old a rendered snapshot may be for passive geometry reads.
    private static let staleRenderedSnapshotAge: TimeInterval = 5

    /// Resolves an item's rendered frame from MenuBarAgent's accessibility
    /// tree. On macOS 27 an app's `AXExtrasMenuBar` proxy can retain its old
    /// frame after the item is removed, while a system-wide hit test can return
    /// a neighbouring application's element. The host tree is authoritative:
    /// only a descendant that still identifies as the source item is accepted.
    static func renderedFrame(for item: HostedMenuBarItemHandle) -> CGRect? {
        // Passive geometry reads tolerate a few seconds of age: the 0.25s
        // freshness window otherwise makes every idle read report "off screen".
        // Clicks refresh the snapshot explicitly before pressing.
        matchingRenderedItem(for: item, in: renderedItems(allowingStale: true))?.frame
    }

    /// The actual occupied rectangles, including system items that have no
    /// corresponding source-app extra. Empty-space clicks need only this tree.
    static func renderedItemFrames(for sourcePID: pid_t? = nil) -> [CGRect] {
        renderedItemFrameSnapshot(for: sourcePID) ?? []
    }

    /// Nil means unknown/expired/failed, never a confirmed empty menu bar.
    static func renderedItemFrameSnapshot(for sourcePID: pid_t? = nil) -> [CGRect]? {
        renderedCache.requestRefresh { await loadRenderedItems() }
        return renderedCache.value()?.filter { sourcePID == nil || $0.pid == sourcePID }.map(\.frame)
    }

    /// Explicit activations await a fresh scan; paint and event readers never do.
    @MainActor
    static func refreshRenderedSnapshot() async -> Bool {
        await renderedCache.refresh(force: true) { await loadRenderedItems() } != nil
    }

    /// The system Clock stays visible under the macOS 27 visibility assertion,
    /// but its native click cannot open Notification Center while the assertion is held.
    static func systemClockFrame(at point: CGPoint, allowingStale: Bool = false) -> CGRect? {
        for item in renderedItems(allowingStale: allowingStale)
        where item.identityStrings.contains("com.apple.menuextra.clock") {
            let displayBounds = CGDisplayBounds(item.displayID)
            let minX = item.frame.minX - 4
            let maxX = displayBounds.maxX - item.frame.maxX <= 32 ? displayBounds.maxX : item.frame.maxX + 4
            let minY = min(displayBounds.minY, item.frame.minY)
            let hitRect = CGRect(
                x: minX,
                y: minY,
                width: max(0, maxX - minX),
                height: max(item.frame.maxY - minY + 6, 40)
            )
            if hitRect.contains(point) {
                return item.frame
            }
        }
        return nil
    }

    static func systemClockFrame(on displayID: CGDirectDisplayID) -> CGRect? {
        let displayBounds = CGDisplayBounds(displayID)
        return renderedItems(allowingStale: true).first {
            $0.identityStrings.contains("com.apple.menuextra.clock") &&
                displayBounds.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY))
        }?.frame
    }

    static func renderedElement(for item: HostedMenuBarItemHandle) -> AXUIElement? {
        // Callers that act on the element refresh the snapshot first; only the
        // fresh (non-stale) snapshot may be used to press.
        matchingRenderedItem(for: item, in: renderedItems())?.element
    }

    static func pickUnambiguousMatch<Candidate>(
        from matches: [Candidate],
        preferredDisplayID: CGDirectDisplayID?,
        displayID: (Candidate) -> CGDirectDisplayID,
        frame: (Candidate) -> CGRect
    ) -> Candidate? {
        guard let firstMatch = matches.first else {
            return nil
        }
        let targetDisplayID: CGDirectDisplayID
        if let preferredDisplayID, matches.contains(where: { displayID($0) == preferredDisplayID }) {
            targetDisplayID = preferredDisplayID
        } else {
            targetDisplayID = displayID(firstMatch)
        }
        let displayMatches = matches.filter { displayID($0) == targetDisplayID }
        // Multiple same-owner icons without identifiers cannot safely be picked
        // by index on the same display: refuse ambiguity instead of activating
        // a neighboring item, while still allowing MenuBarAgent's per-display
        // instances on multi-monitor setups.
        guard
            let first = displayMatches.first,
            displayMatches.dropFirst().allSatisfy({ frame($0) == frame(first) })
        else {
            return nil
        }
        return first
    }

    private static func preferredRenderedDisplayID() -> CGDirectDisplayID? {
        guard Thread.isMainThread else {
            return nil
        }
        return MainActor.assumeIsolated {
            let location = NSEvent.mouseLocation
            if let screen = NSScreen.screens.first(where: { $0.frame.contains(location) }) {
                return screen.displayID
            }
            if let screen = NSScreen.screens.first(where: {
                location.x >= $0.frame.minX && location.x < $0.frame.maxX && location.y == $0.frame.maxY
            }) {
                return screen.displayID
            }
            return NSScreen.main?.displayID
        }
    }

    private static func matchingRenderedItem(
        for source: HostedMenuBarItemHandle,
        in candidates: [RenderedItem]
    ) -> RenderedItem? {
        let sourceStrings = Set(source.identityStrings)
        let matches = candidates.filter { candidate in
            guard candidate.pid == source.sourcePID else {
                return false
            }
            if let element = candidate.element, CFEqual(element, source.element) {
                return true
            }
            if source.sourceBundleIdentifier == "com.apple.MenuBarAgent" {
                return !sourceStrings.isEmpty && !sourceStrings.isDisjoint(with: candidate.identityStrings)
            }
            return sourceStrings.isEmpty || candidate.identityStrings.isEmpty ||
                !sourceStrings.isDisjoint(with: candidate.identityStrings)
        }
        return pickUnambiguousMatch(
            from: matches,
            preferredDisplayID: preferredRenderedDisplayID(),
            displayID: \.displayID,
            frame: \.frame
        )
    }

    private static func renderedItems(allowingStale: Bool = false) -> [RenderedItem] {
        renderedCache.requestRefresh { await loadRenderedItems() }
        if allowingStale {
            return renderedCache.lastValue(maxAge: staleRenderedSnapshotAge) ?? []
        }
        return renderedCache.value() ?? []
    }

    private static func loadRenderedItems() async -> [RenderedItem]? {
        let input = await MainActor.run { () -> (pid_t, [(displayID: CGDirectDisplayID, bounds: CGRect)])? in
            guard
                AXIsProcessTrusted(),
                let host = NSRunningApplication
                    .runningApplications(withBundleIdentifier: "com.apple.MenuBarAgent").first
            else {
                return nil
            }
            let displays = NSScreen.screens.map { ($0.displayID, CGDisplayBounds($0.displayID)) }
            return (host.processIdentifier, displays)
        }
        guard let (pid, displays) = input else {
            logger.debug("Rendered menu bar host or Accessibility permission unavailable")
            return nil
        }
        return await withCheckedContinuation { continuation in
            renderedQueue.async {
                continuation.resume(returning: readRenderedItems(hostPID: pid, displays: displays))
            }
        }
    }

    /// Walk MenuBarAgent once for every item in a layout/hit-test batch. Read
    /// each leaf's AX metadata once; matching individual owners is then in-memory.
    private static func readRenderedItems(
        hostPID: pid_t,
        displays: [(displayID: CGDirectDisplayID, bounds: CGRect)]
    ) -> [RenderedItem]? {
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(500))
        let application = AXUIElementCreateApplication(hostPID)
        AXUIElementSetMessagingTimeout(application, 0.05)
        guard let windows: [AXUIElement] = attribute(kAXWindowsAttribute, of: application) else {
            logger.debug("Rendered menu bar window list unavailable")
            return nil
        }
        var remainingNodes = min(2048, 512 * max(1, windows.count))
        var visited = Set<AXUIElement>()
        var result = [RenderedItem]()
        var complete = true

        func visit(_ element: AXUIElement, parent: AXUIElement? = nil, depth: Int) {
            guard complete, visited.insert(element).inserted else {
                return
            }
            guard depth > 0, remainingNodes > 0, ContinuousClock.now < deadline else {
                logger.debug("Rendered menu bar scan reached its time, depth or node budget")
                complete = false
                return
            }
            remainingNodes -= 1
            AXUIElementSetMessagingTimeout(element, 0.05)
            let role: String?
            switch attributeRead(kAXRoleAttribute, of: element) as AttributeRead<String> {
            case .value(let value): role = value
            // MenuBarAgent uses role-less containers for the hosted extras.
            // Their children still have actionable roles and must be visited.
            case .absent: role = nil
            case .failed(let error):
                logger.debug("Rendered menu bar role read failed: \(error.rawValue)")
                complete = false
                return
            }
            if role == kAXApplicationRole as String || role == kAXUnknownRole as String {
                // Inactive displays can expose the source application in
                // place of a status item. The host group still has its
                // rendered bounds, while the application leads to its
                // regular windows and menu bar on another display.
                var pid: pid_t = 0
                guard
                    let parent,
                    AXUIElementGetPid(element, &pid) == .success,
                    let frame = frame(of: parent)
                else {
                    complete = false
                    return
                }
                if let displayID = matchingMenuBarDisplayID(for: frame, displays: displays) {
                    result.append(
                        RenderedItem(
                            element: nil,
                            pid: pid,
                            displayID: displayID,
                            frame: frame,
                            identityStrings: []
                        )
                    )
                }
                return
            }
            if role == kAXButtonRole as String || role == kAXMenuBarItemRole as String {
                var pid: pid_t = 0
                guard AXUIElementGetPid(element, &pid) == .success, let frame = frame(of: element) else {
                    logger.debug("Rendered menu bar actionable element had unavailable geometry")
                    complete = false
                    return
                }
                if let displayID = matchingMenuBarDisplayID(for: frame, displays: displays) {
                    let strings: [String?] = [
                        attribute(kAXIdentifierAttribute, of: element),
                        attribute(kAXTitleAttribute, of: element),
                        attribute(kAXHelpAttribute, of: element),
                        attribute(kAXDescriptionAttribute, of: element),
                    ]
                    result.append(
                        RenderedItem(
                            element: element,
                            pid: pid,
                            displayID: displayID,
                            frame: frame,
                            identityStrings: Set(strings.compactMap { $0 }.filter { !$0.isEmpty })
                        )
                    )
                }
                // Descending into a status button's open menu confuses its menu
                // contents with the status item and adds synchronous AX traffic.
                return
            }
            switch attributeRead(kAXChildrenAttribute, of: element) as AttributeRead<[AXUIElement]> {
            case .value(let children):
                for child in children {
                    visit(child, parent: element, depth: depth - 1)
                }
            case .absent:
                break
            case .failed(let error):
                logger.debug("Rendered menu bar children read failed: \(error.rawValue)")
                complete = false
            }
        }

        for window in windows {
            visit(window, depth: 12)
        }
        logger.debug("Rendered menu bar scan: \(windows.count) windows, \(visited.count) nodes, \(result.count) items, complete: \(complete)")
        return complete && ContinuousClock.now < deadline ? result : nil
    }

    private static func matchingMenuBarDisplayID(
        for frame: CGRect,
        displays: [(displayID: CGDirectDisplayID, bounds: CGRect)]
    ) -> CGDirectDisplayID? {
        guard frame.width > 0, frame.height > 0 else {
            return nil
        }
        return displays.first { display in
            frame.intersects(display.bounds) && frame.minY <= display.bounds.minY + 80
        }?.displayID
    }
}
