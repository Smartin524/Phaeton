// Generates Resources/AppIcon.icns from SF Symbols on a transparent canvas: vector system
// symbols, no baked-in background, so the icon reads on both light and dark surfaces.
// usage: swift scripts/make-icon.swift   (needs sips + iconutil, both ship with macOS)
import AppKit

let size = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

func drawSymbol(_ name: String, pointSize: CGFloat, weight: NSFont.Weight, color: NSColor, in rect: NSRect) {
    let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        .applying(NSImage.SymbolConfiguration(hierarchicalColor: color))
    guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(configuration) else {
        fputs("Could not load SF Symbol: \(name)\n", stderr)
        exit(1)
    }
    symbol.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
}

drawSymbol("square.on.circle.fill", pointSize: 560, weight: .medium, color: NSColor(srgbRed: 217.0 / 255, green: 119.0 / 255, blue: 87.0 / 255, alpha: 1),
           in: NSRect(x: 130, y: 130, width: 740, height: 740))
drawSymbol("arrow.triangle.2.circlepath", pointSize: 190, weight: .bold, color: .systemIndigo,
           in: NSRect(x: 640, y: 640, width: 270, height: 270))
NSGraphicsContext.restoreGraphicsState()

let work = FileManager.default.temporaryDirectory.appendingPathComponent("phaeton-icon-\(getpid())")
let iconset = work.appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
let master = work.appendingPathComponent("icon-1024.png")
try rep.representation(using: .png, properties: [:])!.write(to: master)

func run(_ tool: String, _ args: [String]) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = args
    process.standardOutput = FileHandle.nullDevice
    try? process.run(); process.waitUntilExit()
}
for (name, pixels) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                       ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    run("/usr/bin/sips", ["-z", "\(pixels)", "\(pixels)", master.path, "--out", iconset.appendingPathComponent("icon_\(name).png").path])
}
let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Resources/AppIcon.icns")
run("/usr/bin/iconutil", ["-c", "icns", iconset.path, "-o", output.path])
let preview = URL(fileURLWithPath: "Resources/AppIcon-1024.png")
try? FileManager.default.removeItem(at: preview)
try? FileManager.default.copyItem(at: master, to: preview)
try? FileManager.default.removeItem(at: work)
print("Wrote \(output.path)")
