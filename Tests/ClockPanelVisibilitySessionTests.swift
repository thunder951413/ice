import CoreGraphics
import Foundation

@main
enum ClockPanelVisibilitySessionTests {
    static func main() {
        var longSession = ClockPanelVisibilitySession()
        expect(longSession.observe(isOpen: true, elapsed: .seconds(1)) == .wait(.milliseconds(100)), "an open panel must keep hiding suspended")
        expect(longSession.observe(isOpen: true, elapsed: .seconds(31)) == .wait(.seconds(1)), "the 30-second threshold must slow polling, not close the panel")
        expect(longSession.observe(isOpen: true, elapsed: .seconds(600)) == .wait(.seconds(1)), "even a long reading session must stay open")
        expect(longSession.observe(isOpen: false, elapsed: .seconds(601)) == .wait(.seconds(1)), "one missing sample must not restore prematurely")
        expect(longSession.observe(isOpen: true, elapsed: .seconds(602)) == .wait(.seconds(1)), "a transient missing sample must recover")
        _ = longSession.observe(isOpen: false, elapsed: .seconds(603))
        expect(longSession.observe(isOpen: false, elapsed: .milliseconds(603_300)) == .restore, "confirmed closure must restore the saved layout")

        var neverOpened = ClockPanelVisibilitySession()
        expect(neverOpened.observe(isOpen: false, elapsed: .seconds(2)) == .wait(.milliseconds(100)), "delayed appearance must get a grace period")
        expect(neverOpened.observe(isOpen: false, elapsed: .seconds(3)) == .restore, "an unsuccessful press must recover promptly")

        let primary = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let external = CGRect(x: 1512, y: 0, width: 2560, height: 1440)
        let displays = [primary, external]

        expect(
            ClockPanelVisibilitySession.isNotificationCenterWindow(
                title: "Notification Center",
                frame: CGRect(x: 1152, y: 38, width: 344, height: 900),
                displayBounds: displays
            ),
            "titled Notification Center window must match"
        )
        expect(
            ClockPanelVisibilitySession.isNotificationCenterWindow(
                title: nil,
                frame: primary,
                displayBounds: displays
            ),
            "full-display Notification Center backdrop must match without title"
        )
        expect(
            ClockPanelVisibilitySession.isNotificationCenterWindow(
                title: nil,
                frame: CGRect(x: 3712, y: 36, width: 348, height: 1380),
                displayBounds: displays
            ),
            "redacted-title trailing Notification Center panel on external display must match"
        )
        expect(
            !ClockPanelVisibilitySession.isNotificationCenterWindow(
                title: nil,
                frame: CGRect(x: 1152, y: 44, width: 344, height: 96),
                displayBounds: displays
            ),
            "compact top-right notification banner must not be mistaken for Notification Center"
        )
        expect(
            !ClockPanelVisibilitySession.isNotificationCenterWindow(
                title: nil,
                frame: CGRect(x: 400, y: 200, width: 360, height: 700),
                displayBounds: displays
            ),
            "centered window without Notification Center title must not match"
        )
        print("ClockPanelVisibilitySessionTests passed")
    }

    private static func expect(_ condition: Bool, _ message: String) {
        if !condition { fatalError(message) }
    }
}
