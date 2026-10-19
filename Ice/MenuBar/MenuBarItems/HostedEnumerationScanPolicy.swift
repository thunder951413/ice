//
//  HostedEnumerationScanPolicy.swift
//  Ice
//

import Foundation

/// Pure scheduling rules for the bounded hosted-menu accessibility scanner.
/// Keeping this independent of AX makes cursor and cache semantics testable.
enum HostedEnumerationScanPolicy {
    /// A normal cache reader neither allocates a main-actor snapshot nor starts
    /// another request while a usable cache or an equivalent scan exists.
    static func shouldRequestRefresh(cacheIsFresh: Bool, scanInFlight: Bool, force: Bool) -> Bool {
        force || (!cacheIsFresh && !scanInFlight)
    }

    static func orderedIndices(count: Int, cursor: Int) -> [Int] {
        guard count > 0 else { return [] }
        let start = cursor % count
        return (0..<count).map { (start + $0) % count }
    }

    static func nextCursor(count: Int, cursor: Int, scannedCount: Int) -> Int {
        guard count > 0 else { return 0 }
        return (cursor + scannedCount) % count
    }

    /// Owners absent from the latest main-thread application snapshot have
    /// exited; owners not scanned in a budgeted pass retain their last complete
    /// descriptors until the rotating cursor reaches them.
    static func retainedOwners<Owner: Hashable>(
        existing: Set<Owner>, live: Set<Owner>, scanned: Set<Owner>
    ) -> Set<Owner> {
        existing.intersection(live).subtracting(scanned)
    }
}
