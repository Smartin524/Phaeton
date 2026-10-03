import AppKit

/// The menu-bar icon: a plain carriage wheel (one rim, a few spokes, a hub) that echoes the app
/// icon. It is a vector template image, so the system tints it for light and dark menu bars.
enum StatusIcon {
    static func make(size: CGFloat = 18, spokes: Int = 8) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let s = rect.width / 18                      // design grid: 18 × 18 points
            let c = CGPoint(x: rect.midX, y: rect.midY)
            NSColor.black.setStroke()
            NSColor.black.setFill()

            let rim = NSBezierPath(ovalIn: CGRect(x: c.x - 7.9 * s, y: c.y - 7.9 * s, width: 15.8 * s, height: 15.8 * s))
            rim.lineWidth = 1.7 * s
            rim.stroke()

            for i in 0..<spokes {
                let angle = CGFloat(i) * 2 * .pi / CGFloat(spokes) + .pi / 2
                let spoke = NSBezierPath()
                spoke.move(to: CGPoint(x: c.x + cos(angle) * 2.2 * s, y: c.y + sin(angle) * 2.2 * s))
                spoke.line(to: CGPoint(x: c.x + cos(angle) * 7.4 * s, y: c.y + sin(angle) * 7.4 * s))
                spoke.lineWidth = 1.15 * s
                spoke.stroke()
            }
            NSBezierPath(ovalIn: CGRect(x: c.x - 2.0 * s, y: c.y - 2.0 * s, width: 4.0 * s, height: 4.0 * s)).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Phaeton"
        return image
    }
}
