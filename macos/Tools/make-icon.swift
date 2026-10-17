#!/usr/bin/env swift
// Renders the Promptscope app icon (same artwork as Design/LogoMark.swift):
// brand-gradient squircle with a white scope symbol.
// Usage (from macos/): swift Tools/make-icon.swift
import AppKit
import Foundation

func render(pixels: Int) -> Data? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    else { return nil }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    defer { NSGraphicsContext.restoreGraphicsState() }

    let p = CGFloat(pixels)
    // macOS icon grid: the tile is 824/1024 of the canvas.
    let side = p * 824 / 1024
    let tile = NSRect(x: (p - side) / 2, y: (p - side) / 2, width: side, height: side)
    let path = NSBezierPath(roundedRect: tile, xRadius: side * 0.2237, yRadius: side * 0.2237)

    let shadow = NSShadow()
    shadow.shadowColor = NSColor(white: 0, alpha: 0.35)
    shadow.shadowBlurRadius = p * 0.025
    shadow.shadowOffset = NSSize(width: 0, height: -p * 0.012)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    NSColor(calibratedRed: 0.36, green: 0.36, blue: 0.93, alpha: 1).setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGradient(colors: [
        NSColor(calibratedRed: 0.13, green: 0.77, blue: 0.69, alpha: 1),
        NSColor(calibratedRed: 0.36, green: 0.36, blue: 0.93, alpha: 1),
    ])!.draw(in: path, angle: -45)

    let palette = NSImage.SymbolConfiguration(paletteColors: [.white])
    let config = NSImage.SymbolConfiguration(pointSize: side * 0.52, weight: .regular).applying(palette)
    if let mark = NSImage(systemSymbolName: "scope", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let s = mark.size
        mark.draw(in: NSRect(x: tile.midX - s.width / 2, y: tile.midY - s.height / 2, width: s.width, height: s.height))
    }
    return rep.representation(using: .png, properties: [:])
}

let fm = FileManager.default
let cwd = URL(fileURLWithPath: fm.currentDirectoryPath)
let resources = cwd.appendingPathComponent("Resources")
guard fm.fileExists(atPath: resources.path) else {
    FileHandle.standardError.write(Data("Run from the macos/ directory (Resources/ not found)\n".utf8))
    exit(1)
}

let tmp = fm.temporaryDirectory.appendingPathComponent("promptscope-icon-\(UUID().uuidString)")
let iconset = tmp.appendingPathComponent("AppIcon.iconset")
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: tmp) }

let variants: [(name: String, px: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for variant in variants {
    guard let png = render(pixels: variant.px) else {
        FileHandle.standardError.write(Data("png encode failed\n".utf8))
        exit(1)
    }
    try png.write(to: iconset.appendingPathComponent("\(variant.name).png"))
}

let out = resources.appendingPathComponent("AppIcon.icns")
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("iconutil failed (\(process.terminationStatus))\n".utf8))
    exit(1)
}

let docs = cwd.deletingLastPathComponent().appendingPathComponent("docs", isDirectory: true)
try fm.createDirectory(at: docs, withIntermediateDirectories: true)
if let preview = render(pixels: 256) {
    try preview.write(to: docs.appendingPathComponent("icon.png"))
}
print("Wrote \(out.path)")
