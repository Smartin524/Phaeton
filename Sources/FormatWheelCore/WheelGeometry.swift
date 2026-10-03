import Foundation

/// UI-independent geometry in top-left-origin coordinates, like SwiftUI.
/// Sectors are equal and run clockwise; unrotated, the first one is centered at the top.
/// The pointer starts in a dead zone. Hit-testing has no gaps between sectors; the
/// gap is only drawn.
public struct WheelGeometry {
    public let innerRadius: Double
    public let outerRadius: Double
    public let gapDegrees: Double

    public init(innerRadius: Double = 40, outerRadius: Double = 106,
                gapDegrees: Double = 2) {
        self.innerRadius = innerRadius
        self.outerRadius = outerRadius
        self.gapDegrees = gapDegrees
    }

    public var middleRadius: Double { (innerRadius + outerRadius) / 2 }

    /// Rotation, in degrees, that carries sector `index` to 9 o'clock. Used to pin the wrench to
    /// the same place on every wheel, whatever the number of sectors.
    public func rotation(pinning index: Int, count: Int) -> Double {
        270 - Double(index) * 360 / Double(max(1, count))
    }

    /// Start and end angle in degrees of a sector, measured like SwiftUI (clockwise from +x).
    public func arc(index: Int, count: Int, rotation: Double = 0) -> (start: Double, end: Double) {
        let span = 360 / Double(count)
        let start = -90 - span / 2 + Double(index) * span + rotation
        return (start + gapDegrees / 2, start + span - gapDegrees / 2)
    }

    public func centerAngle(index: Int, count: Int, rotation: Double = 0) -> Double {
        -90 + Double(index) * 360 / Double(count) + rotation
    }

    public func index(atX x: Double, y: Double, count: Int, rotation: Double = 0) -> Int? {
        guard count > 0, x.isFinite, y.isFinite else { return nil }
        let radius = hypot(x, y)
        guard radius >= innerRadius, radius <= outerRadius else { return nil }
        let span = 360 / Double(count)
        var normalized = (atan2(y, x) * 180 / .pi + 90 + span / 2 - rotation).truncatingRemainder(dividingBy: 360)
        if normalized < 0 { normalized += 360 }
        return min(Int(normalized / span), count - 1)
    }

    public func format(atX x: Double, y: Double, in formats: [OutputFormat]) -> OutputFormat? {
        index(atX: x, y: y, count: formats.count).map { formats[$0] }
    }
}
