import Foundation

@main
@MainActor
enum GracefulApplicationTerminationTests {
    static func main() async throws {
        var requested = 0
        try await GracefulApplicationTermination.terminate(isTerminated: { true }, requestTermination: { requested += 1; return true })
        expect(requested == 0, "an exited process must never receive another quit request")

        var launches = 0
        do {
            try await GracefulApplicationTermination.terminate(isTerminated: { false }, requestTermination: { requested += 1; return false })
            launches += 1
            fatalError("refusing to quit must be reported")
        } catch GracefulApplicationTermination.Failure.refused { }
        expect(launches == 0, "a refused quit must never start a replacement process")

        do {
            try await GracefulApplicationTermination.terminate(timeout: .milliseconds(20), pollInterval: .milliseconds(2),
                                                              isTerminated: { false }, requestTermination: { true })
            launches += 1
            fatalError("an app waiting for saving must time out")
        } catch GracefulApplicationTermination.Failure.timedOut { }
        expect(launches == 0, "timeout must preserve the running process rather than relaunch it")

        var exited = false
        let exitTask = Task { try await Task.sleep(for: .milliseconds(10)); exited = true }
        try await GracefulApplicationTermination.terminate(timeout: .milliseconds(100), pollInterval: .milliseconds(2),
                                                          isTerminated: { exited }, requestTermination: { true })
        try await exitTask.value
        launches += 1
        expect(launches == 1, "a completed cooperative quit permits one restart")

        let cancelled = Task {
            try await GracefulApplicationTermination.terminate(timeout: .seconds(5), pollInterval: .milliseconds(2),
                                                              isTerminated: { false }, requestTermination: { true })
        }
        cancelled.cancel()
        do { try await cancelled.value; fatalError("cancellation must end the wait") } catch is CancellationError { }
        print("GracefulApplicationTerminationTests passed")
    }

    private static func expect(_ condition: Bool, _ message: String) {
        if !condition { fatalError(message) }
    }
}
