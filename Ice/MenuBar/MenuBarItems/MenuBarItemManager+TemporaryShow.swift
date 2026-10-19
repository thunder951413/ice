//
//  MenuBarItemManager+TemporaryShow.swift
//  Ice
//

import Cocoa
import Combine

// MARK: - Temporarily Show Items

extension MenuBarItemManager {
    /// Gets the destination to return the given item to after it is temporarily shown.
    func getReturnDestination(for item: MenuBarItem, in items: [MenuBarItem]) -> MoveDestination? {
        if let index = items.firstIndex(where: { $0.stableID == item.stableID }) {
            if items.indices.contains(index + 1) {
                return .leftOfItem(items[index + 1])
            } else if items.indices.contains(index - 1) {
                return .rightOfItem(items[index - 1])
            }
        }
        return nil
    }

    /// Schedules a timer for the given interval, attempting to rehide the current
    /// temporarily shown items when the timer fires.
    func runTempShownItemTimer(for interval: TimeInterval) {
        Logger.itemManager.debug("Running rehide timer for temporarily shown items with interval: \(interval)")
        tempShownItemsTimer?.invalidate()
        tempShownItemsTimer = .scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            Logger.itemManager.debug("Rehide timer fired")
            Task {
                await self.rehideTempShownItems()
            }
        }
    }

    func presentHostedActivationFailure(_ item: MenuBarItem, error: Error, mouseButton: CGMouseButton) {
        Logger.itemManager.error("Could not open hosted item: \(error.localizedDescription)")
        let alert = NSAlert()
        alert.messageText = "Couldn’t open \(item.displayName)"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "Try Again")
        if item.owningApplication?.bundleURL != nil { alert.addButton(withTitle: "Open App") }
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            tempShowItem(item, clickWhenFinished: true, mouseButton: mouseButton)
        } else if response == .alertSecondButtonReturn, let url = item.owningApplication?.bundleURL {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
    }

    /// Temporarily shows the given item.
    ///
    /// The item is cached alongside a destination that it will be automatically returned
    /// to. If `true` is passed to the `clickWhenFinished` parameter, the item is clicked
    /// once movement is finished.
    ///
    /// - Parameters:
    ///   - item: An item to show.
    ///   - clickWhenFinished: A Boolean value that indicates whether the item should be
    ///     clicked once movement is finished.
    ///   - mouseButton: The mouse button of the click.
    func tempShowItem(_ item: MenuBarItem, clickWhenFinished: Bool, mouseButton: CGMouseButton) {
        if HostedItemVisibilityManager.isSupported, item.hostedHandle != nil, let appState {
            Task {
                do {
                    try await appState.menuBarManager.hostedItemVisibilityManager.withTemporarilyRevealedItem(item) { validate in
                        guard clickWhenFinished else { return }
                        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
                        var attempt = 0
                        repeat {
                            try validate()
                            // The item already exists in the descriptor cache; only the
                            // rendered frames (refreshed below) change when it is revealed.
                            // Force a full scan only if the first, cheap attempt misses.
                            let descriptors = await HostedMenuBarBackend.refreshEnumeration(force: attempt > 0)
                            attempt += 1
                            let hasRenderedSnapshot = await HostedMenuBarBackend.refreshRenderedSnapshot()
                            let latest = descriptors
                                .map(MenuBarItem.init(hostedHandle:))
                                .first { hasRenderedSnapshot && $0.stableID == item.stableID && $0.isOnScreen }
                            try validate()
                            if let latest {
                                try await self.click(item: latest, with: mouseButton, preferPhysicalClick: true)
                                return
                            }
                            try await Task.sleep(for: .milliseconds(150))
                        } while ContinuousClock.now < deadline
                        throw HostedItemVisibilityManager.RevealError.unavailable
                    }
                } catch is CancellationError {
                    // A newer click, pause, or shutdown superseded this request.
                } catch {
                    self.presentHostedActivationFailure(item, error: error, mouseButton: mouseButton)
                }
            }
            return
        }
        let latest = MenuBarItem.getMenuBarItems(onScreenOnly: false, activeSpaceOnly: true)
            .first { $0.stableID == item.stableID }
        if let latest, latest.isOnScreen {
            if clickWhenFinished {
                Task {
                    do {
                        try await click(item: latest, with: mouseButton)
                    } catch {
                        Logger.itemManager.error("ERROR: \(error)")
                    }
                }
            }
            return
        }
        if
            let latest,
            clickWhenFinished,
            mouseButton == .left,
            latest.hostedHandle?.performPress() == true
        {
            Logger.itemManager.debug("Pressed hidden hosted \(item.logString) through Accessibility")
            return
        }
        if item.hostedHandle != nil, latest == nil {
            Task {
                await revealAndClickHostedItem(item, clickWhenFinished: clickWhenFinished, mouseButton: mouseButton)
            }
            return
        }

        guard
            let appState,
            let screen = NSScreen.main,
            let applicationMenuFrame = appState.menuBarManager.getApplicationMenuFrame(for: screen.displayID)
        else {
            Logger.itemManager.warning("No application menu frame, so not showing \(item.logString)")
            return
        }

        Logger.itemManager.info("Temporarily showing \(item.logString)")

        var items = MenuBarItem.getMenuBarItems(onScreenOnly: false, activeSpaceOnly: true)

        guard let destination = getReturnDestination(for: item, in: items) else {
            Logger.itemManager.warning("No return destination for \(item.logString)")
            return
        }

        // Remove all items up to and including the hidden control item.
        guard let hiddenControlIndex = controlItemIndex(for: .hidden, in: items) else {
            Logger.itemManager.warning("No hidden control item, so not showing \(item.logString)")
            return
        }
        items.removeSubrange(items.startIndex...hiddenControlIndex)
        // Remove all offscreen items.
        items.trimPrefix { !$0.isOnScreen }

        let maxX = if let rightArea = screen.auxiliaryTopRightArea {
            max(rightArea.minX + 20, applicationMenuFrame.maxX)
        } else {
            applicationMenuFrame.maxX
        }

        // Remove items until we have enough room to show this item.
        items.trimPrefix { $0.frame.minX - item.frame.width <= maxX }

        guard let targetItem = items.first else {
            let alert = NSAlert()
            alert.messageText = "Not enough room to show \"\(item.displayName)\""
            alert.runModal()
            return
        }

        let initialWindows = WindowInfo.getOnScreenWindows()

        Task {
            if clickWhenFinished {
                do {
                    try await slowMove(item: item, to: .leftOfItem(targetItem))
                    try await click(item: item, with: mouseButton)
                } catch {
                    Logger.itemManager.error("ERROR: \(error)")
                }
            } else {
                do {
                    try await move(item: item, to: .leftOfItem(targetItem))
                } catch {
                    Logger.itemManager.error("ERROR: \(error)")
                }
            }

            try? await Task.sleep(for: .milliseconds(100))

            let currentWindows = WindowInfo.getOnScreenWindows()

            let shownInterfaceWindow = currentWindows.first { currentWindow in
                currentWindow.ownerPID == item.ownerPID &&
                    !initialWindows.contains { initialWindow in
                        currentWindow.windowID == initialWindow.windowID
                    }
            }

            let context = TempShownItemContext(
                stableID: item.stableID,
                info: item.info,
                returnDestination: destination,
                shownInterfaceWindow: shownInterfaceWindow
            )
            tempShownItemContexts.append(context)
            runTempShownItemTimer(for: appState.settingsManager.advancedSettingsManager.tempShowInterval)
        }
    }

    /// Shows every section for the duration of a lease. Overlapping callers
    /// share one capture of the original states, so a second reveal can never
    /// record "shown" as the state to return to.
    func beginSectionReveal(_ appState: AppState) {
        let controls = appState.menuBarManager.sections.map(\.controlItem)
        if sectionRevealLeases == 0 {
            sectionStatesBeforeReveal = controls.map { ($0, $0.state) }
        }
        sectionRevealLeases += 1
        controls.forEach { $0.state = .showItems }
    }

    func endSectionReveal() {
        guard sectionRevealLeases > 0 else { return }
        sectionRevealLeases -= 1
        guard sectionRevealLeases == 0 else { return }
        sectionStatesBeforeReveal.forEach { control, state in control.state = state }
        sectionStatesBeforeReveal.removeAll()
    }

    /// Hosted hidden items can disappear from AX. Reveal their owning section
    /// long enough to reacquire the element and perform the requested click.
    func revealAndClickHostedItem(
        _ item: MenuBarItem,
        clickWhenFinished: Bool,
        mouseButton: CGMouseButton
    ) async {
        guard let appState else {
            return
        }
        beginSectionReveal(appState)
        defer { endSectionReveal() }
        try? await Task.sleep(for: .milliseconds(150))

        let items = MenuBarItem.getMenuBarItems(onScreenOnly: false, activeSpaceOnly: true)
        let latest = items.first { $0.stableID == item.stableID }
            ?? items.first { candidate in
                candidate.ownerPID == item.ownerPID && candidate.info.namespace == item.info.namespace
            }
        guard let latest else {
            Logger.itemManager.error("Could not reacquire hosted \(item.logString) after revealing sections")
            return
        }

        if clickWhenFinished {
            do {
                try await click(item: latest, with: mouseButton)
            } catch {
                Logger.itemManager.error("Failed to click revealed hosted \(item.logString): \(error)")
            }
        }

        let interval = max(1, appState.settingsManager.advancedSettingsManager.tempShowInterval)
        try? await Task.sleep(for: .seconds(interval))
        cachedItemSignatures.removeAll()
    }

    /// Rehides all temporarily shown items.
    ///
    /// If an item is currently showing its interface, this method waits for the
    /// interface to close before hiding the items.
    func rehideTempShownItems() async {
        itemMoveCount += 1
        defer {
            itemMoveCount -= 1
        }

        guard !tempShownItemContexts.isEmpty else {
            return
        }

        guard !isMouseButtonDown else {
            Logger.itemManager.debug("Mouse button is down, so waiting to rehide")
            runTempShownItemTimer(for: 3)
            return
        }
        guard !tempShownItemContexts.contains(where: { $0.isShowingInterface }) else {
            Logger.itemManager.debug("Menu bar item interface is shown, so waiting to rehide")
            runTempShownItemTimer(for: 3)
            return
        }

        Logger.itemManager.info("Rehiding temporarily shown items")

        var failedContexts = [TempShownItemContext]()

        let items = MenuBarItem.getMenuBarItems(onScreenOnly: false, activeSpaceOnly: true)

        MouseCursor.hide()

        defer {
            MouseCursor.show()
        }

        while let context = tempShownItemContexts.popLast() {
            guard let item = items.first(where: { $0.info == context.info }) else {
                continue
            }
            do {
                try await move(item: item, to: context.returnDestination)
            } catch {
                Logger.itemManager.error("Failed to rehide \(item.logString) (error: \(error))")
                failedContexts.append(context)
            }
        }

        if failedContexts.isEmpty {
            tempShownItemsTimer?.invalidate()
            tempShownItemsTimer = nil
        } else {
            tempShownItemContexts = failedContexts
            Logger.itemManager.warning("Some items failed to rehide")
            runTempShownItemTimer(for: 3)
        }
    }

    /// Removes a temporarily shown item from the cache.
    ///
    /// This ensures that the item will _not_ be returned to its previous location.
    func removeTempShownItemFromCache(with info: MenuBarItemInfo) {
        tempShownItemContexts.removeAll { $0.info == info }
    }
}
