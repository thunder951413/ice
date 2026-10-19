import Foundation

@main
@MainActor
enum AsyncSnapshotCacheTests {
    static func main() async throws {
        let cache = AsyncSnapshotCache<Int>(lifetime: 0.02)
        var loads = 0
        let loader: () async -> Int? = {
            loads += 1
            try? await Task.sleep(for: .milliseconds(20))
            return 42
        }
        cache.requestRefresh(load: loader)
        expect(cache.value() == nil, "a UI cache read must return immediately while AX is blocked")
        async let first = cache.refresh(force: true, load: loader)
        async let second = cache.refresh(force: true, load: loader)
        let values = await (first, second)
        expect(values.0 == 42 && values.1 == 42 && loads == 1, "concurrent requests must share one load")
        expect(cache.value() == 42, "a complete result must become readable")
        try await Task.sleep(for: .milliseconds(30))
        expect(cache.value() == nil, "expired occupancy cannot authorize an empty-space click")
        expect(cache.lastValue(maxAge: 5) == 42, "passive layout reads may use an expired but uninvalidated snapshot")
        expect(cache.lastValue(maxAge: 0.01) == nil, "a stale read is still bounded by its maximum age")

        let obsolete = Task { await cache.refresh(force: true, load: loader) }
        while loads < 2 { await Task.yield() }
        cache.invalidate()
        expect(cache.value() == nil, "invalidation must immediately discard obsolete geometry")
        expect(cache.lastValue(maxAge: 60) == nil, "invalidation must also discard the stale fallback")
        let obsoleteValue = await obsolete.value
        expect(obsoleteValue == 42 && loads == 3, "a waiting activation must retry an invalidated scan before publishing fresh geometry")
        let recovered = await cache.refresh(force: true, load: loader)
        expect(recovered == 42, "the next scan must recover after invalidation")

        let failed = await cache.refresh(force: true) { nil }
        expect(failed == nil && cache.value() == nil, "a failed scan must invalidate old occupancy")
        let empty = AsyncSnapshotCache<[Int]>(lifetime: 1)
        let emptyResult = await empty.refresh { [] }
        expect(emptyResult?.isEmpty == true && empty.value() != nil, "a valid empty snapshot must remain distinct from failure")

        let cancellationCache = AsyncSnapshotCache<Int>(lifetime: 1)
        var cancellationLoads = 0
        let cancellationLoader: () async -> Int? = {
            cancellationLoads += 1
            try? await Task.sleep(for: .milliseconds(20))
            return 42
        }
        let cancelled = Task { await cancellationCache.refresh(load: cancellationLoader) }
        while cancellationLoads == 0 { await Task.yield() }
        let active = Task { await cancellationCache.refresh(load: cancellationLoader) }
        cancelled.cancel()
        let cancelledValue = await cancelled.value
        let activeValue = await active.value
        expect(cancelledValue == nil && activeValue == 42 && cancellationLoads == 1,
               "cancelling an activation must stop it without cancelling the shared scan for another caller")
        print("AsyncSnapshotCacheTests passed")
    }

    private static func expect(_ condition: Bool, _ message: String) {
        if !condition { fatalError(message) }
    }
}
