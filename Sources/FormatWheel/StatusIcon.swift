import AppKit

/// The menu-bar icon: a small carriage wheel echoing the app icon. It is drawn as a vector
/// template image, so the system tints it for light and dark menu bars and any size stays sharp.
enum StatusIcon {
    static func make(size: CGFloat = 18) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let s = rect.width / 18                      // design grid: 18 × 18 points
            let c = CGPoint(x: rect.midX, y: rect.midY)
            NSColor.black.setStroke()
            NSColor.black.setFill()

            func ring(_ radius: CGFloat, _ width: CGFloat) {
                let path = NSBezierPath(ovalIn: CGRect(x: c.x - radius * s, y: c.y - radius * s,
                                                       width: radius * 2 * s, height: radius * 2 * s))
                path.lineWidth = width * s
                path.stroke()
            }
            ring(8.2, 1.5)      // the rim
            ring(6.9, 0.6)      // the groove inside it

            // Eight slightly bowed spokes from the hub to the groove.
            for i in 0..<8 {
                let angle = CGFloat(i) * .pi / 4 + .pi / 8
                let along = CGPoint(x: cos(angle), y: sin(angle))
                let across = CGPoint(x: -sin(angle), y: cos(angle))
                func point(_ radius: CGFloat, _ bow: CGFloat) -> CGPoint {
                    CGPoint(x: c.x + (along.x * radius + across.x * bow) * s, y: c.y + (along.y * radius + across.y * bow) * s)
                }
                let spoke = NSBezierPath()
                spoke.move(to: point(3.3, 0))
                spoke.curve(to: point(6.9, 0), controlPoint1: point(4.6, 0.45), controlPoint2: point(5.6, -0.45))
                spoke.lineWidth = 1.15 * s
                spoke.lineCapStyle = .butt
                spoke.stroke()
            }

            ring(3.4, 0.9)      // the hub
            NSBezierPath(ovalIn: CGRect(x: c.x - 1.35 * s, y: c.y - 1.35 * s, width: 2.7 * s, height: 2.7 * s)).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Phaeton"
        return image
    }
}
