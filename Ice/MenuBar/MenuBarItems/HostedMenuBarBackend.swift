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
    let windowID: CGWindowID?
    let initialFrame: CGRect
    let requiresGlobalHitTesting: Bool

    init(
        element: AXUIElement,
        sourcePID: pid_t,
        sourceBundleIdentifier: String?,
        stableID: String,
        title: String?,
        windowID: CGWindowID?,
        initialFrame: CGRect,
        requiresGlobalHitTesting: Bool
    ) {
        self.element = element
        self.sourcePID = sourcePID
        self.sourceBundleIdentifier = sourceBundleIdentifier
        self.stableID = stableID
        self.title = title
        self.windowID = windowID
        self.initialFrame = initialFrame
        self.requiresGlobalHitTesting = requiresGlobalHitTesting
    }

    var currentFrame: CGRect? {
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
        AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
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

        // Fast path: return the cached snapshot if it is still fresh.
        if !forceRefresh, let cached = enumerationCache, Date.now.timeIntervalSince(cached.date) < enumerationTTL {
            return cached.items
        }

        // Coalesce concurrent callers. If an enumeration is already in flight,
        // return whatever we have (even if stale) rather than queuing another
        // full main-thread scan.
        enumerationLock.lock()
        if isEnumerating {
            enumerationLock.unlock()
            return enumerationCache?.items ?? []
        }
        isEnumerating = true
        enumerationLock.unlock()

        defer {
            enumerationLock.lock()
            isEnumerating = false
            enumerationLock.unlock()
        }

        let result = enumerateUncached()
        enumerationCache = (.now, result)
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

                let title = firstNonemptyString([
                    attribute(kAXIdentifierAttribute, of: element),
                    attribute(kAXTitleAttribute, of: element),
                    attribute(kAXHelpAttribute, of: element),
                    attribute(kAXDescriptionAttribute, of: element),
                ])
                let role: String? = attribute(kAXRoleAttribute, of: element)
                let subrole: String? = attribute(kAXSubroleAttribute, of: element)
                let baseStableID = [
                    app.bundleIdentifier ?? "pid:\(app.processIdentifier)",
                    role ?? "",
                    subrole ?? "",
                    title ?? "",
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
        logger.info("Discovered \(deduplicated.count) hosted menu bar items")
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

    /// Resolves the global frame of a hosted item by hit-testing the real menu
    /// bar. Some applications expose only window-local AX coordinates.
    ///
    /// This is expensive: each probe is a synchronous cross-process AX call. To
    /// keep menu bar interactions responsive we (1) cache results for 10 seconds,
    /// (2) use an 8pt stride instead of 2pt, and (3) bail out as soon as a
    /// single contiguous run is found rather than scanning the whole screen.
    static func globalHitFrame(for pid: pid_t, matching title: String?) -> CGRect? {
        let cacheKey = "\(pid)|\(title ?? "")"
        if let cached = hitFrameCache[cacheKey], Date.now.timeIntervalSince(cached.date) < 10 {
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

        hitFrameCache[cacheKey] = (.now, bestFrame ?? .null)
        return bestFrame
    }

    /// Invalidates the enumeration cache. Call this when the set of running
    /// applications is known to have changed (e.g. an app launched or quit).
    static func invalidateEnumerationCache() {
        enumerationLock.lock()
        enumerationCache = nil
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
        values.compactMap { value in
            guard let value, !value.isEmpty else { return nil }
            return value
        }.first
    }
}
