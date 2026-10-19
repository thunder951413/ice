import Foundation

@main
enum HostedEnumerationScanPolicyTests {
    static func main() {
        expect(!HostedEnumerationScanPolicy.shouldRequestRefresh(cacheIsFresh: true, scanInFlight: false, force: false),
               "fresh cache reads must not create tasks")
        expect(!HostedEnumerationScanPolicy.shouldRequestRefresh(cacheIsFresh: false, scanInFlight: true, force: false),
               "an in-flight scan must coalesce ordinary requests")
        expect(HostedEnumerationScanPolicy.shouldRequestRefresh(cacheIsFresh: true, scanInFlight: true, force: true),
               "explicit reacquisition must join the refresh path")
        expect(HostedEnumerationScanPolicy.orderedIndices(count: 5, cursor: 3) == [3, 4, 0, 1, 2],
               "cursor must resume from the first unvisited owner")
        expect(HostedEnumerationScanPolicy.nextCursor(count: 5, cursor: 3, scannedCount: 2) == 0,
               "cursor must wrap after a partial scan")
        expect(HostedEnumerationScanPolicy.nextCursor(count: 5, cursor: 0, scannedCount: 1) == 1,
               "a slow first owner must not block later owners")

        let retained = HostedEnumerationScanPolicy.retainedOwners(
            existing: Set([1, 2, 3]), live: Set([1, 2, 4]), scanned: Set([1])
        )
        expect(retained == Set([2]), "retain unvisited live owners and remove exited or scanned owners")
        print("HostedEnumerationScanPolicyTests passed")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
    }
}
