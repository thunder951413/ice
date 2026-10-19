import Foundation

struct KeyCombination: Codable, Equatable, Hashable {
    let key: String
}

enum HotkeyAction: String, Codable, Equatable, Hashable {
    case searchMenuBarItems
    case toggleHiddenSection

    func perform(appState: AppState) async {
        _ = appState
    }
}

struct Logger {
    init(category: String) {
        _ = category
    }

    func error(_ message: String) {
        fatalError(message)
    }
}

final class GeneralSettingsManager {
    var enableMenuBarSearch: Bool

    init(enableMenuBarSearch: Bool) {
        self.enableMenuBarSearch = enableMenuBarSearch
    }
}

final class SettingsManager {
    let generalSettingsManager: GeneralSettingsManager

    init(enableMenuBarSearch: Bool) {
        generalSettingsManager = GeneralSettingsManager(enableMenuBarSearch: enableMenuBarSearch)
    }
}

final class HotkeyRegistry {
    enum EventKind {
        case keyDown
    }

    private(set) var registrations: [(id: UInt32, combination: KeyCombination)] = []
    private(set) var unregistered: [UInt32] = []
    private var nextID: UInt32 = 1

    func register(
        hotkey: Hotkey,
        eventKind: EventKind,
        action: @escaping () -> Void
    ) -> UInt32? {
        _ = eventKind
        _ = action
        guard let combination = hotkey.keyCombination else { return nil }
        defer { nextID += 1 }
        registrations.append((nextID, combination))
        return nextID
    }

    func unregister(_ id: UInt32) {
        unregistered.append(id)
    }
}

final class AppState {
    let settingsManager: SettingsManager
    let hotkeyRegistry = HotkeyRegistry()

    init(enableMenuBarSearch: Bool) {
        settingsManager = SettingsManager(enableMenuBarSearch: enableMenuBarSearch)
    }
}

@main
@MainActor
enum SearchHotkeyAvailabilityTests {
    static func main() {
        testDisablingReleasesRegistrationAndRetainsCombination()
        testDisabledEditsAndAssignmentDoNotRegister()
        testReenablingRegistersCurrentCombination()
        testUnrelatedHotkeyIgnoresSearchAvailability()
        print("SearchHotkeyAvailabilityTests passed")
    }

    private static func testDisablingReleasesRegistrationAndRetainsCombination() {
        let combination = KeyCombination(key: "f")
        let appState = AppState(enableMenuBarSearch: true)
        let hotkey = Hotkey(keyCombination: combination, action: .searchMenuBarItems)
        hotkey.assignAppState(appState)
        expect(hotkey.isEnabled, "enabled search must register its shortcut")

        hotkey.setRegistrationAllowed(false)
        expect(!hotkey.isEnabled, "disabling search must release its shortcut")
        expect(appState.hotkeyRegistry.unregistered == [1], "the active registration must be unregistered once")
        expect(hotkey.keyCombination == combination, "disabling search must retain the saved shortcut")
    }

    private static func testDisabledEditsAndAssignmentDoNotRegister() {
        let appState = AppState(enableMenuBarSearch: false)
        let hotkey = Hotkey(keyCombination: nil, action: .searchMenuBarItems)
        hotkey.setRegistrationAllowed(false)

        hotkey.keyCombination = KeyCombination(key: "f")
        hotkey.keyCombination = KeyCombination(key: "g")
        hotkey.assignAppState(appState)
        hotkey.keyCombination = KeyCombination(key: "h")

        expect(!hotkey.isEnabled, "recording and editing while disabled must not enable the shortcut")
        expect(appState.hotkeyRegistry.registrations.isEmpty, "disabled shortcut changes must never register")
        expect(hotkey.keyCombination == KeyCombination(key: "h"), "disabled edits must still save the new combination")
    }

    private static func testReenablingRegistersCurrentCombination() {
        let appState = AppState(enableMenuBarSearch: false)
        let hotkey = Hotkey(keyCombination: KeyCombination(key: "f"), action: .searchMenuBarItems)
        hotkey.assignAppState(appState)
        hotkey.keyCombination = KeyCombination(key: "g")

        hotkey.setRegistrationAllowed(true)

        expect(hotkey.isEnabled, "reenabling search must restore shortcut registration")
        expect(appState.hotkeyRegistry.registrations.map(\.combination) == [KeyCombination(key: "g")],
               "reenabling must register the latest saved combination")
    }

    private static func testUnrelatedHotkeyIgnoresSearchAvailability() {
        let appState = AppState(enableMenuBarSearch: false)
        let hotkey = Hotkey(keyCombination: KeyCombination(key: "space"), action: .toggleHiddenSection)

        hotkey.assignAppState(appState)

        expect(hotkey.isEnabled, "disabling search must not affect unrelated hotkeys")
        expect(appState.hotkeyRegistry.registrations.count == 1, "the unrelated hotkey must remain registered")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
    }
}
