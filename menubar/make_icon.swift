// SPDX-License-Identifier: GPL-3.0-or-later
// OllamaTop — Programmatic macOS Squircle AppIcon Generator

import AppKit
import Foundation

let iconsetPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: iconsetPath, withIntermediateDirectories: true)

let sizes: [(Int, String)] = [
    (16, "icon_16x16.png"),
    (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"),
    (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"),
    (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"),
    (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"),
    (1024, "icon_512x512@2x.png")
]

for (px, filename) in sizes {
    let size = NSSize(width: px, height: px)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: px,
        pixelsHigh: px,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let rect = NSRect(origin: .zero, size: size)
    let inset = CGFloat(px) * 0.08
    let cardRect = rect.insetBy(dx: inset, dy: inset)
    let radius = cardRect.width * 0.225

    let path = NSBezierPath(roundedRect: cardRect, xRadius: radius, yRadius: radius)
    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.08, green: 0.11, blue: 0.18, alpha: 1.0),
        NSColor(calibratedRed: 0.12, green: 0.22, blue: 0.34, alpha: 1.0)
    ])!
    gradient.draw(in: path, angle: -45)

    NSColor(calibratedRed: 0.25, green: 0.85, blue: 0.68, alpha: 0.5).setStroke()
    path.lineWidth = max(1.0, CGFloat(px) * 0.02)
    path.stroke()

    if let sym = NSImage(systemSymbolName: "brain.head.profile", accessibilityDescription: nil) {
        let symCfg = NSImage.SymbolConfiguration(pointSize: CGFloat(px) * 0.44, weight: .semibold)
            .applying(.init(paletteColors: [
                NSColor(calibratedRed: 0.30, green: 0.92, blue: 0.75, alpha: 1.0)
            ]))
        if let configured = sym.withSymbolConfiguration(symCfg) {
            let symSize = configured.size
            let drawRect = NSRect(
                x: (CGFloat(px) - symSize.width) / 2.0,
                y: (CGFloat(px) - symSize.height) / 2.0,
                width: symSize.width,
                height: symSize.height
            )
            configured.draw(in: drawRect)
        }
    }

    NSGraphicsContext.restoreGraphicsState()

    if let pngData = rep.representation(using: .png, properties: [:]) {
        let outURL = URL(fileURLWithPath: iconsetPath).appendingPathComponent(filename)
        try? pngData.write(to: outURL)
    }
}
