// Original sample pictures for the repo: a drawn scene (no photo, nothing copied from anywhere).
import AppKit
import CoreGraphics

func render(width: Int, height: Int, transparent: Bool, draw: (CGContext, CGSize) -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    draw(context.cgContext, CGSize(width: width, height: height))
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func scene(_ cg: CGContext, _ size: CGSize, background: Bool) {
    if background {
        let colors = [CGColor(red: 0.98, green: 0.80, blue: 0.62, alpha: 1), CGColor(red: 0.85, green: 0.47, blue: 0.34, alpha: 1)]
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1])!
        cg.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size.height), end: CGPoint(x: size.width, y: 0), options: [])
    }
    cg.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.9))
    cg.fillEllipse(in: CGRect(x: size.width * 0.12, y: size.height * 0.18, width: size.height * 0.62, height: size.height * 0.62))
    cg.setFillColor(CGColor(red: 0.36, green: 0.30, blue: 0.94, alpha: 1))
    cg.fill(CGRect(x: size.width * 0.52, y: size.height * 0.28, width: size.height * 0.5, height: size.height * 0.5))
    cg.setFillColor(CGColor(red: 0.13, green: 0.12, blue: 0.20, alpha: 1))
    cg.fillEllipse(in: CGRect(x: size.width * 0.30, y: size.height * 0.40, width: size.height * 0.18, height: size.height * 0.18))
}

let out = URL(fileURLWithPath: CommandLine.arguments[1])
let photo = render(width: 1200, height: 900, transparent: false) { scene($0, $1, background: true) }
try photo.representation(using: .jpeg, properties: [.compressionFactor: 0.9])!.write(to: out.appendingPathComponent("sample.jpg"))
let cutout = render(width: 800, height: 800, transparent: true) { scene($0, $1, background: false) }
try cutout.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent("sample-transparent.png"))
print("ok")
