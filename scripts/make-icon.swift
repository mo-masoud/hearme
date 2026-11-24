// Draws HearMe's app icon (the menu bar waveform on a gradient tile) and writes
// Resources/AppIcon.icns. Run from the repo root: swift scripts/make-icon.swift
import AppKit

let canvas: CGFloat = 1024
// Apple's macOS icon grid: the tile is 824 pt inside a 1024 canvas.
let tileRect = NSRect(x: 100, y: 100, width: 824, height: 824)

func render(size: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let scale = CGFloat(size) / canvas
    NSGraphicsContext.current!.cgContext.scaleBy(x: scale, y: scale)

    // Soft shadow under the tile.
    let tile = NSBezierPath(roundedRect: tileRect, xRadius: 185, yRadius: 185)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = 24
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.set()
    NSColor.black.setFill()
    tile.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Indigo to teal gradient.
    NSGradient(colors: [
        NSColor(srgbRed: 0.20, green: 0.16, blue: 0.55, alpha: 1),
        NSColor(srgbRed: 0.33, green: 0.30, blue: 0.85, alpha: 1),
        NSColor(srgbRed: 0.10, green: 0.70, blue: 0.80, alpha: 1),
    ])!.draw(in: tile, angle: -60)

    // Subtle top highlight.
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.18), NSColor.white.withAlphaComponent(0)])!
        .draw(in: tile, angle: -90)

    // The waveform symbol, white, centered.
    let config = NSImage.SymbolConfiguration(pointSize: 430, weight: .semibold)
        .applying(.init(paletteColors: [.white]))
    if let symbol = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let fit = symbol.size
        let origin = NSPoint(x: tileRect.midX - fit.width / 2, y: tileRect.midY - fit.height / 2)
        symbol.draw(in: NSRect(origin: origin, size: fit))
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconset)
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! render(size: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(size: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try! render(size: 1024).write(to: URL(fileURLWithPath: "docs/app-icon.png"))

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try! iconutil.run()
iconutil.waitUntilExit()
print(iconutil.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns" : "iconutil failed")
