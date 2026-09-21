//
//  ApplicationMenuGeometry.swift
//  Ice
//

import Foundation
import CoreGraphics

/// All input and output rectangles use the top-left CoreGraphics coordinate
/// space. A missing menu snapshot must never be treated as empty space.
enum ApplicationMenuGeometry {
    static func frame(itemFrames: [CGRect], displayBounds: CGRect) -> CGRect? {
        guard !itemFrames.isEmpty else { return nil }
        let menuBand = CGRect(x: displayBounds.minX, y: displayBounds.minY,
                              width: displayBounds.width, height: 80)
        guard itemFrames.allSatisfy({ frame in
            !frame.isNull && !frame.isInfinite && frame.width > 0 && frame.height > 0
                && frame.height <= 80 && frame.intersects(menuBand)
        }) else { return nil }
        let union = itemFrames.reduce(CGRect.null) { $0.union($1) }
        guard union.maxX > displayBounds.minX, union.maxX <= displayBounds.maxX else { return nil }
        // Include the Apple menu and the gaps between application menu titles.
        return CGRect(x: displayBounds.minX, y: union.minY,
                      width: union.maxX - displayBounds.minX, height: union.height)
    }

    static func isEmptySpace(at point: CGPoint, applicationMenuFrame: CGRect?) -> Bool {
        guard let applicationMenuFrame else { return false }
        // The caller has already established that the point is in the menu
        // bar. Protect title columns across its full height, including padding.
        return point.x > applicationMenuFrame.maxX
    }
}
