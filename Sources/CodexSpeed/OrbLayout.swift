import AppKit

@MainActor
struct OrbLayout: Equatable {
    private static let offsets: [[CGPoint]] = [
        [],
        [CGPoint(x: 80, y: -16)],
        [CGPoint(x: 74, y: -33), CGPoint(x: 78, y: 33)],
        [CGPoint(x: 74, y: -33), CGPoint(x: 78, y: 33), CGPoint(x: 129, y: -14)],
    ]
    static var maximumSatellites: Int { offsets.count - 1 }

    let scale: CGFloat
    let size: CGSize
    let primary: CGRect
    let satellites: [CGRect]

    init(diameter: CGFloat, satelliteCount: Int = 0, extendsLeft: Bool = true) {
        let scale = diameter / OrbDial.size
        let primary = CGRect(x: -diameter / 2, y: -diameter / 2, width: diameter, height: diameter)
        let radius = 26 * scale
        let direction: CGFloat = extendsLeft ? -1 : 1
        let satellites = Self.offsets[satelliteCount].map { offset in
            CGRect(x: direction * offset.x * scale - radius, y: offset.y * scale - radius,
                   width: radius * 2, height: radius * 2)
        }
        let padding = 6 * scale
        let footprint = satellites.reduce(primary) { $0.union($1.insetBy(dx: -padding, dy: -padding)) }
        self.scale = scale
        size = footprint.size
        self.primary = primary.offsetBy(dx: -footprint.minX, dy: -footprint.minY)
        self.satellites = satellites.map { $0.offsetBy(dx: -footprint.minX, dy: -footprint.minY) }
    }

    func frame(centeredOn point: CGPoint) -> CGRect {
        CGRect(origin: CGPoint(x: point.x - primary.midX, y: point.y + primary.midY - size.height), size: size)
    }

    func satelliteIndex(at point: CGPoint) -> Int? {
        satellites.firstIndex { rect in
            hypot(point.x - rect.midX, point.y - rect.midY) <= rect.width / 2
        }
    }
}
