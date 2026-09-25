//
//  HostedItemVisibilityManager.swift
//  Ice
//
// MenuBarClientCore assertion approach documented by Thaw (GPL-3.0):
// https://github.com/thaw-app/Thaw/tree/macos-27-preview.1/Thaw/MenuBar/HiddenSectionPatch

import Cocoa
import Combine

/// Owns a process-scoped menu bar restriction. Releasing it restores the real
/// icons and their space; no wallpaper masks or persistent system writes.
@MainActor
final class HostedItemVisibilityManager: ObservableObject {
    @Published private(set) var failureDescription: String?

    static var isSupported: Bool {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27
    }

    private weak var appState: AppState?
    private lazy var assertion = VisibilityAssertionSession<UnsafeMutableRawPointer>(
        activate: { configuration, completion in
            IceMenuBarVisibilityActivate(configuration.allowed.sorted(), (0...8).map { NSNumber(value: $0) }) { error in
                MainActor.assumeIsolated { completion(error) }
            }
        },
        invalidate: { IceMenuBarVisibilityInvalidate($0) }
    )
    private var needsReactivation = false
    private var lastFailed: HostedVisibilityPolicy.Configuration?
    private var generation = 0
    private var ignoreStateChangesUntil = Date.distantPast
    private var cancellables = Set<AnyCancellable>()
    private var refreshTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var retryConfiguration: HostedVisibilityPolicy.Configuration?
    private var activationFailureCount = 0
    private var revealTasks = [String: Task<Void, Never>]()
    private var temporarilyRevealedBundles = Set<String>()
    private var revealTokens = [String: UUID]()
    private struct RevealWaiter {
        let bundle: String
        let continuation: CheckedContinuation<Void, Error>
        let timeout: Task<Void, Never>
    }
    private var revealWaiters = [UUID: RevealWaiter]()
    private var permissionWasAvailable = true
    private var isStopped = false
    private var isClockActivationInProgress = false
    private let logger = Logger(category: "HostedItemVisibility")

    init(appState: AppState) {
        self.appState = appState
    }

    func performSetup() {
        guard Self.isSupported, let appState else { return }
        if !IceMenuBarVisibilityAvailable() {
            failureDescription = "This macOS version does not provide the menu bar hiding interface. Items remain visible."
        }
        let changes = Publishers.MergeMany(
            [appState.itemManager.$itemCache.mapToVoid().eraseToAnyPublisher(),
             appState.settingsManager.generalSettingsManager.$useIceBar.mapToVoid().eraseToAnyPublisher(),
             appState.settingsManager.advancedSettingsManager.$enableAlwaysHiddenSection.mapToVoid().eraseToAnyPublisher(),
             appState.menuBarManager.$isHidingPaused.mapToVoid().eraseToAnyPublisher()]
                + appState.menuBarManager.sections.map { $0.controlItem.$state.mapToVoid().eraseToAnyPublisher() }
        )
        changes.sink { [weak self] in self?.scheduleRefresh() }.store(in: &cancellables)

        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didWakeNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            NSWorkspace.shared.notificationCenter.publisher(for: name)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    HostedMenuBarBackend.invalidateEnumerationCache()
                    if name == NSWorkspace.didWakeNotification {
                        self?.needsReactivation = true
                        self?.lastFailed = nil
                    }
                    self?.scheduleRefresh()
                }.store(in: &cancellables)
        }
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in
                HostedMenuBarBackend.invalidateEnumerationCache()
                self?.scheduleRefresh()
            }.store(in: &cancellables)
        DistributedNotificationCenter.default()
            .publisher(for: Notification.Name("com.apple.donotdisturb.stateChanged"))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, Date.now >= ignoreStateChangesUntil else { return }
                // A Focus transition can invalidate the assertion. Ignore our
                // own notifications to avoid a reactivation/reflow loop.
                needsReactivation = true
                lastFailed = nil
                scheduleRefresh()
            }.store(in: &cancellables)
        // Recheck revocation without keeping the onboarding one-second poll alive.
        Timer.publish(every: 10, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in
                guard let self, !self.isStopped else { return }
                self.appState?.permissionsManager.refreshPermissions()
                let hadPermission = self.permissionWasAvailable
                if self.checkAccessibility(), !hadPermission { self.scheduleRefresh() }
            }.store(in: &cancellables)
        scheduleRefresh()
    }

    private func scheduleRefresh() {
        guard !isStopped else { return }
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self else { return }
            refreshTask = nil
            refreshNow()
        }
    }

    func refreshNow() {
        guard Self.isSupported, !isStopped, let appState else { return }
        // A held assertion suppresses Notification Center even though Clock
        // itself remains visible. Keep it released until that panel closes.
        guard !isClockActivationInProgress else { return }
        guard checkAccessibility() else { return }
        guard !appState.menuBarManager.isHidingPaused else {
            if assertion.isActive || assertion.isActivating { releaseRestriction() }
            resolveRevealWaiters()
            return
        }
        let useIceBar = appState.settingsManager.generalSettingsManager.useIceBar
        let entries = MenuBarSection.Name.allCases.flatMap { name in
            let section = appState.menuBarManager.section(withName: name)
            let hide = name != .visible && section?.isEnabled == true
                && (useIceBar || section?.controlItem.state == .hideItems)
            return appState.itemManager.itemCache[name].map { item in
                let bundle = item.hostedHandle?.sourceBundleIdentifier
                return HostedVisibilityPolicy.Item(
                    bundleIdentifier: bundle,
                    shouldHide: hide && item.canBeHidden && !temporarilyRevealedBundles.contains(bundle ?? "")
                )
            }
        }
        let desired = HostedVisibilityPolicy.configuration(
            items: entries,
            runningBundleIdentifiers: Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)),
            ownBundleIdentifier: Constants.bundleIdentifier
        )
        if retryConfiguration != nil, retryConfiguration != desired {
            cancelActivationRetry()
            lastFailed = nil
        }
        guard !desired.concealed.isEmpty else {
            releaseRestriction()
            failureDescription = nil
            lastFailed = nil
            cancelActivationRetry()
            resolveRevealWaiters()
            return
        }
        guard IceMenuBarVisibilityAvailable() else {
            failureDescription = "Menu bar hiding is unavailable on this macOS version. Items remain visible."
            return
        }
        guard !assertion.isActivating else { return }
        if !needsReactivation, let applied = assertion.activeConfiguration, assertion.isActive,
           applied.concealed == desired.concealed,
           desired.allowed.isSubset(of: applied.allowed) {
            resolveRevealWaiters()
            return
        }
        guard lastFailed != desired else { return }
        needsReactivation = false
        generation += 1
        let attempt = generation
        ignoreStateChangesUntil = .now.addingTimeInterval(1.5)
        assertion.begin(desired) { [weak self] result in
            guard let self, self.generation == attempt, !self.isStopped else { return }
            self.ignoreStateChangesUntil = .now.addingTimeInterval(1.5)
            switch result {
            case .failure(let error):
                self.needsReactivation = true
                self.recordActivationFailure(desired, description: error.localizedDescription)
                self.failRevealWaiters(error)
                self.logger.error("Visibility assertion failed: \(error.localizedDescription)")
            case .success:
                HostedMenuBarBackend.setConcealedBundleIdentifiers(desired.concealed)
                self.cancelActivationRetry()
                self.lastFailed = nil
                self.failureDescription = nil
                HostedMenuBarBackend.invalidateEnumerationCache()
                self.resolveRevealWaiters()
            }
            self.scheduleRefresh()
        }
    }

    enum RevealError: LocalizedError {
        case permissionRequired
        case timedOut
        case unavailable

        var errorDescription: String? {
            switch self {
            case .permissionRequired: "Accessibility permission is required. Enable it in System Settings, then try again."
            case .timedOut: "The menu bar item did not become available in time. Try again."
            case .unavailable: "This menu bar item is no longer available."
            }
        }
    }

    /// Wait for the actual configuration completion, perform the click, and only
    /// then start the user's rehide delay. Newer clicks supersede older requests.
    func withTemporarilyRevealedItem(
        _ item: MenuBarItem,
        action: @MainActor (_ validate: @escaping @MainActor () throws -> Void) async throws -> Void
    ) async throws {
        guard !isStopped else { throw CancellationError() }
        guard checkAccessibility() else { throw RevealError.permissionRequired }
        guard let bundle = item.hostedHandle?.sourceBundleIdentifier else { throw RevealError.unavailable }
        let baselineWindowIDs = Set(WindowInfo.getOnScreenWindows()
            .filter { $0.ownerPID == item.ownerPID }.map(\.windowID))
        if let previous = revealTokens[bundle] { finishRevealWaiter(previous, error: CancellationError()) }
        let token = UUID()
        revealTokens[bundle] = token
        temporarilyRevealedBundles.insert(bundle)
        revealTasks[bundle]?.cancel()
        revealTasks[bundle] = nil
        var didPerformAction = false
        defer {
            scheduleRehide(item, bundle: bundle, token: token,
                baselineWindowIDs: baselineWindowIDs, didPerformAction: didPerformAction)
        }
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let timeout = Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: .seconds(8)) } catch { return }
                    self?.finishRevealWaiter(token, error: RevealError.timedOut)
                }
                revealWaiters[token] = RevealWaiter(bundle: bundle, continuation: continuation, timeout: timeout)
                refreshNow()
                resolveRevealWaiters()
            }
            try Task.checkCancellation()
            guard revealTokens[bundle] == token, !isStopped else { throw CancellationError() }
            try await action { [weak self] in
                try Task.checkCancellation()
                guard let self, !self.isStopped, self.revealTokens[bundle] == token else {
                    throw CancellationError()
                }
                guard self.checkAccessibility() else { throw RevealError.permissionRequired }
            }
            didPerformAction = true
        } onCancel: {
            Task { @MainActor [weak self] in self?.finishRevealWaiter(token, error: CancellationError()) }
        }
    }

    private func resolveRevealWaiters() {
        guard !assertion.isActivating else { return }
        let concealed = assertion.activeConfiguration?.concealed ?? []
        let ready = revealWaiters.filter { !concealed.contains($0.value.bundle) }.map(\.key)
        for token in ready { finishRevealWaiter(token, error: nil) }
    }

    private func finishRevealWaiter(_ token: UUID, error: Error?) {
        guard let waiter = revealWaiters.removeValue(forKey: token) else { return }
        waiter.timeout.cancel()
        if let error { waiter.continuation.resume(throwing: error) }
        else { waiter.continuation.resume() }
    }

    private func failRevealWaiters(_ error: Error) {
        for token in Array(revealWaiters.keys) { finishRevealWaiter(token, error: error) }
    }

    private func scheduleRehide(
        _ item: MenuBarItem, bundle: String, token: UUID,
        baselineWindowIDs: Set<CGWindowID>, didPerformAction: Bool
    ) {
        guard revealTokens[bundle] == token, !isStopped else { return }
        let configuredDelay = appState?.settingsManager.advancedSettingsManager.tempShowInterval ?? 15
        let boundedDelay = configuredDelay.isFinite ? min(30, max(0, configuredDelay)) : 15
        // Even zero-delay menus need one run-loop opportunity to create their
        // windows after AXPress; the user's delay begins after the action.
        let delay = didPerformAction ? max(0.5, boundedDelay) : 0
        revealTasks[bundle] = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self else { return }
            while WindowInfo.getOnScreenWindows().contains(where: {
                $0.ownerPID == item.ownerPID && !baselineWindowIDs.contains($0.windowID)
            }) {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
            guard self.revealTokens[bundle] == token, !Task.isCancelled else { return }
            self.revealTokens[bundle] = nil
            self.temporarilyRevealedBundles.remove(bundle)
            self.revealTasks[bundle] = nil
            self.refreshNow()
        }
    }

    @discardableResult
    private func checkAccessibility() -> Bool {
        guard AXIsProcessTrusted() else {
            permissionWasAvailable = false
            failRevealWaiters(RevealError.permissionRequired)
            if assertion.isActive || assertion.isActivating {
                releaseRestriction()
                cancelActivationRetry()
            }
            failureDescription = RevealError.permissionRequired.localizedDescription
            return false
        }
        if !permissionWasAvailable {
            permissionWasAvailable = true
            needsReactivation = true
            lastFailed = nil
        }
        return true
    }

    func restoreAll(stop: Bool = false) {
        isStopped = stop
        isClockActivationInProgress = false
        refreshTask?.cancel()
        refreshTask = nil
        cancelActivationRetry()
        revealTasks.values.forEach { $0.cancel() }
        revealTasks.removeAll()
        temporarilyRevealedBundles.removeAll()
        revealTokens.removeAll()
        failRevealWaiters(CancellationError())
        lastFailed = nil
        failureDescription = nil
        releaseRestriction()
    }

    var needsClockActivationBridge: Bool {
        Self.isSupported && !isStopped && !isClockActivationInProgress && assertion.isActive
    }

    func beginClockActivationBridge() -> Bool {
        guard needsClockActivationBridge else { return false }
        isClockActivationInProgress = true
        releaseRestriction()
        return true
    }

    func endClockActivationBridge() {
        guard isClockActivationInProgress else { return }
        isClockActivationInProgress = false
        refreshNow()
    }

    private func recordActivationFailure(
        _ configuration: HostedVisibilityPolicy.Configuration,
        description: String
    ) {
        if retryConfiguration != configuration {
            cancelActivationRetry()
            retryConfiguration = configuration
        }
        let delays: [Duration] = [
            .milliseconds(500), .seconds(1), .seconds(2), .seconds(4), .seconds(8),
        ]
        activationFailureCount = min(activationFailureCount + 1, delays.count)
        lastFailed = configuration
        failureDescription = "macOS could not hide menu bar items: \(description)"

        let delay = delays[activationFailureCount - 1]
        retryTask?.cancel()
        retryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, !self.isStopped,
                  self.retryConfiguration == configuration else { return }
            self.retryTask = nil
            self.lastFailed = nil
            self.refreshNow()
        }
    }

    private func cancelActivationRetry() {
        retryTask?.cancel()
        retryTask = nil
        retryConfiguration = nil
        activationFailureCount = 0
    }

    private func releaseRestriction() {
        generation += 1
        ignoreStateChangesUntil = .now.addingTimeInterval(1.5)
        assertion.invalidateAll()
        needsReactivation = false
        HostedMenuBarBackend.setConcealedBundleIdentifiers([])
    }
}
