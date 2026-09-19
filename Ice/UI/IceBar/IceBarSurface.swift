//
//  IceBarSurface.swift
//  Ice
//

import SwiftUI

/// An independent, legible surface. Never derive its opacity from a menu-bar
/// screenshot: hosted menu-bar captures may consist of transparent pixels.
struct IceBarSurface: View {
    let style: IceBarStyle
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
    }

    private var fillColor: Color {
        colorScheme == .dark
            ? Color(red: 0.16, green: 0.17, blue: 0.19)
            : Color(red: 0.96, green: 0.97, blue: 0.98)
    }

    var body: some View {
        ZStack {
            if style == .frosted && !reduceTransparency {
                VisualEffectView(material: .popover, blendingMode: .behindWindow)
                // A minimum tint prevents the bar disappearing on either bright
                // wallpaper or dark windows, even if vibrancy is unavailable.
                fillColor.opacity(0.86)
            } else {
                fillColor
            }
        }
        .clipShape(shape)
        .overlay {
            shape.strokeBorder(
                colorScheme == .dark ? Color.white.opacity(0.24) : Color.black.opacity(0.16),
                lineWidth: contrast == .increased ? 2 : 1
            )
        }
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.34 : 0.18), radius: 6, x: 0, y: 2)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
