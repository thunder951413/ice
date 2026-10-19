//
//  HostedItemSnapshotPolicy.swift
//  Ice
//

import Foundation

enum HostedItemSnapshotPolicy {
    /// Only a complete, unconcealed owner scan can establish that an item was
    /// removed. Missing/partial scans and native concealment retain descriptors.
    static func merge<Item, ID: Hashable, Owner: Hashable>(
        existing: [ID: Item],
        discovered: [Item],
        liveOwners: Set<Owner>,
        scannedOwners: Set<Owner>,
        id: (Item) -> ID,
        owner: (Item) -> Owner,
        preserveMissing: (Item) -> Bool
    ) -> [ID: Item] {
        let discoveredIDs = Set(discovered.map(id))
        var result = existing.filter { key, item in
            liveOwners.contains(owner(item)) &&
                (!scannedOwners.contains(owner(item)) || preserveMissing(item) || discoveredIDs.contains(key))
        }
        for item in discovered where liveOwners.contains(owner(item)) { result[id(item)] = item }
        return result
    }
}
