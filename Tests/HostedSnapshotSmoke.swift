import ApplicationServices
import Cocoa

// The smoke compiles the production backend; only its unused legacy adapters
// and application-wide constants are supplied by this standalone harness.
enum Constants { static let bundleIdentifier = "com.ice.hosted-snapshot-smoke" }
struct Logger {
    init(category: String) { }
    func debug(_ message: String) { print(message); fflush(stdout) }
    func warning(_ message: String) { print(message); fflush(stdout) }
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
@MainActor
enum HostedSnapshotSmoke {
    static func main() async {
        _ = NSApplication.shared
        guard AXIsProcessTrusted() else {
            print("Hosted snapshot smoke requires Accessibility permission for its launching terminal.")
            exit(77)
        }
        HostedMenuBarBackend.invalidateEnumerationCache()
        let start = ContinuousClock.now
        let cold = HostedMenuBarBackend.renderedItemFrameSnapshot()
        guard cold == nil, start.duration(to: .now) < .milliseconds(100) else {
            fatalError("cold synchronous UI reads must return immediately without walking AX")
        }
        guard await HostedMenuBarBackend.refreshRenderedSnapshot(),
              let frames = HostedMenuBarBackend.renderedItemFrameSnapshot(), !frames.isEmpty else {
            fatalError("the complete live MenuBarAgent tree must produce a usable snapshot")
        }
        if CommandLine.arguments.contains("--frames") {
            print("Display bounds: \(NSScreen.screens.map { CGDisplayBounds($0.displayID) })")
            print("Rendered frames: \(frames.map { NSStringFromRect($0) })")
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: "com.jordanbaird.Ice") {
                print("Ice frames: \(HostedMenuBarBackend.renderedItemFrames(for: app.processIdentifier).map { NSStringFromRect($0) })")
            }
        }
        let descriptors = await HostedMenuBarBackend.refreshDescriptorSnapshot(force: true)
        print("Hosted snapshot smoke passed: \(frames.count) rendered frames, \(descriptors.items.count) descriptors, \(descriptors.scannedPIDs.count) complete owner scans")
    }
}
