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
        print("ClockPanelVisibilitySessionTests passed")
    }

    private static func expect(_ condition: Bool, _ message: String) {
        if !condition { fatalError(message) }
    }
}
