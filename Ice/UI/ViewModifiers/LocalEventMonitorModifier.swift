//
//  LocalEventMonitorModifier.swift
//  Ice
//

import SwiftUI

private final class LocalEventMonitorModifierState: ObservableObject {
    private final class ActionBox {
        var action: (NSEvent) -> NSEvent?

        init(action: @escaping (NSEvent) -> NSEvent?) {
            self.action = action
        }
    }

    private let actionBox: ActionBox
    let monitor: LocalEventMonitor

    init(mask: NSEvent.EventTypeMask, action: @escaping (NSEvent) -> NSEvent?) {
        let actionBox = ActionBox(action: action)
        self.actionBox = actionBox
        self.monitor = LocalEventMonitor(mask: mask) { event in
            actionBox.action(event)
        }
        self.monitor.start()
    }

    deinit {
        monitor.stop()
    }

    func updateAction(_ action: @escaping (NSEvent) -> NSEvent?) {
        actionBox.action = action
    }
}

private struct LocalEventMonitorModifier: ViewModifier {
    @StateObject private var state: LocalEventMonitorModifierState
    private let action: (NSEvent) -> NSEvent?

    init(mask: NSEvent.EventTypeMask, action: @escaping (NSEvent) -> NSEvent?) {
        self._state = StateObject(wrappedValue: LocalEventMonitorModifierState(mask: mask, action: action))
        self.action = action
    }

    func body(content: Content) -> some View {
        state.updateAction(action)
        return content
    }
}

extension View {
    /// Returns a view that performs the given action when events
    /// specified by the given mask are received.
    ///
    /// - Parameters:
    ///   - mask: An event type mask specifying which events to monitor.
    ///   - action: An action to perform when the event monitor receives
    ///     an event corresponding to the event types in `mask`.
    func localEventMonitor(
        mask: NSEvent.EventTypeMask,
        action: @escaping (NSEvent) -> NSEvent?
    ) -> some View {
        modifier(LocalEventMonitorModifier(mask: mask, action: action))
    }
}
