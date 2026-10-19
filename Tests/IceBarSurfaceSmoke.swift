import AppKit
import SwiftUI

@main
struct IceBarSurfaceSmoke {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for scheme in [ColorScheme.light, .dark] {
            for style in IceBarStyle.allCases {
                let name = "\(scheme)-\(style)"
                let view = IceBarSurface(style: style)
                    .frame(width: 78, height: 40)
                    .padding(8)
                    .environment(\.colorScheme, scheme)
                let host = NSHostingView(rootView: view)
                host.frame = NSRect(x: 0, y: 0, width: 94, height: 56)
                // Render our own view offscreen; no desktop capture or input.
                let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
                window.contentView = host
                host.layoutSubtreeIfNeeded()
                guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                    fatalError("No bitmap for \(name)")
                }
                host.cacheDisplay(in: host.bounds, to: bitmap)
                guard let center = bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2),
                      center.alphaComponent >= 0.8 else {
                    fatalError("Ice Bar center is transparent: \(name)")
                }
                guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("No PNG") }
                try png.write(to: output.appendingPathComponent("\(name).png"))
                print("PASS \(name): center alpha \(center.alphaComponent)")
            }
        }
    }
}
