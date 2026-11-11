import ApplicationServices
import Cocoa

enum Constants { static let bundleIdentifier = "com.ice.hosted-rendered-matching-tests" }
struct Logger {
    init(category: String) { }
    func debug(_ message: String) { }
    func warning(_ message: String) { }
}
enum Bridging {
    enum Responsivity { case responsive, unresponsive }
    static func responsivity(for pid: pid_t) -> Responsivity { .responsive }
    static func getWindowFrame(_ id: CGWindowID) -> CGRect? { nil }
}
extension NSScreen {
    var displayID: CGDirectDisplayID { (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0 }
}
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ window: UnsafeMutablePointer<CGWindowID>) -> AXError

@main
enum HostedRenderedMatchingTests {
    private struct StubCandidate: Equatable {
        let id: String
        let displayID: CGDirectDisplayID
        let frame: CGRect
    }

    static func main() {
        let primary = StubCandidate(id: "primary", displayID: 1, frame: CGRect(x: 1220, y: 0, width: 28, height: 24))
        let external = StubCandidate(id: "external", displayID: 2, frame: CGRect(x: 3680, y: 0, width: 28, height: 24))

        let pickedExternal = HostedMenuBarBackend.pickUnambiguousMatch(
            from: [primary, external],
            preferredDisplayID: 2,
            displayID: \.displayID,
            frame: \.frame
        )
        expect(pickedExternal == external, "multi-monitor match must select the preferred display")

        let pickedPrimary = HostedMenuBarBackend.pickUnambiguousMatch(
            from: [primary, external],
            preferredDisplayID: 1,
            displayID: \.displayID,
            frame: \.frame
        )
        expect(pickedPrimary == primary, "multi-monitor match must select primary display when preferred")

        let fallbackMatch = HostedMenuBarBackend.pickUnambiguousMatch(
            from: [primary, external],
            preferredDisplayID: 99,
            displayID: \.displayID,
            frame: \.frame
        )
        expect(fallbackMatch == primary, "when preferred display lacks the item, first unambiguous display must be used")

        let sameDisplaySibling = StubCandidate(id: "sibling", displayID: 1, frame: CGRect(x: 1252, y: 0, width: 28, height: 24))
        let ambiguous = HostedMenuBarBackend.pickUnambiguousMatch(
            from: [primary, sameDisplaySibling, external],
            preferredDisplayID: 1,
            displayID: \.displayID,
            frame: \.frame
        )
        expect(ambiguous == nil, "multiple unidentified items on the same display must still be rejected as ambiguous")

        let duplicateSameFrame = StubCandidate(id: "dup", displayID: 1, frame: primary.frame)
        let deduplicated = HostedMenuBarBackend.pickUnambiguousMatch(
            from: [primary, duplicateSameFrame],
            preferredDisplayID: 1,
            displayID: \.displayID,
            frame: \.frame
        )
        expect(deduplicated == primary, "duplicate entries sharing an identical frame on one display remain unambiguous")

        print("HostedRenderedMatchingTests passed")
    }

    private static func expect(_ condition: Bool, _ message: String) {
        if !condition { fatalError(message) }
    }
}
