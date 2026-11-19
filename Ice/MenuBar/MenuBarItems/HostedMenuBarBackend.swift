//
//  HostedMenuBarBackend.swift
//  Ice
//

import ApplicationServices
import Cocoa

/// Accessibility-backed menu bar item discovery, rendered-tree tracking, and
/// action dispatch for macOS 27+ `MenuBarAgent`-hosted status items.
enum HostedMenuBarBackend {
    /// Cached result of bounded background AX enumeration.
    struct DescriptorSnapshot: Sendable {
        let items: [HostedMenuBarItemHandle]
        let scannedPIDs: Set<pid_t>
        let concealedBundles: Set<String>

        static let empty = DescriptorSnapshot(items: [], scannedPIDs: [], concealedBundles: [])
    }

    struct RenderedItem: @unchecked Sendable {
        let element: AXUIElement?
        let pid: pid_t
        let displayID: CGDirectDisplayID
        let frame: CGRect
        let identityStrings: Set<String>
    }

    struct ApplicationSnapshot: Sendable {
        let pid: pid_t
        let bundleIdentifier: String?
        let isResponsive: Bool
    }

    struct EnumerationSnapshot: Sendable {
        let applications: [ApplicationSnapshot]
        let displayBounds: [CGRect]
    }

    struct EnumerationState {
        var cache: (date: Date, snapshot: DescriptorSnapshot)?
        var isEnumerating = false
        var cacheGeneration = 0
        /// Circular cursor used by bounded scans so a slow app cannot starve
        /// later owners beyond the total scan budget.
        var cursor = 0
        var waiters = [CheckedContinuation<DescriptorSnapshot, Never>]()
        var pendingSnapshot: EnumerationSnapshot?
        var concealedBundleIdentifiers = Set<String>()

        /// Keep descriptors across an invalidation so a budgeted replacement pass
        /// can retain owners it has not yet reached. Generation checks still stop
        /// the pre-invalidation AX result from ever being published.
        mutating func expireCache() {
            cache = cache.map {
                (
                    date: .distantPast,
                    snapshot: DescriptorSnapshot(
                        items: $0.snapshot.items,
                        scannedPIDs: [],
                        concealedBundles: concealedBundleIdentifiers
                    ),
                )
            }
        }
    }

    final class LockedEnumerationState: @unchecked Sendable {
        private let lock = NSLock()
        private var state = EnumerationState()

        func withLock<R>(_ body: (inout EnumerationState) -> R) -> R {
            lock.withLock {
                body(&state)
            }
        }
    }

    enum AttributeRead<Value> {
        case value(Value)
        /// The owner answered, but does not expose this attribute. This is a
        /// genuine absence and may clear descriptors for that owner.
        case absent
        /// AX could not answer reliably (including cannotComplete/timeout).
        /// Preserve the prior owner snapshot and retry on a later cursor lap.
        case failed(AXError)
    }

    static let logger = Logger(category: "HostedMenuBarBackend")
    static let renderedCache = AsyncSnapshotCache<[RenderedItem]>(lifetime: 0.25)
    static let renderedQueue = DispatchQueue(label: "com.jordansamuel.ice.rendered-menu-bar")
    /// Accessibility queries can block in another process. Keep the complete
    /// walk off the main actor, and serialize it so a burst of layout events
    /// becomes one bounded scan instead of several competing scans.
    static let enumerationQueue = DispatchQueue(label: "com.jordansamuel.ice.hosted-menu-bar-enumeration")
    static let enumerationState = LockedEnumerationState()

    /// Scan reads use very short AX timeouts. A press may legitimately take
    /// longer while the owner builds its menu; inheriting the scan timeout
    /// reports `.cannotComplete` for a press that was in fact delivered, and the
    /// caller would then post a second, synthetic click that closes the menu.
    static let pressTimeout: Float = 1

    static func press(_ element: AXUIElement) -> Bool {
        AXUIElementSetMessagingTimeout(element, pressTimeout)
        switch AXUIElementPerformAction(element, kAXPressAction as CFString) {
        case .success:
            return true
        case .cannotComplete:
            // The request reached the owner but it did not reply in time.
            logger.debug("AXPress did not complete in time; treating it as delivered")
            return true
        case let error:
            logger.debug("AXPress failed: \(error.rawValue)")
            return false
        }
    }

    static func isConcealed(_ bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else {
            return false
        }
        return enumerationState.withLock {
            $0.concealedBundleIdentifiers.contains(bundleIdentifier)
        }
    }

    static func setConcealedBundleIdentifiers(_ identifiers: Set<String>) {
        let changed = enumerationState.withLock { state -> Bool in
            // Releasing an already released restriction happens on every item
            // cache publish. Invalidating here would discard in-flight scans and
            // feed a refresh -> invalidate -> rescan loop.
            guard identifiers != state.concealedBundleIdentifiers else {
                return false
            }
            state.concealedBundleIdentifiers = identifiers
            state.cacheGeneration += 1
            state.expireCache()
            return true
        }
        if changed {
            renderedCache.invalidate()
        }
    }

    /// Invalidates the enumeration and rendered-frame caches. Call this when
    /// the set of running applications or display geometry changes.
    static func invalidateEnumerationCache() {
        enumerationState.withLock { state in
            state.cacheGeneration += 1
            state.expireCache()
        }
        renderedCache.invalidate()
    }

    static func frame(of element: AXUIElement) -> CGRect? {
        guard case .value(let frame) = frameRead(of: element) else {
            return nil
        }
        return frame
    }

    static func frameRead(of element: AXUIElement) -> AttributeRead<CGRect> {
        let positionValue: AXValue
        let sizeValue: AXValue
        switch attributeRead(kAXPositionAttribute, of: element) as AttributeRead<AXValue> {
        case .value(let value): positionValue = value
        case .absent: return .absent
        case .failed(let error): return .failed(error)
        }
        switch attributeRead(kAXSizeAttribute, of: element) as AttributeRead<AXValue> {
        case .value(let value): sizeValue = value
        case .absent: return .absent
        case .failed(let error): return .failed(error)
        }
        guard
            AXValueGetType(positionValue) == .cgPoint,
            AXValueGetType(sizeValue) == .cgSize
        else {
            return .failed(.failure)
        }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard
            AXValueGetValue(positionValue, .cgPoint, &position),
            AXValueGetValue(sizeValue, .cgSize, &size)
        else {
            return .failed(.failure)
        }
        return .value(CGRect(origin: position, size: size))
    }

    static func attributeRead<T>(_ name: String, of element: AXUIElement) -> AttributeRead<T> {
        var value: CFTypeRef?
        switch AXUIElementCopyAttributeValue(element, name as CFString, &value) {
        case .success:
            guard let typedValue = value as? T else {
                return .failed(.failure)
            }
            return .value(typedValue)
        case .noValue, .attributeUnsupported:
            return .absent
        case let error:
            return .failed(error)
        }
    }

    static func attribute<T>(_ name: String, of element: AXUIElement) -> T? {
        guard case let .value(value) = attributeRead(name, of: element) as AttributeRead<T> else {
            return nil
        }
        return value
    }
}
