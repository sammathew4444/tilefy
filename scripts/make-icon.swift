#!/usr/bin/env swift
// Draws the app icon: a dwindle layout of tiles on a dark squircle.
// Run from the repo root: swift scripts/make-icon.swift
// Writes Resources/AppIcon.icns and docs/icon.png.
import AppKit

func render(size: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(size) / 1024

    func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
        NSRect(x: x * s, y: y * s, width: w * s, height: h * s)
    }
    func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }

    // Apple's icon grid: an 824pt rounded square, centered, with room for the shadow.
    let body = rect(100, 100, 824, 824)
    let bodyPath = NSBezierPath(roundedRect: body, xRadius: 185 * s, yRadius: 185 * s)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = 28 * s
    shadow.shadowOffset = NSSize(width: 0, height: -12 * s)
    shadow.set()
    color(0x171A2B).setFill()
    bodyPath.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGradient(colors: [color(0x2A2F4F), color(0x12142A)])!.draw(in: bodyPath, angle: -90)

    // Tiles, laid out the way dwindle does: left half, then top right, then the rest spiralling in.
    let outer: CGFloat = 170
    let gap: CGFloat = 26
    let full: CGFloat = 1024 - 2 * outer
    let half = (full - gap) / 2
    let quarter = (half - gap) / 2
    let tiles: [(NSRect, UInt32, UInt32)] = [
        (rect(outer, outer, half, full), 0x7AA2FF, 0x4F6BFF),
        (rect(outer + half + gap, outer + half + gap, half, half), 0xC29BFF, 0x8E63F5),
        (rect(outer + half + gap, outer, quarter, half), 0x5FE3C0, 0x25B99A),
        (rect(outer + half + gap + quarter + gap, outer + quarter + gap, quarter, quarter), 0xFFC37A, 0xF59A3E),
        (rect(outer + half + gap + quarter + gap, outer, quarter, quarter), 0xFF8FA8, 0xF0587C),
    ]
    for (frame, top, bottom) in tiles {
        let path = NSBezierPath(roundedRect: frame, xRadius: 34 * s, yRadius: 34 * s)
        NSGradient(colors: [color(top), color(bottom)])!.draw(in: path, angle: -90)
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let iconset = fm.temporaryDirectory.appendingPathComponent("AppIcon-\(UUID().uuidString).iconset")
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: iconset) }

for base in [16, 32, 128, 256, 512] {
    try render(size: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(size: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try render(size: 512).write(to: URL(fileURLWithPath: "docs/icon.png"))

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try iconutil.run()
iconutil.waitUntilExit()
exit(iconutil.terminationStatus)
