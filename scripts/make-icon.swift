// Draws FastBG's app icon, the Background family's striped glyph in white on a green squircle, the green of the
// menu bar pill while a call reads the camera, and writes App/AppIcon.icns. Re-run after changing it:
//   swift scripts/make-icon.swift
// With only the Command Line Tools, name an SDK their compiler can use, as dev-build.sh does.
import AppKit
import SwiftUI

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let work = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: work)
try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

/// An 824 pt squircle centred on a 1024 pt canvas, as on Apple's icon grid, with room left for the shadow. The
/// corner is continuous, 26% of the side. That fits the mask macOS 26 puts its own icons in. A circular one looks boxy.
func icon(_ side: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let scale = CGFloat(side) / 1024
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: scale, y: scale)

    let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
    let shape = RoundedRectangle(cornerRadius: 0.26 * tile.width, style: .continuous).path(in: tile).cgPath
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.shadowBlurRadius = 28
    shadow.set()
    ctx.addPath(shape)
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fillPath()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    ctx.addPath(shape)
    ctx.clip()
    NSGradient(starting: NSColor(srgbRed: 0.27, green: 0.86, blue: 0.43, alpha: 1),
               ending: NSColor(srgbRed: 0.10, green: 0.60, blue: 0.29, alpha: 1))!.draw(in: tile, angle: -90)
    // A faint sheen across the top, as Apple's own icons carry.
    NSGradient(starting: NSColor.white.withAlphaComponent(0.18), ending: NSColor.white.withAlphaComponent(0))!
        .draw(in: NSRect(x: tile.minX, y: tile.midY, width: tile.width, height: tile.height / 2), angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    let config = NSImage.SymbolConfiguration(pointSize: 420, weight: .semibold)
        .applying(.init(paletteColors: [.white]))
    if let glyph = NSImage(systemSymbolName: "person.and.background.striped.horizontal", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let size = glyph.size, fit = min(560 / size.width, 560 / size.height)
        let w = size.width * fit, h = size.height * fit
        glyph.draw(in: NSRect(x: 512 - w / 2, y: 512 - h / 2 - 6, width: w, height: h))
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

for (name, side) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                     ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512),
                     ("512x512@2x", 1024)] {
    try icon(side).representation(using: .png, properties: [:])!
        .write(to: work.appendingPathComponent("icon_\(name).png"))
}
let out = root.appendingPathComponent("App/AppIcon.icns")
let make = Process()
make.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
make.arguments = ["-c", "icns", work.path, "-o", out.path]
try make.run()
make.waitUntilExit()
try icon(1024).representation(using: .png, properties: [:])!
    .write(to: root.appendingPathComponent("build/AppIcon-1024.png"))
print(make.terminationStatus == 0 ? "wrote \(out.path)" : "iconutil failed")
