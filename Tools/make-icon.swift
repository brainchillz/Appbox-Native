#!/usr/bin/env swift
//
// make-icon.swift — generate Resources/AppIcon.icns.
//
// The icon is generated rather than committed as a binary blob, so it stays
// diffable, tweakable, and regenerable. Run it after changing anything here:
//
//   swift Tools/make-icon.swift
//
// Draws a macOS-style rounded square with a gradient and a shipping-box glyph,
// then emits every size the iconset needs and calls iconutil.

import AppKit
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let resources = root.appendingPathComponent("Resources")
let iconset = resources.appendingPathComponent("AppIcon.iconset")

try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

/// Render the icon at a given pixel size.
func renderIcon(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(size), pixelsHigh: Int(size),
        bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0)!

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // macOS icons sit inset within their canvas rather than bleeding to the
    // edge, and use a continuous-curvature squircle.
    let inset = size * 0.06
    let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let radius = rect.width * 0.2237  // Apple's squircle ratio
    let squircle = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.35, green: 0.53, blue: 0.92, alpha: 1),
        NSColor(calibratedRed: 0.20, green: 0.30, blue: 0.72, alpha: 1),
    ])!
    gradient.draw(in: squircle, angle: -90)

    // Subtle top highlight so it doesn't read as flat.
    NSGraphicsContext.current?.saveGraphicsState()
    squircle.setClip()
    let highlight = NSGradient(colors: [
        NSColor(white: 1, alpha: 0.22),
        NSColor(white: 1, alpha: 0.0),
    ])!
    highlight.draw(
        in: NSRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2),
        angle: -90)
    NSGraphicsContext.current?.restoreGraphicsState()

    // The glyph: SF Symbols gives a properly weighted box without hand-drawing.
    let configuration = NSImage.SymbolConfiguration(
        pointSize: size * 0.46, weight: .medium)
    if let symbol = NSImage(systemSymbolName: "shippingbox.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(configuration)
    {
        let tinted = NSImage(size: symbol.size)
        tinted.lockFocus()
        NSColor.white.set()
        NSRect(origin: .zero, size: symbol.size).fill(using: .sourceOver)
        symbol.draw(
            at: .zero, from: .zero, operation: .destinationIn, fraction: 1)
        tinted.unlockFocus()

        let glyphRect = NSRect(
            x: (size - tinted.size.width) / 2,
            y: (size - tinted.size.height) / 2,
            width: tinted.size.width,
            height: tinted.size.height)

        // Slight shadow to lift the glyph off the gradient.
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(white: 0, alpha: 0.28)
        shadow.shadowBlurRadius = size * 0.025
        shadow.shadowOffset = NSSize(width: 0, height: -size * 0.012)
        shadow.set()

        tinted.draw(in: glyphRect, from: .zero, operation: .sourceOver, fraction: 0.97)
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

/// The sizes iconutil expects, as (points, scale) pairs.
let variants: [(point: Int, scale: Int)] = [
    (16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
    (256, 1), (256, 2), (512, 1), (512, 2),
]

for variant in variants {
    let pixels = CGFloat(variant.point * variant.scale)
    let rep = renderIcon(size: pixels)
    guard let data = rep.representation(using: .png, properties: [:]) else { continue }

    let suffix = variant.scale == 1 ? "" : "@\(variant.scale)x"
    let name = "icon_\(variant.point)x\(variant.point)\(suffix).png"
    try data.write(to: iconset.appendingPathComponent(name))
}

// Build the .icns.
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = [
    "-c", "icns", iconset.path,
    "-o", resources.appendingPathComponent("AppIcon.icns").path,
]
try process.run()
process.waitUntilExit()

guard process.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("iconutil failed\n".utf8))
    exit(1)
}

// The .iconset is an intermediate; only the .icns is kept.
try? FileManager.default.removeItem(at: iconset)
print("wrote Resources/AppIcon.icns")
