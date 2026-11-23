import CoreGraphics

struct OrbLayout: Equatable {
    static let maximumRings = 5
    static let baseDiameter = CGFloat(OrbSettings.defaultSize)
    static let bounds = CGRect(x: 0, y: 0, width: baseDiameter, height: baseDiameter)
    static let center = CGPoint(x: bounds.midX, y: bounds.midY)
    private static let ringSpacing: CGFloat = 5

    let diameter: CGFloat
    var scale: CGFloat { diameter / Self.baseDiameter }

    static func ringRadius(at index: Int) -> CGFloat {
        baseDiameter / 2 - 5 - CGFloat(index) * ringSpacing
    }

    func frame(centeredOn point: CGPoint) -> CGRect {
        CGRect(x: point.x - diameter / 2, y: point.y - diameter / 2, width: diameter, height: diameter)
    }

    func ringIndex(at point: CGPoint, count: Int) -> Int? {
        let distance = hypot(point.x - diameter / 2, point.y - diameter / 2) / scale
        return (0..<count).first { index in
            abs(distance - Self.ringRadius(at: index)) <= Self.ringSpacing / 2
        }
    }
}
