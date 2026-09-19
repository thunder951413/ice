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
    private var handle: UnsafeMutableRawPointer?
    private var pendingHandle: UnsafeMutableRawPointer?
    private var pendingConfiguration: HostedVisibilityPolicy.Configuration?
    private var needsReactivation = false
    private var applied: HostedVisibilityPolicy.Configuration?
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
    private var isStopped = false
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
             appState.settingsManager.advancedSettingsManager.$enableAlwaysHiddenSection.mapToVoid().eraseToAnyPublisher()]
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
            return
        }
        guard IceMenuBarVisibilityAvailable() else {
            failureDescription = "Menu bar hiding is unavailable on this macOS version. Items remain visible."
            return
        }
        // Serialize replacements. Changes arriving during activation are folded
        // into the next refresh after completion rather than opening a gap.
        guard pendingConfiguration == nil else { return }
        if !needsReactivation, let applied, handle != nil,
           applied.concealed == desired.concealed,
           desired.allowed.isSubset(of: applied.allowed) { return }
        guard lastFailed != desired else { return }
        needsReactivation = false
        generation += 1
        let attempt = generation
        pendingConfiguration = desired
        ignoreStateChangesUntil = .now.addingTimeInterval(1.5)
        // Keep the current restriction alive until its replacement is active.
        // Releasing it first briefly reveals every hidden menu bar item.
        pendingHandle = IceMenuBarVisibilityActivate(desired.allowed.sorted(), (0...8).map { NSNumber(value: $0) }) { [weak self] error in
            MainActor.assumeIsolated {
                guard let self, self.generation == attempt, !self.isStopped else { return }
                self.ignoreStateChangesUntil = .now.addingTimeInterval(1.5)
                if let error {
                    if let pendingHandle = self.pendingHandle {
                        IceMenuBarVisibilityInvalidate(pendingHandle)
                    }
                    self.pendingHandle = nil
                    self.pendingConfiguration = nil
                    // A failed replacement must not discard the working one.
                    self.needsReactivation = true
                    self.recordActivationFailure(desired, description: error.localizedDescription)
                    self.logger.error("Visibility assertion failed: \(error.localizedDescription)")
                    self.scheduleRefresh()
                } else {
                    let previousHandle = self.handle
                    self.handle = self.pendingHandle
                    self.pendingHandle = nil
                    self.pendingConfiguration = nil
                    self.applied = desired
                    HostedMenuBarBackend.setConcealedBundleIdentifiers(desired.concealed)
                    if let previousHandle {
                        IceMenuBarVisibilityInvalidate(previousHandle)
                    }
                    self.cancelActivationRetry()
                    self.lastFailed = nil
                    self.failureDescription = nil
                    HostedMenuBarBackend.invalidateEnumerationCache()
                    self.scheduleRefresh()
                }
            }
        }
        if pendingHandle == nil {
            // The bridge also completes asynchronously on this path. Invalidate
            // that callback so this failed attempt is counted only once.
            generation += 1
            pendingConfiguration = nil
            needsReactivation = true
            recordActivationFailure(desired, description: "macOS could not activate menu bar hiding.")
        }
    }

    /// Reveal before reacquiring the AX element: hidden elements can disappear
    /// entirely, and stale coordinates may now belong to a different app.
    func temporarilyReveal(_ item: MenuBarItem) async {
        guard let bundle = item.hostedHandle?.sourceBundleIdentifier else { return }
        let baselineWindowIDs = Set(
            WindowInfo.getOnScreenWindows()
                .filter { $0.ownerPID == item.ownerPID }
                .map(\.windowID)
        )
        temporarilyRevealedBundles.insert(bundle)
        revealTasks[bundle]?.cancel()
        refreshNow()
        try? await Task.sleep(for: .milliseconds(300))
        HostedMenuBarBackend.invalidateEnumerationCache()
        revealTasks[bundle] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, let self else { return }
            // Keep the original menu available while the user interacts with it.
            while NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundle
                || WindowInfo.getOnScreenWindows().contains(where: {
                    $0.ownerPID == item.ownerPID && !baselineWindowIDs.contains($0.windowID)
                }) {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
            }
            temporarilyRevealedBundles.remove(bundle)
            revealTasks[bundle] = nil
            refreshNow()
        }
    }

    func restoreAll(stop: Bool = false) {
        isStopped = stop
        refreshTask?.cancel()
        refreshTask = nil
        cancelActivationRetry()
        revealTasks.values.forEach { $0.cancel() }
        revealTasks.removeAll()
        temporarilyRevealedBundles.removeAll()
        lastFailed = nil
        failureDescription = nil
        releaseRestriction()
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
        if let pendingHandle {
            IceMenuBarVisibilityInvalidate(pendingHandle)
        }
        if let handle {
            IceMenuBarVisibilityInvalidate(handle)
        }
        pendingHandle = nil
        pendingConfiguration = nil
        handle = nil
        applied = nil
        needsReactivation = false
        HostedMenuBarBackend.setConcealedBundleIdentifiers([])
    }
}
