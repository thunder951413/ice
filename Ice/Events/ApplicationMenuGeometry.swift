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
        let menuBand = CGRect(
            x: displayBounds.minX,
            y: displayBounds.minY,
            width: displayBounds.width,
            height: 80
        )
        guard itemFrames.allSatisfy({ frame in
            !frame.isNull && !frame.isInfinite && frame.width > 0 && frame.height > 0
                && frame.height <= 80 && frame.intersects(menuBand)
        }) else { return nil }
        let union = itemFrames.reduce(CGRect.null) { $0.union($1) }
        guard union.maxX > displayBounds.minX, union.maxX <= displayBounds.maxX else { return nil }
        // Include the Apple menu and the gaps between application menu titles.
        return CGRect(
            x: displayBounds.minX,
            y: union.minY,
            width: union.maxX - displayBounds.minX,
            height: union.height
        )
    }

    static func isEmptySpace(at point: CGPoint, applicationMenuFrame: CGRect?) -> Bool {
        guard let applicationMenuFrame else { return false }
        // The caller has already established that the point is in the menu
        // bar. Protect title columns across its full height, including padding.
        return point.x > applicationMenuFrame.maxX
    }

    /// Projects the title span when the system-wide hit test returns the same
    /// application menu proxy on another display.
    static func projectedFrame(_ frame: CGRect, on displayBounds: CGRect) -> CGRect? {
        guard frame.width > 0, frame.width < displayBounds.width else { return nil }
        return CGRect(
            x: displayBounds.minX,
            y: displayBounds.minY,
            width: frame.width,
            height: frame.height
        )
    }

    static func isEmptyHostedSpace(
        at point: CGPoint, applicationMenuFrame: CGRect?, itemFrames: [CGRect]?, displayBounds: CGRect
    ) -> Bool {
        guard isEmptySpace(at: point, applicationMenuFrame: applicationMenuFrame), let itemFrames else { return false }
        let onDisplay = itemFrames.filter { $0.intersects(displayBounds) }
        if let trailingMaxX = onDisplay.map(\.maxX).max(),
           displayBounds.maxX - trailingMaxX <= 32,
           point.x >= trailingMaxX - 2 {
            return false
        }
        return !onDisplay.contains {
            point.x >= $0.minX - 2 && point.x <= $0.maxX + 2
        }
    }
}
