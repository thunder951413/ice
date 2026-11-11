//
//  OnKeyDown.swift
//  Ice
//

import SwiftUI

extension View {
    /// Returns a view that performs the given action when
    /// the specified key is pressed.
    func onKeyDown(
        key: KeyCode,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        localEventMonitor(mask: .keyDown) { event in
            guard
                isEnabled,
                !(NSApp.keyWindow?.firstResponder is NSText)
            else {
                return event
            }
            if event.keyCode == key.rawValue {
                action()
                return nil
            }
            return event
        }
    }
}
