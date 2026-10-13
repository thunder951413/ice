//
//  TemporaryRevealRehidePolicy.swift
//  Ice
//

import Foundation

enum TemporaryRevealRehidePolicy {
    struct Window {
        let id: UInt32
        let ownerPID: Int32
        let layer: Int
    }

    /// Regular document/settings windows must not extend a temporary reveal.
    /// A stale floating interface cannot keep its owner revealed indefinitely.
    static func shouldWait(
        windows: [Window],
        ownerPID: Int32,
        baselineIDs: Set<UInt32>,
        interfaceLayers: ClosedRange<Int>,
        elapsed: Duration,
        maximumWait: Duration = .seconds(120)
    ) -> Bool {
        guard elapsed < maximumWait else { return false }
        return windows.contains {
            $0.ownerPID == ownerPID && !baselineIDs.contains($0.id) && interfaceLayers.contains($0.layer)
        }
    }
}
