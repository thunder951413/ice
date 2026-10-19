//
//  GracefulApplicationTermination.swift
//  Ice
//

import Foundation

/// Waits for cooperative termination without bypassing an app's save dialogs.
@MainActor
enum GracefulApplicationTermination {
    enum Failure: LocalizedError {
        case refused
        case timedOut

        var errorDescription: String? {
            switch self {
            case .refused: "The application declined to quit. Quit and reopen it manually when ready."
            case .timedOut: "The application is still running. Finish saving, then quit and reopen it manually."
            }
        }
    }

    static func terminate(
        timeout: Duration = .seconds(5),
        pollInterval: Duration = .milliseconds(100),
        isTerminated: () -> Bool,
        requestTermination: () -> Bool
    ) async throws {
        try Task.checkCancellation()
        guard !isTerminated() else { return }
        guard requestTermination() else {
            if isTerminated() { return }
            throw Failure.refused
        }
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !isTerminated() {
            try Task.checkCancellation()
            let remaining = ContinuousClock.now.duration(to: deadline)
            guard remaining > .zero else { throw Failure.timedOut }
            try await Task.sleep(for: min(pollInterval, remaining))
        }
    }
}
