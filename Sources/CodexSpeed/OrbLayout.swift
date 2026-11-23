import CoreGraphics

struct OrbLayout: Equatable {
    static let baseDiameter = CGFloat(OrbSettings.defaultSize)
    static let bounds = CGRect(x: 0, y: 0, width: baseDiameter, height: baseDiameter)
    static let center = CGPoint(x: bounds.midX, y: bounds.midY)
    static let parallelBadge = CGRect(x: center.x - 23, y: 88, width: 46, height: 15)

    let diameter: CGFloat
    var scale: CGFloat { diameter / Self.baseDiameter }

    func frame(centeredOn point: CGPoint) -> CGRect {
        CGRect(x: point.x - diameter / 2, y: point.y - diameter / 2, width: diameter, height: diameter)
    }

    func containsParallelBadge(at point: CGPoint) -> Bool {
        Self.parallelBadge.contains(CGPoint(x: point.x / scale, y: point.y / scale))
    }
}
