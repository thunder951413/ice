import Foundation

@main
enum MenuBarClickPolicyTests {
    static func main() async {
        expect(resolve(.primary) == .toggleHidden, "A normal primary click must toggle hidden items")
        expect(resolve(.primary, [.option]) == .toggleAlwaysHidden, "Option-click must toggle always-hidden items")
        expect(resolve(.primary, [.control]) == .showMenu, "Control-click must show the menu")
        expect(resolve(.secondary) == .showMenu, "A secondary click must show the menu")
        let capsLock = MenuBarClickPolicy.ModifierSnapshot(rawValue: 1 << 7)
        expect(resolve(.primary, [.option, capsLock]) == .toggleAlwaysHidden,
               "Caps Lock must not change an Option-click snapshot")
        expect(resolve(.primary, [.control, .option]) == .showMenu, "Control must take precedence over Option")
        expect(resolve(.primary, [.option], allowsAlwaysHidden: false) == .toggleHidden,
               "Disabled always-hidden support must fall back to hidden items")
        await testSnapshotSurvivesDelay()
        print("MenuBarClickPolicyTests passed")
    }

    private static func testSnapshotSurvivesDelay() async {
        var liveFlags: MenuBarClickPolicy.ModifierSnapshot = [.option]
        let snapshot = liveFlags
        liveFlags = [.control]
        try? await Task.sleep(for: .milliseconds(1))
        expect(resolve(.primary, snapshot) == .toggleAlwaysHidden,
               "A delayed action must use the event-time modifier snapshot")
        expect(resolve(.primary, liveFlags) == .showMenu, "The test must change the later modifier state")
    }

    private static func resolve(
        _ button: MenuBarClickPolicy.Button,
        _ modifiers: MenuBarClickPolicy.ModifierSnapshot = [],
        allowsAlwaysHidden: Bool = true
    ) -> MenuBarClickPolicy.Action {
        MenuBarClickPolicy.resolve(
            button: button,
            modifiers: modifiers,
            allowsAlwaysHidden: allowsAlwaysHidden
        )
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
    }
}
