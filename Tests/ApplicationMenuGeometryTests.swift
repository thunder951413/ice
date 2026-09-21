import Foundation
import CoreGraphics

@main
enum ApplicationMenuGeometryTests {
    static func main() {
        testAppleMenuTitlesAndGapsAreProtected()
        testGenuineBlankSpaceIsAllowed()
        testMissingAndInvalidSnapshotsFailClosed()
        testWrongDisplaySnapshotFailsClosed()
        testSecondaryDisplayCoordinates()
        testFrameUnionIncludesEveryTitle()
        print("ApplicationMenuGeometryTests passed")
    }

    private static func testAppleMenuTitlesAndGapsAreProtected() {
        let display = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let frame = ApplicationMenuGeometry.frame(
            itemFrames: [
                CGRect(x: 12, y: 2, width: 28, height: 24),
                CGRect(x: 52, y: 2, width: 54, height: 24),
                CGRect(x: 118, y: 2, width: 38, height: 24),
                CGRect(x: 169, y: 2, width: 42, height: 24),
            ],
            displayBounds: display
        )

        expect(frame == CGRect(x: 0, y: 2, width: 211, height: 24),
               "the protected frame must span the Apple menu, title gaps, and every title")
        expect(!ApplicationMenuGeometry.isEmptySpace(at: CGPoint(x: 4, y: 12), applicationMenuFrame: frame),
               "space before the Apple menu must remain protected")
        expect(!ApplicationMenuGeometry.isEmptySpace(at: CGPoint(x: 46, y: 12), applicationMenuFrame: frame),
               "a gap between the Apple menu and application title must remain protected")
        expect(!ApplicationMenuGeometry.isEmptySpace(at: CGPoint(x: 180, y: 12), applicationMenuFrame: frame),
               "an application title must remain protected")
        expect(!ApplicationMenuGeometry.isEmptySpace(at: CGPoint(x: 180, y: 1), applicationMenuFrame: frame),
               "vertical padding above a title must remain protected")
        expect(!ApplicationMenuGeometry.isEmptySpace(at: CGPoint(x: 180, y: 30), applicationMenuFrame: frame),
               "vertical padding below a title must remain protected")
    }

    private static func testGenuineBlankSpaceIsAllowed() {
        let menuFrame = CGRect(x: 0, y: 2, width: 211, height: 24)
        expect(ApplicationMenuGeometry.isEmptySpace(at: CGPoint(x: 400, y: 12), applicationMenuFrame: menuFrame),
               "space after the final application menu title must be available")
        expect(!ApplicationMenuGeometry.isEmptySpace(at: CGPoint(x: 211, y: 12), applicationMenuFrame: menuFrame),
               "the final menu title edge must remain protected")
    }

    private static func testMissingAndInvalidSnapshotsFailClosed() {
        let display = CGRect(x: 0, y: 0, width: 1512, height: 982)
        expect(ApplicationMenuGeometry.frame(itemFrames: [], displayBounds: display) == nil,
               "an empty menu snapshot must be rejected")
        expect(!ApplicationMenuGeometry.isEmptySpace(at: CGPoint(x: 400, y: 12), applicationMenuFrame: nil),
               "a missing menu snapshot must never authorize a click")

        let invalidFrames = [
            CGRect.null,
            CGRect.infinite,
            CGRect(x: 40, y: 2, width: 0, height: 24),
            CGRect(x: 40, y: 2, width: 50, height: 0),
            CGRect(x: 40, y: 2, width: 50, height: 81),
            CGRect(x: 40, y: 100, width: 50, height: 24),
        ]
        for invalidFrame in invalidFrames {
            expect(ApplicationMenuGeometry.frame(itemFrames: [invalidFrame], displayBounds: display) == nil,
                   "invalid menu item frames must be rejected: \(invalidFrame)")
        }
    }

    private static func testWrongDisplaySnapshotFailsClosed() {
        let leftDisplay = CGRect(x: -1440, y: 0, width: 1440, height: 900)
        let primaryMenuItems = [CGRect(x: 20, y: 2, width: 60, height: 24)]
        expect(ApplicationMenuGeometry.frame(itemFrames: primaryMenuItems, displayBounds: leftDisplay) == nil,
               "menu items from another display must not authorize empty space")
    }

    private static func testSecondaryDisplayCoordinates() {
        assertDisplay(
            CGRect(x: -1440, y: 0, width: 1440, height: 900),
            itemFrames: [CGRect(x: -1428, y: 2, width: 28, height: 24), CGRect(x: -1388, y: 2, width: 68, height: 24)],
            expected: CGRect(x: -1440, y: 2, width: 120, height: 24),
            name: "left"
        )
        assertDisplay(
            CGRect(x: 0, y: -900, width: 1440, height: 900),
            itemFrames: [CGRect(x: 12, y: -898, width: 28, height: 24), CGRect(x: 52, y: -898, width: 68, height: 24)],
            expected: CGRect(x: 0, y: -898, width: 120, height: 24),
            name: "above"
        )
        assertDisplay(
            CGRect(x: 0, y: 982, width: 1440, height: 900),
            itemFrames: [CGRect(x: 12, y: 984, width: 28, height: 24), CGRect(x: 52, y: 984, width: 68, height: 24)],
            expected: CGRect(x: 0, y: 984, width: 120, height: 24),
            name: "below"
        )
    }

    private static func testFrameUnionIncludesEveryTitle() {
        let display = CGRect(x: 1920, y: 0, width: 1920, height: 1080)
        let frames = [
            CGRect(x: 1932, y: 3, width: 28, height: 24),
            CGRect(x: 1972, y: 3, width: 72, height: 24),
            CGRect(x: 2060, y: 3, width: 52, height: 24),
            CGRect(x: 2131, y: 3, width: 101, height: 24),
        ]
        let frame = ApplicationMenuGeometry.frame(itemFrames: frames, displayBounds: display)
        expect(frame?.minX == display.minX, "the protected frame must begin at the display edge")
        expect(frame?.maxX == frames.last?.maxX, "the protected frame must end after the final title")
        for title in frames {
            expect(frame?.contains(CGPoint(x: title.midX, y: title.midY)) == true,
                   "the union must not exclude any application menu title")
        }
    }

    private static func assertDisplay(
        _ display: CGRect,
        itemFrames: [CGRect],
        expected: CGRect,
        name: String
    ) {
        let frame = ApplicationMenuGeometry.frame(itemFrames: itemFrames, displayBounds: display)
        expect(frame == expected, "\(name) display must use global Core Graphics coordinates")
        expect(!ApplicationMenuGeometry.isEmptySpace(at: CGPoint(x: expected.minX + 1, y: expected.midY), applicationMenuFrame: frame),
               "\(name) display's Apple-side edge must be protected")
        expect(ApplicationMenuGeometry.isEmptySpace(at: CGPoint(x: expected.maxX + 20, y: expected.midY), applicationMenuFrame: frame),
               "\(name) display's genuine blank space must remain available")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
    }
}
