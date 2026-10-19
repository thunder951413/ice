//
//  MenuBarItemManager+Events.swift
//  Ice
//

import Cocoa
import Combine

// Synthetic CGEvent move/click paths. Used on macOS 14–26; the macOS 27
// hosted backend hides by owner bundle and never drags items.

// MARK: - Menu Bar Item Events -

extension MenuBarItemManager {
    /// An error that can occur during menu bar item event operations.
    struct EventError: Error, CustomStringConvertible, LocalizedError {
        /// Error codes within the domain of menu bar item event errors.
        enum ErrorCode: Int, CustomStringConvertible {
            /// An operation could not be completed.
            case couldNotComplete

            /// The creation of a menu bar item event failed.
            case eventCreationFailure

            /// The shared app state is invalid or could not be found.
            case invalidAppState

            /// An event source could not be created or is otherwise invalid.
            case invalidEventSource

            /// The location of the mouse cursor is invalid or could not be found.
            case invalidCursorLocation

            /// A menu bar item is invalid.
            case invalidItem

            /// A menu bar item cannot be moved.
            case notMovable

            /// Hosted menu bar items cannot be safely moved on this system.
            case hostedMovementUnsupported

            /// A menu bar item event operation timed out.
            case eventOperationTimeout

            /// A menu bar item frame check timed out.
            case frameCheckTimeout

            /// An operation timed out.
            case otherTimeout

            /// Description of the code for debugging purposes.
            var description: String {
                switch self {
                case .couldNotComplete: "couldNotComplete"
                case .eventCreationFailure: "eventCreationFailure"
                case .invalidAppState: "invalidAppState"
                case .invalidEventSource: "invalidEventSource"
                case .invalidCursorLocation: "invalidCursorLocation"
                case .invalidItem: "invalidItem"
                case .notMovable: "notMovable"
                case .hostedMovementUnsupported: "hostedMovementUnsupported"
                case .eventOperationTimeout: "eventOperationTimeout"
                case .frameCheckTimeout: "frameCheckTimeout"
                case .otherTimeout: "otherTimeout"
                }
            }

            /// A string to use for logging purposes.
            var logString: String {
                "\(self) (rawValue: \(rawValue))"
            }
        }

        /// The error code of this error.
        let code: ErrorCode

        /// The error's menu bar item.
        let item: MenuBarItem

        /// The message associated with this error.
        var message: String {
            switch code {
            case .couldNotComplete:
                "Could not complete event operation for \"\(item.displayName)\""
            case .eventCreationFailure:
                "Failed to create event for \"\(item.displayName)\""
            case .invalidAppState:
                "Invalid app state for \"\(item.displayName)\""
            case .invalidEventSource:
                "Invalid event source for \"\(item.displayName)\""
            case .invalidCursorLocation:
                "Invalid cursor location for \"\(item.displayName)\""
            case .invalidItem:
                "\"\(item.displayName)\" is invalid"
            case .notMovable:
                "\"\(item.displayName)\" is not movable"
            case .hostedMovementUnsupported:
                "macOS does not allow Ice to safely move \"\(item.displayName)\" into a hidden section"
            case .eventOperationTimeout:
                "Event operation timed out for \"\(item.displayName)\""
            case .frameCheckTimeout:
                "Frame check timed out for \"\(item.displayName)\""
            case .otherTimeout:
                "Operation timed out for \"\(item.displayName)\""
            }
        }

        /// Description of the error for debugging purposes.
        var description: String {
            var parameters = [String]()
            parameters.append("code: \(code.logString)")
            parameters.append("item: \(item.logString)")
            return "\(Self.self)(\(parameters.joined(separator: ", ")))"
        }

        /// Description of the error for display purposes.
        var errorDescription: String? {
            message
        }

        /// Suggestion for recovery from the error.
        var recoverySuggestion: String? {
            "Please try again. If the error persists, please file a bug report."
        }
    }
}

// MARK: - Async Waiters

extension MenuBarItemManager {
    /// Waits asynchronously for the given operation to complete.
    ///
    /// - Parameters:
    ///   - timeout: Amount of time to wait before throwing an error.
    ///   - operation: The operation to perform.
    func waitWithTask(timeout: Duration?, operation: @escaping @Sendable () async throws -> Void) async throws {
        let task = if let timeout {
            Task(timeout: timeout, operation: operation)
        } else {
            Task(operation: operation)
        }
        try await task.value
    }

    /// Waits asynchronously for all menu bar items to stop moving.
    ///
    /// - Parameter timeout: Amount of time to wait before throwing an error.
    func waitForItemsToStopMoving(timeout: Duration? = nil) async throws {
        try await waitWithTask(timeout: timeout) { [weak self] in
            guard let self else {
                return
            }
            while await isMovingItem {
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(10))
            }
        }
    }

    /// Waits asynchronously for the mouse to stop moving.
    ///
    /// - Parameters:
    ///   - threshold: A threshold to use to determine whether the mouse has stopped moving.
    ///   - timeout: Amount of time to wait before throwing an error.
    func waitForMouseToStopMoving(threshold: TimeInterval = 0.1, timeout: Duration? = nil) async throws {
        try await waitWithTask(timeout: timeout) { [weak self] in
            guard let self else {
                return
            }
            while true {
                try Task.checkCancellation()
                guard let date = await lastMouseMoveStartDate else {
                    break
                }
                if Date.now.timeIntervalSince(date) > threshold {
                    break
                }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
    }

    /// Waits asynchronously until no modifier keys are pressed.
    ///
    /// - Parameter timeout: Amount of time to wait before throwing an error.
    func waitForNoModifiersPressed(timeout: Duration? = nil) async throws {
        try await waitWithTask(timeout: timeout) {
            // Return early if no flags are pressed.
            if NSEvent.modifierFlags.isEmpty {
                return
            }

            var cancellable: AnyCancellable?

            await withCheckedContinuation { continuation in
                cancellable = Publishers.Merge(
                    UniversalEventMonitor.publisher(for: .flagsChanged),
                    RunLoopLocalEventMonitor.publisher(for: .flagsChanged, mode: .eventTracking)
                )
                .removeDuplicates()
                .sink { _ in
                    if NSEvent.modifierFlags.isEmpty {
                        cancellable?.cancel()
                        continuation.resume()
                    }
                }
            }
        }
    }
}

// MARK: - Move Items

extension MenuBarItemManager {
    /// A destination that a menu bar item can be moved to.
    enum MoveDestination {
        /// The menu bar item will be moved to the left of the given menu bar item.
        case leftOfItem(MenuBarItem)

        /// The menu bar item will be moved to the right of the given menu bar item.
        case rightOfItem(MenuBarItem)

        /// A string to use for logging purposes.
        var logString: String {
            switch self {
            case .leftOfItem(let item): "left of \(item.logString)"
            case .rightOfItem(let item): "right of \(item.logString)"
            }
        }
    }

    /// Returns the current frame for the given item.
    ///
    /// - Parameter item: The item to return the current frame for.
    func getCurrentFrame(for item: MenuBarItem) -> CGRect? {
        if let hostedHandle = item.hostedHandle {
            return hostedHandle.currentFrame
        }
        guard let frame = Bridging.getWindowFrame(for: item.window.windowID) else {
            Logger.itemManager.error("Couldn't get current frame for \(item.logString)")
            return nil
        }
        return frame
    }

    /// Returns usable geometry for hosted control items whose expanded AX
    /// frame wraps across the display coordinate space.
    func getEffectiveFrame(for item: MenuBarItem) -> CGRect? {
        guard let frame = getCurrentFrame(for: item) else {
            return nil
        }
        let isControlItem = item.info == .hiddenControlItem || item.info == .alwaysHiddenControlItem
        guard
            item.hostedHandle != nil,
            isControlItem,
            let screen = NSScreen.screens.first(where: { $0.frame.minX <= frame.minX && frame.minX < $0.frame.maxX }),
            frame.width > screen.frame.width,
            screen.frame.width > 0
        else {
            return frame
        }
        var wrappedX = (frame.maxX - screen.frame.minX).truncatingRemainder(dividingBy: screen.frame.width)
        if wrappedX < 0 {
            wrappedX += screen.frame.width
        }
        wrappedX += screen.frame.minX
        return CGRect(x: wrappedX, y: frame.minY, width: 0, height: frame.height)
    }

    /// Returns the end point for moving an item to the given destination.
    ///
    /// - Parameter destination: The destination to return the end point for.
    func getEndPoint(for destination: MoveDestination) throws -> CGPoint {
        switch destination {
        case .leftOfItem(let targetItem):
            guard let currentFrame = getEffectiveFrame(for: targetItem) else {
                throw EventError(code: .invalidItem, item: targetItem)
            }
            return CGPoint(x: currentFrame.minX, y: currentFrame.midY)
        case .rightOfItem(let targetItem):
            guard let currentFrame = getEffectiveFrame(for: targetItem) else {
                throw EventError(code: .invalidItem, item: targetItem)
            }
            return CGPoint(x: currentFrame.maxX, y: currentFrame.midY)
        }
    }

    /// Returns the fallback point for returning the given item to its original
    /// position if a move fails.
    ///
    /// - Parameter item: The item to return the fallback point for.
    func getFallbackPoint(for item: MenuBarItem) throws -> CGPoint {
        guard let currentFrame = getCurrentFrame(for: item) else {
            throw EventError(code: .invalidItem, item: item)
        }
        return CGPoint(x: currentFrame.midX, y: currentFrame.midY)
    }

    /// Returns the target item for the given destination.
    ///
    /// - Parameter destination: The destination to get the target item from.
    func getTargetItem(for destination: MoveDestination) -> MenuBarItem {
        switch destination {
        case .leftOfItem(let targetItem), .rightOfItem(let targetItem): targetItem
        }
    }

    /// Returns a Boolean value that indicates whether the given item is in the
    /// correct position for the given destination.
    ///
    /// - Parameters:
    ///   - item: The item to check the position of.
    ///   - destination: The destination to compare the item's position against.
    func itemHasCorrectPosition(item: MenuBarItem, for destination: MoveDestination) throws -> Bool {
        guard let currentFrame = getCurrentFrame(for: item) else {
            throw EventError(code: .invalidItem, item: item)
        }
        switch destination {
        case .leftOfItem(let targetItem):
            guard let currentTargetFrame = getCurrentFrame(for: targetItem) else {
                throw EventError(code: .invalidItem, item: targetItem)
            }
            return abs(currentFrame.maxX - currentTargetFrame.minX) <= 1
        case .rightOfItem(let targetItem):
            guard let currentTargetFrame = getCurrentFrame(for: targetItem) else {
                throw EventError(code: .invalidItem, item: targetItem)
            }
            return abs(currentFrame.minX - currentTargetFrame.maxX) <= 1
        }
    }

    /// Returns a Boolean value that indicates whether the given events have the
    /// same values for each integer value field.
    ///
    /// - Parameters:
    ///   - events: The events to compare.
    ///   - integerFields: An array of integer value fields to compare on each event.
    nonisolated func eventsMatch(_ events: [CGEvent], by integerFields: [CGEventField]) -> Bool {
        var fieldValues = Set<[Int64]>()
        for event in events {
            let values = integerFields.map(event.getIntegerValueField)
            fieldValues.insert(values)
            if fieldValues.count != 1 {
                return false
            }
        }
        return true
    }

    /// Posts an event to the given event tap location.
    ///
    /// - Parameters:
    ///   - event: The event to post.
    ///   - location: The event tap location to post the event to.
    nonisolated func postEvent(_ event: CGEvent, to location: EventTap.Location) {
        Logger.itemManager.debug("Posting \(event.type.logString) to \(location.logString)")
        switch location {
        case .hidEventTap:
            event.post(tap: .cghidEventTap)
        case .sessionEventTap:
            event.post(tap: .cgSessionEventTap)
        case .annotatedSessionEventTap:
            event.post(tap: .cgAnnotatedSessionEventTap)
        case .pid(let pid):
            event.postToPid(pid)
        }
    }

    /// Posts an event to the given event tap location and waits until it is
    /// received before returning.
    ///
    /// - Parameters:
    ///   - event: The event to post.
    ///   - location: The event tap location to post the event to.
    ///   - item: The menu bar item that the event affects.
    func postEventAndWaitToReceive(
        _ event: CGEvent,
        to location: EventTap.Location,
        item: MenuBarItem
    ) async throws {
        return try await withCheckedThrowingContinuation { continuation in
            let eventTap = EventTap(
                options: .listenOnly,
                location: location,
                place: .tailAppendEventTap,
                types: [event.type]
            ) { [weak self] proxy, type, rEvent in
                guard let self else {
                    proxy.disable()
                    return nil
                }

                // Reenable the tap if disabled by the system.
                if type == .tapDisabledByUserInput || type == .tapDisabledByTimeout {
                    proxy.enable()
                    return nil
                }

                // Verify that the received event was the sent event.
                guard eventsMatch([rEvent, event], by: CGEventField.menuBarItemEventFields) else {
                    return nil
                }

                // Ensure the tap is enabled, preventing multiple calls to resume().
                guard proxy.isEnabled else {
                    Logger.itemManager.debug("Event tap \"\(proxy.label)\" is disabled (item: \(item.logString))")
                    return nil
                }

                Logger.itemManager.debug("Received \(type.logString) at \(location.logString) (item: \(item.logString))")

                // Disable the tap and resume the continuation.
                proxy.disable()
                continuation.resume()

                return nil
            }

            eventTap.enable(timeout: .milliseconds(50)) {
                Logger.itemManager.error("Event tap \"\(eventTap.label)\" timed out (item: \(item.logString))")
                eventTap.disable()
                continuation.resume(throwing: EventError(code: .eventOperationTimeout, item: item))
            }

            // Post the event to the location.
            postEvent(event, to: location)
        }
    }

    /// Does a lot of weird magic to make a menu bar item receive an event.
    ///
    /// - Parameters:
    ///   - event: The event to send.
    ///   - firstLocation: The first location to send the event to.
    ///   - secondLocation: The second location to send the event to.
    ///   - item: The menu bar item that the event affects.
    func scrombleEvent(
        _ event: CGEvent,
        from firstLocation: EventTap.Location,
        to secondLocation: EventTap.Location,
        item: MenuBarItem
    ) async throws {
        // Create a null event and assign it unique user data.
        guard let nullEvent = CGEvent(source: nil) else {
            throw EventError(code: .eventCreationFailure, item: item)
        }
        let nullUserData = Int64(truncatingIfNeeded: Int(bitPattern: ObjectIdentifier(nullEvent)))
        nullEvent.setIntegerValueField(.eventSourceUserData, value: nullUserData)

        return try await withCheckedThrowingContinuation { continuation in
            // Create an event tap for the null event at the first location.
            // This tap throws away all events it receives.
            let eventTap1 = EventTap(
                label: "EventTap 1",
                options: .defaultTap,
                location: firstLocation,
                place: .tailAppendEventTap,
                types: [nullEvent.type]
            ) { [weak self] proxy, type, rEvent in
                guard let self else {
                    proxy.disable()
                    return nil
                }

                // Reenable the tap if disabled by the system.
                if type == .tapDisabledByUserInput || type == .tapDisabledByTimeout {
                    proxy.enable()
                    return nil
                }

                // Verify that this is the null event.
                guard rEvent.getIntegerValueField(.eventSourceUserData) == nullUserData else {
                    return nil
                }

                // Disable the tap and post the real event to the second location.
                proxy.disable()
                postEvent(event, to: secondLocation)

                return nil
            }

            // Create an event tap for the real event at the second location.
            // This tap can listen for events, but cannot alter or discard them.
            let eventTap2 = EventTap(
                label: "EventTap 2",
                options: .listenOnly,
                location: secondLocation,
                place: .tailAppendEventTap,
                types: [event.type]
            ) { [weak self] proxy, type, rEvent in
                guard let self else {
                    proxy.disable()
                    return nil
                }

                // Reenable the tap if disabled by the system.
                if type == .tapDisabledByUserInput || type == .tapDisabledByTimeout {
                    proxy.enable()
                    return nil
                }

                // Verify that the received event was the sent event.
                guard eventsMatch([rEvent, event], by: CGEventField.menuBarItemEventFields) else {
                    return nil
                }

                // Ensure the tap is enabled, preventing multiple calls to resume().
                guard proxy.isEnabled else {
                    Logger.itemManager.debug("Event tap \"\(proxy.label)\" is disabled (item: \(item.logString))")
                    return nil
                }

                // Disable the tap, post the event to the first location, and resume
                // the continuation.
                proxy.disable()
                postEvent(event, to: firstLocation)
                continuation.resume()

                return nil
            }

            // Enable both taps, with a timeout on the second tap.
            eventTap1.enable()
            eventTap2.enable(timeout: .milliseconds(50)) {
                Logger.itemManager.error("Event tap \"\(eventTap2.label)\" timed out (item: \(item.logString))")
                eventTap1.disable()
                eventTap2.disable()
                continuation.resume(throwing: EventError(code: .eventOperationTimeout, item: item))
            }

            // Post the null event to the first location.
            postEvent(nullEvent, to: firstLocation)
        }
    }

    /// Does a lot of weird magic to make a menu bar item receive an event, then
    /// waits for the frame of the given menu bar item to change before returning.
    ///
    /// - Parameters:
    ///   - event: The event to send.
    ///   - firstLocation: The first location to send the event to.
    ///   - secondLocation: The second location to send the event to.
    ///   - item: The item whose frame should be observed.
    func scrombleEvent(
        _ event: CGEvent,
        from firstLocation: EventTap.Location,
        to secondLocation: EventTap.Location,
        waitingForFrameChangeOf item: MenuBarItem
    ) async throws {
        guard let currentFrame = getCurrentFrame(for: item) else {
            try await scrombleEvent(event, from: firstLocation, to: secondLocation, item: item)
            Logger.itemManager.warning("Couldn't get menu bar item frame for \(item.logString), so using fixed delay")
            // This will be slow, but subsequent events will have a better chance of succeeding.
            try await Task.sleep(for: .milliseconds(50))
            return
        }
        try await scrombleEvent(event, from: firstLocation, to: secondLocation, item: item)
        try await waitForFrameChange(of: item, initialFrame: currentFrame, timeout: .milliseconds(50))
    }

    /// Waits for a menu bar item's frame to change from an initial frame.
    ///
    /// - Parameters:
    ///   - item: The item whose frame should be observed.
    ///   - initialFrame: An initial frame to compare the item's frame against.
    ///   - timeout: The amount of time to wait before throwing a timeout error.
    func waitForFrameChange(of item: MenuBarItem, initialFrame: CGRect, timeout: Duration) async throws {
        struct FrameCheckCancellationError: Error { }

        let frameCheckTask = Task(timeout: timeout) {
            while true {
                try Task.checkCancellation()
                guard let currentFrame = await self.getCurrentFrame(for: item) else {
                    throw FrameCheckCancellationError()
                }
                if currentFrame != initialFrame {
                    Logger.itemManager.debug("Menu bar item frame for \(item.logString) has changed to \(NSStringFromRect(currentFrame))")
                    return
                }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        do {
            try await frameCheckTask.value
        } catch is FrameCheckCancellationError {
            Logger.itemManager.warning("Menu bar item frame check for \(item.logString) was cancelled, so using fixed delay")
            // This will be slow, but subsequent events will have a better chance of succeeding.
            try await Task.sleep(for: .milliseconds(50))
        } catch is TaskTimeoutError {
            throw EventError(code: .frameCheckTimeout, item: item)
        }
    }

    /// Permits all events for an event source during the given suppression states,
    /// suppressing local events for the given interval.
    func permitAllEvents(
        for stateID: CGEventSourceStateID,
        during states: [CGEventSuppressionState],
        suppressionInterval: TimeInterval,
        item: MenuBarItem
    ) throws {
        guard let source = CGEventSource(stateID: stateID) else {
            throw EventError(code: .invalidEventSource, item: item)
        }
        for state in states {
            source.setLocalEventsFilterDuringSuppressionState(.permitAllEvents, state: state)
        }
        source.localEventsSuppressionInterval = suppressionInterval
    }

    /// Tries to wake up the given item if it is not responding to events.
    func wakeUpItem(_ item: MenuBarItem) async throws {
        Logger.itemManager.debug("Attempting to wake up \(item.logString)")

        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw EventError(code: .invalidEventSource, item: item)
        }
        guard let currentFrame = getCurrentFrame(for: item) else {
            throw EventError(code: .invalidItem, item: item)
        }

        guard
            let mouseDownEvent = CGEvent.menuBarItemEvent(
                type: .move(.leftMouseDown),
                location: CGPoint(x: currentFrame.midX, y: currentFrame.midY),
                item: item,
                pid: item.ownerPID,
                source: source
            ),
            let mouseUpEvent = CGEvent.menuBarItemEvent(
                type: .move(.leftMouseUp),
                location: CGPoint(x: currentFrame.midX, y: currentFrame.midY),
                item: item,
                pid: item.ownerPID,
                source: source
            )
        else {
            throw EventError(code: .eventCreationFailure, item: item)
        }

        try await scrombleEvent(
            mouseDownEvent,
            from: .pid(item.ownerPID),
            to: .sessionEventTap,
            item: item
        )
        try await scrombleEvent(
            mouseUpEvent,
            from: .pid(item.ownerPID),
            to: .sessionEventTap,
            item: item
        )
    }

    /// Moves a menu bar item to the given destination, without restoring the mouse
    /// pointer to its initial location.
    ///
    /// - Parameters:
    ///   - item: A menu bar item to move.
    ///   - destination: A destination to move the menu bar item.
    func moveItemWithoutRestoringMouseLocation(_ item: MenuBarItem, to destination: MoveDestination) async throws {
        itemMoveCount += 1
        defer {
            itemMoveCount -= 1
        }

        guard item.isMovable else {
            throw EventError(code: .notMovable, item: item)
        }
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw EventError(code: .invalidEventSource, item: item)
        }

        let startPoint = CGPoint(x: 20_000, y: 20_000)
        let endPoint = try getEndPoint(for: destination)
        let fallbackPoint = try getFallbackPoint(for: item)
        let targetItem = getTargetItem(for: destination)

        guard
            let mouseDownEvent = CGEvent.menuBarItemEvent(
                type: .move(.leftMouseDown),
                location: startPoint,
                item: item,
                pid: item.ownerPID,
                source: source
            ),
            let mouseUpEvent = CGEvent.menuBarItemEvent(
                type: .move(.leftMouseUp),
                location: endPoint,
                item: targetItem,
                pid: item.ownerPID,
                source: source
            ),
            let fallbackEvent = CGEvent.menuBarItemEvent(
                type: .move(.leftMouseUp),
                location: fallbackPoint,
                item: item,
                pid: item.ownerPID,
                source: source
            )
        else {
            throw EventError(code: .eventCreationFailure, item: item)
        }

        try permitAllEvents(
            for: .combinedSessionState,
            during: [
                .eventSuppressionStateRemoteMouseDrag,
                .eventSuppressionStateSuppressionInterval,
            ],
            suppressionInterval: 0,
            item: item
        )

        lastItemMoveStartDate = .now

        do {
            try await scrombleEvent(
                mouseDownEvent,
                from: .pid(item.ownerPID),
                to: .sessionEventTap,
                waitingForFrameChangeOf: item
            )
            try await scrombleEvent(
                mouseUpEvent,
                from: .pid(item.ownerPID),
                to: .sessionEventTap,
                waitingForFrameChangeOf: item
            )
        } catch {
            do {
                Logger.itemManager.debug("Posting fallback event for moving \(item.logString)")
                // Catch this, as we still want to throw the existing error if the fallback fails.
                try await postEventAndWaitToReceive(
                    fallbackEvent,
                    to: .sessionEventTap,
                    item: item
                )
            } catch {
                Logger.itemManager.error("Failed to post fallback event for moving \(item.logString)")
            }
            throw error
        }
    }

    /// Moves a menu bar item to the given destination.
    ///
    /// - Parameters:
    ///   - item: A menu bar item to move.
    ///   - destination: A destination to move the menu bar item.
    func move(item: MenuBarItem, to destination: MoveDestination) async throws {
        if item.hostedHandle == nil, try itemHasCorrectPosition(item: item, for: destination) {
            Logger.itemManager.debug("\(item.logString) is already in the correct position")
            return
        }

        do {
            // Order of these waiters matters, as the modifiers could be released
            // while the mouse is still moving.
            try await waitForNoModifiersPressed()
            try await waitForMouseToStopMoving()
        } catch {
            throw EventError(code: .couldNotComplete, item: item)
        }

        if item.hostedHandle != nil {
            try await moveHostedItem(item, to: destination)
            return
        }

        Logger.itemManager.info("Moving \(item.logString) to \(destination.logString)")

        guard let appState else {
            throw EventError(code: .invalidAppState, item: item)
        }
        guard let cursorLocation = MouseCursor.locationCoreGraphics else {
            throw EventError(code: .invalidCursorLocation, item: item)
        }
        guard let initialFrame = getCurrentFrame(for: item) else {
            throw EventError(code: .invalidItem, item: item)
        }

        appState.eventManager.stopAll()
        defer {
            appState.eventManager.startAll()
        }

        MouseCursor.hide()

        defer {
            MouseCursor.warp(to: cursorLocation)
            MouseCursor.show()
        }

        // Item movement can occasionally fail. Retry up to a total of 5 attempts,
        // throwing the last attempt's error if it fails.
        for n in 1...5 {
            do {
                try await moveItemWithoutRestoringMouseLocation(item, to: destination)
                guard let newFrame = getCurrentFrame(for: item) else {
                    throw EventError(code: .invalidItem, item: item)
                }
                if newFrame != initialFrame {
                    Logger.itemManager.info("Successfully moved \(item.logString)")
                    break
                } else {
                    throw EventError(code: .couldNotComplete, item: item)
                }
            } catch where n < 5 {
                Logger.itemManager.warning("Attempt \(n) to move \(item.logString) failed (error: \(error))")
                try await wakeUpItem(item)
                Logger.itemManager.info("Retrying move of \(item.logString)")
                continue
            }
        }
    }

    /// Moves an Accessibility-discovered item with the public Command-drag
    /// gesture used by macOS menu extras. Hosted items do not have a distinct
    /// WindowServer identifier, so the legacy event-field path cannot target them.
    func moveHostedItem(_ item: MenuBarItem, to destination: MoveDestination) async throws {
        guard let appState else {
            throw EventError(code: .invalidAppState, item: item)
        }
        if ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 {
            // Hosted menu items expose AXPress but not writable position/size.
            // A synthetic Command-drag can remove or strand a third-party item,
            // and virtual section dividers have no physical drop coordinate.
            Logger.itemManager.error("Refusing unsafe hosted move of \(item.logString) to \(destination.logString)")
            throw EventError(code: .hostedMovementUnsupported, item: item)
        }
        func matchingItem(for reference: MenuBarItem, in items: [MenuBarItem]) -> MenuBarItem? {
            items.first(where: { $0.stableID == reference.stableID })
                ?? items.first(where: {
                    $0.ownerPID == reference.ownerPID
                        && $0.info.title == reference.info.title
                        && $0.info.namespace == reference.info.namespace
                })
                ?? items.first(where: {
                    $0.ownerPID == reference.ownerPID && $0.info.namespace == reference.info.namespace
                })
        }

        // A layout drag is an explicit user action, so do not reuse the periodic
        // AX enumeration cache here. The cached element can have gone stale while
        // AppKit was running the drag session.
        var currentItems = MenuBarItem.getMenuBarItems(
            onScreenOnly: false,
            activeSpaceOnly: true,
            forceRefresh: true
        )
        var currentItem = matchingItem(for: item, in: currentItems)
        var didRevealSections = false
        // Declared before the sleep below so a cancellation cannot leak the lease.
        defer {
            if didRevealSections { endSectionReveal() }
        }

        // A cached hidden source may not currently exist in AX. Collapse the
        // spacer controls to reacquire it, then restore their previous states.
        if currentItem == nil {
            beginSectionReveal(appState)
            didRevealSections = true
            try await Task.sleep(for: .milliseconds(120))
            currentItems = MenuBarItem.getMenuBarItems(
                onScreenOnly: false,
                activeSpaceOnly: true,
                forceRefresh: true
            )
            currentItem = matchingItem(for: item, in: currentItems)
        }

        // The source view already owns a valid AX handle and frame snapshot. If
        // fresh enumeration cannot see it momentarily, using that handle is safer
        // than rejecting a valid item (the old behavior produced `"…" is invalid`).
        let effectiveItem = currentItem ?? item
        let originalTarget = getTargetItem(for: destination)
        let currentTarget = matchingItem(for: originalTarget, in: currentItems) ?? originalTarget
        let currentDestination: MoveDestination = switch destination {
        case .leftOfItem: .leftOfItem(currentTarget)
        case .rightOfItem: .rightOfItem(currentTarget)
        }

        guard
            let source = CGEventSource(stateID: .hidSystemState),
            let cursorLocation = MouseCursor.locationCoreGraphics
        else {
            throw EventError(code: .eventCreationFailure, item: item)
        }
        let targetFrame = getEffectiveFrame(for: currentTarget)
            ?? currentTarget.hostedHandle?.initialFrame
            ?? originalTarget.hostedHandle?.initialFrame
        guard let targetFrame else {
            // Cross-section drags on a hosted menu bar resolve to a virtual
            // divider (hidden/always-hidden control item) that has no
            // Accessibility frame, so there is no physical Command-drag target.
            // The caller records the new section via `assignHostedItem`, which is
            // the source of truth for visibility on hosted menu bars, so treat
            // this as a successful logical move instead of an error.
            if originalTarget.info == .hiddenControlItem || originalTarget.info == .alwaysHiddenControlItem {
                cachedItemSignatures.removeAll()
                Logger.itemManager.info("Recorded hosted \(item.logString) section assignment (virtual target, no physical drag)")
                return
            }
            throw EventError(code: .invalidItem, item: originalTarget)
        }
        let end = switch currentDestination {
        case .leftOfItem: CGPoint(x: targetFrame.minX, y: targetFrame.midY)
        case .rightOfItem: CGPoint(x: targetFrame.maxX, y: targetFrame.midY)
        }

        appState.eventManager.stopAll()
        MouseCursor.hide()
        defer {
            MouseCursor.warp(to: cursorLocation)
            MouseCursor.show()
            appState.eventManager.startAll()
        }

        // Reads the item's current frame, used as the drag origin and as the
        // pre-move reference for verification. Re-read on every attempt so a
        // partially-applied previous attempt does not poison the next one.
        func currentStart() throws -> CGPoint {
            guard let frame = getCurrentFrame(for: effectiveItem) else {
                throw EventError(code: .invalidItem, item: effectiveItem)
            }
            guard frame.width > 0, frame.height > 0 else {
                throw EventError(code: .invalidItem, item: effectiveItem)
            }
            return CGPoint(x: frame.midX, y: frame.midY)
        }

        func performDrag(from start: CGPoint) async throws {
            guard
                let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: start, mouseButton: .left),
                let drag = CGEvent(mouseEventSource: source, mouseType: .leftMouseDragged, mouseCursorPosition: end, mouseButton: .left),
                let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: end, mouseButton: .left)
            else {
                throw EventError(code: .eventCreationFailure, item: item)
            }
            [down, drag, up].forEach { $0.flags = .maskCommand }

            down.post(tap: .cghidEventTap)
            try await Task.sleep(for: .milliseconds(120))
            for step in 1...20 {
                let progress = CGFloat(step) / 20
                let point = CGPoint(
                    x: start.x + (end.x - start.x) * progress,
                    y: start.y + (end.y - start.y) * progress
                )
                guard let intermediate = CGEvent(
                    mouseEventSource: source,
                    mouseType: .leftMouseDragged,
                    mouseCursorPosition: point,
                    mouseButton: .left
                ) else {
                    throw EventError(code: .eventCreationFailure, item: item)
                }
                intermediate.flags = .maskCommand
                intermediate.post(tap: .cghidEventTap)
                try await Task.sleep(for: .milliseconds(15))
            }
            drag.post(tap: .cghidEventTap)
            try await Task.sleep(for: .milliseconds(30))
            up.post(tap: .cghidEventTap)
            try await Task.sleep(for: .milliseconds(60))
        }

        // Returns `true` if the move took effect. A hosted item that was hidden
        // may vanish from Accessibility entirely, which also counts as success.
        // Items resolved through global hit-testing cache their frame for 10
        // seconds, so the cache must be invalidated before re-reading, otherwise
        // the post-drag frame equals the pre-drag frame and a real move fails
        // verification.
        func verifyMove(against initial: CGRect) throws -> Bool {
            if
                let handle = effectiveItem.hostedHandle,
                handle.requiresGlobalHitTesting
            {
                HostedMenuBarBackend.invalidateGlobalHitFrameCache(
                    for: handle.sourcePID,
                    title: handle.title
                )
            }
            guard let newFrame = effectiveItem.hostedHandle?.currentFrame else {
                return true
            }
            return newFrame != initial
        }

        let maxAttempts = 3
        for attempt in 1...maxAttempts {
            // Invalidate any cached global-hit frame so this attempt presses the
            // item at its actual current position (a prior attempt may have moved
            // it, and the 10-second cache would otherwise report the old spot).
            if let handle = effectiveItem.hostedHandle, handle.requiresGlobalHitTesting {
                HostedMenuBarBackend.invalidateGlobalHitFrameCache(for: handle.sourcePID, title: handle.title)
            }
            let start = try currentStart()
            let initial = getCurrentFrame(for: effectiveItem) ?? .null
            try await performDrag(from: start)
            do {
                if try verifyMove(against: initial) {
                    cachedItemSignatures.removeAll()
                    Logger.itemManager.info("Successfully moved hosted \(item.logString) (attempt \(attempt))")
                    return
                }
            } catch {
                Logger.itemManager.warning("Hosted move verification for \(item.logString) threw: \(error)")
            }
            if attempt < maxAttempts {
                Logger.itemManager.warning("Hosted move attempt \(attempt) for \(item.logString) did not take effect; retrying")
                try await Task.sleep(for: .milliseconds(150))
            }
        }
        throw EventError(code: .couldNotComplete, item: item)
    }

    /// Moves a menu bar item to the given destination and waits until the move
    /// completes before returning.
    ///
    /// - Parameters:
    ///   - item: A menu bar item to move.
    ///   - destination: A destination to move the menu bar item.
    ///   - timeout: Amount of time to wait before throwing an error.
    func slowMove(item: MenuBarItem, to destination: MoveDestination, timeout: Duration = .seconds(1)) async throws {
        itemMoveCount += 1
        defer {
            itemMoveCount -= 1
        }
        try await move(item: item, to: destination)
        if item.hostedHandle != nil {
            return
        }
        let waitTask = Task(timeout: timeout) {
            while true {
                try Task.checkCancellation()
                if try await self.itemHasCorrectPosition(item: item, for: destination) {
                    return
                }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        do {
            try await waitTask.value
        } catch is TaskTimeoutError {
            throw EventError(code: .otherTimeout, item: item)
        }
    }
}

// MARK: - Click Items

extension MenuBarItemManager {
    /// Clicks the given menu bar item with the given mouse button.
    ///
    /// - Parameter preferPhysicalClick: Skips the Accessibility press for hosted
    ///   items and posts a real mouse click at the item's frame. Used right after
    ///   a hidden item was revealed, where AXPress is acknowledged but often does
    ///   not open the item's menu.
    func click(item: MenuBarItem, with mouseButton: CGMouseButton, preferPhysicalClick: Bool = false) async throws {
        if HostedItemVisibilityManager.isSupported, item.hostedHandle != nil {
            guard await HostedMenuBarBackend.refreshRenderedSnapshot() else {
                throw EventError(code: .invalidItem, item: item)
            }
            try Task.checkCancellation()
        }
        if mouseButton == .left, !preferPhysicalClick, item.hostedHandle?.performPress() == true {
            Logger.itemManager.debug("Pressed hosted \(item.logString) through Accessibility")
            return
        }
        if item.hostedHandle != nil {
            try await clickHostedItem(item, with: mouseButton)
            return
        }
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw EventError(code: .invalidEventSource, item: item)
        }
        guard let cursorLocation = MouseCursor.locationCoreGraphics else {
            throw EventError(code: .invalidCursorLocation, item: item)
        }
        guard let currentFrame = getCurrentFrame(for: item) else {
            throw EventError(code: .invalidItem, item: item)
        }

        let buttonStates = mouseButton.buttonStates
        let clickPoint = CGPoint(x: currentFrame.midX, y: currentFrame.midY)

        guard
            let mouseDownEvent = CGEvent.menuBarItemEvent(
                type: .click(buttonStates.down),
                location: clickPoint,
                item: item,
                pid: item.ownerPID,
                source: source
            ),
            let mouseUpEvent = CGEvent.menuBarItemEvent(
                type: .click(buttonStates.up),
                location: clickPoint,
                item: item,
                pid: item.ownerPID,
                source: source
            ),
            let fallbackEvent = CGEvent.menuBarItemEvent(
                type: .click(buttonStates.up),
                location: clickPoint,
                item: item,
                pid: item.ownerPID,
                source: source
            )
        else {
            throw EventError(code: .eventCreationFailure, item: item)
        }

        try permitAllEvents(
            for: .combinedSessionState,
            during: [
                .eventSuppressionStateRemoteMouseDrag,
                .eventSuppressionStateSuppressionInterval,
            ],
            suppressionInterval: 0,
            item: item
        )

        MouseCursor.hide()

        defer {
            MouseCursor.warp(to: cursorLocation)
            MouseCursor.show()
        }

        do {
            Logger.itemManager.info("Clicking \(item.logString) with \(mouseButton.logString)")
            try await postEventAndWaitToReceive(
                mouseDownEvent,
                to: .sessionEventTap,
                item: item
            )
            try await postEventAndWaitToReceive(
                mouseUpEvent,
                to: .sessionEventTap,
                item: item
            )
        } catch {
            do {
                Logger.itemManager.debug("Posting fallback event for clicking \(item.logString)")
                // Catch this, as we still want to throw the existing error if the fallback fails.
                try await postEventAndWaitToReceive(
                    fallbackEvent,
                    to: .sessionEventTap,
                    item: item
                )
            } catch {
                Logger.itemManager.error("Failed to post fallback event for clicking \(item.logString)")
            }
            throw error
        }
    }

    /// Clicks a hosted item by screen coordinate when its Accessibility element
    /// does not support AXPress (including secondary clicks).
    func clickHostedItem(_ item: MenuBarItem, with mouseButton: CGMouseButton) async throws {
        guard
            let source = CGEventSource(stateID: .hidSystemState),
            let cursorLocation = MouseCursor.locationCoreGraphics,
            let frame = getCurrentFrame(for: item)
        else {
            throw EventError(code: .eventCreationFailure, item: item)
        }
        let eventTypes: (down: CGEventType, up: CGEventType) = switch mouseButton {
        case .left: (.leftMouseDown, .leftMouseUp)
        case .right: (.rightMouseDown, .rightMouseUp)
        default: (.otherMouseDown, .otherMouseUp)
        }
        let point = CGPoint(x: frame.midX, y: frame.midY)
        guard
            let down = CGEvent(mouseEventSource: source, mouseType: eventTypes.down, mouseCursorPosition: point, mouseButton: mouseButton),
            let up = CGEvent(mouseEventSource: source, mouseType: eventTypes.up, mouseCursorPosition: point, mouseButton: mouseButton)
        else {
            throw EventError(code: .eventCreationFailure, item: item)
        }
        MouseCursor.hide()
        defer {
            MouseCursor.warp(to: cursorLocation)
            MouseCursor.show()
        }
        CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?
            .post(tap: .cghidEventTap)
        try await Task.sleep(for: .milliseconds(20))
        down.post(tap: .cghidEventTap)
        try await Task.sleep(for: .milliseconds(20))
        up.post(tap: .cghidEventTap)
    }
}

// MARK: - Arrange Items

extension MenuBarItemManager {
    /// Enforces the order of the given control items, ensuring that the always-hidden
    /// control item stays to the left of the hidden control item.
    ///
    /// - Parameters:
    ///   - hiddenControlItem: A menu bar item that represents the control item for the
    ///     hidden section.
    ///   - alwaysHiddenControlItem: A menu bar item that represents the control item
    ///     for the always-hidden section.
    func enforceControlItemOrder(hiddenControlItem: MenuBarItem, alwaysHiddenControlItem: MenuBarItem) async throws {
        guard !isMouseButtonDown else {
            Logger.itemManager.debug("Mouse button is down, so will not enforce control item order")
            return
        }
        guard !mouseHasRecentlyMoved else {
            Logger.itemManager.debug("Mouse has recently moved, so will not enforce control item order")
            return
        }
        if hiddenControlItem.frame.maxX <= alwaysHiddenControlItem.frame.minX {
            Logger.itemManager.info("Arranging menu bar items")
            try await slowMove(item: alwaysHiddenControlItem, to: .leftOfItem(hiddenControlItem))
        }
    }
}

// MARK: - Menu Bar Item Event Helper Types

/// Button states for menu bar item events.
private enum MenuBarItemEventButtonState {
    case leftMouseDown
    case leftMouseUp
    case rightMouseDown
    case rightMouseUp
    case otherMouseDown
    case otherMouseUp
}

/// Event types for menu bar item events.
private enum MenuBarItemEventType {
    /// The event type for moving a menu bar item.
    case move(MenuBarItemEventButtonState)

    /// The event type for clicking a menu bar item.
    case click(MenuBarItemEventButtonState)

    /// The button state of this event type.
    var buttonState: MenuBarItemEventButtonState {
        switch self {
        case .move(let state), .click(let state): state
        }
    }

    /// This event type's equivalent CGEventType.
    var cgEventType: CGEventType {
        switch buttonState {
        case .leftMouseDown: .leftMouseDown
        case .leftMouseUp: .leftMouseUp
        case .rightMouseDown: .rightMouseDown
        case .rightMouseUp: .rightMouseUp
        case .otherMouseDown: .otherMouseDown
        case .otherMouseUp: .otherMouseUp
        }
    }

    /// The event flags for this event type.
    var cgEventFlags: CGEventFlags {
        switch self {
        case .move(.leftMouseDown): .maskCommand
        case .move, .click: []
        }
    }

    /// The mouse button for this event type.
    var mouseButton: CGMouseButton {
        switch buttonState {
        case .leftMouseDown, .leftMouseUp: .left
        case .rightMouseDown, .rightMouseUp: .right
        case .otherMouseDown, .otherMouseUp: .center
        }
    }
}

// MARK: - CGEventField Helpers

private extension CGEventField {
    /// Key to access a field that contains the event's window identifier.
    static let windowID = CGEventField(rawValue: 0x33)! // swiftlint:disable:this force_unwrapping

    /// An array of integer event fields that can be used to compare menu bar item events.
    static let menuBarItemEventFields: [CGEventField] = [
        .eventSourceUserData,
        .mouseEventWindowUnderMousePointer,
        .mouseEventWindowUnderMousePointerThatCanHandleThisEvent,
        .windowID,
    ]
}

// MARK: - CGEventFilterMask Helpers

private extension CGEventFilterMask {
    /// Specifies that all events should be permitted during event suppression states.
    static let permitAllEvents: CGEventFilterMask = [
        .permitLocalMouseEvents,
        .permitLocalKeyboardEvents,
        .permitSystemDefinedEvents,
    ]
}

// MARK: - CGEventType Helpers

private extension CGEventType {
    /// A string to use for logging purposes.
    var logString: String {
        switch self {
        case .null: "null event"
        case .leftMouseDown: "leftMouseDown event"
        case .leftMouseUp: "leftMouseUp event"
        case .rightMouseDown: "rightMouseDown event"
        case .rightMouseUp: "rightMouseUp event"
        case .mouseMoved: "mouseMoved event"
        case .leftMouseDragged: "leftMouseDragged event"
        case .rightMouseDragged: "rightMouseDragged event"
        case .keyDown: "keyDown event"
        case .keyUp: "keyUp event"
        case .flagsChanged: "flagsChanged event"
        case .scrollWheel: "scrollWheel event"
        case .tabletPointer: "tabletPointer event"
        case .tabletProximity: "tabletProximity event"
        case .otherMouseDown: "otherMouseDown event"
        case .otherMouseUp: "otherMouseUp event"
        case .otherMouseDragged: "otherMouseDragged event"
        case .tapDisabledByTimeout: "tapDisabledByTimeout event"
        case .tapDisabledByUserInput: "tapDisabledByUserInput event"
        @unknown default: "unknown event"
        }
    }
}

// MARK: - CGMouseButton Helpers

private extension CGMouseButton {
    /// A string to use for logging purposes.
    var logString: String {
        switch self {
        case .left: "left mouse button"
        case .right: "right mouse button"
        case .center: "center mouse button"
        @unknown default: "unknown mouse button"
        }
    }

    /// The equivalent down and up button states for menu bar item click events.
    var buttonStates: (down: MenuBarItemEventButtonState, up: MenuBarItemEventButtonState) {
        switch self {
        case .left: (.leftMouseDown, .leftMouseUp)
        case .right: (.rightMouseDown, .rightMouseUp)
        default: (.otherMouseDown, .otherMouseUp)
        }
    }
}

// MARK: - CGEvent Constructor

private extension CGEvent {
    /// Returns an event that can be sent to the given menu bar item.
    ///
    /// - Parameters:
    ///   - type: The type of the event.
    ///   - location: The location of the event. Does not need to be within the bounds of the item.
    ///   - item: The target item of the event.
    ///   - pid: The target process identifier of the event. Does not need to be the item's `ownerPID`.
    ///   - source: The source of the event.
    class func menuBarItemEvent(type: MenuBarItemEventType, location: CGPoint, item: MenuBarItem, pid: pid_t, source: CGEventSource) -> CGEvent? {
        let mouseType = type.cgEventType
        let mouseButton = type.mouseButton

        guard let event = CGEvent(mouseEventSource: source, mouseType: mouseType, mouseCursorPosition: location, mouseButton: mouseButton) else {
            return nil
        }

        event.flags = type.cgEventFlags

        let targetPID = Int64(pid)
        let userData = Int64(truncatingIfNeeded: Int(bitPattern: ObjectIdentifier(event)))
        let windowID = Int64(item.windowID)

        event.setIntegerValueField(.eventTargetUnixProcessID, value: targetPID)
        event.setIntegerValueField(.eventSourceUserData, value: userData)
        event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: windowID)
        event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: windowID)
        event.setIntegerValueField(.windowID, value: windowID)

        if case .click = type {
            event.setIntegerValueField(.mouseEventClickState, value: 1)
        }

        return event
    }
}
