import Foundation

@main
enum TemporaryRevealRehidePolicyTests {
    static func main() {
        typealias Window = TemporaryRevealRehidePolicy.Window
        func shouldWait(_ windows: [Window], elapsed: Duration = .seconds(1)) -> Bool {
            TemporaryRevealRehidePolicy.shouldWait(windows: windows, ownerPID: 10, baselineIDs: [1],
                                                  interfaceLayers: 8...101, elapsed: elapsed)
        }
        expect(!shouldWait([.init(id: 2, ownerPID: 10, layer: 0)]), "a new document/settings window must not keep icons revealed")
        expect(!shouldWait([.init(id: 2, ownerPID: 10, layer: 3)]), "a regular floating utility window must not delay rehide")
        expect(shouldWait([.init(id: 2, ownerPID: 10, layer: 101)]), "a newly opened menu must remain usable")
        expect(shouldWait([.init(id: 2, ownerPID: 10, layer: 25)]), "a status-item panel must remain usable")
        expect(!shouldWait([.init(id: 1, ownerPID: 10, layer: 101)]), "a preexisting menu must not extend this reveal")
        expect(!shouldWait([.init(id: 2, ownerPID: 11, layer: 101)]), "another owner must not delay rehide")
        expect(!shouldWait([.init(id: 2, ownerPID: 10, layer: 101)], elapsed: .seconds(120)), "a stale menu must have a bounded recovery wait")
        expect(!shouldWait([]), "closing the menu must allow rehide")
        print("TemporaryRevealRehidePolicyTests passed")
    }

    private static func expect(_ condition: Bool, _ message: String) {
        if !condition { fatalError(message) }
    }
}
