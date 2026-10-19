//
//  VisibilityAssertionSession.swift
//  Ice
//

import Foundation

/// Keeps a working native restriction alive while its replacement is pending.
/// The injected bridge also makes late callbacks and missing callbacks testable.
@MainActor
final class VisibilityAssertionSession<Handle> {
    typealias Configuration = HostedVisibilityPolicy.Configuration
    typealias Completion = @MainActor (Result<Configuration, Error>) -> Void

    enum Failure: LocalizedError {
        case unavailable
        case timedOut

        var errorDescription: String? {
            switch self {
            case .unavailable: "The menu bar hiding request could not start."
            case .timedOut: "macOS did not finish updating menu bar visibility. Try again."
            }
        }
    }

    private let activate: (Configuration, @escaping @MainActor (Error?) -> Void) -> Handle?
    private let invalidate: (Handle) -> Void
    private let timeout: Duration
    private var activeHandle: Handle?
    private var pendingHandle: Handle?
    private var pendingConfiguration: Configuration?
    private var completion: Completion?
    private var timeoutTask: Task<Void, Never>?
    private var generation = 0

    private(set) var activeConfiguration: Configuration?
    var isActive: Bool { activeHandle != nil }
    var isActivating: Bool { pendingConfiguration != nil }

    init(
        timeout: Duration = .seconds(3),
        activate: @escaping (Configuration, @escaping @MainActor (Error?) -> Void) -> Handle?,
        invalidate: @escaping (Handle) -> Void
    ) {
        self.timeout = timeout
        self.activate = activate
        self.invalidate = invalidate
    }

    @discardableResult
    func begin(_ configuration: Configuration, completion: @escaping Completion) -> Bool {
        guard !isActivating else { return false }
        generation += 1
        let attempt = generation
        pendingConfiguration = configuration
        self.completion = completion
        pendingHandle = activate(configuration) { [weak self] error in
            // Always defer completion until the bridge has returned its handle,
            // including synchronous callbacks in tests or future system APIs.
            Task { @MainActor [weak self] in self?.finish(attempt, error: error) }
        }
        guard pendingHandle != nil else {
            finish(attempt, error: Failure.unavailable)
            return true
        }
        timeoutTask = Task { @MainActor [weak self, timeout] in
            do { try await Task.sleep(for: timeout) } catch { return }
            self?.finish(attempt, error: Failure.timedOut)
        }
        return true
    }

    func invalidateAll() {
        generation += 1
        timeoutTask?.cancel()
        timeoutTask = nil
        let callback = completion
        completion = nil
        pendingConfiguration = nil
        if let pendingHandle { invalidate(pendingHandle) }
        if let activeHandle { invalidate(activeHandle) }
        pendingHandle = nil
        activeHandle = nil
        activeConfiguration = nil
        callback?(.failure(CancellationError()))
    }

    private func finish(_ attempt: Int, error: Error?) {
        guard generation == attempt, let configuration = pendingConfiguration else { return }
        generation += 1
        timeoutTask?.cancel()
        timeoutTask = nil
        let callback = completion
        completion = nil
        pendingConfiguration = nil
        if let error {
            if let pendingHandle { invalidate(pendingHandle) }
            pendingHandle = nil
            callback?(.failure(error))
        } else {
            let previous = activeHandle
            activeHandle = pendingHandle
            pendingHandle = nil
            activeConfiguration = configuration
            if let previous { invalidate(previous) }
            callback?(.success(configuration))
        }
    }
}
