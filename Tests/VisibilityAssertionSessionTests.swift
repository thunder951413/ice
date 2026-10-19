import Foundation

@main
@MainActor
enum VisibilityAssertionSessionTests {
    private struct TestError: Error {}

    @MainActor
    private final class Bridge {
        enum Behavior {
            case deferred
            case nilHandle
            case synchronous(Error?)
        }

        var behavior: Behavior = .deferred
        var nextHandle = 1
        var callbacks: [@MainActor (Error?) -> Void] = []
        var invalidated: [Int] = []

        func activate(
            _ configuration: HostedVisibilityPolicy.Configuration,
            callback: @escaping @MainActor (Error?) -> Void
        ) -> Int? {
            _ = configuration
            callbacks.append(callback)
            switch behavior {
            case .deferred:
                defer { nextHandle += 1 }
                return nextHandle
            case .nilHandle:
                return nil
            case let .synchronous(error):
                callback(error)
                defer { nextHandle += 1 }
                return nextHandle
            }
        }

        func invalidate(_ handle: Int) {
            invalidated.append(handle)
        }
    }

    static func main() async {
        await testPendingReplacementKeepsWorkingHandleUntilSuccess()
        await testFailurePreservesWorkingHandle()
        await testTimeoutClearsPendingAndAllowsRetry()
        await testInvalidateAllCompletesOnceAndReleasesBothHandles()
        await testNilBridgeAndSynchronousCallbacks()
        print("VisibilityAssertionSessionTests passed")
    }

    private static func configuration(_ name: String) -> HostedVisibilityPolicy.Configuration {
        .init(concealed: ["hidden.\(name)"], allowed: ["visible.\(name)"])
    }

    private static func makeSession(
        bridge: Bridge,
        timeout: Duration = .seconds(1)
    ) -> VisibilityAssertionSession<Int> {
        VisibilityAssertionSession(
            timeout: timeout,
            activate: { configuration, callback in
                bridge.activate(configuration, callback: callback)
            },
            invalidate: { handle in bridge.invalidate(handle) }
        )
    }

    private static func drainTasks() async {
        for _ in 0..<4 { await Task.yield() }
    }

    private static func establishActive(
        _ name: String,
        session: VisibilityAssertionSession<Int>,
        bridge: Bridge
    ) async {
        var succeeded = false
        expect(session.begin(configuration(name)) { result in
            if case .success = result { succeeded = true }
        }, "initial activation must start")
        bridge.callbacks.last?(nil)
        await drainTasks()
        expect(succeeded, "initial activation must complete")
    }

    private static func testPendingReplacementKeepsWorkingHandleUntilSuccess() async {
        let bridge = Bridge()
        let session = makeSession(bridge: bridge)
        await establishActive("old", session: session, bridge: bridge)

        var completions = 0
        expect(session.begin(configuration("new")) { result in
            if case .success = result { completions += 1 }
        }, "replacement must start")
        expect(session.isActive, "working handle must remain active while replacement is pending")
        expect(session.activeConfiguration == configuration("old"), "working configuration must remain published")
        expect(bridge.invalidated.isEmpty, "working handle must not be retired before replacement succeeds")

        let replacementCallback = bridge.callbacks.last!
        replacementCallback(nil)
        await drainTasks()
        expect(session.activeConfiguration == configuration("new"), "successful replacement must become active")
        expect(bridge.invalidated == [1], "success must retire the old handle exactly once")
        expect(completions == 1, "success completion must run exactly once")

        replacementCallback(TestError())
        await drainTasks()
        expect(bridge.invalidated == [1], "a late stale callback must be ignored")
        expect(completions == 1, "a late stale callback must not repeat completion")
    }

    private static func testFailurePreservesWorkingHandle() async {
        let bridge = Bridge()
        let session = makeSession(bridge: bridge)
        await establishActive("old", session: session, bridge: bridge)

        var failures = 0
        expect(session.begin(configuration("failed")) { result in
            if case .failure = result { failures += 1 }
        }, "replacement must start")
        bridge.callbacks.last?(TestError())
        await drainTasks()
        expect(failures == 1, "failure must complete once")
        expect(session.activeConfiguration == configuration("old"), "failure must preserve the old configuration")
        expect(session.isActive, "failure must preserve the old handle")
        expect(!session.isActivating, "failure must clear pending state")
        expect(bridge.invalidated == [2], "failure must release only the failed replacement")
    }

    private static func testTimeoutClearsPendingAndAllowsRetry() async {
        let bridge = Bridge()
        let session = makeSession(bridge: bridge, timeout: .milliseconds(20))
        await establishActive("old", session: session, bridge: bridge)

        var failures = 0
        expect(session.begin(configuration("timeout")) { result in
            if case .failure = result { failures += 1 }
        }, "timed replacement must start")
        let staleCallback = bridge.callbacks.last!
        try? await Task.sleep(for: .milliseconds(80))
        expect(failures == 1, "timeout must complete once")
        expect(!session.isActivating, "timeout must clear pending state")
        expect(session.activeConfiguration == configuration("old"), "timeout must preserve the old configuration")
        expect(bridge.invalidated == [2], "timeout must release only the pending handle")

        var retrySucceeded = false
        expect(session.begin(configuration("retry")) { result in
            if case .success = result { retrySucceeded = true }
        }, "a retry must start after timeout")
        staleCallback(nil)
        await drainTasks()
        expect(session.isActivating, "late timed-out callback must not finish the retry")
        bridge.callbacks.last?(nil)
        await drainTasks()
        expect(retrySucceeded, "retry must succeed")
        expect(session.activeConfiguration == configuration("retry"), "retry must replace the old configuration")
        expect(bridge.invalidated == [2, 1], "retry success must retire the old handle once")
    }

    private static func testInvalidateAllCompletesOnceAndReleasesBothHandles() async {
        let bridge = Bridge()
        let session = makeSession(bridge: bridge, timeout: .milliseconds(20))
        await establishActive("old", session: session, bridge: bridge)

        var cancellations = 0
        expect(session.begin(configuration("pending")) { result in
            if case let .failure(error) = result, error is CancellationError { cancellations += 1 }
        }, "replacement must start")
        let pendingCallback = bridge.callbacks.last!
        session.invalidateAll()
        expect(cancellations == 1, "invalidateAll must cancel completion exactly once")
        expect(bridge.invalidated == [2, 1], "invalidateAll must release pending and active handles once")
        expect(!session.isActive && !session.isActivating, "invalidateAll must clear all state")

        session.invalidateAll()
        pendingCallback(nil)
        try? await Task.sleep(for: .milliseconds(50))
        expect(cancellations == 1, "repeated invalidation and stale callbacks must not repeat completion")
        expect(bridge.invalidated == [2, 1], "repeated invalidation must not release handles twice")
    }

    private static func testNilBridgeAndSynchronousCallbacks() async {
        let nilBridge = Bridge()
        let nilSession = makeSession(bridge: nilBridge)
        await establishActive("old", session: nilSession, bridge: nilBridge)
        nilBridge.behavior = .nilHandle
        var unavailableFailures = 0
        expect(nilSession.begin(configuration("nil")) { result in
            if case .failure = result { unavailableFailures += 1 }
        }, "nil bridge attempt is accepted and reported through completion")
        expect(unavailableFailures == 1, "nil bridge must fail synchronously exactly once")
        expect(nilSession.isActive && !nilSession.isActivating, "nil bridge must preserve the working handle")
        expect(nilSession.activeConfiguration == configuration("old"), "nil bridge must preserve the old configuration")
        expect(nilBridge.invalidated.isEmpty, "nil bridge must not release the working handle")

        let successBridge = Bridge()
        successBridge.behavior = .synchronous(nil)
        let successSession = makeSession(bridge: successBridge)
        var successes = 0
        expect(successSession.begin(configuration("sync-success")) { result in
            if case .success = result { successes += 1 }
        }, "synchronous success must start")
        expect(successSession.isActivating, "synchronous callback must wait until activate returns its handle")
        await drainTasks()
        expect(successes == 1 && successSession.isActive, "synchronous success must retain the returned handle")

        let failureBridge = Bridge()
        failureBridge.behavior = .synchronous(TestError())
        let failureSession = makeSession(bridge: failureBridge)
        var failures = 0
        expect(failureSession.begin(configuration("sync-failure")) { result in
            if case .failure = result { failures += 1 }
        }, "synchronous failure must start")
        await drainTasks()
        expect(failures == 1, "synchronous failure must complete once")
        expect(failureBridge.invalidated == [1], "synchronous failure must release the returned handle")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
    }
}
