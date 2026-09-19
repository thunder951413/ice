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
    /// Set while an enumeration is in progress so callers can short-circuit
    /// instead of piling up behind the lock and then all re-running the scan.
    private static var isEnumerating = false
    private static var cacheGeneration = 0
    private static var concealedBundleIdentifiers = Set<String>()

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
        enumerationCache = nil
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

        let result = enumerateUncached()
        enumerationLock.lock()
        if generation == cacheGeneration { enumerationCache = (.now, result) }
        isEnumerating = false
        enumerationLock.unlock()
        return result
    }

    private static func enumerateUncached() -> [HostedMenuBarItemHandle] {
        var result = [HostedMenuBarItemHandle]()
        var stableIDOccurrences = [String: Int]()

        for app in NSWorkspace.shared.runningApplications {
            guard
                app.isFinishedLaunching,
                !app.isTerminated,
                Bridging.responsivity(for: app.processIdentifier) != .unresponsive
            else {
                continue
            }

            let appElement = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(appElement, 0.15)
            guard let menuBar: AXUIElement = attribute(kAXExtrasMenuBarAttribute, of: appElement) else {
                continue
            }
            guard let children: [AXUIElement] = attribute(kAXChildrenAttribute, of: menuBar) else {
                continue
            }

            for element in children {
                guard let frame = frame(of: element), frame.width > 0, frame.height > 0 else {
                    continue
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
                let role: String? = attribute(kAXRoleAttribute, of: element)
                let subrole: String? = attribute(kAXSubroleAttribute, of: element)
                let baseStableID = [
                    app.bundleIdentifier ?? "pid:\(app.processIdentifier)",
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
                let isGlobalFrame = NSScreen.screens.contains { screen in
                    let bounds = CGDisplayBounds(screen.displayID)
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
                        sourcePID: app.processIdentifier,
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
        }

        // AX can expose system-created clones at identical positions. Prefer one
        // descriptor per source application and frame.
        var seen = Set<String>()
        let deduplicated = result.filter { item in
            let key = "\(item.sourcePID)|\(NSStringFromRect(item.initialFrame))|\(item.title ?? "")"
            return seen.insert(key).inserted
        }
        logger.debug("Discovered \(deduplicated.count) hosted menu bar items")
        return deduplicated
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
        guard Set(matches.map(\.frame)).count == 1 else { return nil }
        return matches.first
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
        enumerationCache = nil
        hitFrameCache.removeAll()
        renderedSnapshot = nil
        enumerationLock.unlock()
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

    private static func attribute<T>(_ name: String, of element: AXUIElement) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
            return nil
        }
        return value as? T
    }

    private static func firstNonemptyString(_ values: [String?]) -> String? {
        values.compactMap { (value: String?) -> String? in
            guard let value, !value.isEmpty else { return nil }
            return value
        }.first
    }
}
