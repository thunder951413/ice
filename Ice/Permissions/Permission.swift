//
//  Permission.swift
//  Ice
//

import AXSwift
import Cocoa
import Combine

// MARK: - Permission

/// An object that encapsulates the behavior of checking for and requesting
/// a specific permission for the app.
@MainActor
class Permission: ObservableObject, Identifiable {
    /// A Boolean value that indicates whether the app has this permission.
    @Published private(set) var hasPermission = false

    /// The title of the permission.
    let title: String

    /// Descriptive details for the permission.
    let details: [String]

    /// A Boolean value that indicates if the app can work without this permission.
    let isRequired: Bool

    /// The URL of the settings pane to open.
    private let settingsURL: URL?

    /// The function that checks permissions.
    private let check: () -> Bool

    /// The function that requests permissions.
    private let request: () -> Void

    /// Observer that runs on a timer to check permissions.
    private var timerCancellable: AnyCancellable?

    /// Pending continuations awaiting permission grant or check cancellation.
    private var waitContinuations = [UUID: CheckedContinuation<Void, Never>]()

    init(
        title: String,
        details: [String],
        isRequired: Bool,
        settingsURL: URL?,
        check: @escaping () -> Bool,
        request: @escaping () -> Void
    ) {
        self.title = title
        self.details = details
        self.isRequired = isRequired
        self.settingsURL = settingsURL
        self.check = check
        self.request = request
        self.hasPermission = check()
        configureCancellables()
    }

    private func configureCancellables() {
        guard timerCancellable == nil else {
            return
        }
        timerCancellable = Timer.publish(every: 1, on: .main, in: .default)
            .autoconnect()
            .merge(with: Just(.now))
            .sink { [weak self] _ in
                guard let self else {
                    return
                }
                let current = check()
                if hasPermission != current {
                    hasPermission = current
                }
                if current {
                    resumeWaitContinuations()
                }
            }
    }

    private func resumeWaitContinuations() {
        let continuations = Array(waitContinuations.values)
        waitContinuations.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }

    /// Performs the request and opens the System Settings app to the appropriate pane.
    func performRequest() {
        request()
        if let settingsURL {
            NSWorkspace.shared.open(settingsURL)
        }
    }

    /// Opens the System Settings pane for this permission without triggering a system prompt.
    func openSystemSettings() {
        if let settingsURL {
            NSWorkspace.shared.open(settingsURL)
        }
    }

    /// Asynchronously waits for the app to be granted this permission.
    func waitForPermission() async {
        configureCancellables()
        guard !hasPermission else {
            return
        }
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if hasPermission {
                    continuation.resume()
                } else {
                    waitContinuations[id] = continuation
                }
            }
        } onCancel: { [weak self] in
            Task { @MainActor [weak self] in
                self?.waitContinuations.removeValue(forKey: id)?.resume()
            }
        }
    }

    /// Refreshes the displayed permission state without starting a new timer.
    func refresh() {
        let current = check()
        if current != hasPermission {
            hasPermission = current
        }
        if current {
            resumeWaitContinuations()
        }
    }

    /// Stops running the permission check.
    func stopCheck() {
        timerCancellable?.cancel()
        timerCancellable = nil
        resumeWaitContinuations()
    }
}

// MARK: - AccessibilityPermission

final class AccessibilityPermission: Permission {
    init() {
        super.init(
            title: "辅助功能权限",
            details: [
                "读取菜单栏图标状态与布局信息",
                "在点击隐藏图标时安全唤醒对应菜单",
            ],
            isRequired: true,
            settingsURL: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"),
            check: {
                checkIsProcessTrusted()
            },
            request: {
                checkIsProcessTrusted(prompt: true)
            }
        )
    }
}
